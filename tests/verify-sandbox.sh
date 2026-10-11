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
      SET_DNS_ZZ_NO_UPDATE=1 \
      bash "$SRC" "$@" 2>&1; }

# 判档位测试要用假 cpuinfo（真机 /proc/cpuinfo 只有一份，没法覆盖各种 CPU）
EXK(){ # $1=cpuinfo 路径，其余同 EX。SET_DNS_LDSO 指向不存在的文件以关掉 glibc 探测，
       # 否则真机 glibc 会按真实 CPU 返回档位，假 cpuinfo 就白造了
      local ci=$1; shift
      SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_LOG="$MNT/dns-watch.log" \
      SET_DNS_ZZ_NO_UPDATE=1 \
      SET_DNS_CPUINFO="$ci" SET_DNS_LDSO=/nonexistent-ld.so \
      SET_DNS_RUNNING_KERNEL=none bash "$SRC" "$@" 2>&1; }
# 注：SET_DNS_ZZ_NO_UPDATE=1 关掉 zz 入口脚本的自动更新联网检查 —— 本文件要可重复、不依赖
# 网络；自动更新本身（"每次调用都查"、防降级、失败冷却）在 tests/verify-zz.sh 里单独验。
# 造一份只含指定 flags 的 cpuinfo
fake_cpu(){ # $1=输出文件 $2=flags
  printf 'processor\t: 0\nvendor_id\t: GenuineIntel\nmodel name\t: Intel(R) Xeon(R) CPU E5-2699 v4 @ 2.20GHz\nflags\t\t: %s\n' "$2" > "$1"
}
# 从 --kernel 面板里抠出档位
lvl_of(){ sed -n 's/.*CPU 微架构档位： *\([x0-9a-z]*\).*/\1/p' | head -1; }

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
out=$(SET_DNS_ETC="$MNT" bash "$SRC" --help 2>&1); echo "$out" | grep -q 'set-dns v3.10' && ck "--help 输出用法" 0 || ck "--help 输出用法" 1
echo "$out" | grep -q 'wget -qO-' && ck "--help 含 wget 一键写法" 0 || ck "--help 含 wget 一键写法" 1
echo "$out" | grep -q -- '--unguard' && ck "--help 含 --unguard" 0 || ck "--help 含 --unguard" 1
echo "$out" | grep -q -- '--sysinfo' && ck "--help 含 --sysinfo" 0 || ck "--help 含 --sysinfo" 1
echo "$out" | grep -q -- '--tools' && ck "--help 含 --tools" 0 || ck "--help 含 --tools" 1
echo "$out" | grep -q '7) 基础工具安装' && ck "--help 含菜单 7" 0 || ck "--help 含菜单 7" 1
echo "$out" | grep -q -- '--mirror' && ck "--help 含 --mirror" 0 || ck "--help 含 --mirror" 1
echo "$out" | grep -q -- '--mirror-restore' && ck "--help 含 --mirror-restore" 0 || ck "--help 含 --mirror-restore" 1
echo "$out" | grep -q '8) 自动换源' && ck "--help 含菜单 8" 0 || ck "--help 含菜单 8" 1
echo "$out" | grep -q -- '--ssh-port=' && ck "--help 含 --ssh-port=" 0 || ck "--help 含 --ssh-port=" 1
echo "$out" | grep -q -- '--ssh-port-restore' && ck "--help 含 --ssh-port-restore" 0 || ck "--help 含 --ssh-port-restore" 1
echo "$out" | grep -q '9) 自定义 SSH 端口' && ck "--help 含菜单 9" 0 || ck "--help 含菜单 9" 1
echo "$out" | grep -q -- '--kernel-update' && ck "--help 含 --kernel-update" 0 || ck "--help 含 --kernel-update" 1
echo "$out" | grep -q -- '--kernel-remove' && ck "--help 含 --kernel-remove" 0 || ck "--help 含 --kernel-remove" 1
echo "$out" | grep -q '10) 内核管理' && ck "--help 含菜单 10" 0 || ck "--help 含菜单 10" 1
echo "$out" | grep -q 'SET_DNS_KERNEL_LEVEL' && ck "--help 含 SET_DNS_KERNEL_LEVEL" 0 || ck "--help 含 SET_DNS_KERNEL_LEVEL" 1
# 6) 系统信息查询：纯只读，必须不写任何文件
out=$(SET_DNS_SYSINFO_NO_NET=1 SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" bash "$SRC" --sysinfo 2>&1)
echo "$out" | grep -q '系统信息查询' && ck "--sysinfo 打印面板" 0 || ck "--sysinfo 打印面板" 1
echo "$out" | grep -qE '主机名:|CPU占用:|物理内存:|运行时长:' && ck "--sysinfo 关键字段齐全" 0 || ck "--sysinfo 关键字段齐全" 1
out6=$(SET_DNS_SYSINFO_NO_NET=1 SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" bash "$SRC" 6 2>&1)
echo "$out6" | grep -q '系统信息查询' && ck "参数 6 -> 系统信息" 0 || ck "参数 6 -> 系统信息" 1

# 7) 基础工具：沙箱里 REAL=0，绝不能真的装包，也不能碰 resolv.conf
sum_before=$(md5sum "$MNT/resolv.conf" | cut -d' ' -f1)
out7=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_TOOLS_ALL=1 bash "$SRC" --tools 2>&1)
echo "$out7" | grep -q '基础工具' && ck "--tools 打印面板" 0 || ck "--tools 打印面板" 1
echo "$out7" | grep -qE 'curl|wget|vim|git' && ck "--tools 面板含 curl/wget/vim/git" 0 || ck "--tools 面板含 curl/wget/vim/git" 1
echo "$out7" | grep -qE '✓|✗' && ck "--tools 有安装状态标记" 0 || ck "--tools 有安装状态标记" 1
# 真机上的沙箱：REAL=0 时必须走「跳过安装」；若本机恰好啥都不缺就落到「全都装好了」分支，
# 两条都算通过 —— 关键是不许真装包。
echo "$out7" | grep -qE '沙箱模式：跳过安装|全都装好了|核心工具都齐了' && ck "--tools 沙箱不真装包" 0 || ck "--tools 沙箱不真装包" 1
[ "$(md5sum "$MNT/resolv.conf" | cut -d' ' -f1)" = "$sum_before" ] && ck "--tools 不动 resolv.conf" 0 || ck "--tools 不动 resolv.conf" 1
out7b=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_TOOLS_ALL=1 bash "$SRC" 7 2>&1)
echo "$out7b" | grep -q '基础工具' && ck "参数 7 -> 基础工具" 0 || ck "参数 7 -> 基础工具" 1
out7c=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_TOOLS_ALL=1 bash "$SRC" --tools-all 2>&1)
echo "$out7c" | grep -q '基础工具' && ck "--tools-all 也可用" 0 || ck "--tools-all 也可用" 1

# --- 回归：装了却报「未安装」---
# Debian 把 sl / bastet / ninvaders / nsnake 装在 /usr/games，而 root 的 PATH 来自
# login.defs 的 ENV_SUPATH（不含 /usr/games）。旧代码只用 `command -v` 判断，于是
# apt 明明装成功（日志里 Setting up bastet ...），面板还是报未安装、末尾还说「还剩 4 个」。
# 不变式：只要包管理器认为这个包装好了，面板就不许显示「未安装」。
awk '/^tools_catalog\(\)/,/^TEOF/' "$SRC" | grep -E '^[a-z]' | grep '|' > /tmp/v3/cat.txt
cat_n=$(wc -l < /tmp/v3/cat.txt)
[ "$cat_n" -gt 10 ] && ck "能解析出工具清单（$cat_n 项）" 0 || ck "能解析出工具清单" 1
# 判据 1：源码必须显式补上 /usr/games，否则这个 bug 必然复发
grep -q '/usr/games' "$SRC" && ck "检测时补上 /usr/games（修 PATH 盲区）" 0 || ck "检测时补上 /usr/games（修 PATH 盲区）" 1
grep -q 'tool_present()' "$SRC" && ck "有统一的 tool_present 判据" 0 || ck "有统一的 tool_present 判据" 1
# 判据 2：tools 相关代码里不许再出现裸 command -v 做安装判断
# 注意 grep -c 在 0 匹配时输出 "0" 且退出码为 1，直接接 || echo 0 会拼出两行 "0"（踩过）
n_raw=$(grep -c 'command -v "\${T_CHK' "$SRC" 2>/dev/null || true)
n_raw=$(printf '%s' "$n_raw" | head -1)
[ "${n_raw:-0}" = 0 ] && ck "工具检测不再用裸 command -v（${n_raw:-0} 处）" 0 || ck "工具检测不再用裸 command -v（${n_raw:-0} 处）" 1
# 判据 3：逐项对账 —— dpkg 说装了，面板就必须说已安装
mismatch=0
while IFS='|' read -r disp chk pkg core; do
  [ -n "$disp" ] || continue
  if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
    # 面板里该工具那一格，后面应跟「已安装」
    if echo "$out7" | grep -qE "[✓✗] $disp[[:space:]]+未安装"; then
      mismatch=$((mismatch + 1)); echo "     对账失败: $disp（包 $pkg 已装，面板却说未安装）"
    fi
  fi
