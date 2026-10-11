#!/bin/bash
# ---------------------------------------------------------------------------
# 菜单 16「多协议 VPN / 代理」单元测（全部在沙箱里跑，不碰真实 /etc、/usr/local）
#
# 覆盖的是「只有真机踩过才知道」的那些点，每一条都对应一次实际故障：
#   * xl2tpd.conf 首行必须是 [global]（首行注释会让 xl2tpd 起不来）
#   * ipsec.secrets 里的私钥类型要按实际类型写（LE 的 IP 证书是 ECDSA，写 RSA 会没有私钥）
#   * 证书链的中间证书要同步到 ipsec.d/cacerts（否则 Linux 客户端 IKE_AUTH 失败）
#   * 单独卸 SSTP 不能删 chap-secrets（否则还在跑的 L2TP 立刻认证失败）
#   * sstpd 的 ExecStart 必须显式 -l 0.0.0.0（默认值 "all" 会让 getaddrinfo 失败）
#   * nat.sh 的 down 分支要真的撤得掉规则
# 用法：bash tests/verify-vpn.sh
# ---------------------------------------------------------------------------
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$HERE/../set-dns.sh}
SB=${SB:-/tmp/vpn-test-$$}
PASS=0; FAIL=0
ck() { if [ "$2" = 1 ]; then PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; fi; }
has()   { grep -qF -- "$2" "$1" 2>/dev/null && echo 1 || echo 0; }
hasre() { grep -qE -- "$2" "$1" 2>/dev/null && echo 1 || echo 0; }
both()  { [ "$1" = 1 ] && [ "$2" = 1 ] && echo 1 || echo 0; }

IPA=203.0.113.9
TRY_LE_DIR=${TRY_LE_DIR:-}
run() {
  SET_DNS_ETC=$SB/etc SET_DNS_VPN_IP=$IPA \
  SET_DNS_ZZ_LIB=$SB/zl SET_DNS_ZZ_BIN=$SB/zb \
  SET_DNS_ZZ_NO_UPDATE=1 SET_DNS_VPN_LE_DIR=$TRY_LE_DIR \
  bash "$SRC" "$@" 2>&1
}
rm -rf "$SB"; mkdir -p "$SB/etc/bin"
VD=$SB/set-dns-vpn; ETC=$SB/etc
# 造一个假的 gost 可执行文件：沙箱里下不到真 gost 会退成 microsocks，
# 那样就测不到 gost 那个 unit（VPN_GOST=$(dirname "$ZZ_BIN")/bin/gost）
mkdir -p "$SB/bin"
printf '#!/bin/sh\nexit 0\n' > "$SB/bin/gost"
chmod +x "$SB/bin/gost"

echo "===== 1. 干净沙箱下的 --vpn=status ====="
O=$(run --vpn=status)
ck "status 不崩且提示还没有凭据" "$(echo "$O" | grep -qF '还没有生成任何凭据' && echo 1 || echo 0)"
ck "status 能列出各协议检查行" "$(echo "$O" | grep -qE 'SoftEther|SSTP|PPTP' && echo 1 || echo 0)"

echo "===== 2. 帮助 / 菜单接线 ====="
O=$(run --help)
ck "帮助里有菜单 16" "$(echo "$O" | grep -qF '16) 多协议 VPN/代理' && echo 1 || echo 0)"
ck "帮助里有 --vpn=softether" "$(echo "$O" | grep -qF -- '--vpn=softether' && echo 1 || echo 0)"
ck "帮助里有 --vpn=remove" "$(echo "$O" | grep -qF -- '--vpn=remove' && echo 1 || echo 0)"
ck "pick_mode 里 16) 走 vpn" "$(grep -qE '^[[:space:]]+16\) CMD=vpn ;;' "$SRC" && echo 1 || echo 0)"
ck "分发点至少写了 3 处 vpn_entry" "$([ "$(grep -c 'CMD" = vpn \]; then vpn_entry' "$SRC")" -ge 3 ] && echo 1 || echo 0)"
ck "主菜单是循环的（子菜单返回能回主菜单）" "$(grep -q 'MENU_FIRST=1' "$SRC" && grep -q 'MENU_BACK=1' "$SRC" && echo 1 || echo 0)"

