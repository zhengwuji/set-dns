#!/bin/bash
# ---------------------------------------------------------------------------
# 「菜单 1/2/3 落地的到底是不是国际解析器」单元测（全部在沙箱里跑）
#
# 起因（真机复现，用户反馈"选择 1 2 3 最后DNS 都是 国内的dns 不对"）：
#   老版本的 cn_detect() 会按地理位置自动判定 —— 时区是 Asia/Shanghai 就直接
#   返回"是大陆"，而判不出来时**还默认当大陆**。于是：
#     * 菜单 1「明文 DNS —— 1.1.1.1 / 8.8.8.8」实际写 223.5.5.5 / 223.6.6.6
#     * 菜单 2 DoT / 菜单 3 DoH 的明文兜底也变成 223.5.5.5 / 223.6.6.6
#   菜单写的和实际做的对不上 = 用户看到的"不对"。
#   另外 cn_build_upstream4() 里"国际兜底"是**死代码**：上面那个循环刚好把
#   out 填到 2 条，下面判断 `[ ${#out[@]} -ge 2 ] && break` 立刻退出，
#   于是注释里写的"国内优先 + 国际兜底"从来只有国内那 2 条。
#
# 本文件锁住修好之后的行为：
#   A. 只有**显式**开关（SET_DNS_CN=1 / $BK/cn=1）才用国内解析器
#   B. 国内模式下**必须**带一条国际兜底，且总数不超过调用方给的上限
#   C. 菜单 1/2/3 在时区=Asia/Shanghai 的机器上仍写 1.1.1.1 / 8.8.8.8
# 用法：bash tests/verify-cn.sh
# ---------------------------------------------------------------------------
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$HERE/../set-dns.sh}
SB=${SB:-/tmp/cn-test-$$}
PASS=0; FAIL=0
ck() { if [ "$2" = 1 ]; then PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; fi; }
has()   { grep -qF -- "$2" "$1" 2>/dev/null && echo 1 || echo 0; }
hasre() { grep -qE -- "$2" "$1" 2>/dev/null && echo 1 || echo 0; }

rm -rf "$SB"; mkdir -p "$SB/etc/set-dns.bak" "$SB/bin"
ETC=$SB/etc; BK=$ETC/set-dns.bak
printf '%s\n' 'Asia/Shanghai' > "$ETC/timezone"     # 故意造成"大陆机器"

echo "===== A. 函数级：显式开关与上游组装（桩掉探测，不依赖网络）====="
# 把要测的函数体从脚本里抠出来 eval；probe/ok/inf 用桩顶掉，保证结果只由逻辑决定
eval "$(awk '/^cn_plain_v4\(\)/,/^}/'      "$SRC")"
eval "$(awk '/^cn_doh_servers\(\)/,/^}/'   "$SRC")"
eval "$(awk '/^cn_detect\(\)/,/^}/'        "$SRC")"
eval "$(awk '/^cn_hint\(\)/,/^}/'          "$SRC")"
eval "$(awk '/^cn_set_pref\(\)/,/^}/'      "$SRC")"
eval "$(awk '/^cn_pref_text\(\)/,/^}/'     "$SRC")"
eval "$(awk '/^cn_build_upstream4\(\)/,/^}/' "$SRC")"
eval "$(awk '/^cn_build_upstream_dot\(\)/,/^}/' "$SRC")"
eval "$(awk '/^cn_build_doh_servers\(\)/,/^}/' "$SRC")"
D4A=1.1.1.1; D4B=8.8.8.8; MAXNS=3
CN_PLAIN_ORDER="aliyun tencent 114 baidu dnspod hinet"
ok(){ :; }; inf(){ printf '%s\n' "$*"; }; no(){ :; }
# 桩：国内那几条都能通，1.1.1.1 通、8.8.8.8 不通（正好验"兜底挑得到人也挑得对"）
probe() { case "$1" in 8.8.8.8) return 1 ;; *) return 0 ;; esac; }
cn_probe4() { probe "$1"; }
cn_plain_v6() { return 1; }

# --- A1 默认（无任何显式开关）---
rm -f "$BK/cn"; unset SET_DNS_CN 2>/dev/null || true
if cn_detect; then ck "默认不启用国内解析器（时区是大陆也不启用）" 0; else ck "默认不启用国内解析器（时区是大陆也不启用）" 1; fi
ck "默认时 cn_build_upstream4 返回空（调用方走国际）" "$([ -z "$(cn_build_upstream4 3)" ] && echo 1 || echo 0)"

# --- A2 偏好文件 ---
cn_set_pref 1 >/dev/null
if cn_detect; then ck "偏好文件 = 1 时启用" 1; else ck "偏好文件 = 1 时启用" 0; fi
cn_set_pref 0 >/dev/null
if cn_detect; then ck "偏好文件 = 0 时不启用" 0; else ck "偏好文件 = 0 时不启用" 1; fi

