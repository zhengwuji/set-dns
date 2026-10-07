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

hr "S0b 系统信息查询（--sysinfo，纯只读，不许动任何文件）"
snap_before=$(find /etc/set-dns.bak /usr/local/sbin /etc/systemd/system -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum)
rc_before=$(md5sum /etc/resolv.conf | cut -d' ' -f1)
bash "$SRC" --sysinfo > /tmp/v3/sysinfo.out 2>&1; si_rc=$?
sed 's/^/  /' /tmp/v3/sysinfo.out
echo "  退出码: $si_rc（应为 0）"
echo "  resolv.conf 是否被改动: $( [ "$(md5sum /etc/resolv.conf | cut -d' ' -f1)" = "$rc_before" ] && echo 否-正确 || echo 是-有问题)"
snap_after=$(find /etc/set-dns.bak /usr/local/sbin /etc/systemd/system -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum)
echo "  守护/DNS 相关文件是否被改动: $( [ "$snap_before" = "$snap_after" ] && echo 否-正确 || echo 是-有问题)"
echo "  字段完整性: $(bash "$SRC" --sysinfo 2>/dev/null | grep -cE '主机名:|系统版本:|Linux版本:|CPU架构:|CPU型号:|CPU核心数:|CPU频率:|CPU占用:|系统负载:|TCP/UDP连接数:|物理内存:|虚拟内存:|硬盘占用:|总接收:|总发送:|网络算法:|运营商:|IPv4地址:|DNS地址:|地理位置:|系统时间:|运行时长:')/22"
echo "  裸数字写法 set-dns 6: $(bash "$SRC" 6 2>/dev/null | head -1)"

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

hr "S5 抗故障演练 2：托管副本被毁（守护的致命盲区回归）"
M1=/etc/set-dns.bak/resolv.conf.managed
M2=/usr/local/sbin/dns-watch.managed
W=/usr/local/sbin/dns-watch.sh
echo "  副本现状: 主=$( [ -s "$M1" ] && echo "$(wc -c < "$M1")B" || echo 缺失)  第二=$( [ -s "$M2" ] && echo "$(wc -c < "$M2")B" || echo 缺失)"
echo "  留底: $( [ -s "$W.bak" ] && echo "$(wc -c < "$W.bak")B" || echo 缺失)"
echo "  A) 改坏 resolv.conf + 删主副本 -> 应靠第二副本修回"
printf 'nameserver 127.0.0.53\n' > /etc/resolv.conf; rm -f "$M1"
bash "$W" >/dev/null 2>&1
echo "     首行: $(head -1 /etc/resolv.conf)"
echo "     主副本是否补回: $( [ -s "$M1" ] && echo 是 || echo 否)"
echo "  B) 改坏 + 两份副本全删 -> 应救急，绝不无 DNS"
printf 'nameserver 127.0.0.53\n' > /etc/resolv.conf; rm -f "$M1" "$M2"
bash "$W" >/dev/null 2>&1
echo "     首行: $(head -1 /etc/resolv.conf)"
echo "     是否还在 127.0.0.53: $(grep -q 127.0.0.53 /etc/resolv.conf && echo 是-未修复 || echo 否-已救回)"
echo "     两份副本是否回写: 主=$( [ -s "$M1" ] && echo 是 || echo 否) 第二=$( [ -s "$M2" ] && echo 是 || echo 否)"
echo "     getent: $(rdy)  curl: $(c)"
# 注意：改 resolv.conf 会同时触发 dns-watch.path，它的那次运行可能排在我们这次之后，
# 那一刻文件已被救回、副本也在，所以它记 ok —— 因此不能只看 tail -1，要查整段日志。
echo "     日志最近 5 行:"; tail -5 /var/log/dns-watch.log 2>/dev/null | sed 's/^/       /'
echo "     本段是否记录 rescue: $(tail -20 /var/log/dns-watch.log 2>/dev/null | grep -q 'action=rescue' && echo 是-正确 || echo 否-需检查)"
echo "  C) 重配一次恢复完整状态"
bash "$SRC" --doh >/dev/null 2>&1
echo "     模式: $(cat /etc/set-dns.bak/mode 2>/dev/null)  副本: 主=$( [ -s "$M1" ] && echo OK || echo 缺) 第二=$( [ -s "$M2" ] && echo OK || echo 缺)"
echo "     getent: $(rdy)  curl: $(c)"

hr "S6 --unguard / --guard 往返（只动防护，不动 DNS 配置）"
before=$(md5sum /etc/resolv.conf | cut -d' ' -f1)
bash "$SRC" --unguard 2>&1 | tail -5
echo "  resolv.conf 是否被改动: $( [ "$(md5sum /etc/resolv.conf | cut -d' ' -f1)" = "$before" ] && echo 否-正确 || echo 是-有问题)"
echo "  守护脚本还在吗: $( [ -e "$W" ] && echo 在-有问题 || echo 已删-正确)"
echo "  path 单元还在吗: $( [ -e /etc/systemd/system/dns-watch.path ] && echo 在-有问题 || echo 已删-正确)"
echo "  getent: $(rdy)  curl: $(c)"
bash "$SRC" --guard 2>&1 | tail -5
echo "  重装后守护: $( [ -x "$W" ] && echo 就位 || echo 缺失)  path 状态: $(systemctl is-enabled dns-watch.path 2>/dev/null)"
echo "  getent: $(rdy)  curl: $(c)"

hr "S7 最终状态"
live
echo "  模式记录: $(cat /etc/set-dns.bak/mode 2>/dev/null)"
echo "  守护: path=$(systemctl is-active dns-watch.path 2>/dev/null) timer=$(systemctl is-active dns-watch.timer 2>/dev/null)"
echo "  副本: 主=$( [ -s "$M1" ] && echo OK || echo 缺) 第二=$( [ -s "$M2" ] && echo OK || echo 缺) 留底=$( [ -s "$W.bak" ] && echo OK || echo 缺)"
echo "=== REAL_DONE ==="
