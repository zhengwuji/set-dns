#!/bin/bash
# set-dns v3 真机沙箱验证（loop ext4 冒充 /etc，REAL=0，不碰线上服务）
set -u
PASS=0; FAIL=0
ck(){ if [ "$2" = 0 ]; then echo "  [PASS] $1"; PASS=$((PASS+1)); else echo "  [FAIL] $1"; FAIL=$((FAIL+1)); fi; }
IMG=/tmp/v3/img.ext4
MNT=/tmp/v3/etc
# 被验证的脚本：默认取仓库根目录的 set-dns.sh（本脚本在 tests/ 下）；
# 也可 SRC=/path/to/set-dns.sh bash tests/verify-sandbox.sh 覆盖。
SRC=${SRC:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/set-dns.sh}
[ -f "$SRC" ] || { echo "找不到待测脚本 $SRC（用 SRC=... 指定）"; exit 2; }
CA=${CA:-/etc/ssl/certs/ca-certificates.crt}

echo "===== 0. 准备沙箱 ====="
mkdir -p /tmp/v3
umount "$MNT" 2>/dev/null
rm -rf "$MNT" "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count=96 status=none
mkfs.ext4 -q -F "$IMG" && mkdir -p "$MNT" && mount -o loop "$IMG" "$MNT"
ck "ext4 镜像挂载成功" $?
mkdir -p "$MNT/unbound" "$MNT/systemd/system" "$MNT/apt/apt.conf.d" "$MNT/ssl/certs"
cp -a /etc/unbound/unbound.conf "$MNT/unbound/unbound.conf" 2>/dev/null
# 沙箱基线必须是"干净的原始配置"：若宿主机的 unbound.conf 已被之前的 set-dns 运行
# 改过（带 #[set-dns-old] 标记或 set-dns upstream 块），直接照抄会让第 8 段的
# "restore 后不应再有标记" 断言失真。这里先还原成未改动的样子。
if [ -f "$MNT/unbound/unbound.conf" ]; then
  sed -i 's/^#\[set-dns-old\] //' "$MNT/unbound/unbound.conf"
  sed -i '/^# >>> set-dns upstream begin/,/^# <<< set-dns upstream end/d' "$MNT/unbound/unbound.conf"
  sed -i '/^# set-dns: TLS 证书链/d' "$MNT/unbound/unbound.conf"
  # 上面删块会留下孤立的 server: 头，补一个干净的原始 forward-zone
  if ! grep -qE '^[[:space:]]*forward-zone:' "$MNT/unbound/unbound.conf"; then
    printf 'forward-zone:\n    name: "."\n    forward-addr: 1.1.1.1\n    forward-addr: 8.8.8.8\n    forward-addr: 9.9.9.9\n    forward-first: no\n' >> "$MNT/unbound/unbound.conf"
  fi
  grep -q 'set-dns' "$MNT/unbound/unbound.conf" && echo "  [WARN] 沙箱基线仍含 set-dns 痕迹" || echo "  [ OK ] 沙箱 unbound 基线干净（无 set-dns 痕迹）"
fi
cp -a "$CA" "$MNT/ssl/certs/ca-certificates.crt" 2>/dev/null
# 造真实故障态：符号链接指向死 stub
# 注意：链接是相对的 ../run/... ，从 $MNT(/tmp/v3/etc) 解析出来是 /tmp/v3/run/...
#       目标必须建在 /tmp/v3/run 下，建在 $MNT/run 下会变成断链（上一轮就是这个测试脚本 bug）
mkdir -p /tmp/v3/run/systemd/resolve
printf 'nameserver 127.0.0.53\noptions edns0 trust-ad\nsearch lan\n' > /tmp/v3/run/systemd/resolve/stub-resolv.conf
ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/resolv.conf"
ck "沙箱初始为坏符号链接态 -> $(readlink "$MNT/resolv.conf")" 0
[ -r "$MNT/resolv.conf" ] && ck "沙箱链接目标可读" 0 || ck "沙箱链接目标可读" 1

EX(){ SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_LOG="$MNT/dns-watch.log" \
      bash "$SRC" "$@" 2>&1; }