done < /tmp/v3/cat.txt
[ "$mismatch" = 0 ] && ck "dpkg 已装的都显示已安装（0 处矛盾）" 0 || ck "dpkg 已装的都显示已安装（$mismatch 处矛盾）" 1

# 判据 4：直接单元测 tool_present 的 dpkg 回退分支 ——
# 命令名故意不存在，但包已安装，此时必须判为「已安装」。
# 这正是 sl / bastet 那批包的处境：二进制在 PATH 之外，只有包数据库知道它在。
#
# 抽函数出来跑：只取 tools_catalog 与 tool_present 两个定义，避免执行整个脚本。
sed -n '/^tool_present()/,/^}/p' "$SRC" > /tmp/v3/tp.sh
[ -s /tmp/v3/tp.sh ] && ck "抽出 tool_present 函数体" 0 || ck "抽出 tool_present 函数体" 1
if command -v dpkg >/dev/null 2>&1; then
  # 找个确实已安装的包来测（bash 必然在）。ck 约定 0 = PASS，所以判据成功时报 0。
  tp_installed=$( ( . /tmp/v3/tp.sh; tool_present __no_such_cmd__ bash ) && echo 0 || echo 1 )
  ck "已装包走 dpkg 回退分支（命令名不存在也认）" $tp_installed
  # 没装的包必须仍判「未安装」—— 这里要的是 tool_present 失败，所以失败才算 PASS。
  tp_missing=$( ( . /tmp/v3/tp.sh; tool_present __no_such_cmd__ __no_such_pkg_xyz__ ) && echo 1 || echo 0 )
  ck "没装的包仍判未安装（不误报）" $tp_missing
  # /usr/games 里的命令即使不在 PATH 也要被认出来
  if [ -x /usr/games/sl ]; then
    tp_games=$( ( . /tmp/v3/tp.sh; PATH=/usr/bin:/bin; tool_present sl sl ) && echo 0 || echo 1 )
    ck "/usr/games/sl 在 PATH 外仍被认出" $tp_games
  else
    ck "/usr/games/sl 不在本机，跳过该断言" 0
  fi
else
  ck "本机无 dpkg，跳过 dpkg 回退分支测试" 0
fi
out=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" bash "$SRC" < /dev/null 2>&1)
echo "$out" | grep -q '无可用终端' && ck "非交互时自动降级为明文" 0 || ck "非交互时自动降级为明文" 1
echo "$out" | grep -q '模式: 明文 DNS' && ck "非交互默认明文" 0 || ck "非交互默认明文" 1

# --- 8) 自动换源（菜单 8 / --mirror）：只动发行版仓库，绝不碰第三方源，也绝不碰 DNS ---
# 换源逻辑的细粒度断言在 tests/verify-mirror.sh 里（不联网、不需要 root）；
# 这里只验「脚本接线对不对」：参数能进、菜单能进、沙箱里改的是测试目录、改完不碰 resolv.conf。
mkdir -p "$MNT/apt/sources.list.d"
cat > "$MNT/os-release" <<'EOF'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
ID=debian
VERSION_ID="13"
VERSION_CODENAME=trixie
EOF
cat > "$MNT/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/ca-certificates/mozilla/Debian_Internal_CA.crt
EOF
cat > "$MNT/apt/sources.list.d/docker.list" <<'EOF'
deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable
EOF
: > "$MNT/apt/sources.list"
sum_dns=$(md5sum "$MNT/resolv.conf" | cut -d' ' -f1)
sum_docker=$(md5sum "$MNT/apt/sources.list.d/docker.list" | cut -d' ' -f1)
# SET_DNS_MIRROR_NO_PROBE=1 + SET_DNS_MIRROR=aliyun：跳过联网测速并指定候选，结果可复现
outm=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_LOG="$MNT/dns-watch.log" \
       SET_DNS_MIRROR_NO_PROBE=1 SET_DNS_MIRROR=aliyun bash "$SRC" --mirror 2>&1)
echo "$outm" | grep -q '自动换源' && ck "--mirror 进入换源流程" 0 || { ck "--mirror 进入换源流程" 1; echo "$outm" | tail -5 | sed 's/^/     /'; }
echo "$outm" | grep -q '选定 aliyun' && ck "--mirror 按 SET_DNS_MIRROR 选定候选" 0 || { ck "--mirror 按 SET_DNS_MIRROR 选定候选" 1; echo "$outm" | tail -5 | sed 's/^/     /'; }
grep -q 'mirrors.aliyun.com/debian$' "$MNT/apt/sources.list.d/debian.sources" && ck "发行版源已换成 aliyun" 0 || ck "发行版源已换成 aliyun" 1
grep -q 'Signed-By:' "$MNT/apt/sources.list.d/debian.sources" && ck "换源后 Signed-By 仍在（丢了 apt 就废）" 0 || ck "换源后 Signed-By 仍在（丢了 apt 就废）" 1
grep -q 'deb\.debian\.org' "$MNT/apt/sources.list.d/debian.sources" && ck "旧地址已清掉" 1 || ck "旧地址已清掉" 0
[ "$(md5sum "$MNT/apt/sources.list.d/docker.list" | cut -d' ' -f1)" = "$sum_docker" ] && ck "第三方 docker 源一个字节没动" 0 || ck "第三方 docker 源一个字节没动" 1
[ -s "$MNT/set-dns.bak/mirror/manifest" ] && ck "--mirror 留下了备份 manifest" 0 || ck "--mirror 留下了备份 manifest" 1
[ "$(md5sum "$MNT/resolv.conf" | cut -d' ' -f1)" = "$sum_dns" ] && ck "--mirror 不动 resolv.conf" 0 || ck "--mirror 不动 resolv.conf" 1
# 沙箱里必须跳过 apt-get update（REAL=0），绝不能真去改本机 apt
echo "$outm" | grep -q '沙箱模式：文件已改写' && ck "--mirror 沙箱里跳过 apt update" 0 || ck "--mirror 沙箱里跳过 apt update" 1
# 还原
outm2=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" bash "$SRC" --mirror-restore 2>&1)
echo "$outm2" | grep -q '还原软件源配置' && ck "--mirror-restore 进入还原流程" 0 || ck "--mirror-restore 进入还原流程" 1
grep -q 'deb\.debian\.org/debian$' "$MNT/apt/sources.list.d/debian.sources" && ck "还原回原始官方源" 0 || { ck "还原回原始官方源" 1; cat "$MNT/apt/sources.list.d/debian.sources" | sed 's/^/     /'; }
outm3=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_MIRROR_NO_PROBE=1 SET_DNS_MIRROR=aliyun bash "$SRC" 8 2>&1)
echo "$outm3" | grep -q '自动换源' && ck "参数 8 -> 自动换源" 0 || ck "参数 8 -> 自动换源" 1
# 源码级不变式：换源代码里不许出现裸的 deb.debian.org 直写（必须走候选表）
grep -q 'mirror_catalog()' "$SRC" && ck "有候选源表 mirror_catalog" 0 || ck "有候选源表 mirror_catalog" 1
grep -q 'is_distro_uri()' "$SRC" && ck "有第三方源白名单判据 is_distro_uri" 0 || ck "有第三方源白名单判据 is_distro_uri" 1

# --- 9) 自定义 SSH 端口（菜单 9 / --ssh-port）：改前备份、Match 块不被污染、可一键还原 ---
# 这是在临时目录里模拟一台机器：sshd_config 里既有全局 Port，也有 Match User 里的 Port 2022。
# 关键不变式：全局 Port 被换掉，而 Match 里的 Port 2022 必须原样不动（那是条件性的，不是全机端口）。
mkdir -p "$MNT/ssh/sshd_config.d"
cat > "$MNT/ssh/sshd_config" <<'EOF'
# sandbox sshd_config
Port 22
PermitRootLogin yes
#Port 2222
PasswordAuthentication yes

Match User foo
  Port 2022
  X11Forwarding no
EOF
printf 'Port 22\nClientAliveInterval 30\n' > "$MNT/ssh/sshd_config.d/50-cloud.conf"
sum_dns9=$(md5sum "$MNT/resolv.conf" | cut -d' ' -f1)
out9=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_LOG="$MNT/dns-watch.log" bash "$SRC" --ssh-port=2222 2>&1)
rc9=$?
[ "$rc9" = 0 ] && ck "--ssh-port 退出码 0" 0 || { ck "--ssh-port 退出码 0" 1; echo "$out9" | tail -6 | sed 's/^/     /'; }
echo "$out9" | grep -qE '当前生效端口: 22([^0-9]|$)' && ck "--ssh-port 读到当前端口 22" 0 || { ck "--ssh-port 读到当前端口 22" 1; echo "$out9" | head -8 | sed 's/^/     /'; }
# Match User foo 里的 Port 2022 是条件性的，不算全局生效端口；若被当成全局会显示「22 2022」
echo "$out9" | grep -q '当前生效端口: 22 2022' && ck "Match 块里的 Port 2022 未被误认为全局端口" 1 || ck "Match 块里的 Port 2022 未被误认为全局端口" 0
grep -q '^Port 2222' "$MNT/ssh/sshd_config" && ck "--ssh-port 写入新端口" 0 || { ck "--ssh-port 写入新端口" 1; cat "$MNT/ssh/sshd_config" | sed 's/^/     /'; }
grep -q '#set-dns-old# Port 22' "$MNT/ssh/sshd_config" && ck "旧全局 Port 被注释而不是删掉" 0 || ck "旧全局 Port 被注释而不是删掉" 1
grep -q 'set-dns ssh port begin' "$MNT/ssh/sshd_config" && ck "改写块有标记（便于下次幂等替换）" 0 || ck "改写块有标记（便于下次幂等替换）" 1
# Match 块必须完好：Port 2022 在 Match 作用域内，绝不能被改成 2222
awk '/^Match /{m=1} m && /^[[:space:]]*Port[[:space:]]+2022/{found=1} END{exit !found}' "$MNT/ssh/sshd_config" \
  && ck "Match 块里的 Port 2022 未被污染" 0 || ck "Match 块里的 Port 2022 未被污染" 1