echo "===== 3. 七个协议全装 ====="
run --vpn=all >/dev/null
ck "installed 有 7 行" "$([ "$(grep -c . "$VD/installed" 2>/dev/null)" = 7 ] && echo 1 || echo 0)"
for x in socks5 ikev2 l2tp-psk l2tp-cert sstp pptp softether; do
  ck "installed 里有 $x" "$(hasre "$VD/installed" "^$x[|]")"
done

echo "===== 4. 证书 ====="
ck "私有 CA 生成了" "$([ -s "$VD/ca/ca.crt" ] && [ -s "$VD/ca/ca.key" ] && echo 1 || echo 0)"
ck "服务端证书生成了" "$([ -s "$VD/certs/server.crt" ] && [ -s "$VD/certs/server.key" ] && echo 1 || echo 0)"
ck "客户端 p12 导出了" "$([ -s "$VD/clients/client.p12" ] && echo 1 || echo 0)"
ck "ca.crt 拷给了客户端" "$([ -s "$VD/clients/ca.crt" ] && echo 1 || echo 0)"
SAN=$(openssl x509 -in "$VD/certs/server.crt" -noout -ext subjectAltName 2>/dev/null | tr -d ' ')
EKU=$(openssl x509 -in "$VD/certs/server.crt" -noout -ext extendedKeyUsage 2>/dev/null)
ck "服务端证书 SAN 是本金公网 IP" "$(echo "$SAN" | grep -qF "IPAddress:$IPA" && echo 1 || echo 0)"
ck "服务端证书带 serverAuth" "$(echo "$EKU" | grep -q 'TLS Web Server Authentication' && echo 1 || echo 0)"
ck "服务端证书带 ikeIntermediate" "$(echo "$EKU" | grep -qi 'Internet Key Exchange' && echo 1 || echo 0)"

echo "===== 5. ipsec.secrets 的私钥类型（真机踩过：LE 是 ECDSA；且 openssl ec 的退出码不能信）====="
K=$VD/certs/server.key
if openssl pkey -in "$K" -noout -text 2>/dev/null | head -30 | grep -q 'ASN1 OID'; then WANT=ECDSA; else WANT=RSA; fi
ck "secrets 里私钥类型写成 $WANT（与实际一致）" "$(hasre "$ETC/ipsec.secrets" "^: $WANT ")"
ck "secrets 里有 EAP 行" "$(hasre "$ETC/ipsec.secrets" ': EAP "')"
ck "secrets 里有 PSK 行" "$(hasre "$ETC/ipsec.secrets" '%any %any : PSK "')"
M=$(stat -c %a "$ETC/ipsec.secrets" 2>/dev/null)
ck "secrets 权限不含全局可写位（$M；MSYS 下 chmod 是模拟的）" "$(case "$M" in 600|640|644) echo 1;; *) echo 0;; esac)"

echo "===== 6. ipsec.conf ====="
ck "三个 conn 都在" "$([ "$(grep -c '^conn ' "$ETC/ipsec.conf")" = 3 ] && echo 1 || echo 0)"
for cc in setdns-l2tp-psk setdns-l2tp-cert setdns-ikev2; do
  ck "有 conn $cc" "$(hasre "$ETC/ipsec.conf" "^conn $cc$")"
done
ck "l2tp-psk 用 PSK" "$(hasre "$ETC/ipsec.conf" 'authby=secret')"
ck "ikev2 用 eap-mschapv2" "$(hasre "$ETC/ipsec.conf" 'rightauth=eap-mschapv2')"
ck "ikev2 的 leftid 是公网 IP" "$(hasre "$ETC/ipsec.conf" "^    leftid=$IPA$")"
ck "有托管块标记 begin/end" "$(both "$(has "$ETC/ipsec.conf" '# set-dns-vpn begin')" "$(has "$ETC/ipsec.conf" '# set-dns-vpn end')")"