echo
echo "===== 1. 明文模式（v2 回归）====="
out=$(EX --plain); rc=$?
echo "$out" | grep -qE '写入完成' && ck "明文写入完成" 0 || ck "明文写入完成" 1
[ -f "$MNT/resolv.conf" ] && [ ! -L "$MNT/resolv.conf" ] && ck "resolv.conf 已变普通文件" 0 || ck "resolv.conf 已变普通文件" 1
grep -q 'nameserver 1.1.1.1' "$MNT/resolv.conf" && ck "含 1.1.1.1" 0 || ck "含 1.1.1.1" 1
grep -q 'mode=plain' "$MNT/resolv.conf" && ck "标记 mode=plain" 0 || ck "标记 mode=plain" 1
[ -s "$MNT/set-dns.bak/resolv.conf.orig" ] && ck "备份非空（含原 stub 内容）" 0 || ck "备份非空" 1
grep -q '127.0.0.53' "$MNT/set-dns.bak/resolv.conf.orig" && ck "备份保真（含 127.0.0.53）" 0 || ck "备份保真" 1

echo
echo "===== 2. --check 在明文模式下 ====="
out=$(EX --check); rc=$?
echo "$out" | grep -q '当前模式: 明文 DNS' && ck "--check 识别明文模式" 0 || ck "--check 识别明文模式" 1
echo "$out" | grep -q '结论：正常' && ck "--check 结论正常" 0 || ck "--check 结论正常" 1

echo
echo "===== 3. DoT 模式：关键 — 重复 forward-zone 必须被消除 ====="
out=$(EX --dot); rc=$?
echo "$out" | grep -q 'unbound 配置校验通过' && ck "unbound-checkconf 通过" 0 || { ck "unbound-checkconf 通过" 1; echo "$out" | tail -12 | sed 's/^/     /'; }
grep -q 'set-dns upstream begin' "$MNT/unbound/unbound.conf" && ck "已插入 set-dns 上游块" 0 || ck "已插入 set-dns 上游块" 1
grep -q 'forward-tls-upstream: yes' "$MNT/unbound/unbound.conf" && ck "含 forward-tls-upstream: yes" 0 || ck "含 forward-tls-upstream: yes" 1
grep -qE 'forward-addr: 1\.1\.1\.1@853#cloudflare-dns\.com' "$MNT/unbound/unbound.conf" && ck "含 DoT 上游 cloudflare" 0 || ck "含 DoT 上游 cloudflare" 1
# 原来的 forward-zone 必须已被注释，否则 unbound 会 duplicate 丢弃
act=$(grep -cE '^[[:space:]]*forward-zone:' "$MNT/unbound/unbound.conf")
ck "生效的 forward-zone 恰好 1 个（实际 $act）" $([ "$act" = 1 ] && echo 0 || echo 1)
# 直接让 unbound 自己判定是否还有 duplicate 警告
unbound-checkconf "$MNT/unbound/unbound.conf" 2>&1 | grep -qi 'duplicate' && ck "无 duplicate forward zone 警告" 1 || ck "无 duplicate forward zone 警告" 0
# 注意：成功时输出 "no errors in ..."，用 grep -qi error 会误判，必须匹配具体错误形式
cc=$(unbound-checkconf "$MNT/unbound/unbound.conf" 2>&1)
echo "$cc" | grep -qiE '^(fatal )?error:|error: ' && { ck "checkconf 无真实报错" 1; echo "     $cc"; } || ck "checkconf 无真实报错" 0
grep -q 'mode=dot' "$MNT/resolv.conf" && ck "resolv.conf 标记 mode=dot" 0 || ck "resolv.conf 标记 mode=dot" 1
head -3 "$MNT/resolv.conf" | grep -q 'nameserver 127.0.0.1' && ck "加密模式首条是 127.0.0.1" 0 || ck "加密模式首条是 127.0.0.1" 1
grep -q 'nameserver 1.1.1.1' "$MNT/resolv.conf" && ck "含明文兜底 1.1.1.1" 0 || ck "含明文兜底 1.1.1.1" 1
grep -q '@MODE@' "$MNT/sbin/dns-watch.sh" && ck "守护模板变量已展开" 1 || ck "守护模板变量已展开" 0
grep -q "MODE=dot" "$MNT/sbin/dns-watch.sh" && ck "守护记录了 dot 模式" 0 || ck "守护记录了 dot 模式" 1

