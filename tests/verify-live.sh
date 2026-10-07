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

hr "S0c 基础工具（--tools）：面板必须能出，且装完 DNS 仍然可用"
# 注意：这段会走真实分支。无 tty 时 --tools 不会询问，默认只装核心工具里缺的那几件
# （实测这台机器缺 git / sudo，就真的装上了）。装包会触发 apt 钩子跑一次守护脚本，属预期。
# 无论走「真装」还是「全都装好了」，只要不把 resolv.conf 弄坏、装完还能解析就算过。
rc_before=$(md5sum /etc/resolv.conf | cut -d' ' -f1)
bash "$SRC" --tools > /tmp/v3/tools.out 2>&1; tl_rc=$?
sed 's/^/  /' /tmp/v3/tools.out
echo "  退出码: $tl_rc（应为 0）"
echo "  面板含基础工具标题: $(grep -q '基础工具' /tmp/v3/tools.out && echo 是 || echo 否)"
echo "  面板工具数（✓+✗ 计）: $(grep -oE '[✓✗]' /tmp/v3/tools.out | wc -l)"
echo "  resolv.conf 是否被改动: $( [ "$(md5sum /etc/resolv.conf | cut -d' ' -f1)" = "$rc_before" ] && echo 否-正确 || echo 是-有问题)"
echo "  装完解析仍可用: $(rdy)"
echo "  装完守护仍活: path=$(systemctl is-active dns-watch.path) timer=$(systemctl is-active dns-watch.timer)"
echo "  裸数字写法 set-dns 7 首行: $(bash "$SRC" 7 2>/dev/null | head -1)"

hr "S0d 自动换源（--mirror）：改完能 apt update，第三方源一个字节没动，还原后回到原样"
# 这段会真的改 /etc/apt 里的发行版源（第三方源绝不动），跑完用 --mirror-restore 还原。
# 用 SET_DNS_MIRROR=aliyun 钉住候选，避免每次跑到不同源、结果不可复现。
if [ -d /etc/apt ]; then
  src_sum() { find /etc/apt/sources.list /etc/apt/sources.list.d -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum; }
  dist_sum() { grep -rhoE '(deb|URIs:)[[:space:]]+https?://[^ ]+' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
                 | grep -E 'debian\.org|ubuntu\.com' | sort | md5sum; }
  all_before=$(src_sum)
  echo "  换源前发行版源:"; grep -rhoE '(deb|URIs:)[[:space:]]+https?://[^ ]+' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
                        | grep -E 'debian\.org|ubuntu\.com' | sort -u | sed 's/^/    /' | head -6
  echo "  第三方源文件（绝不许被改）:"; grep -rl 'docker\|nodesource\|packages.microsoft\|mongodb\|pgdg' /etc/apt/sources.list.d/ 2>/dev/null | sed 's/^/    /' | head -6
  third_before=$(grep -rl 'docker\|nodesource\|packages.microsoft\|mongodb\|pgdg' /etc/apt/sources.list.d/ 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum)
  # 钉住候选 aliyun：不钉的话这台机器往往本来就选到 official，等于什么都没换，断言就变空转了。
  # 仍然真跑一遍测速（不加 NO_PROBE），确认探测链路是活的。
  SET_DNS_MIRROR=aliyun bash "$SRC" --mirror > /tmp/v3/mirror.out 2>&1; mr_rc=$?
  sed 's/^/  /' /tmp/v3/mirror.out | tail -25
  echo "  退出码: $mr_rc（应为 0）"
  echo "  换源后发行版源:"; grep -rhoE '(deb|URIs:)[[:space:]]+https?://[^ ]+' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
                        | grep -vE 'debian\.org|ubuntu\.com' | sort -u | sed 's/^/    /' | head -6
  echo "  第三方源是否被动过: $( [ "$third_before" = "$(grep -rl 'docker\|nodesource\|packages.microsoft\|mongodb\|pgdg' /etc/apt/sources.list.d/ 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum)" ] && echo 否-正确 || echo 是-有问题)"
  echo "  apt 是否仍可用: $(apt-get update -qq >/dev/null 2>&1 && echo 是-正确 || echo 否-需回滚)"
  echo "  resolv.conf 是否被改动: $(md5sum /etc/resolv.conf | cut -d' ' -f1)"
  echo "  还原: $(bash "$SRC" --mirror-restore 2>&1 | tail -2 | tr '\n' ' ')"
  # 注意：dist_sum 是函数，必须写 $(dist_sum)；写成 "$dist_sum" 在 set -u 下直接报 unbound variable（踩过）
  echo "  还原后发行版源是否回到原样: $( [ "$(dist_sum)" = "$(grep -rhoE '(deb|URIs:)[[:space:]]+https?://[^ ]+' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -E 'debian\.org|ubuntu\.com' | sort | md5sum)" ] && echo 是-正确 || echo 否-需检查)"
  echo "  还原后 apt: $(apt-get update -qq >/dev/null 2>&1 && echo OK || echo FAIL)"
  # 裸数字 8 也会真的换一次源，所以跑完必须再还原一次；
  # 这里同样钉住候选并跳过测速，免得为了验一个参数又去探十几个源。
  echo "  裸数字写法 set-dns 8 首行: $(SET_DNS_MIRROR_NO_PROBE=1 SET_DNS_MIRROR=aliyun bash "$SRC" 8 2>/dev/null | head -1)"
  echo "  再次还原: $(bash "$SRC" --mirror-restore 2>&1 | tail -1)"
  echo "  裸数字测试后 apt: $(apt-get update -qq >/dev/null 2>&1 && echo OK || echo FAIL)"
  # 最终一致性：还原干净后，整个 /etc/apt 应回到换源前的字节状态
  echo "  /etc/apt 是否完全回到换源前: $( [ "$all_before" = "$(src_sum)" ] && echo 是-正确 || echo 否-需检查)"