# --- A3 环境变量优先于文件 ---
cn_set_pref 0 >/dev/null
if SET_DNS_CN=1 cn_detect; then ck "SET_DNS_CN=1 覆盖偏好文件 0" 1; else ck "SET_DNS_CN=1 覆盖偏好文件 0" 0; fi
cn_set_pref 1 >/dev/null
if SET_DNS_CN=0 cn_detect; then ck "SET_DNS_CN=0 覆盖偏好文件 1" 0; else ck "SET_DNS_CN=0 覆盖偏好文件 1" 1; fi

# --- A4 国内模式下的"国内优先 + 国际兜底"（死代码那处）---
cn_set_pref 1 >/dev/null
L3=$(cn_build_upstream4 3)
L2=$(cn_build_upstream4 2)
ck "cap=3 时给出 3 条" "$([ "$(printf '%s\n' "$L3" | grep -c .)" = 3 ] && echo 1 || echo 0)"
ck "cap=3 时前两条是国内（223.5.5.5）" "$(printf '%s\n' "$L3" | sed -n 1p | grep -qF '223.5.5.5' && echo 1 || echo 0)"
ck "cap=3 时**最后一条是国际兜底 1.1.1.1**（老版本这里是死代码，永远没有）" "$(printf '%s\n' "$L3" | sed -n 3p | grep -qF '1.1.1.1' && echo 1 || echo 0)"
ck "cap=2 时给出 2 条且含国际兜底" "$([ "$(printf '%s\n' "$L2" | grep -c .)" = 2 ] && printf '%s\n' "$L2" | grep -qF '1.1.1.1' && echo 1 || echo 0)"
ck "cap=1 时不超过 1 条" "$([ "$(printf '%s\n' "$(cn_build_upstream4 1)" | grep -c .)" -le 1 ] && echo 1 || echo 0)"
ck "非法 cap 当默认处理，不炸" "$(cn_build_upstream4 abc >/dev/null 2>&1 && echo 1 || echo 0)"

# --- A5 DoT / DoH 上游不含国内地址 ---
DOT=$(cn_build_upstream_dot)
ck "DoT 上游是 1.1.1.1@853 / 8.8.8.8@853" "$(printf '%s\n' "$DOT" | grep -qF '1.1.1.1@853' && printf '%s\n' "$DOT" | grep -qF '8.8.8.8@853' && echo 1 || echo 0)"
ck "DoT 上游不含国内地址" "$(printf '%s\n' "$DOT" | grep -qE '223\.|119\.|114\.' && echo 0 || echo 1)"
unset SET_DNS_CN 2>/dev/null || true
rm -f "$BK/cn"
ck "未启用国内时 DoH 用 cloudflare google" "$([ "$(cn_build_doh_servers)" = "cloudflare google" ] && echo 1 || echo 0)"
cn_set_pref 1 >/dev/null
ck "启用国内时 DoH 含 alidns-doh" "$(cn_build_doh_servers | grep -qF 'alidns-doh' && echo 1 || echo 0)"
ck "启用国内时 DoH 仍保留 cloudflare 兜底" "$(cn_build_doh_servers | grep -qF 'cloudflare' && echo 1 || echo 0)"

# --- A6 提示与偏好显示 ---
rm -f "$BK/cn"
ck "时区是大陆但没开开关时会提示怎么开" "$(cn_hint | grep -qF -- '--cn-dns=on' && echo 1 || echo 0)"
cn_set_pref 1 >/dev/null
ck "已经启用时不再重复提示" "$([ -z "$(cn_hint)" ] && echo 1 || echo 0)"
ck "SET_DNS_CN=0 时也不提示" "$([ -z "$(SET_DNS_CN=0 cn_hint)" ] && echo 1 || echo 0)"
ck "偏好显示能反映文件状态" "$(cn_pref_text | grep -qF '开启' && echo 1 || echo 0)"
cn_set_pref auto >/dev/null
ck "清除偏好后回到默认文案" "$(cn_pref_text | grep -qF '未设置' && echo 1 || echo 0)"