echo "===== 7. xl2tpd（真机踩过：首行不能是注释）====="
ck "xl2tpd.conf 第一行就是 [global]" "$([ "$(head -1 "$ETC/xl2tpd/xl2tpd.conf")" = '[global]' ] && echo 1 || echo 0)"
ck "xl2tpd.conf 里有 ip range" "$(hasre "$ETC/xl2tpd/xl2tpd.conf" '^ip range = 10[.]9[.]10[.]')"
ck "options.xl2tpd 里有 require-mschap-v2" "$(hasre "$ETC/ppp/options.xl2tpd" '^require-mschap-v2$')"

echo "===== 8. sstpd（真机踩过：必须 -l 0.0.0.0）====="
U=$ETC/systemd/system/set-dns-sstpd.service
ck "sstpd unit 存在" "$([ -s "$U" ] && echo 1 || echo 0)"
ck "ExecStart 显式 -l 0.0.0.0" "$(hasre "$U" -- '-l 0[.]0[.]0[.]0')"
ck "ExecStart 带 --local/--remote" "$(hasre "$U" -- '--local 10[.]9[.]30[.]1 --remote 10[.]9[.]30[.]0/24')"
ck "options.sstpd 存在" "$([ -s "$ETC/ppp/options.sstpd" ] && echo 1 || echo 0)"

echo "===== 9. PPTP / gost / SoftEther 配置文件 ====="
ck "pptpd.conf 有 localip" "$(hasre "$ETC/pptpd.conf" '^localip 10[.]9[.]20[.]1$')"
ck "pptpd-options 要求 MPPE" "$(hasre "$ETC/ppp/pptpd-options" '^require-mppe-128$')"
ck "gost unit 里 socks5+http 双端口" "$(both "$(hasre "$ETC/systemd/system/set-dns-gost.service" 'socks5://')" "$(has "$ETC/systemd/system/set-dns-gost.service" 'http://')")"
ck "SoftEther unit 是 Type=forking" "$(hasre "$ETC/systemd/system/set-dns-softether.service" '^Type=forking$')"

echo "===== 10. chap-secrets 托管块 + 保护用户自带内容 ====="
printf 'alice * "keepme" *\n' > "$ETC/ppp/chap-secrets"
run --vpn=pptp >/dev/null
ck "写入 setdns 那条" "$(hasre "$ETC/ppp/chap-secrets" '^setdns [*] "')"
ck "保留了用户自己那条 alice" "$(hasre "$ETC/ppp/chap-secrets" '^alice [*] "keepme" [*]$')"
ck "chap-secrets 托管块成对" "$(both "$(has "$ETC/ppp/chap-secrets" '# set-dns-vpn begin')" "$(has "$ETC/ppp/chap-secrets" '# set-dns-vpn end')")"
run --vpn=remove-sstp >/dev/null
ck "卸 SSTP 后 chap-secrets 仍在（L2TP 还在用）" "$([ -s "$ETC/ppp/chap-secrets" ] && echo 1 || echo 0)"
run --vpn=remove-ikev2 >/dev/null
ck "卸 IKEv2 后还剩 2 个 conn" "$([ "$(grep -c '^conn ' "$ETC/ipsec.conf")" = 2 ] && echo 1 || echo 0)"
ck "卸 IKEv2 后 secrets 里 EAP 行没了" "$(hasre "$ETC/ipsec.secrets" ': EAP "' | grep -q 1 && echo 0 || echo 1)"
ck "卸 IKEv2 后 PSK 行还在" "$(hasre "$ETC/ipsec.secrets" '%any %any : PSK "')"