else
  echo "  本机没有 /etc/apt，跳过（非 Debian 系）"
fi

hr "S0e 自定义 SSH 端口（--ssh-port）：改完能连、校验失败会回滚、最后必须还原回原端口"
# 这段会真的改 sshd 配置并重启 sshd。安全约束（很重要，弄丢 22 就再也连不上了）：
#   1) 一律用 SET_DNS_SSH_KEEP=1 —— 新旧端口同时监听，任何时候都还能从 22 连回来；
#   2) 测完立刻 --ssh-port-restore 还原，断言配置逐字节回到测试前；
#   3) 绝不能在这段里把 22 关掉。
if [ -f /etc/ssh/sshd_config ]; then
  ssh_sum_orig=$(find /etc/ssh -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum)
  echo "  改前端口情况:"
  echo "    配置里的 Port: $(grep -hE '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tr '\n' ' ')"
  echo "    实际监听: $(ss -lnt 2>/dev/null | awk '{print $4}' | grep -oE '[:.][0-9]+$' | tr -d ':. ' | sort -un | tr '\n' ' ')"
  echo "  sshd -T port: $(sshd -T 2>/dev/null | grep -E '^port' | tr '\n' ' ')"
  echo "  单元: ssh.service=$(systemctl is-enabled ssh.service 2>/dev/null) ssh.socket=$(systemctl is-enabled ssh.socket 2>/dev/null)"
  # 只读子命令：不带端口时不该动任何东西
  ro_before=$(md5sum /etc/ssh/sshd_config | cut -d' ' -f1)
  SET_DNS_SSH_PORT= bash "$SRC" --ssh-port > /tmp/v3/sshport-ro.out 2>&1
  sed 's/^/  /' /tmp/v3/sshport-ro.out | head -12
  echo "  只读模式是否改动配置: $( [ "$(md5sum /etc/ssh/sshd_config | cut -d' ' -f1)" = "$ro_before" ] && echo 否-正确 || echo 是-有问题)"
  # 非法端口必须先被挡住，且不许碰配置
  SET_DNS_SSH_PORT=99999 bash "$SRC" --ssh-port > /tmp/v3/sshport-bad.out 2>&1; bad_rc=$?
  echo "  非法端口退出码: $bad_rc（应为非 0）"
  echo "  非法端口提示: $(grep -o '端口范围应为 1-65535' /tmp/v3/sshport-bad.out | head -1)"
  echo "  非法端口是否改动配置: $( [ "$(md5sum /etc/ssh/sshd_config | cut -d' ' -f1)" = "$ro_before" ] && echo 否-正确 || echo 是-有问题)"
  # 真改：保留旧端口双端口并行，改完两个端口都得在监听
  SET_DNS_SSH_KEEP=1 bash "$SRC" --ssh-port=2223 > /tmp/v3/sshport.out 2>&1; sp_rc=$?
  sed 's/^/  /' /tmp/v3/sshport.out | tail -22
  echo "  退出码: $sp_rc（应为 0）"
  echo "  sshd -T port: $(sshd -T 2>/dev/null | grep -E '^port' | tr '\n' ' ')"
  echo "  22 是否仍在监听: $(ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '[:.]22$' && echo 是-正确 || echo 否-危险)"
  echo "  2223 是否已在监听: $(ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '[:.]2223$' && echo 是-正确 || echo 否-需检查)"
  echo "  解析仍可用: $(rdy)"
  echo "  守护仍活: path=$(systemctl is-active dns-watch.path) timer=$(systemctl is-active dns-watch.timer)"
  # 还原：必须回到测试前的字节状态，并且只剩原来的端口
  sp_rb=$(bash "$SRC" --ssh-port-restore 2>&1)
  echo "$sp_rb" | sed 's/^/  /' | tail -8
  echo "  sshd -T port（应只剩原端口）: $(sshd -T 2>/dev/null | grep -E '^port' | tr '\n' ' ')"
  echo "  2223 是否已关闭: $(ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '[:.]2223$' && echo 否-需检查 || echo 是-正确)"
  echo "  22 是否可用: $(ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '[:.]22$' && echo 是-正确 || echo 否-危险)"
  echo "  /etc/ssh 是否逐字节回到测试前: $( [ "$ssh_sum_orig" = "$(find /etc/ssh -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum)" ] && echo 是-正确 || echo 否-需检查)"
  echo "  解析仍可用: $(rdy)"
  echo "  裸数字写法 set-dns 9 首行: $(SET_DNS_SSH_PORT= bash "$SRC" 9 2>/dev/null | sed -n '2p')"