echo
echo "===== 4. --check 在 DoT 模式下 ====="
out=$(EX --check)
echo "$out" | grep -q '当前模式: DoT 加密' && ck "--check 识别 DoT" 0 || ck "--check 识别 DoT" 1
echo "$out" | grep -q '上游方式: DoT' && ck "--check 报告 DoT 上游" 0 || ck "--check 报告 DoT 上游" 1
echo "$out" | grep -q '127.0.0.1（本地加密栈）' && ck "--check 检查本地加密栈" 0 || ck "--check 检查本地加密栈" 1

echo
echo "===== 5. 切到 DoH 模式（dnscrypt-proxy 配置生成）====="
out=$(EX --doh); rc=$?
echo "$out" | grep -qE '已写 .*dnscrypt-proxy.toml' && ck "DoH 配置已生成" 0 || { ck "DoH 配置已生成" 1; echo "$out" | tail -10 | sed 's/^/     /'; }
D=$MNT/dnscrypt-proxy/dnscrypt-proxy.toml
[ -f "$D" ] && ck "toml 存在" 0 || ck "toml 存在" 1
grep -q "listen_addresses = \['127.0.0.1:5353'\]" "$D" && ck "只监听 127.0.0.1:5353（不抢 53）" 0 || ck "只监听 5353" 1
grep -q 'doh_servers = true' "$D" && ck "启用 DoH" 0 || ck "启用 DoH" 1
grep -q 'dnscrypt_servers = false' "$D" && ck "关闭明文 dnscrypt" 0 || ck "关闭明文 dnscrypt" 1
grep -q "server_names = \['cloudflare', 'google'\]" "$D" && ck "服务器名正确" 0 || { ck "服务器名正确" 1; grep server_names "$D" | sed 's/^/     /'; }
grep -q 'minisign_key' "$D" && ck "含 sources minisign_key" 0 || ck "含 minisign_key" 1
grep -qE "forward-addr: 127\.0\.0\.1@5353" "$MNT/unbound/unbound.conf" && ck "unbound 已指向本地 DoH" 0 || ck "unbound 已指向本地 DoH" 1
act=$(grep -cE '^[[:space:]]*forward-zone:' "$MNT/unbound/unbound.conf")
ck "DoH 下仍只有 1 个生效 forward-zone（实际 $act）" $([ "$act" = 1 ] && echo 0 || echo 1)
unbound-checkconf "$MNT/unbound/unbound.conf" >/dev/null 2>&1 && ck "DoH 配置 checkconf 通过" 0 || ck "DoH 配置 checkconf 通过" 1
out=$(EX --check)
echo "$out" | grep -q '当前模式: DoH 加密' && ck "--check 识别 DoH" 0 || ck "--check 识别 DoH" 1
echo "$out" | grep -q '上游方式: DoH' && ck "--check 报告 DoH 上游" 0 || ck "--check 报告 DoH 上游" 1

echo
echo "===== 6. 反复切换模式不污染配置（幂等）====="
EX --dot >/dev/null 2>&1; EX --doh >/dev/null 2>&1; EX --dot >/dev/null 2>&1
n=$(grep -c 'set-dns upstream begin' "$MNT/unbound/unbound.conf")
ck "上游块只有 1 个（实际 $n，不能累积）" $([ "$n" = 1 ] && echo 0 || echo 1)
act=$(grep -cE '^[[:space:]]*forward-zone:' "$MNT/unbound/unbound.conf")
ck "反复切换后生效 forward-zone 仍为 1（实际 $act）" $([ "$act" = 1 ] && echo 0 || echo 1)
unbound-checkconf "$MNT/unbound/unbound.conf" >/dev/null 2>&1 && ck "反复切换后配置仍合法" 0 || ck "反复切换后配置仍合法" 1