grep -q '^Port 2222' "$MNT/ssh/sshd_config.d/50-cloud.conf" && ck "drop-in 里的 Port 也一起改（否则会盖掉主配置）" 0 || ck "drop-in 里的 Port 也一起改（否则会盖掉主配置）" 1
[ -s "$MNT/set-dns.bak/ssh/orig/manifest" ] && ck "--ssh-port 留下首次备份 manifest" 0 || ck "--ssh-port 留下首次备份 manifest" 1
# 备份里除了主配置还必须有 drop-in，否则还原时会剩一个 Port 22 的 50-cloud.conf 把新端口盖回去
grep -qxF "$MNT/ssh/sshd_config" "$MNT/set-dns.bak/ssh/orig/manifest" \
  && ck "备份 manifest 记录了主配置原始路径" 0 || { ck "备份 manifest 记录了主配置原始路径" 1; cat -n "$MNT/set-dns.bak/ssh/orig/manifest" | sed 's/^/     /'; }
grep -qxF "$MNT/ssh/sshd_config.d/50-cloud.conf" "$MNT/set-dns.bak/ssh/orig/manifest" \
  && ck "备份 manifest 也记录了 drop-in" 0 || ck "备份 manifest 也记录了 drop-in" 1
[ "$(md5sum "$MNT/resolv.conf" | cut -d' ' -f1)" = "$sum_dns9" ] && ck "--ssh-port 不动 resolv.conf" 0 || ck "--ssh-port 不动 resolv.conf" 1
# 幂等：再跑一次，块不能被追加成两份
SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_LOG="$MNT/dns-watch.log" SET_DNS_SSH_KEEP=1 bash "$SRC" --ssh-port=2222 >/dev/null 2>&1
nb=$(grep -c 'set-dns ssh port begin' "$MNT/ssh/sshd_config")
[ "$nb" = 1 ] && ck "重复执行不会累积改写块（实际 $nb）" 0 || ck "重复执行不会累积改写块（实际 $nb）" 1
np=$(grep -c '^Port 2222' "$MNT/ssh/sshd_config")
[ "$np" = 1 ] && ck "保留旧端口模式下新端口不重复（实际 $np）" 0 || ck "保留旧端口模式下新端口不重复（实际 $np）" 1
# 非法端口必须挡住
out9b=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" bash "$SRC" --ssh-port=99999 2>&1); rc9b=$?
[ "$rc9b" != 0 ] && ck "超范围端口被拒（退出码非 0）" 0 || ck "超范围端口被拒（退出码非 0）" 1
echo "$out9b" | grep -q '端口范围应为 1-65535' && ck "超范围端口给出明确原因" 0 || ck "超范围端口给出明确原因" 1
out9c=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" bash "$SRC" --ssh-port=abc 2>&1); rc9c=$?
[ "$rc9c" != 0 ] && ck "非数字端口被拒" 0 || ck "非数字端口被拒" 1
# 还原
out9d=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" bash "$SRC" --ssh-port-restore 2>&1)
echo "$out9d" | grep -q '还原 SSH 端口配置' && ck "--ssh-port-restore 进入还原流程" 0 || ck "--ssh-port-restore 进入还原流程" 1
grep -q '^Port 22' "$MNT/ssh/sshd_config" && ! grep -q 'set-dns ssh port begin' "$MNT/ssh/sshd_config" \
  && ck "还原后配置回到原样（无残留标记）" 0 || ck "还原后配置回到原样（无残留标记）" 1
grep -q '^Port 22' "$MNT/ssh/sshd_config.d/50-cloud.conf" && ck "还原后 drop-in 也回到原样" 0 \
  || { ck "还原后 drop-in 也回到原样" 1; cat "$MNT/ssh/sshd_config.d/50-cloud.conf" | sed 's/^/     /'; }
grep -q '2022' "$MNT/ssh/sshd_config" && sed -n '/^Match User foo/,/^$/p' "$MNT/ssh/sshd_config" | grep -q 'Port 2022' \
  && ck "还原后 Match 块仍然完好" 0 || ck "还原后 Match 块仍然完好" 1
out9e=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_SSH_PORT=2222 bash "$SRC" 9 2>&1)
echo "$out9e" | grep -q '自定义 SSH 连接端口' && ck "参数 9 -> 自定义 SSH 端口" 0 || ck "参数 9 -> 自定义 SSH 端口" 1
# 源码级不变式：ssh_conf_ports 必须排除 Match 作用域内的 Port
grep -q 'ssh_conf_ports()' "$SRC" && ck "有端口解析函数 ssh_conf_ports" 0 || ck "有端口解析函数 ssh_conf_ports" 1

echo
echo "===== 10b. 内核管理（菜单 10 / --kernel / --kernel-update / --kernel-remove）====="
# 纯只读面板：报告当前内核、CPU 微架构档位、BBRv3 安装状态、BBR 可用性，且不许碰 resolv.conf
sumkd=$(md5sum "$MNT/resolv.conf" | cut -d' ' -f1)
outk=$(EX --kernel 2>&1); rck=$?
[ "$rck" = 0 ] && ck "--kernel 退出码 0" 0 || { ck "--kernel 退出码 0" 1; echo "$outk" | tail -6 | sed 's/^/     /'; }
echo "$outk" | grep -qE '您(已|尚未)安装 xanmod' && ck "--kernel 报告 xanmod BBRv3 安装状态" 0 || ck "--kernel 报告 xanmod BBRv3 安装状态" 1
echo "$outk" | grep -q '当前内核版本：' && ck "--kernel 报告当前内核版本" 0 || ck "--kernel 报告当前内核版本" 1
echo "$outk" | grep -q 'CPU 微架构档位：' && ck "--kernel 报告 CPU 微架构档位" 0 || ck "--kernel 报告 CPU 微架构档位" 1
echo "$outk" | grep -q 'BBR 状态：' && ck "--kernel 报告 BBR 状态" 0 || ck "--kernel 报告 BBR 状态" 1
echo "$outk" | grep -q '更新BBRv3内核' && ck "--kernel 打印内核管理菜单" 0 || ck "--kernel 打印内核管理菜单" 1
[ "$(md5sum "$MNT/resolv.conf" | cut -d' ' -f1)" = "$sumkd" ] && ck "--kernel 是只读，不动 resolv.conf" 0 || ck "--kernel 是只读，不动 resolv.conf" 1

# 微架构档位：档位选高了（比如没 avx512f 的机器装 x64v4）内核直接起不来，必须能自动判、也能强制
lv_auto=$(EX --kernel 2>&1 | sed -n 's/.*CPU 微架构档位： *\([x0-9a-z]*\).*/\1/p' | head -1)
case "$lv_auto" in
  x64v1|x64v2|x64v3|x64v4) ck "默认按 CPU flags 自动判定档位（$lv_auto）" 0 ;;
  *) ck "默认按 CPU flags 自动判定档位（得到「$lv_auto」）" 1 ;;
esac
lv_force=$(SET_DNS_KERNEL_LEVEL=x64v4 EX --kernel 2>&1 | sed -n 's/.*CPU 微架构档位： *\([x0-9a-z]*\).*/\1/p' | head -1)
[ "$lv_force" = x64v4 ] && ck "SET_DNS_KERNEL_LEVEL 可强制指定档位" 0 || ck "SET_DNS_KERNEL_LEVEL 可强制指定档位（得到「$lv_force」）" 1