else
  echo "  本机没有 /etc/ssh/sshd_config，跳过"
fi

hr "S0f 内核管理（--kernel）：只读面板必须不改任何东西；--kernel-update 只验计划"
# 这段刻意不真的装/卸内核 —— 内核换错档位或卸掉唯一内核都会导致重启后进不去系统，
# 所以真机只做三件事：① 只读面板；② --kernel-update 在 --dry-run 下出计划；
# ③ 改前改后对「resolv.conf + 守护相关目录 + /boot + /etc/default/grub」做哈希比对，必须完全一致。
krn_before=$( { cat /etc/resolv.conf 2>/dev/null; find /usr/local/sbin /etc/systemd/system /boot /etc/default -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null; } | md5sum)
echo "  改前内核: $(uname -r)"
echo "  改前 /boot 内内核镜像: $(ls /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | tr '\n' ' ')"
echo "  已装的 xanmod 包: $(dpkg-query -W -f '${Package} ' 'linux-image-*xanmod*' 'linux-xanmod-*' 2>/dev/null)"
echo "  xanmod 源: $( [ -f /etc/apt/sources.list.d/xanmod-release.list ] && echo 有-$(cat /etc/apt/sources.list.d/xanmod-release.list) || echo 无)"
bash "$SRC" --kernel > /tmp/v3/kernel.out 2>&1; krn_rc=$?
sed 's/^/  /' /tmp/v3/kernel.out
echo "  --kernel 退出码: $krn_rc（应为 0）"
echo "  档位判定: $(grep -o 'CPU 微架构档位： *[x0-9a-z]*' /tmp/v3/kernel.out | head -1)"
echo "  BBR 状态: $(grep -o 'BBR 状态：.*' /tmp/v3/kernel.out | head -1)"
echo "  curl 仍可用: $(c)"
# 只验计划：--dry-run 下 krn_update 在 apt 之前就返回，不会装任何内核
bash "$SRC" --dry-run --kernel-update > /tmp/v3/kernel-dry.out 2>&1; krn_dry=$?
sed 's/^/  /' /tmp/v3/kernel-dry.out | head -10
echo "  --dry-run --kernel-update 退出码: $krn_dry（应为 0）"
echo "  dry-run 是否只出计划: $(grep -q 'dry-run' /tmp/v3/kernel-dry.out && echo 是-正确 || echo 否-需检查)"
# 档位若判高了，装上内核直接起不来 —— 拿 glibc 的 hwcaps 判定做交叉验证
echo "  ld.so 判定: $(krn_ldo=$(ld.so --help 2>/dev/null | grep -oE 'x86-64-v[0-9]' | sort -u | tr '\n' ' '); echo "${krn_ldo:-读不到}")"
echo "  档位判定依据: $(grep -o '档位判定依据：.*' /tmp/v3/kernel.out | head -1)"
# 判低了同样有害：会给出错误的档位建议，让用户装上功能更少的低档内核。
# 硬标准 —— 正在跑的内核名字里就带档位（7.2.9-x64v3-xanmod1），跑起来了就说明 CPU 至少支持这一档，
# 所以判出的档位绝不允许低于它。（这条就是回归 Xeon E5-2699 v4 被误判成 x64v2 的那个 bug）
krn_run=$(uname -r)
case "$krn_run" in
  *-x64v4-*) krn_need=4 ;;
  *-x64v3-*) krn_need=3 ;;
  *-x64v2-*) krn_need=2 ;;
  *-x64v1-*) krn_need=1 ;;
  *)         krn_need=0 ;;