echo
echo "===== 7. SET_DNS_NO_FALLBACK=1 ====="
SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_LOG="$MNT/dns-watch.log" \
  SET_DNS_NO_FALLBACK=1 SET_DNS_MODE=doh bash "$SRC" >/dev/null 2>&1
grep -q 'nameserver 1.1.1.1' "$MNT/resolv.conf" && ck "无兜底时不应含 1.1.1.1（实际残留）" 1 || ck "无兜底时不写明文解析器" 0
grep -c 'nameserver' "$MNT/resolv.conf" | { read c; [ "$c" = 1 ] && ck "只有 127.0.0.1 一条" 0 || { ck "只有一条 nameserver（实际 $c）" 1; sed 's/^/     /' "$MNT/resolv.conf"; }; }

echo
echo "===== 8. --restore 还原 + 配置回滚 ====="
EX --restore >/dev/null 2>&1
[ -L "$MNT/resolv.conf" ] && [ "$(readlink "$MNT/resolv.conf")" = "../run/systemd/resolve/stub-resolv.conf" ] \
  && ck "resolv.conf 还原为原符号链接" 0 || ck "resolv.conf 还原为原符号链接" 1
grep -q '127.0.0.53' "$MNT/resolv.conf" 2>/dev/null && ck "还原后内容为原 stub" 0 || ck "还原后内容为原 stub" 1
grep -q 'set-dns-old' "$MNT/unbound/unbound.conf" && ck "unbound 配置已回滚（恢复 old 行）" 1 || ck "unbound 原配置已还原" 0
grep -qE '^[[:space:]]*forward-addr: 9\.9\.9\.9' "$MNT/unbound/unbound.conf" && ck "原有 9.9.9.9 上游已恢复" 0 || ck "原有 9.9.9.9 上游已恢复" 1
[ -f "$MNT/set-dns.bak/mode" ] && ck "mode 记录应已删除" 1 || ck "mode 记录已删除" 0

echo
echo "===== 9. --dry-run 零改动 ====="
before=$(cd "$MNT" && find . -type f | sort | xargs md5sum 2>/dev/null | md5sum)
SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_LOG="$MNT/dns-watch.log" bash "$SRC" --dot --dry-run >/dev/null 2>&1
after=$(cd "$MNT" && find . -type f | sort | xargs md5sum 2>/dev/null | md5sum)
[ "$before" = "$after" ] && ck "dry-run 未改动任何文件" 0 || ck "dry-run 未改动任何文件" 1

echo
echo "===== 10. 参数校验与菜单非交互 ====="
out=$(SET_DNS_ETC="$MNT" bash "$SRC" --bogus 2>&1); [ $? = 2 ] && ck "未知参数退 2" 0 || ck "未知参数退 2" 1
out=$(SET_DNS_ETC="$MNT" bash "$SRC" --help 2>&1); echo "$out" | grep -q 'set-dns v3.0' && ck "--help 输出用法" 0 || ck "--help 输出用法" 1
out=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" bash "$SRC" < /dev/null 2>&1)
echo "$out" | grep -q '非交互环境' && ck "非交互时自动降级为明文" 0 || ck "非交互时自动降级为明文" 1
echo "$out" | grep -q '模式: 明文 DNS' && ck "非交互默认明文" 0 || ck "非交互默认明文" 1

echo
echo "===== 11. 交互菜单（用 pty 模拟真实终端）====="
if command -v script >/dev/null 2>&1; then
  for choice in 1 2 3; do
    printf '%s\n' "$choice" | timeout 90 script -qec "SET_DNS_ETC=$MNT SET_DNS_SBIN=$MNT/sbin SET_DNS_LOG=$MNT/dns-watch.log bash $SRC" /dev/null > /tmp/v3/menu-$choice.txt 2>&1
    want=$(case $choice in 1) echo '明文 DNS';; 2) echo 'DoT 加密';; 3) echo 'DoH 加密';; esac)
    grep -q "模式: $want" /tmp/v3/menu-$choice.txt && ck "菜单选 $choice -> $want" 0 || { ck "菜单选 $choice -> $want" 1; tail -4 /tmp/v3/menu-$choice.txt | sed 's/^/     /'; }
  done
  grep -q '请选择 DNS 模式' /tmp/v3/menu-1.txt && ck "菜单有提示文字" 0 || ck "菜单有提示文字" 1
  printf '\n' | timeout 90 script -qec "SET_DNS_ETC=$MNT SET_DNS_SBIN=$MNT/sbin bash $SRC" /dev/null > /tmp/v3/menu-enter.txt 2>&1
  grep -q '模式: 明文 DNS' /tmp/v3/menu-enter.txt && ck "回车默认选 1" 0 || ck "回车默认选 1" 1
