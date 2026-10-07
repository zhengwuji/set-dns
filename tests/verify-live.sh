#!/bin/bash
# set-dns v3 真机（非沙箱）端到端测试：DoT -> DoH，每步验真解析。
# 会在真实 /etc 上操作：先做一次 --dot，再做一次 --doh，然后验证守护自愈。
# 失败可随时回滚：bash set-dns.sh --restore
#
# 用法（在仓库根目录）：bash tests/verify-live.sh
#    或： SRC=/path/to/set-dns.sh bash tests/verify-live.sh
set -u
SRC=${SRC:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/set-dns.sh}
[ -f "$SRC" ] || { echo "找不到待测脚本 $SRC（用 SRC=... 指定）"; exit 2; }
# 真机测试前先确保 resolv.conf 是明文，万一中途出错也不会断 DNS
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf 2>/dev/null
hr(){ printf '\n########## %s ##########\n' "$1"; }
rdy(){ getent hosts raw.githubusercontent.com >/dev/null 2>&1 && echo "  getent OK" || echo "  getent FAIL"; }
live(){ echo "  resolv.conf: $(head -c 200 /etc/resolv.conf | tr '\n' '|')"; }
c() { curl -s -o /dev/null -m 12 -w '%{http_code}' https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh; }

hr "S0 前置快照"
cp -a /etc/resolv.conf /tmp/v3/pre_resolv.conf 2>/dev/null
cp -a /etc/unbound/unbound.conf /tmp/v3/pre_unbound.conf 2>/dev/null
echo "  之前 resolv.conf 形态: $(if [ -L /etc/resolv.conf ]; then echo "symlink -> $(readlink /etc/resolv.conf)"; else echo 普通文件; fi)"
live
echo "  curl 基线: $(c)"
echo "  unbound: $(systemctl is-active unbound)  dnscrypt-proxy: $(systemctl is-active dnscrypt-proxy 2>/dev/null || echo 未装)"

hr "S1 真机跑 --dot（安装/切换加密栈）"
bash "$SRC" --dot 2>&1 | tail -30
echo "  --- 切换后 ---"
live
echo "  getent: $(rdy)"
echo "  curl: $(c)"
echo "  到 853 的连接:"; ss -tn 2>/dev/null | grep -c ':853' || true
echo "  unbound 状态: $(systemctl is-active unbound)"
echo "  resolv 实测:"; getent hosts raw.githubusercontent.com | head -2

hr "S2 真机跑 --doh（装 dnscrypt-proxy，DoH 全链路）"
bash "$SRC" --doh 2>&1 | tail -35
echo "  --- 切换后 ---"
live
echo "  getent: $(rdy)"
echo "  curl: $(c)"
echo "  dnscrypt-proxy: $(systemctl is-active dnscrypt-proxy)"
echo "  监听 5353: $(ss -lun 2>/dev/null | grep -c ':5353')"
echo "  到 443 的 DoH 连接数: $(ss -tnp 2>/dev/null | grep dnscrypt | grep -c ':443')"
echo "  unbound 状态: $(systemctl is-active unbound)"
echo "  三个域名解析:"; for d in raw.githubusercontent.com github.com one.one.one.one; do printf '    %s -> %s\n' "$d" "$(getent hosts "$d" | head -1 | awk '{print $1}')"; done

hr "S3 --check 与守护"
bash "$SRC" --check 2>&1 | tail -20
echo "  dns-watch.path: $(systemctl is-active dns-watch.path 2>/dev/null)"
echo "  dns-watch.timer: $(systemctl is-active dns-watch.timer 2>/dev/null)"
echo "  apt 钩子: $(ls /etc/apt/apt.conf.d/99-dns-watch 2>/dev/null && cat /etc/apt/apt.conf.d/99-dns-watch | tail -1)"
echo "  守护日志末尾:"; tail -3 /var/log/dns-watch.log 2>/dev/null | sed 's/^/    /'

hr "S4 抗故障演练：手工把 resolv.conf 改坏，看守护是否毫秒级修回"
echo "nameserver 127.0.0.53" > /etc/resolv.conf
echo "  改坏后立即: $(head -1 /etc/resolv.conf)"
for i in 1 2 3 4 5 6; do sleep 1; done
echo "  等 6 秒后: $(head -1 /etc/resolv.conf)"
echo "  getent: $(rdy)  curl: $(c)"

hr "S5 最终状态"
live
echo "  模式记录: $(cat /etc/set-dns.bak/mode 2>/dev/null)"
echo "=== REAL_DONE ==="