esac
krn_got=$(sed -n 's/.*CPU 微架构档位： *x64v\([0-9]\).*/\1/p' /tmp/v3/kernel.out | head -1)
if [ "$krn_need" = 0 ]; then
  echo "  判档是否不低过在跑的内核: 跳过-不是 xanmod 内核，无参照"
elif [ -n "$krn_got" ] && [ "$krn_got" -ge "$krn_need" ]; then
  echo "  判档是否不低过在跑的内核: 是-正确（判 x64v$krn_got，在跑 x64v$krn_need）"
else
  echo "  判档是否不低过在跑的内核: 否-有问题（判 x64v${krn_got:-?}，却在跑 x64v$krn_need —— 判低了）"
fi
# 强制档位必须生效（用来给判错的机器兜底）
echo "  强制档位 x64v4: $(SET_DNS_KERNEL_LEVEL=x64v4 bash "$SRC" --kernel 2>&1 | grep -o 'CPU 微架构档位： *[x0-9a-z]*' | head -1)"
krn_after=$( { cat /etc/resolv.conf 2>/dev/null; find /usr/local/sbin /etc/systemd/system /boot /etc/default -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null; } | md5sum)
echo "  是否改动 resolv.conf / 守护 / /boot / grub 默认值: $( [ "$krn_before" = "$krn_after" ] && echo 否-正确 || echo 是-有问题)"
echo "  解析仍可用: $(rdy)"