else echo "  [跳过] 无 script 命令"; fi

echo
echo "===== 12. 空备份时 --restore 必须失败 ====="
rm -rf "$MNT/set-dns.bak"
out=$(EX --restore 2>&1); rc=$?
[ "$rc" != 0 ] && ck "空备份 --restore 退非 0" 0 || ck "空备份 --restore 退非 0" 1
echo "$out" | grep -q '无可用备份' && ck "给出明确提示" 0 || ck "给出明确提示" 1

echo
echo "===== 13. 断链符号链接（目标不存在）也要有序处理 ====="
rm -f "$MNT/resolv.conf"; rm -rf "$MNT/set-dns.bak"
rm -rf /tmp/v3/run    # 目标必须真的不存在，否则不是断链（上一轮就是这个测试脚本 bug）
ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/resolv.conf"   # 目标已删 -> 断链
[ -L "$MNT/resolv.conf" ] && [ ! -e "$MNT/resolv.conf" ] && ck "构造出断链符号链接" 0 || ck "构造出断链符号链接" 1
out=$(EX --plain 2>&1)
echo "$out" | grep -q '断链符号链接' && ck "识别并告警断链情形" 0 || ck "识别并告警断链情形" 1
[ -s "$MNT/set-dns.bak/resolv.conf.orig" ] && ck "断链时备份仍非空（写入说明而非空文件）" 0 || ck "断链时备份仍非空" 1
grep -q '断链符号链接' "$MNT/set-dns.bak/resolv.conf.orig" 2>/dev/null && ck "备份记录了原链接目标" 0 || ck "备份记录了原链接目标" 1
EX --restore >/dev/null 2>&1
[ -L "$MNT/resolv.conf" ] && ck "还原回符号链接形态" 0 || ck "还原回符号链接形态" 1

echo
echo "===== 14. 旧版守护（dns-guard.py / dns-guard.*）必须被识别并退役 ====="
mkdir -p "$MNT/systemd/system" "$MNT/sbin"
printf '[Unit]\nDescription=old\n' > "$MNT/systemd/system/dns-guard.path"
printf '[Unit]\nDescription=old\n' > "$MNT/systemd/system/dns-guard.timer"
printf '#!/usr/bin/env python3\n# legacy\n' > "$MNT/sbin/dns-guard.py"
out=$(EX --guard 2>&1)
echo "$out" | grep -q '检测到旧版守护' && ck "识别出旧版守护" 0 || { ck "识别出旧版守护" 1; echo "$out" | tail -8 | sed 's/^/     /'; }
echo "$out" | grep -q '沙箱模式：跳过旧守护退役' && ck "沙箱内不真删（安全）" 0 || ck "沙箱内不真删（安全）" 1
[ -e "$MNT/systemd/system/dns-guard.path" ] && ck "沙箱内旧单元文件保留" 0 || ck "沙箱内旧单元文件保留" 1
# 无旧守护时不应误报
rm -f "$MNT/systemd/system/dns-guard.path" "$MNT/systemd/system/dns-guard.timer" "$MNT/sbin/dns-guard.py"
out=$(EX --guard 2>&1)
echo "$out" | grep -q '检测到旧版守护' && ck "无旧守护时不误报" 1 || ck "无旧守护时不误报" 0

echo
umount "$MNT" 2>/dev/null
rm -rf "$MNT" "$IMG" /tmp/v3/menu-*.txt   # 注意别删 /tmp/v3 本身，否则下次还得重传脚本
echo "=== V3_DONE PASS=$PASS FAIL=$FAIL ==="