echo "===== 11. nat.sh 幂等 + down 真的撤得掉 ====="
ck "nat.sh 生成且可执行" "$([ -x "$VD/nat.sh" ] && echo 1 || echo 0)"
ck "nat.sh 里没有未定义的 WAN2（曾导致 down 撤不掉）" "$(grep -q 'WAN2' "$VD/nat.sh" && echo 0 || echo 1)"
ck "四个隧道网段都在 NETS 里" "$(for nn in 10.9.10.0/24 10.9.20.0/24 10.9.30.0/24 10.9.40.0/24; do grep -qF "$nn" "$VD/nat.sh" || { echo 0; break; }; done | grep -q 0 && echo 0 || echo 1)"
ck "nat unit 是 oneshot + RemainAfterExit" "$(both "$(hasre "$ETC/systemd/system/set-dns-vpn-nat.service" '^Type=oneshot$')" "$(hasre "$ETC/systemd/system/set-dns-vpn-nat.service" '^RemainAfterExit=yes$')")"

echo "===== 12. 证书链同步（Linux 客户端 IKE_AUTH 失败的那个坑）====="
# 直接拿脚本自己签出来的 server.crt 当叶子、ca.crt 当中间证书拼一条 2 张的链。
# 不在这里现造证书：`openssl req -subj "/CN=leaf"` 在 git-bash 下会被 MSYS 把
# 开头的 / 当路径改写掉，命令直接失败（脚本内部早就改成写配置文件了）。
LD=$SB/le; mkdir -p "$LD"
cp -f "$VD/certs/server.key" "$LD/privkey.pem"
cat "$VD/certs/server.crt" "$VD/ca/ca.crt" > "$LD/fullchain.pem"
TRY_LE_DIR=$LD run --vpn=ikev2 >/dev/null
N=$(ls "$ETC/ipsec.d/cacerts"/setdns-chain-*.pem 2>/dev/null | wc -l)
ck "从 fullchain 里抽出了中间证书（实际 $N 张）" "$([ "$N" -ge 1 ] && echo 1 || echo 0)"
ck "LE 模式下 leftcert 指向 LE 的 fullchain" "$(hasre "$ETC/ipsec.conf" "leftcert=$LD/fullchain[.]pem")"
TRY_LE_DIR= run --vpn=ikev2 >/dev/null
ck "回到自建 CA 模式后 leftcert 指向自签服务端证书" "$(hasre "$ETC/ipsec.conf" "leftcert=$VD/certs/server[.]crt")"

echo "===== 13. 全部卸载 ====="
run --vpn=remove >/dev/null
ck "installed 被删掉" "$([ -e "$VD/installed" ] && echo 0 || echo 1)"
ck "ipsec.conf 清空了" "$([ -e "$ETC/ipsec.conf" ] && echo 0 || echo 1)"
ck "xl2tpd.conf 清掉了" "$([ -e "$ETC/xl2tpd/xl2tpd.conf" ] && echo 0 || echo 1)"
ck "chap-secrets 的托管块被清掉" "$(grep -q 'set-dns-vpn begin' "$ETC/ppp/chap-secrets" 2>/dev/null && echo 0 || echo 1)"
ck "chap-secrets 保留了用户自带的 alice 行" "$(hasre "$ETC/ppp/chap-secrets" '^alice [*] "keepme" [*]$')"
ck "证书/凭据保留（便于重装）" "$([ -s "$VD/credentials" ] && echo 1 || echo 0)"
ck "nat 单元被移除" "$([ -e "$ETC/systemd/system/set-dns-vpn-nat.service" ] && echo 0 || echo 1)"

echo "===== 14. dry-run 零改动 ====="
SB2=$SB-dry; rm -rf "$SB2"
SB_SAVE=$SB; SB=$SB2; mkdir -p "$SB/etc"
run --dry-run --vpn=ikev2 >/dev/null
ck "dry-run 没有生成 CA" "$([ -e "$SB/set-dns-vpn/ca/ca.crt" ] && echo 0 || echo 1)"
ck "dry-run 没有写 ipsec.conf" "$([ -e "$SB/etc/ipsec.conf" ] && echo 0 || echo 1)"
SB=$SB_SAVE

rm -rf "$SB" "$SB2"
echo
echo "=== VPN_TEST PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
