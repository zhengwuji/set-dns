#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
敏感信息审计（提交前跑一次，公开仓库尤其要跑）

设计原则：**本脚本自身不含任何具体凭据字面量**。
曾经犯过这个错：为了"记住那个密码别再提交"而把明文写进检查脚本，
结果检查脚本自己成了唯一携带该凭据的文件（而且它还会被提交）。
所以这里只用**通用形态**匹配 —— 覆盖能力一样，但脚本本身干净。

用法:
  python tests/secret_audit.py            # 审计工作区全部已跟踪文件
  python tests/secret_audit.py --history  # 审计全部 git 历史（逐 commit × 逐文件）
  python tests/secret_audit.py --all      # 上面两项都跑

退出码: 0 = 干净；1 = 发现需人工确认的内容
"""
import os, re, subprocess, sys

# ---- 通用凭据形态（不写任何具体值） ----
PATTERNS = [
    # 1) 硬编码的口令赋值（排除变量插值 / 占位符，见 ALLOW）
    ("硬编码口令", re.compile(
        r'''(?i)\b(password|passwd|pass|pwd|secret|token|apikey|api_key)\s*[:=]\s*["'][^"'$\{\}\s<>]{6,}["']''')),
    # 2) 具体形态的服务器地址
    ("内网/公网 IP", re.compile(
        r'\b(?:10|172\.(?:1[6-9]|2\d|3[01])|192\.168)\.\d{1,3}\.\d{1,3}\b')),
    ("公网 IPv4 字面量", re.compile(
        r'\b(?!0\.|127\.|255\.)(?:\d{1,3}\.){3}\d{1,3}\b')),
    # 3) 各类 token（真实前缀 + 足够长度才可能是真的）
    ("GitHub token", re.compile(r'\b(?:ghp_|gho_|ghs_|ghu_)[A-Za-z0-9]{36}\b')),
    ("GitHub fine-grained", re.compile(r'\bgithub_pat_[A-Za-z0-9_]{60,}\b')),
    ("AWS Access Key", re.compile(r'\bAKIA[0-9A-Z]{16}\b')),
    ("Google API Key", re.compile(r'\bAIza[0-9A-Za-z_\-]{35}\b')),
    ("Slack token", re.compile(r'\bxox[baprs]-[A-Za-z0-9\-]{10,}\b')),
    ("OpenAI key", re.compile(r'\bsk-[A-Za-z0-9]{32,}\b')),
    ("Stripe key", re.compile(r'\b(?:sk|pk)_(?:live|test)_[A-Za-z0-9]{20,}\b')),
    ("私钥实体", re.compile(r'-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----')),
    ("带凭据连接串", re.compile(
        r'(?i)\b(?:postgres|postgresql|mysql|mongodb|redis|amqp|ftp)://[^/\s:@]+:[^/\s@]+@')),
    # 4) 命令行里直接给密码（部署脚本典型）
    ("sshpass -p", re.compile(r'(?i)\bsshpass\s+-\w*\s*-?p\s*\S+')),
    ("pscp/plink -pw", re.compile(r'(?i)\b(?:pscp|plink)\b[^\n]*\s-pw\s+\S+')),
    ("ConvertTo-SecureString 明文", re.compile(
        r'''ConvertTo-SecureString\s+["'][^"']{6,}["']''')),
    ("硬编码 Bearer/token 头", re.compile(
        r'''(?i)Authorization:\s*(?:Bearer|token)\s+[A-Za-z0-9_\-\.]{20,}''')),
]

# ---- 明确安全的例外（避免误报刷屏，误报多了就会被 --no-verify 绕过） ----
ALLOW = [
    # 检查脚本里的"检测模式"本身（正则字面量）
    re.compile(r'''['"]-{5}BEGIN \[A-Z \]\*PRIVATE KEY-{5}['"]'''),
    # sshd_config 的服务端开关
    re.compile(r'''(?i)PasswordAuthentication\s+(?:yes|no)'''),
    # 变量插值 / 环境变量名
    re.compile(r'''(?i)\b(?:password|pass|pwd|secret|token)\s*[:=]\s*["']?\$\{?[A-Za-z_]'''),
    re.compile(r'''\b(?:GH_TOKEN|GITHUB_TOKEN|SET_DNS_GH_TOKEN|GITHUB_PAT)\b'''),
    # 占位符
    re.compile(r'''(?i)\b(?:password|pass|pwd|secret|token)\s*[:=]\s*["'](?:<[^>]*>|x{3,}|your|YOUR|你的|test|TEST|example|EXAMPLE|placeholder|CHANGEME|redacted|REDACTED)'''),
    # 代码里按字段名取值 / JSON 键名
    re.compile(r'''(?i)\.get\(\s*['"](?:password|passwd|secret)['"]'''),
    re.compile(r'''(?i)['"](?:password|passwd|secret|token)['"]\s*:\s*[\[{'"']'''),
    # 文档里的示意地址 + 公共 DNS/测试地址（这些不是凭据）
    re.compile(r'\b(?:192\.0\.2\.\d{1,3}|198\.51\.100\.\d{1,3}|203\.0\.113\.\d{1,3}|'
               r'1\.1\.1\.1|8\.8\.8\.8|9\.9\.9\.9|8\.8\.4\.4|1\.0\.0\.1|208\.67\.222\.\d{1,3}|'
               r'127\.0\.0\.1|0\.0\.0\.0|255\.255\.255\.255)\b'),
    # 版本号/计数形如 x.y.z.w
    re.compile(r'\b\d+\.\d+\.\d+\.\d+\b.*(?:版本|version|v\d|PASS|FAIL)'),
    # 本审计脚本自身：它的 PATTERNS 里就是这些正则字面量
    re.compile(r'''(?i)(?:sshpass|pscp|plink)\b.*re\.compile'''),
    re.compile(r'''(?i)["'](?:硬编码|历史泄露|服务器 IP|主机别名|GitHub token|私钥实体|带凭据连接串)'''),
]


def allowed(line: str) -> bool:
    return any(a.search(line) for a in ALLOW)


def scan(text: str, label: str):
    hits = []
    for i, line in enumerate(text.splitlines(), 1):
        if allowed(line):
            continue
        for name, rx in PATTERNS:
            if rx.search(line):
                hits.append((label, i, name, line.strip()[:150]))
                break
    return hits


def tracked_files():
    out = subprocess.run(['git', 'ls-files'], capture_output=True, text=True).stdout
    return [f for f in out.splitlines() if f and os.path.isfile(f)]


def audit_worktree():
    print("=== 审计工作区已跟踪文件 ===")
    hits = []
    files = tracked_files()
    for f in files:
        try:
            text = open(f, encoding='utf-8', errors='replace').read()
        except Exception:
            continue
        hits += scan(text, f)
    print(f"  扫描 {len(files)} 个文件")
    return hits


def audit_history():
    print("=== 审计全部 git 历史 ===")
    revs = subprocess.run(['git', 'rev-list', '--all'],
                          capture_output=True, text=True).stdout.split()
    hits = []
    n = 0
    for c in revs:
        tree = subprocess.run(['git', 'ls-tree', '-r', '--name-only', c],
                              capture_output=True, text=True).stdout.splitlines()
        for f in tree:
            blob = subprocess.run(['git', 'cat-file', '-p', f'{c}:{f}'],
                                  capture_output=True, text=True,
                                  errors='replace').stdout
            n += 1
            hits += scan(blob, f"{c[:8]}:{f}")
    print(f"  扫描 {len(revs)} 个提交 / {n} 个 (commit,file) 组合")
    return hits


def audit_extras():
    """未跟踪文件、dangling 对象、作者信息、git 配置 —— 这些最容易被漏掉。"""
    print("=== 审计易漏项 ===")
    hits = []

    # 未跟踪 + 被忽略的文件（一旦 git add -f 就会上传）
    for flag in (['--others', '--exclude-standard'],
                 ['--others', '--ignored', '--exclude-standard']):
        out = subprocess.run(['git', 'ls-files'] + flag,
                             capture_output=True, text=True).stdout.splitlines()
        for f in out:
            if not os.path.isfile(f):
                continue
            try:
                text = open(f, encoding='utf-8', errors='replace').read()
            except Exception:
                continue
            h = scan(text, f"未跟踪:{f}")
            if h:
                hits += h
                print(f"    ⚠️  {f} 命中 {len(h)} 处")

    # dangling / unreachable 对象
    fsck = subprocess.run(['git', 'fsck', '--dangling', '--unreachable'],
                          capture_output=True, text=True).stdout
    objs = re.findall(r'(?:dangling|unreachable) (blob|commit) ([0-9a-f]{40})', fsck)
    print(f"    dangling/unreachable 对象: {len(objs)} 个")
    for kind, sha in objs:
        blob = subprocess.run(['git', 'cat-file', '-p', sha], capture_output=True,
                              text=True, errors='replace').stdout
        h = scan(blob, f"悬空:{kind}:{sha[:10]}")
        if h:
            hits += h
            print(f"    ⚠️  悬空 {kind} {sha[:10]} 命中 {len(h)} 处")

    # .git/config 里 remote URL 是否内嵌凭据
    cfg = os.path.join('.git', 'config')
    if os.path.isfile(cfg):
        text = open(cfg, encoding='utf-8', errors='replace').read()
        for line in text.splitlines():
            if 'url' in line and '@' in line and re.search(r'://[^/@]+@', line):
                hits.append(('.git/config', 0, 'URL 内嵌凭据', line.strip()))
                print(f"    ⚠️  remote URL 内嵌凭据")

    # 作者/提交者身份（可能含个人信息）
    ids = subprocess.run(['git', 'log', '--all', '--format=%an <%ae>|%cn <%ce>'],
                         capture_output=True, text=True).stdout.splitlines()
    print("    提交身份:")
    for x in sorted(set(ids)):
        print(f"      {x}")
    return hits


def main():
    args = sys.argv[1:]
    do_all = '--all' in args
    hits = []
    if do_all or '--history' not in args:
        hits += audit_worktree()
        print()
    if do_all or '--history' in args:
        hits += audit_history()
        print()
    if do_all:
        hits += audit_extras()
        print()

    if not hits:
        print("✅ 未发现任何真实凭据")
        return 0

    print(f"⚠️  共 {len(hits)} 处需人工确认：")
    cur = None
    for label, ln, name, text in hits:
        if label != cur:
            print(f"\n  [{label}]")
            cur = label
        print(f"    L{ln}  ({name})  {text}")
    return 1


if __name__ == '__main__':
    sys.exit(main())