echo "===== B. 源码级不变式（防止有人又把自动判定加回去）====="
# cn_detect 里**不能**再出现"按 tz 返回 0"这种自动判定
CN_BODY=$(awk '/^cn_detect\(\)/,/^}/' "$SRC")
ck "cn_detect 不再读 timezone 做判定" "$(printf '%s\n' "$CN_BODY" | grep -q 'timezone' && echo 0 || echo 1)"
ck "cn_detect 不再出现 Asia/Shanghai" "$(printf '%s\n' "$CN_BODY" | grep -q 'Asia/Shanghai' && echo 0 || echo 1)"
ck "cn_detect 会读偏好文件 \$BK/cn" "$(printf '%s\n' "$CN_BODY" | grep -qF '$BK/cn' && echo 1 || echo 0)"
# 死代码那处的判断条件不能回来
UP_BODY=$(awk '/^cn_build_upstream4\(\)/,/^}/' "$SRC")
ck "cn_build_upstream4 里没有 '\${#out[@]} -ge 2' 这种写死上限" "$(printf '%s\n' "$UP_BODY" | grep -qF '${#out[@]}" -ge 2' && echo 0 || echo 1)"
ck "cn_build_upstream4 支持传入上限 cap" "$(printf '%s\n' "$UP_BODY" | grep -qF 'cap=${1:-2}' && echo 1 || echo 0)"
ck "明文模式把 MAXNS 传给 cn_build_upstream4" "$(hasre "$SRC" 'cn_build_upstream4 "\$MAXNS"')"
ck "加密兜底按 MAXNS-1 要位置" "$(hasre "$SRC" 'cn_build_upstream4 \$\(\(MAXNS - 1\)\)')"
ck "菜单 13 走 cn_menu（能改偏好，不再只是只读）" "$(hasre "$SRC" 'CMD" = cn-dns \]; then cn_menu')"
ck "两条 cn_act 分发（root 闸前后各一）" "$([ "$(grep -c 'cn_act "\$CN_ACT"' "$SRC")" = 2 ] && echo 1 || echo 0)"

echo "===== C. 脚本级：偏好文件与帮助文案（沙箱 SET_DNS_ETC）====="
run() {
  SET_DNS_ETC=$ETC SET_DNS_ZZ_LIB=$SB/zl SET_DNS_ZZ_BIN=$SB/zb \
  SET_DNS_ZZ_NO_UPDATE=1 bash "$SRC" "$@" 2>&1
}
O=$(run --cn-dns=on);  ck "--cn-dns=on 写入 \$BK/cn=1" "$([ "$(cat "$BK/cn" 2>/dev/null)" = 1 ] && echo 1 || echo 0)"
ck "--cn-dns=on 有回执" "$(printf '%s' "$O" | grep -qF '已记住' && echo 1 || echo 0)"
O=$(run --cn-dns=off); ck "--cn-dns=off 写入 \$BK/cn=0" "$([ "$(cat "$BK/cn" 2>/dev/null)" = 0 ] && echo 1 || echo 0)"
run --cn-dns=auto >/dev/null; ck "--cn-dns=auto 删掉偏好文件" "$([ -e "$BK/cn" ] && echo 0 || echo 1)"
O=$(run --cn-dns=off); rm -f "$BK/cn"
O=$(run --cn-dns 2>&1); ck "--cn-dns 只读面板不创建偏好文件" "$([ -e "$BK/cn" ] && echo 0 || echo 1)"
ck "--cn-dns 面板会打印当前偏好" "$(printf '%s' "$O" | grep -qF '未设置' && echo 1 || echo 0)"
O=$(run --cn-dns=bogus); RC=$?
ck "--cn-dns=bogus 报错退出" "$(printf '%s' "$O" | grep -qF '不认识的参数' && echo 1 || echo 0)"

O=$(run --help)
ck "帮助里有 --cn-dns=on"  "$(printf '%s' "$O" | grep -qF -- '--cn-dns=on'  && echo 1 || echo 0)"
ck "帮助里有 --cn-dns=off" "$(printf '%s' "$O" | grep -qF -- '--cn-dns=off' && echo 1 || echo 0)"
ck "帮助里有 --cn-dns=auto" "$(printf '%s' "$O" | grep -qF -- '--cn-dns=auto' && echo 1 || echo 0)"
ck "菜单 13 文案说明要显式开启" "$(printf '%s' "$O" | grep -qE '13\) 大陆 DNS 预设.*显式' && echo 1 || echo 0)"
ck "菜单 1 文案仍是 1.1.1.1 / 8.8.8.8" "$(printf '%s' "$O" | grep -qF '1.1.1.1 / 8.8.8.8' && echo 1 || echo 0)"

echo "===== D. 端到端 dry-run：大陆时区机器上菜单 1 写的是国际解析器 ====="
rm -f "$BK/cn"
O=$(run --plain --dry-run)
ck "dry-run 输出里点出了'仍然按国际解析器'" "$(printf '%s' "$O" | grep -qF '但本次仍按国际解析器配置' && echo 1 || echo 0)"
ck "dry-run 要写的第一条是 1.1.1.1" "$(printf '%s' "$O" | grep -qE 'nameserver 1\.1\.1\.1' && echo 1 || echo 0)"
ck "dry-run 里**没有** 223.5.5.5" "$(printf '%s' "$O" | grep -qE 'nameserver 223\.5\.5\.5' && echo 0 || echo 1)"
ck "dry-run 保持不改（明确说没动）" "$(printf '%s' "$O" | grep -qF 'dry-run，什么都没改' && echo 1 || echo 0)"
# 真实文件没被动过（dry-run 的意义就在这）
ck "dry-run 没真的写 resolv.conf" "$([ -e "$ETC/resolv.conf" ] && echo 0 || echo 1)"

rm -rf "$SB"
echo "=== CN_TEST PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
