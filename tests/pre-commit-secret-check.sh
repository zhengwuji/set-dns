#!/bin/bash
# ============================================================
#  提交前敏感信息检查（本地 git hook）
#
#  为什么需要它：本项目曾经把含服务器地址与密码的部署辅助脚本
#  （_ssh.ps1）误提交并推到公开仓库。虽然发现后用 amend + force-push
#  把分支引用改掉了，但 GitHub 上的不可达对象**在一段时间内仍可按
#  commit SHA 直接读到**（实测 raw 地址返回 200 并给出明文密码）。
#  也就是说「先推上去再删」是不可逆的泄露，唯一可靠的办法是**推之前拦住**。
#
#  安装（在本仓库根目录执行一次即可）：
#      cp tests/pre-commit-secret-check.sh .git/hooks/pre-commit
#      chmod +x .git/hooks/pre-commit
#
#  手动检查全部已跟踪文件：
#      bash tests/pre-commit-secret-check.sh --all
#
#  退出码：0 = 干净；1 = 发现敏感信息（提交会被拒绝）
# ============================================================
set -uo pipefail

# 高置信度模式：命中即拦。
# 注意不要写得太宽（比如把所有 `password = "xxx"` 都算上）—— 误报多了就会被 --no-verify 绕过，
# 反而失去意义。这里只放"一旦出现几乎必定是泄露"的形态。
PATTERNS=(
  # 私钥 / 证书
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'ssh-rsa AAAA'
  'ssh-ed25519 AAAA'
  # 各类 token
  'ghp_[A-Za-z0-9]{36}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'AKIA[0-9A-Z]{16}'
  'AIza[0-9A-Za-z_-]{35}'
  # 凭据赋值（部署脚本的典型形态）。
  # 注意这里**不写任何具体密码字面量** —— 曾经犯过这个错：为了"记住这个密码别再提交"
  # 而把明文写进本检查脚本，结果检查脚本自己成了唯一携带该凭据的文件。
  # 通用模式已经覆盖这种形态，不需要具体值。
  '[Pp]assword[[:space:]]*=[[:space:]]*"[^"$]{4,}"'
  '[Pp]asswd[[:space:]]*=[[:space:]]*"[^"$]{4,}"'
  '[Pp]ass[[:space:]]*=[[:space:]]*"[^"$]{4,}"'
  # 常见凭据文件名/字段（部署脚本里出现多半要留意）
  '(secret|token|api[_-]?key)[[:space:]]*=[[:space:]]*"[^"$]{8,}"'
)

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
[ -t 1 ] || { RED=''; GRN=''; YEL=''; RST=''; }

# 这些是仓库里本来就有的、明确安全的文件（例如测试脚本里演示用的假值）
ALLOWLIST_RE='^(tests/verify-.*\.sh|\.gitignore|tests/pre-commit-secret-check\.sh)$'

collect_files() {
  if [ "${1:-}" = "--all" ]; then
    git ls-files -z
  else
    # 默认只检查本次暂存的内容（快，且正是要提交的东西）
    git diff --cached --name-only --diff-filter=ACM -z
  fi
}

fail=0
while IFS= read -r -d '' f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  # 只查文本文件（二进制里出现随机字节会误报）
  case "$(file -b --mime-encoding "$f" 2>/dev/null)" in
    binary) continue ;;
  esac
  printf '%s' "$f" | grep -qE "$ALLOWLIST_RE" && continue

  for p in "${PATTERNS[@]}"; do
    hit=$(grep -nE -- "$p" "$f" 2>/dev/null | head -3)
    if [ -n "$hit" ]; then
      fail=1
      printf '%s[敏感信息]%s %s\n' "$RED" "$RST" "$f"
      printf '%s\n' "$hit" | sed 's/^/    /'
    fi
  done
done < <(collect_files "${1:-}")

if [ "$fail" = 0 ]; then
  printf '%s[ OK ]%s 未发现敏感信息\n' "$GRN" "$RST"
  exit 0
fi

cat <<EOF

${RED}提交已被拒绝${RST} —— 上面的文件里有疑似凭据。

处置建议：
  1. 把该文件加入 .gitignore，并从暂存区移除：git rm --cached <文件>
  2. 如果凭据是真的，${YEL}先换掉它${RST} —— 只要推上去过一次，
     GitHub 上的不可达对象在一段时间内仍可按 commit SHA 读到，
     改分支引用（amend / force-push）清不掉已经发生的泄露。
  3. 确认是误报（例如测试用的假值）时，把它加进本脚本的 ALLOWLIST_RE。

确实要跳过检查（不推荐）：git commit --no-verify
EOF
exit 1