# 判档回归（Xeon E5-2699 v4 实测误判成 x64v2 的 bug）：
# Intel 内核只把 LZCNT 报成 abm、不报 lzcnt，而 SSE3 在 Linux 里叫 pni —— 照字面找 lzcnt/sse3 会判低一档，
# 判低会让用户装上功能更少的 x64v2 内核（能启动但不是他要的 BBRv3 v3 档）。
FC=$MNT/cpuinfo.fake
read -r -d '' E5V4 <<'EOF'
fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts acpi mmx fxsr sse sse2 ss ht tm pbe syscall nx pdpe1gb rdtscp lm constant_tsc arch_perfmon pebs bts rep_good nopl xtopology nonstop_tsc cpuid aperfmperf pni pclmulqdq dtes64 monitor ds_cpl vmx smx est tm2 ssse3 sdbg fma cx16 xtpr pdcm pcid dca sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdrand lahf_lm abm 3dnowprefetch cpuid_fault epb cat_l3 cdp_l3 invpcid_single intel_ppin ssbd mba ibrs ibpb stibp ibrs_enhanced tpr_shadow vnmi flexpriority ept vpid fsgsbase tsc_adjust bmi1 hle avx2 smep bmi2 erms invpcid rtm cqm rdt_a rdseed adx smap intel_pt xsaveopt cqm_llc cqm_occup_llc cqm_mbm_total cqm_mbm_local dtherm ida arat pln pts hwp hwp_act_window hwp_epp hwp_pkg_req hfi pku ospke md_clear flush_l1d arch_capabilities
EOF
fake_cpu "$FC" "$E5V4"
lv=$(EXK "$FC" --kernel | lvl_of)
[ "$lv" = x64v3 ] && ck "E5-2699 v4（只报 abm）判为 x64v3" 0 || { ck "E5-2699 v4（只报 abm）判为 x64v3（得到「$lv」）" 1; }
fake_cpu "$FC" "${E5V4// abm / lzcnt }"
lv=$(EXK "$FC" --kernel | lvl_of)
[ "$lv" = x64v3 ] && ck "内核报字面 lzcnt 也判 x64v3" 0 || ck "内核报字面 lzcnt 也判 x64v3（得到「$lv」）" 1
fake_cpu "$FC" "${E5V4// abm / }"
lv=$(EXK "$FC" --kernel | lvl_of)
[ "$lv" = x64v2 ] && ck "lzcnt/abm 都没有时保守降 x64v2" 0 || ck "lzcnt/abm 都没有时保守降 x64v2（得到「$lv」）" 1
fake_cpu "$FC" "$E5V4 avx512f avx512bw avx512cd avx512dq avx512vl"
lv=$(EXK "$FC" --kernel | lvl_of)
[ "$lv" = x64v4 ] && ck "有 avx512 全项判 x64v4" 0 || ck "有 avx512 全项判 x64v4（得到「$lv」）" 1
fake_cpu "$FC" "fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts acpi mmx fxsr sse sse2 ss ht tm pbe syscall nx lm pni ssse3 cx16 sse4_1 sse4_2 popcnt xsave lahf_lm"
lv=$(EXK "$FC" --kernel | lvl_of)
[ "$lv" = x64v2 ] && ck "缺 avx2 的老 CPU 判 x64v2" 0 || ck "缺 avx2 的老 CPU 判 x64v2（得到「$lv」）" 1
fake_cpu "$FC" "fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts acpi mmx fxsr sse sse2 ss ht tm pbe syscall nx lm"
lv=$(EXK "$FC" --kernel | lvl_of)
[ "$lv" = x64v1 ] && ck "只有 sse2 的远古 CPU 判 x64v1" 0 || ck "只有 sse2 的远古 CPU 判 x64v1（得到「$lv」）" 1
: > "$FC"
lv=$(EXK "$FC" --kernel | lvl_of)
[ "$lv" = x64v2 ] && ck "cpuinfo 读不到时兜底 x64v2" 0 || ck "cpuinfo 读不到时兜底 x64v2（得到「$lv」）" 1
# 判档依据要打印出来，用户能看出为什么是这个档位
EX --kernel | grep -q '档位判定依据：' && ck "--kernel 打印档位判定依据" 0 || ck "--kernel 打印档位判定依据" 1
# 正在跑 x64v3 内核的机器不允许被判成更低的档（跑起来就是硬证据）
EX --kernel | grep -q 'krn_running_level' && ck "源码含「按在跑的内核兜底判档」" 1 || ck "源码含「按在跑的内核兜底判档」" 0
# 正在跑 x64v3 内核时，即便探测判低了也要按 v3 出力（跑起来就是硬证据）
lv=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_LOG="$MNT/dns-watch.log" \
     SET_DNS_CPUINFO="$MNT/cpuinfo.fake" SET_DNS_LDSO=/nonexistent-ld.so \
     SET_DNS_RUNNING_KERNEL=7.2.9-x64v3-xanmod1 bash "$SRC" --kernel 2>&1 | lvl_of)
[ "$lv" = x64v3 ] && ck "在跑 x64v3 内核时不会被判低（得 $lv）" 0 || ck "在跑 x64v3 内核时不会被判低（得「$lv」）" 1
grep -q 'krn_glibc_level' "$SRC" && ck "源码优先用 glibc hwcaps 判档" 0 || ck "源码优先用 glibc hwcaps 判档" 1
grep -qE '"\s*lzcnt\s*"\*\|' "$SRC" && ck "源码不再字面单依赖 lzcnt" 0 || ck "源码不再字面单依赖 lzcnt" 1
grep -q 'pni sse4_1' "$SRC" && ck "源码用 Linux 的 pni 表示 SSE3" 0 || ck "源码用 Linux 的 pni 表示 SSE3" 1

# 沙箱里不许真装真卸（REAL=0），只出计划
outku=$(SET_DNS_KERNEL_LEVEL=x64v3 EX --kernel-update 2>&1); rcu=$?
[ "$rcu" = 0 ] && ck "--kernel-update 沙箱内退出码 0" 0 || { ck "--kernel-update 沙箱内退出码 0" 1; echo "$outku" | tail -8 | sed 's/^/     /'; }
echo "$outku" | grep -q '更新 BBRv3 内核' && ck "--kernel-update 打印更新流程" 0 || ck "--kernel-update 打印更新流程" 1
echo "$outku" | grep -q '沙箱模式' && ck "--kernel-update 沙箱内不真装内核" 0 || { ck "--kernel-update 沙箱内不真装内核" 1; echo "$outku" | tail -6 | sed 's/^/     /'; }
outkr=$(EX --kernel-remove 2>&1); rcr=$?
[ "$rcr" = 0 ] && ck "--kernel-remove 退出码 0" 0 || ck "--kernel-remove 退出码 0" 1
echo "$outkr" | grep -qE '沙箱模式|没有装过 xanmod' && ck "--kernel-remove 沙箱内不真卸" 0 || { ck "--kernel-remove 沙箱内不真卸" 1; echo "$outkr" | tail -6 | sed 's/^/     /'; }
echo "$outkr" | grep -q '已卸载 xanmod 内核包' && ck "--kernel-remove 沙箱内确实没执行卸载" 1 || ck "--kernel-remove 沙箱内确实没执行卸载" 0
outk10=$(EX 10 2>&1)
echo "$outk10" | grep -q '内核管理' && ck "参数 10 -> 内核管理" 0 || ck "参数 10 -> 内核管理" 1

# 源码级不变式
grep -q 'krn_stock_images' "$SRC" && ck "源码含「非 xanmod 兜底内核」检查" 0 || ck "源码含「非 xanmod 兜底内核」检查" 1
grep -q 'avx512f' "$SRC" && ck "源码按 avx512f 等判 x64v4 档" 0 || ck "源码按 avx512f 等判 x64v4 档" 1
grep -q 'deb\.xanmod\.org' "$SRC" && ck "源码含 xanmod 源地址" 0 || ck "源码含 xanmod 源地址" 1
# 内核段绝不改 BBR sysctl 参数 —— /etc/sysctl.d 那两个文件是 de_GWD / kejilion 的
# （注意范围终点要用 TCP 加速段的头，否则会把后面的加速段一起框进来）
awk '/^# ================= 内核管理/,/^# ================= TCP 加速管理/' "$SRC" | grep -qE 'sysctl -w|sysctl\.d/[^ ]*(>|tee)' \
  && ck "内核段不抢 BBR 参数（不写 sysctl.d）" 1 || ck "内核段不抢 BBR 参数（不写 sysctl.d）" 0

echo
echo "===== 10c. TCP 加速管理（菜单 11 / --accel*）====="
ACCC="$MNT/sysctl.d/99-zz-setdns-accel.conf"
ACCM="$MNT/modules-load.d/setdns-qdisc.conf"
# 固定可用算法列表，避免真机/容器差异让断言摇摆（真机上是 "reno bbr cubic"）
EXA(){ SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_LOG="$MNT/dns-watch.log" \
       SET_DNS_ACC_AVAIL="reno bbr cubic" bash "$SRC" "$@" 2>&1; }

rm -f "$ACCC" "$ACCM"

# --- 只读项：不写任何文件、不碰 resolv.conf ---
rm -rf "$MNT/set-dns.bak"; EX --plain >/dev/null 2>&1
sum0=$(md5sum "$MNT/resolv.conf" | awk '{print $1}')
out=$(EXA --accel-status 2>&1); rc=$?
[ "$rc" = 0 ] && ck "--accel-status 退 0" 0 || ck "--accel-status 退 0" 1
echo "$out" | grep -q '信息:' && ck "--accel-status 打印「信息:」行（对齐截图面板）" 0 || { ck "--accel-status 打印「信息:」行" 1; echo "$out" | sed 's/^/     /'; }
echo "$out" | grep -q '拥塞控制算法:' && ck "--accel-status 打印拥塞控制/队列算法行" 0 || ck "--accel-status 打印拥塞控制/队列算法行" 1
echo "$out" | grep -q 'Headers状态:' && ck "--accel-status 打印 Headers 状态" 0 || ck "--accel-status 打印 Headers 状态" 1
[ ! -e "$ACCC" ] && ck "只读状态不改动加速配置" 0 || ck "只读状态不改动加速配置" 1
[ "$(md5sum "$MNT/resolv.conf" | awk '{print $1}')" = "$sum0" ] && ck "只读状态不动 resolv.conf" 0 || ck "只读状态不动 resolv.conf" 1
out=$(EXA --accel-kernels 2>&1)
echo "$out" | grep -q '已安装内核' && ck "--accel-kernels 列出内核" 0 || ck "--accel-kernels 列出内核" 1
echo "$out" | grep -q '本项只读' && ck "--accel-kernels 声明只读" 0 || ck "--accel-kernels 声明只读" 1