hr "S0g TCP 加速管理（--accel*）：只读项不许动，可写项必须真生效，最后必须能干净还原"
# 这段会真的改 sysctl（这是功能本身），所以严格按「记录 -> 改 -> 验生效 -> 还原 -> 验回到原样」走。
# 绝不碰 /etc/sysctl.d/99-degwd.conf 与 99-kejilion-bbr.conf（de_GWD / kejilion 的地盘），
# 也绝不真的装/卸内核，只跑 --dry-run 看计划。
ACCC=/etc/sysctl.d/99-zz-setdns-accel.conf
ACCM=/etc/modules-load.d/setdns-qdisc.conf
acc_snap(){ { cat /etc/resolv.conf 2>/dev/null; find /etc/sysctl.d /etc/modules-load.d /usr/local/sbin /etc/systemd/system -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null; } | md5sum | cut -d' ' -f1; }
acc_others(){ md5sum /etc/sysctl.d/99-degwd.conf /etc/sysctl.d/99-kejilion-bbr.conf 2>/dev/null | md5sum | cut -d' ' -f1; }
acc_base=$(acc_snap); acc_oth_base=$(acc_others)
acc_boot_base=$(ls /boot/vmlinuz-* 2>/dev/null | sort | tr '\n' ' ')
acc_dns_base=$( { cat /etc/resolv.conf; find /usr/local/sbin /etc/systemd/system -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null; } | md5sum | cut -d' ' -f1)
echo "  基线: resolv.conf+sysctl.d+modules-load.d+守护 指纹 ${acc_base:0:12}"
echo "  基线: 现有 cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null) ecn=$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null) ipv6关闭=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)"
echo "  主机上谁在管这两个键: $(grep -hs 'congestion_control\|default_qdisc' /etc/sysctl.d/*.conf 2>/dev/null | tr '\n' ' ')"
echo "  之前是否已有本脚本的加速配置: $( [ -e "$ACCC" ] && echo 有 || echo 无)"

# --- 只读项：--accel-status / --accel-kernels 必须零改动 ---
bash "$SRC" --accel-status > /tmp/v3/accel-status.out 2>&1; as_rc=$?
sed 's/^/  /' /tmp/v3/accel-status.out
echo "  --accel-status 退出码: $as_rc（应为 0）"
bash "$SRC" --accel-kernels > /tmp/v3/accel-kernels.out 2>&1; ak_rc=$?
sed 's/^/  /' /tmp/v3/accel-kernels.out | head -12
echo "  --accel-kernels 退出码: $ak_rc（应为 0）"
echo "  只读项是否零改动: $( [ "$acc_base" = "$(acc_snap)" ] && echo 是-正确 || echo 否-有问题)"

# --- 20/21/22 真机切加速：bbr+fq / bbr+fq_pie / bbr+cake ---
for pair in "bbr:fq:--accel-bbr" "bbr:fq_pie:--accel-fqpie" "bbr:cake:--accel-cake"; do
  want_cc=${pair%%:*}; rest=${pair#*:}; want_q=${rest%%:*}; flag=${rest##*:}
  out=$(bash "$SRC" "$flag" 2>&1); rc=$?
  got_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  got_q=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  echo "  $flag -> 退出码 $rc，cc=$got_cc qdisc=$got_q（期望 $want_cc + $want_q）"
  echo "     配置文件里:$([ "$(grep -cE '^net\.(core\.default_qdisc|ipv4\.tcp_congestion_control)[[:space:]]*=' "$ACCC" 2>/dev/null)" = 2 ] && echo 两项各一行-正确 || echo 行数异常-需检查)"
  echo "     网卡 $(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1) 真实队列: $(tc qdisc show dev "$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)" 2>/dev/null | head -1 | awk '{print $2}')"
  echo "     解析仍可用: $(rdy)  curl: $(c)"
done
echo "  配置写在最后读的那个文件里（压得住前面两个）: $( [ "$(printf '%s\n' 99-degwd.conf 99-kejilion-bbr.conf 99-zz-setdns-accel.conf | LC_ALL=C sort | tail -1)" = 99-zz-setdns-accel.conf ] && echo 是-正确 || echo 否-有问题)"

# --- 30/31 ECN ---
bash "$SRC" --accel-ecn-on  >/dev/null 2>&1; echo "  开启 ECN 后 tcp_ecn = $(sysctl -n net.ipv4.tcp_ecn 2>/dev/null)（期望 1）"
bash "$SRC" --accel-ecn-off >/dev/null 2>&1; echo "  关闭 ECN 后 tcp_ecn = $(sysctl -n net.ipv4.tcp_ecn 2>/dev/null)（期望 0）"
echo "  tcp_ecn_fallback 是否被误伤: $(sysctl -n net.ipv4.tcp_ecn_fallback 2>/dev/null)（应仍是 1）"