# --- 加速启用：20/21/22 ---
EXA --accel-bbr >/dev/null 2>&1
grep -q '^net\.core\.default_qdisc = fq$' "$ACCC" && ck "--accel-bbr 写 default_qdisc=fq" 0 || ck "--accel-bbr 写 default_qdisc=fq" 1
grep -q '^net\.ipv4\.tcp_congestion_control = bbr$' "$ACCC" && ck "--accel-bbr 写 tcp_congestion_control=bbr" 0 || ck "--accel-bbr 写 tcp_congestion_control=bbr" 1
EXA --accel-fqpie >/dev/null 2>&1
grep -q '^net\.core\.default_qdisc = fq_pie$' "$ACCC" && ck "--accel-fqpie 切到 fq_pie" 0 || ck "--accel-fqpie 切到 fq_pie" 1
EXA --accel-cake >/dev/null 2>&1
grep -q '^net\.core\.default_qdisc = cake$' "$ACCC" && ck "--accel-cake 切到 cake" 0 || ck "--accel-cake 切到 cake" 1
# 幂等：反复切不能累积重复键
EXA --accel-bbr >/dev/null 2>&1; EXA --accel-cake >/dev/null 2>&1; EXA --accel-bbr >/dev/null 2>&1
n_q=$(grep -cE '^net\.core\.default_qdisc[[:space:]]*=' "$ACCC"); n_c=$(grep -cE '^net\.ipv4\.tcp_congestion_control[[:space:]]*=' "$ACCC")
[ "$n_q" = 1 ] && [ "$n_c" = 1 ] && ck "反复切换不产生重复键（qdisc $n_q / cc $n_c）" 0 || ck "反复切换不产生重复键（qdisc $n_q / cc $n_c）" 1
# qdisc 模块要记进 modules-load.d，否则重启后模块不在、qdisc 装不上
grep -qxF 'sch_fq' "$ACCM" 2>/dev/null && ck "qdisc 模块写进 modules-load.d" 0 || ck "qdisc 模块写进 modules-load.d" 1
# 拿不到的拥塞算法必须拒绝，而不是写一个内核不认的值
out=$(SET_DNS_ETC="$MNT" SET_DNS_SBIN="$MNT/sbin" SET_DNS_LOG="$MNT/dns-watch.log" \
      SET_DNS_ACC_AVAIL="reno cubic" bash "$SRC" --accel-bbr 2>&1); rc=$?
[ "$rc" != 0 ] && ck "内核没有 bbr 时 --accel-bbr 退非 0" 0 || ck "内核没有 bbr 时 --accel-bbr 退非 0" 1
echo "$out" | grep -q '不支持 bbr' && ck "并说明「当前内核不支持 bbr」" 0 || ck "并说明「当前内核不支持 bbr」" 1

# --- ECN 30/31 ---
EXA --accel-ecn-on >/dev/null 2>&1
grep -q '^net\.ipv4\.tcp_ecn = 1$' "$ACCC" && ck "开启 ECN 写 tcp_ecn=1" 0 || ck "开启 ECN 写 tcp_ecn=1" 1
EXA --accel-ecn-off >/dev/null 2>&1
grep -q '^net\.ipv4\.tcp_ecn = 0$' "$ACCC" && ck "关闭 ECN 写 tcp_ecn=0" 0 || ck "关闭 ECN 写 tcp_ecn=0" 1
[ "$(grep -cE '^net\.ipv4\.tcp_ecn[[:space:]]*=' "$ACCC")" = 1 ] && ck "tcp_ecn 不重复（锚定 = 不误伤 tcp_ecn_fallback）" 0 || ck "tcp_ecn 不重复" 1

# --- IPv6 35/36 ---
EXA --accel-ipv6-off >/dev/null 2>&1
grep -q '^net\.ipv6\.conf\.all\.disable_ipv6 = 1$' "$ACCC" && ck "禁用 IPv6 写 all.disable_ipv6=1" 0 || ck "禁用 IPv6 写 all.disable_ipv6=1" 1
grep -q '^net\.ipv6\.conf\.default\.disable_ipv6 = 1$' "$ACCC" && ck "禁用 IPv6 同时写 default 键" 0 || ck "禁用 IPv6 同时写 default 键" 1
EXA --accel-ipv6-on >/dev/null 2>&1
grep -q '^net\.ipv6\.conf\.all\.disable_ipv6 = 0$' "$ACCC" && ck "开启 IPv6 写回 0" 0 || ck "开启 IPv6 写回 0" 1

# --- 32 自适应优化 / 33 防 CC ---
EXA --accel-optimize >/dev/null 2>&1
n_opt=$(grep -cE '^[^#]*=' "$ACCC")
[ "$n_opt" -ge 15 ] && ck "--accel-optimize 写入成组参数（$n_opt 项）" 0 || ck "--accel-optimize 写入成组参数（$n_opt 项）" 1
grep -qE '^net\.ipv4\.ip_local_port_range = 1024 65535$' "$ACCC" && ck "优化写入 ip_local_port_range 1024 65535" 0 || { ck "优化写入 ip_local_port_range 1024 65535" 1; grep -n 'port_range' "$ACCC" | sed 's/^/     /'; }
grep -qE '^net\.core\.somaxconn = [0-9]+$' "$ACCC" && ck "somaxconn 按内存分档写入" 0 || ck "somaxconn 按内存分档写入" 1
# 关键回归：优化不能把用户刚关掉的 IPv6 又打开（tcpx.sh 踩过这个坑）
EXA --accel-ipv6-off >/dev/null 2>&1; EXA --accel-optimize >/dev/null 2>&1
grep -q '^net\.ipv6\.conf\.all\.disable_ipv6 = 1$' "$ACCC" && ck "自适应优化保留「已禁用 IPv6」状态" 0 || ck "自适应优化保留「已禁用 IPv6」状态" 1
EXA --accel-ecn-on >/dev/null 2>&1; EXA --accel-optimize >/dev/null 2>&1
grep -q '^net\.ipv4\.tcp_ecn = 1$' "$ACCC" && ck "自适应优化保留 ECN 现状" 0 || ck "自适应优化保留 ECN 现状" 1
EXA --accel-ddcc >/dev/null 2>&1
grep -q '^net\.ipv4\.tcp_syncookies = 1$' "$ACCC" && ck "防 CC 开 syncookies" 0 || ck "防 CC 开 syncookies" 1
grep -q '^net\.ipv4\.tcp_synack_retries = 1$' "$ACCC" && ck "防 CC 降 synack 重试" 0 || ck "防 CC 降 synack 重试" 1
# tcpx.sh 用 1024000 这种离谱值，本脚本必须跟随真实 somaxconn
grep -qE '^net\.ipv4\.tcp_max_syn_backlog = 1024000$' "$ACCC" && ck "防 CC 不用上游那个 1024000 的离谱值" 1 || ck "防 CC 不用上游那个 1024000 的离谱值" 0
echo "$(EXA --accel-ddcc)" | grep -q '不能替代真防护' && ck "防 CC 明说不能替代真防护" 0 || ck "防 CC 明说不能替代真防护" 1

# --- 37 提交合并 ---
out=$(EXA --accel-merge 2>&1); rc=$?
[ "$rc" = 0 ] && ck "--accel-merge 退 0" 0 || ck "--accel-merge 退 0" 1
echo "$out" | grep -qE '共 [0-9]+ 项：生效' && ck "--accel-merge 统计项数" 0 || { ck "--accel-merge 统计项数" 1; echo "$out" | tail -4 | sed 's/^/     /'; }
# --- 38 编辑：没有终端必须拒绝而不是挂着 ---
out=$(EXA --accel-edit 2>&1); rc=$?
[ "$rc" != 0 ] && ck "--accel-edit 无终端时拒绝" 0 || ck "--accel-edit 无终端时拒绝" 1
echo "$out" | grep -qE '没有终端|编辑器' && ck "--accel-edit 给出可行提示" 0 || ck "--accel-edit 给出可行提示" 1

# --- 内核安装：能装的走真实包名，装不了的必须说清为什么 ---
lv_now=$(EXA --kernel | lvl_of)
out=$(SET_DNS_ACC_KERNEL="$lv_now" EXA --accel-kernel=xanmod-main 2>&1)
echo "$out" | grep -q "linux-xanmod-$lv_now" && ck "XANMOD main 用真实元包名 linux-xanmod-$lv_now" 0 || { ck "XANMOD main 用真实元包名" 1; echo "$out" | sed 's/^/     /'; }
echo "$out" | grep -q '沙箱模式：不真的装内核' && ck "沙箱内不真装内核" 0 || ck "沙箱内不真装内核" 1
out=$(SET_DNS_ACC_KERNEL="$lv_now" EXA --accel-kernel=xanmod-lts 2>&1)
echo "$out" | grep -q "linux-xanmod-lts-$lv_now" && ck "XANMOD LTS 用 linux-xanmod-lts-<档位>" 0 || ck "XANMOD LTS 用 linux-xanmod-lts-<档位>" 1
out=$(SET_DNS_ACC_KERNEL="$lv_now" EXA --accel-kernel=xanmod-edge 2>&1)
echo "$out" | grep -q "linux-xanmod-edge-$lv_now" && ck "XANMOD EDGE 用 linux-xanmod-edge-<档位>" 0 || ck "XANMOD EDGE 用 linux-xanmod-edge-<档位>" 1
out=$(SET_DNS_ACC_KERNEL="$lv_now" EXA --accel-kernel=xanmod-rt 2>&1)
echo "$out" | grep -q "linux-xanmod-rt-$lv_now" && ck "XANMOD RT 用 linux-xanmod-rt-<档位>" 0 || ck "XANMOD RT 用 linux-xanmod-rt-<档位>" 1
out=$(EXA --accel-kernel=official 2>&1)
echo "$out" | grep -q 'linux-image-amd64' && ck "官方稳定内核用 linux-image-amd64" 0 || ck "官方稳定内核用 linux-image-amd64" 1
out=$(EXA --accel-kernel=cloud 2>&1)
echo "$out" | grep -q 'linux-image-cloud-amd64' && ck "官方 cloud 内核用 linux-image-cloud-amd64" 0 || ck "官方 cloud 内核用 linux-image-cloud-amd64" 1
out=$(EXA --accel-kernel=latest 2>&1)
echo "$out" | grep -q 'backports' && ck "官方最新内核走 backports" 0 || ck "官方最新内核走 backports" 1
for v in bbr-orig bbrplus lotserver zen; do
  out=$(EXA --accel-kernel=$v 2>&1); rc=$?
  [ "$rc" != 0 ] && ck "做不到的变体 $v 退非 0（不假装装上）" 0 || ck "做不到的变体 $v 退非 0" 1
  echo "$out" | grep -qE '替代|装不了|只支持' && ck "变体 $v 给出替代方案" 0 || { ck "变体 $v 给出替代方案" 1; echo "$out" | sed 's/^/     /'; }
done

# --- 52 删内核的安全屏障：删完没内核可启动必须拦住 ---
allimg=$(dpkg-query -W -f '${Package} ${db:Status-Status}\n' 'linux-image-*' 2>/dev/null | awk '$2=="installed" && $1 !~ /-unsigned$/ {print $1}' | tr '\n' ' ')
if [ -n "$allimg" ]; then
  out=$(SET_DNS_ACC_DEL="$allimg" EXA --accel-kernel-del 2>&1); rc=$?
  [ "$rc" != 0 ] && ck "全删内核被安全屏障拦住（退非 0）" 0 || { ck "全删内核被安全屏障拦住" 1; echo "$out" | tail -6 | sed 's/^/     /'; }
  echo "$out" | grep -q '操作已阻止' && ck "屏障提示「操作已阻止」" 0 || ck "屏障提示「操作已阻止」" 1
  echo "$out" | grep -q '变砖' && ck "屏障说明重启即变砖" 0 || ck "屏障说明重启即变砖" 1
  # 只删一个非当前内核：沙箱只出计划，不真卸
  one=$(printf '%s' "$allimg" | tr ' ' '\n' | grep -v "$(uname -r)" | head -1)
  if [ -n "$one" ]; then
    out=$(SET_DNS_ACC_DEL="$one" EXA --accel-kernel-del 2>&1); rc=$?
    [ "$rc" = 0 ] && ck "删单个非当前内核退 0" 0 || ck "删单个非当前内核退 0" 1
    echo "$out" | grep -q '沙箱模式：不真的卸载' && ck "沙箱内不真卸内核" 0 || ck "沙箱内不真卸内核" 1
  fi
  # 安全屏障要在 dry-run 之前就生效（dry-run 也不能放过全删）
  SET_DNS_ACC_DEL="$allimg" EXA --dry-run --accel-kernel-del 2>&1 | grep -q '操作已阻止' \
    && ck "[dry-run] 也拦得住全删" 0 || ck "[dry-run] 也拦得住全删" 1
else
  inf "（本机 dpkg 没有 linux-image-* 包，跳过删除屏障断言）"
fi

# --- 55 卸载全部加速：只删自己的配置 ---
EXA --accel-bbr >/dev/null 2>&1
out=$(EXA --accel-restore 2>&1); rc=$?
[ "$rc" = 0 ] && ck "--accel-restore 退 0" 0 || ck "--accel-restore 退 0" 1
[ ! -e "$ACCC" ] && ck "卸载后加速配置已删" 0 || ck "卸载后加速配置已删" 1
[ ! -e "$ACCM" ] && ck "卸载后 modules-load 条目已删" 0 || ck "卸载后 modules-load 条目已删" 1
echo "$out" | grep -q '99-degwd.conf / 99-kejilion-bbr.conf 原样保留' && ck "明确声明没动别人的配置" 0 || ck "明确声明没动别人的配置" 1
out=$(EXA --accel-restore 2>&1)
echo "$out" | grep -q '无需卸载' && ck "重复卸载是幂等的" 0 || ck "重复卸载是幂等的" 1

# --- dry-run 必须零改动 ---
rm -f "$ACCC"; EXA --dry-run --accel-optimize >/dev/null 2>&1
[ ! -e "$ACCC" ] && ck "[dry-run] 不写加速配置" 0 || ck "[dry-run] 不写加速配置" 1

# --- 参数 11 与源码级不变式 ---
out=$(EXA 11 2>&1)
echo "$out" | grep -q 'TCP 加速' && ck "参数 11 -> TCP 加速管理" 0 || ck "参数 11 -> TCP 加速管理" 1
echo "$out" | grep -q '使用 BBR+FQ 加速' && ck "面板含「使用 BBR+FQ 加速」（对齐截图）" 0 || ck "面板含「使用 BBR+FQ 加速」" 1
echo "$out" | grep -q '安装 XANMOD(RT)' && ck "面板含「安装 XANMOD(RT)」（对齐截图）" 0 || ck "面板含「安装 XANMOD(RT)」" 1
echo "$out" | grep -q '一键 DD 重装系统' && ck "面板含「一键 DD 重装系统」（对齐截图）" 0 || ck "面板含「一键 DD 重装系统」" 1
echo "$out" | grep -q '网络精调' && ck "面板含「网络精调」（对齐截图）" 0 || ck "面板含「网络精调」" 1
# 配置文件必须排在 99-degwd.conf / 99-kejilion-bbr.conf 之后，否则改了不生效
[ "$(printf '%s\n' 99-degwd.conf 99-kejilion-bbr.conf 99-zz-setdns-accel.conf | LC_ALL=C sort | tail -1)" = 99-zz-setdns-accel.conf ] \
  && ck "加速配置文件按字典序排在最后（压得住前两个）" 0 || ck "加速配置文件按字典序排在最后" 1
grep -q '99-zz-setdns-accel.conf' "$SRC" && ck "源码使用 99-zz-setdns-accel.conf" 0 || ck "源码使用 99-zz-setdns-accel.conf" 1
# 加速段绝不去改 de_GWD / kejilion 的 sysctl 文件（那是别人的地盘）
awk '/^# ================= TCP 加速管理/,/^# ================= 参数解析/' "$SRC" \
  | grep -qE 'sysctl\.d/(99-degwd|99-kejilion)|/etc/sysctl\.conf' \
  && ck "加速段不碰 de_GWD / kejilion 的 sysctl（只写自己的 zz 文件）" 1 \
  || ck "加速段不碰 de_GWD / kejilion 的 sysctl（只写自己的 zz 文件）" 0