# --- 35/36 IPv6（改完立刻改回来）---
v6_before=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
bash "$SRC" --accel-ipv6-off >/dev/null 2>&1
echo "  禁用 IPv6: all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null) default=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)（期望都 1）"
bash "$SRC" --accel-ipv6-on >/dev/null 2>&1
echo "  恢复 IPv6: all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)（原为 $v6_before）"

# --- 32 自适应优化 / 33 防 CC / 37 合并 ---
bash "$SRC" --accel-optimize > /tmp/v3/accel-opt.out 2>&1; opt_rc=$?
echo "  --accel-optimize 退出码: $opt_rc（应为 0），写入 $(grep -cE '^[^#]*=' "$ACCC" 2>/dev/null) 项"
echo "     生效抽查: somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null) rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null) backlog=$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null) fastopen=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"
bash "$SRC" --accel-ddcc > /tmp/v3/accel-ddcc.out 2>&1
echo "  防 CC 后: syncookies=$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null) synack_retries=$(sysctl -n net.ipv4.tcp_synack_retries 2>/dev/null)（期望 1 / 1）"
echo "  防 CC 是否声明替代不了真防护: $(grep -q '不能替代真防护' /tmp/v3/accel-ddcc.out && echo 是-正确 || echo 否-需检查)"
bash "$SRC" --accel-merge > /tmp/v3/accel-merge.out 2>&1; mrg_rc=$?
echo "  --accel-merge 退出码: $mrg_rc（应为 0）: $(grep -oE '共 [0-9]+ 项：生效 [0-9]+' /tmp/v3/accel-merge.out | head -1)"
echo "  是否动了别人的 sysctl 文件: $( [ "$acc_oth_base" = "$(acc_others)" ] && echo 否-正确 || echo 是-有问题)"
echo "  解析仍可用: $(rdy)  curl: $(c)"

# --- 9~12 / 4 / 7 / 8：只验计划，绝不真装内核 ---
for v in xanmod-main xanmod-lts xanmod-edge xanmod-rt official cloud latest; do
  line=$(bash "$SRC" --dry-run --accel-kernel=$v 2>&1 | grep -E '包名：|\[dry-run\]' | tr '\n' ' ')
  echo "  --accel-kernel=$v（dry-run）: ${line:-无输出-需检查}"
done
for v in bbr-orig bbrplus lotserver zen; do
  out=$(bash "$SRC" --accel-kernel=$v 2>&1); rc=$?
  echo "  --accel-kernel=$v 退出码 $rc（应非 0），说明: $(echo "$out" | grep -E '替代' | head -1)"
done
echo "  装内核镜像是否真的没变: $( [ "$acc_boot_base" = "$(ls /boot/vmlinuz-* 2>/dev/null | sort | tr '\n' ' ')" ] && echo 是-正确 || echo 否-有问题 )  当前: $acc_boot_base"

# --- 55 卸载全部加速：本脚本的配置要删干净，别人的要原样，参数要回到原来那两个值 ---
bash "$SRC" --accel-restore 2>&1 | sed 's/^/  /'
echo "  加速配置是否已删: $( [ -e "$ACCC" ] && echo 否-有问题 || echo 是-正确)   modules-load 条目: $( [ -e "$ACCM" ] && echo 仍在 || echo 已删)"
echo "  还原后 cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)（应回到 99-kejilion-bbr.conf 给的 bbr + fq）"
echo "  别人的 sysctl 文件是否原样: $( [ "$acc_oth_base" = "$(acc_others)" ] && echo 是-正确 || echo 否-有问题)"
echo "  resolv.conf 与守护是否零改动: $( [ "$acc_dns_base" = "$( { cat /etc/resolv.conf; find /usr/local/sbin /etc/systemd/system -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null; } | md5sum | cut -d' ' -f1)" ] && echo 是-正确 || echo 否-有问题)"
echo "  守护仍活: path=$(systemctl is-active dns-watch.path) timer=$(systemctl is-active dns-watch.timer)"
echo "  解析仍可用: $(rdy)  curl: $(c)"

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