grep -q 'SET_DNS_ACC_AVAIL' "$SRC" && ck "源码支持 SET_DNS_ACC_AVAIL（测试可注入）" 0 || ck "源码支持 SET_DNS_ACC_AVAIL" 1

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

  # --- 菜单 4/5/6/7/8/9/10/11：只做防护、只看信息、装工具、换源、改 SSH 端口或调 TCP 加速，绝不能顺手把 DNS 重写一遍 ---
  for choice in 4 5 6 7 8 9 10 11 12; do
    if [ "$choice" = 6 ]; then
      # 第二个回车喂给「按任意键继续」，否则要等 timeout
      printf '6\n\n' | SET_DNS_SYSINFO_NO_NET=1 timeout 90 script -qec "SET_DNS_ETC=$MNT SET_DNS_SBIN=$MNT/sbin SET_DNS_LOG=$MNT/dns-watch.log bash $SRC" /dev/null > /tmp/v3/menu-$choice.txt 2>&1
    elif [ "$choice" = 7 ]; then
      # 7 会问「怎么装」，再喂一个 3（不装）避免它真的往下走
      printf '7\n3\n' | SET_DNS_TOOLS_ALL=1 timeout 90 script -qec "SET_DNS_ETC=$MNT SET_DNS_SBIN=$MNT/sbin SET_DNS_LOG=$MNT/dns-watch.log bash $SRC" /dev/null > /tmp/v3/menu-$choice.txt 2>&1
    elif [ "$choice" = 8 ]; then
      # 8 会问「用第几名」，喂 q（取消）—— 只验菜单接线，测速与改写交给第 10 段和 verify-mirror.sh
      printf '8\nq\n' | SET_DNS_MIRROR_NO_PROBE=1 timeout 120 script -qec "SET_DNS_ETC=$MNT SET_DNS_SBIN=$MNT/sbin SET_DNS_LOG=$MNT/dns-watch.log bash $SRC" /dev/null > /tmp/v3/menu-$choice.txt 2>&1
    elif [ "$choice" = 9 ]; then
      # 9 指定端口跳过端口询问，但会问「旧端口怎么办」，喂 1（关掉旧端口）
      printf '9\n1\n' | SET_DNS_SSH_PORT=2222 timeout 90 script -qec "SET_DNS_ETC=$MNT SET_DNS_SBIN=$MNT/sbin SET_DNS_LOG=$MNT/dns-watch.log bash $SRC" /dev/null > /tmp/v3/menu-$choice.txt 2>&1
    elif [ "$choice" = 10 ]; then
      # 10 会问「请输入你的选择」，喂 0（返回）—— 只验菜单接线，装/卸内核交给上面第 10b 段
      printf '10\n0\n' | timeout 90 script -qec "SET_DNS_ETC=$MNT SET_DNS_SBIN=$MNT/sbin SET_DNS_LOG=$MNT/dns-watch.log bash $SRC" /dev/null > /tmp/v3/menu-$choice.txt 2>&1
    elif [ "$choice" = 11 ]; then
      # 11 会问「请输入数字」，喂 99（退出）—— 只验菜单接线，具体动作交给第 10c 段
      printf '11\n99\n' | SET_DNS_ACC_AVAIL='reno bbr cubic' timeout 90 script -qec "SET_DNS_ETC=$MNT SET_DNS_SBIN=$MNT/sbin SET_DNS_LOG=$MNT/dns-watch.log bash $SRC" /dev/null > /tmp/v3/menu-$choice.txt 2>&1
    elif [ "$choice" = 12 ]; then
      # 12 会问「请输入数字」，喂 0（返回）—— 只验菜单接线；沙箱里绝不能真去装 3x-ui
      printf '12\n0\n' | timeout 90 script -qec "SET_DNS_ETC=$MNT SET_DNS_SBIN=$MNT/sbin SET_DNS_LOG=$MNT/dns-watch.log bash $SRC" /dev/null > /tmp/v3/menu-$choice.txt 2>&1
    else
      printf '%s\n' "$choice" | timeout 90 script -qec "SET_DNS_ETC=$MNT SET_DNS_SBIN=$MNT/sbin SET_DNS_LOG=$MNT/dns-watch.log bash $SRC" /dev/null > /tmp/v3/menu-$choice.txt 2>&1
    fi
    case "$choice" in
      4) grep -q '安装自动修复守护' /tmp/v3/menu-$choice.txt && ck "菜单选 4 进守护安装" 0 || { ck "菜单选 4 进守护安装" 1; tail -4 /tmp/v3/menu-$choice.txt | sed 's/^/     /'; } ;;
      5) grep -q '移除防护守护' /tmp/v3/menu-$choice.txt && ck "菜单选 5 进守护移除" 0 || { ck "菜单选 5 进守护移除" 1; tail -4 /tmp/v3/menu-$choice.txt | sed 's/^/     /'; } ;;
      6) grep -q '系统信息查询' /tmp/v3/menu-$choice.txt && ck "菜单选 6 进系统信息" 0 || { ck "菜单选 6 进系统信息" 1; tail -4 /tmp/v3/menu-$choice.txt | sed 's/^/     /'; } ;;
      7) grep -q '基础工具' /tmp/v3/menu-$choice.txt && ck "菜单选 7 进基础工具" 0 || { ck "菜单选 7 进基础工具" 1; tail -4 /tmp/v3/menu-$choice.txt | sed 's/^/     /'; } ;;
      8) grep -q '自动换源' /tmp/v3/menu-$choice.txt && ck "菜单选 8 进自动换源" 0 || { ck "菜单选 8 进自动换源" 1; tail -4 /tmp/v3/menu-$choice.txt | sed 's/^/     /'; } ;;
      9) grep -q '自定义 SSH 连接端口' /tmp/v3/menu-$choice.txt && ck "菜单选 9 进 SSH 端口" 0 || { ck "菜单选 9 进 SSH 端口" 1; tail -4 /tmp/v3/menu-$choice.txt | sed 's/^/     /'; } ;;
      10) grep -q '内核管理' /tmp/v3/menu-$choice.txt && ck "菜单选 10 进内核管理" 0 || { ck "菜单选 10 进内核管理" 1; tail -4 /tmp/v3/menu-$choice.txt | sed 's/^/     /'; } ;;
      11) grep -q 'TCP 加速' /tmp/v3/menu-$choice.txt && ck "菜单选 11 进 TCP 加速管理" 0 || { ck "菜单选 11 进 TCP 加速管理" 1; tail -4 /tmp/v3/menu-$choice.txt | sed 's/^/     /'; } ;;
      12) grep -q '3x-ui 面板管理' /tmp/v3/menu-$choice.txt && ck "菜单选 12 进 3x-ui 面板" 0 || { ck "菜单选 12 进 3x-ui 面板" 1; tail -4 /tmp/v3/menu-$choice.txt | sed 's/^/     /'; } ;;
    esac
    # 主流程第一步的横幅是它独有的标记；出现即说明选 4~11 后仍然重写了 DNS
    grep -q '关闭会改写 resolv.conf 的服务' /tmp/v3/menu-$choice.txt && ck "菜单选 $choice 未误入主流程" 1 || ck "菜单选 $choice 未误入主流程" 0
  done
  grep -q '7) 基础工具安装' /tmp/v3/menu-1.txt && ck "菜单列出选项 7" 0 || ck "菜单列出选项 7" 1
  grep -q '8) 自动换源' /tmp/v3/menu-1.txt && ck "菜单列出选项 8" 0 || ck "菜单列出选项 8" 1
  grep -q '9) 自定义 SSH 端口' /tmp/v3/menu-1.txt && ck "菜单列出选项 9" 0 || ck "菜单列出选项 9" 1
  grep -q '10) 内核管理' /tmp/v3/menu-1.txt && ck "菜单列出选项 10" 0 || ck "菜单列出选项 10" 1
  grep -q '11) TCP 加速管理' /tmp/v3/menu-1.txt && ck "菜单列出选项 11" 0 || ck "菜单列出选项 11" 1
  grep -q '12) 3x-ui 面板' /tmp/v3/menu-1.txt && ck "菜单列出选项 12" 0 || ck "菜单列出选项 12" 1

  # --- 回归：stdin 是脚本内容本身（等价 `bash <(curl ...)` / `bash <(wget -qO- ...)`）---
  # 这种写法下 [ -t 0 ] 为假，必须靠 /dev/tty 才能读到菜单输入。
  printf '2\n' | timeout 90 script -qec "cat $SRC | SET_DNS_ETC=$MNT SET_DNS_SBIN=$MNT/sbin SET_DNS_LOG=$MNT/dns-watch.log bash" /dev/null > /tmp/v3/menu-pipe.txt 2>&1
  grep -q '请选择 DNS 模式' /tmp/v3/menu-pipe.txt && ck "stdin 为脚本管道时菜单仍弹出" 0 || { ck "stdin 为脚本管道时菜单仍弹出" 1; tail -4 /tmp/v3/menu-pipe.txt | sed 's/^/     /'; }
  grep -q '模式: DoT 加密' /tmp/v3/menu-pipe.txt && ck "stdin 为脚本管道时选择生效" 0 || ck "stdin 为脚本管道时选择生效" 1
  out=$(cat "$SRC" | bash -s -- --help 2>&1)
  echo "$out" | grep -q 'set-dns v3.10' && ck "管道方式 --help 有输出" 0 || ck "管道方式 --help 有输出" 1
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
echo "===== 15. 守护自愈：托管副本丢失 / 为空 / 守护脚本被删 ====="
# 这一组是线上实测出来的真实漏洞：守护原来只认主托管副本，副本一丢就永久只写
# action=repair 却永不修复，整机 DNS 死在 127.0.0.53；守护脚本被删则 apt 钩子静默摆烂。
rm -f "$MNT/resolv.conf"; rm -rf "$MNT/set-dns.bak" "$MNT/sbin"
EX --plain >/dev/null 2>&1
EX --guard >/dev/null 2>&1
W="$MNT/sbin/dns-watch.sh"
M1="$MNT/set-dns.bak/resolv.conf.managed"
M2="$MNT/sbin/dns-watch.managed"
[ -x "$W" ] && ck "守护脚本已生成" 0 || ck "守护脚本已生成" 1
[ -s "$M1" ] && [ -s "$M2" ] && ck "托管副本已双写两处" 0 || ck "托管副本已双写两处" 1
[ -s "$MNT/sbin/dns-watch.sh.bak" ] && ck "守护脚本已留底" 0 || ck "守护脚本已留底" 1
grep -q 'network-online.target' "$MNT/systemd/system/dns-watch.service" && ck "service 等网络就绪" 0 || ck "service 等网络就绪" 1
grep -q 'dns-watch.sh.bak' "$MNT/apt/apt.conf.d/99-dns-watch" && ck "apt 钩子含自愈补回" 0 || ck "apt 钩子含自愈补回" 1

# 用例 B：resolv.conf 改坏 + 主副本被删 -> 必须靠第二副本修好
printf 'nameserver 127.0.0.53\n' > "$MNT/resolv.conf"; rm -f "$M1"
bash "$W" >/dev/null 2>&1
grep -q '127.0.0.53' "$MNT/resolv.conf" && ck "主副本丢失后仍被修复" 1 || ck "主副本丢失后仍被修复" 0
cmp -s "$MNT/resolv.conf" "$M2" && ck "修复内容取自第二副本" 0 || ck "修复内容取自第二副本" 1
[ -s "$M1" ] && ck "缺失的主副本被补回" 0 || ck "缺失的主副本被补回" 1

# 用例 C：两份托管副本全丢 -> 必须救急，绝不留在无 DNS 状态
printf 'nameserver 127.0.0.53\n' > "$MNT/resolv.conf"; rm -f "$M1" "$M2"
bash "$W" >/dev/null 2>&1
grep -q '127.0.0.53' "$MNT/resolv.conf" && ck "两份副本全丢时仍能救急" 1 || ck "两份副本全丢时仍能救急" 0
grep -q 'nameserver 1.1.1.1' "$MNT/resolv.conf" && ck "救急内容含可用解析器" 0 || ck "救急内容含可用解析器" 1
grep -q 'set-dns recovery' "$MNT/resolv.conf" && ck "救急内容有标记" 0 || ck "救急内容有标记" 1
[ -s "$M1" ] && [ -s "$M2" ] && ck "救急内容回写两份副本" 0 || ck "救急内容回写两份副本" 1
tail -1 "$MNT/dns-watch.log" 2>/dev/null | grep -q 'rescue' && ck "日志记录 rescue" 0 || { ck "日志记录 rescue" 1; tail -1 "$MNT/dns-watch.log" | sed 's/^/     /'; }

# 用例 D：resolv.conf 正常但副本被清空 -> 用当前配置重建副本
rm -f "$M1" "$M2"
EX --plain >/dev/null 2>&1; rm -f "$M1" "$M2"
bash "$W" >/dev/null 2>&1
[ -s "$M1" ] && ck "副本被清空后自动重建" 0 || ck "副本被清空后自动重建" 1

# 用例 E：--unguard 只拆防护，不动 DNS 配置
before=$(md5sum "$MNT/resolv.conf" | cut -d' ' -f1)
out=$(EX --unguard 2>&1)
echo "$out" | grep -q '防护守护已移除' && ck "--unguard 报告已移除" 0 || { ck "--unguard 报告已移除" 1; echo "$out" | tail -5 | sed 's/^/     /'; }
[ -e "$W" ] && ck "--unguard 删掉守护脚本" 1 || ck "--unguard 删掉守护脚本" 0
[ -e "$MNT/systemd/system/dns-watch.path" ] && ck "--unguard 删掉 path 单元" 1 || ck "--unguard 删掉 path 单元" 0
[ -e "$MNT/apt/apt.conf.d/99-dns-watch" ] && ck "--unguard 删掉 apt 钩子" 1 || ck "--unguard 删掉 apt 钩子" 0
[ "$(md5sum "$MNT/resolv.conf" | cut -d' ' -f1)" = "$before" ] && ck "--unguard 不动 DNS 配置" 0 || ck "--unguard 不动 DNS 配置" 1
out=$(EX --unguard 2>&1)
echo "$out" | grep -q '没有安装防护守护' && ck "重复 --unguard 友好提示" 0 || ck "重复 --unguard 友好提示" 1
EX --guard >/dev/null 2>&1
[ -x "$W" ] && ck "--guard 可重新装回" 0 || ck "--guard 可重新装回" 1
[ -s "$MNT/apt/apt.conf.d/99-dns-watch" ] && ck "--guard 重装后 apt 钩子就位" 0 || ck "--guard 重装后 apt 钩子就位" 1

echo
echo "===== 16. 换源改写逻辑单元测（verify-mirror.sh）====="
# 换源的文本改写分支多（老式 / deb822 / 选项段 / Signed-By / 第三方源），
# 单独一个文件跑，不联网不需要 root，任何机器都能验。这里串起来跑一遍并汇总。
MIRROR_T="$(dirname "$0")/verify-mirror.sh"
if [ -f "$MIRROR_T" ]; then
  mout=$(SRC="$SRC" bash "$MIRROR_T" 2>&1); mrc=$?
  msum=$(printf '%s\n' "$mout" | grep '=== MIRROR_DONE' | tail -1)
  echo "  $msum"
  mf=$(printf '%s' "$msum" | sed -n 's/.*FAIL=\([0-9][0-9]*\).*/\1/p')
  case "${mf:-1}" in
    0) ck "换源单元测全绿" 0 ;;
    *) ck "换源单元测全绿（$msum）" 1; printf '%s\n' "$mout" | grep '\[FAIL\]' | sed 's/^/     /' | head -10 ;;
  esac
  [ "$mrc" = 0 ] && ck "换源单元测退出码 0" 0 || ck "换源单元测退出码 0（得到 $mrc）" 1
else
  echo "  [跳过] 没有 $MIRROR_T（单独上传该文件即可）"
fi

echo
echo "===== 17. zz 快捷键与自动更新单元测（verify-zz.sh）====="
# zz/自动更新涉及"另起进程的入口脚本 + 联网检查 + 防降级换新"，分支多且都在沙箱里能验
# （全程落在 mktemp 出来的临时目录，不碰真实 /usr/local）。这里串起来跑并汇总。
ZZ_T="$(dirname "$0")/verify-zz.sh"
if [ -f "$ZZ_T" ]; then
  zout=$(SRC="$SRC" bash "$ZZ_T" 2>&1); zrc=$?
  zsum=$(printf '%s\n' "$zout" | grep '=== ZZ_TEST' | tail -1)
  echo "  $zsum"
  zf=$(printf '%s' "$zsum" | sed -n 's/.*FAIL=\([0-9][0-9]*\).*/\1/p')
  case "${zf:-1}" in
    0) ck "zz 单元测全绿" 0 ;;
    *) ck "zz 单元测全绿（$zsum）" 1; printf '%s\n' "$zout" | grep 'FAIL -' | sed 's/^/     /' | head -10 ;;
  esac
  [ "$zrc" = 0 ] && ck "zz 单元测退出码 0" 0 || ck "zz 单元测退出码 0（得到 $zrc）" 1
else
  echo "  [跳过] 没有 $ZZ_T（单独上传该文件即可）"
fi

echo "===== 18. 系统更新/清理单元测（verify-sysupd.sh）====="
# 系统更新/清理会真跑 apt，绝不能在沙箱里执行；那个文件用**桩包管理器**驱动，
# 全程只验"该不该执行、执行了什么、危险项有没有被拦住"。附带源码级不变式
# （不删 /var/log、不用 vacuum-time=1s、不 pkill）。这里串起来跑并汇总。
SU_T="$(dirname "$0")/verify-sysupd.sh"
if [ -f "$SU_T" ]; then
  sout=$(SRC="$SRC" bash "$SU_T" 2>&1); src_rc=$?
  ssum=$(printf '%s\n' "$sout" | grep '=== SU_TEST' | tail -1)
  echo "  $ssum"
  sf=$(printf '%s' "$ssum" | sed -n 's/.*FAIL=\([0-9][0-9]*\).*/\1/p')
  case "${sf:-1}" in
    0) ck "系统更新/清理单元测全绿" 0 ;;
    *) ck "系统更新/清理单元测全绿（$ssum）" 1; printf '%s\n' "$sout" | grep 'FAIL -' | sed 's/^/     /' | head -10 ;;
  esac
  [ "$src_rc" = 0 ] && ck "系统更新/清理单元测退出码 0" 0 || ck "系统更新/清理单元测退出码 0（得到 $src_rc）" 1
else
  echo "  [跳过] 没有 $SU_T（单独上传该文件即可）"
fi

echo "===== 19. 菜单 16 多协议 VPN/代理单元测（verify-vpn.sh）====="
# 菜单 16 会真装包/真写 /etc，绝不能在这里直接跑；那个文件全程走 SET_DNS_ETC 沙箱，
# 只验「配置写对没有、该清的清没清、该留的留没留」。
VP_T="$(dirname "$0")/verify-vpn.sh"
if [ -f "$VP_T" ]; then
  vout=$(SRC="$SRC" bash "$VP_T" 2>&1); vrc=$?
  vsum=$(printf '%s\n' "$vout" | grep '=== VPN_TEST' | tail -1)
  echo "  $vsum"
  vf=$(printf '%s' "$vsum" | sed -n 's/.*FAIL=\([0-9][0-9]*\).*/\1/p')
  case "${vf:-1}" in
    0) ck "菜单 16 单元测全绿" 0 ;;
    *) ck "菜单 16 单元测全绿（$vsum）" 1; printf '%s\n' "$vout" | grep 'FAIL -' | sed 's/^/     /' | head -10 ;;
  esac
  [ "$vrc" = 0 ] && ck "菜单 16 单元测退出码 0" 0 || ck "菜单 16 单元测退出码 0（得到 $vrc）" 1
else
  echo "  [跳过] 没有 $VP_T（单独上传该文件即可）"
fi

echo
umount "$MNT" 2>/dev/null
rm -rf "$MNT" "$IMG" /tmp/v3/menu-*.txt   # 注意别删 /tmp/v3 本身，否则下次还得重传脚本
echo "=== V3_DONE PASS=$PASS FAIL=$FAIL ==="
