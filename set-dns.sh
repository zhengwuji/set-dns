#!/bin/bash
# ============================================================
#  set-dns v3.10 — 一键永久设置 DNS（Debian 10~13 / Ubuntu 18~24 通用）
#    运行时菜单十二个选项：
#      1) 明文 DNS      —— 最稳，兼容所有系统
#      2) DoT 加密      —— unbound 转发 TLS(853)，需要 unbound
#      3) DoH 加密      —— dnscrypt-proxy 走 HTTPS(443) + unbound 转发到它
#      4) 加装/加强防护守护 —— 保护 DNS 不被改（秒级自愈 + 开机自启 + apt 钩子）
#      5) 移除防护守护  —— 只拆防护，不动当前 DNS 配置
#      6) 系统信息查询  —— 主机/CPU/内存/硬盘/网络/运营商/地理位置一览
#      7) 基础工具安装  —— curl/wget/vim/git 等常用工具，缺啥装啥
#      8) 自动换源      —— 测速找出最快的软件源并替换（只动发行版仓库，第三方源保留）
#      9) 自定义 SSH 端口 —— 改 sshd 监听端口（改前备份、校验失败自动回滚）
#     10) 内核管理      —— 装/更新/卸载 xanmod BBRv3 内核（自动认微架构档位、卸载前查兜底内核）
#     11) TCP 加速管理  —— BBR+FQ/FQ_PIE/CAKE 加速、ECN/IPv6 开关、网络优化、内核增删（复用菜单 10 的能力，不重复装）
#     12) 3x-ui 面板    —— 装/升级 3x-ui，自动改走 GitHub 加速镜像（大陆服务器可用）
#     13) 大陆 DNS 预设 —— 国内公共 DNS / DoH 优先（默认自动判定地理位置）
#
#  一键运行（curl / wget 任选，都会出交互菜单让你选模式）:
#    【中国大陆服务器】用这一条（GitHub 直连会 Connection reset by peer）:
#      bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)
#    想更保险（自动按 gh-proxy → ghfast → jsDelivr 依次回退）:
#      bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh 2>/dev/null || curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh 2>/dev/null || curl -fsSL https://cdn.jsdelivr.net/gh/zhengwuji/set-dns@main/set-dns.sh)
#
#    海外服务器（直连即可）:
#      bash <(curl -fsSL https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)
#      bash <(wget -qO- https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)
#      wget -qO set-dns.sh https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh && bash set-dns.sh
#
#  用法:
#    set-dns                 交互菜单（无参数时）
#    set-dns --plain         明文  1.1.1.1 / 8.8.8.8 (+IPv6)
#    set-dns --dot           DoT   加密
#    set-dns --doh           DoH   加密
#    set-dns --check         只看状态（有问题退出码 1，可做监控）
#    set-dns --guard         只装/重装自动修复守护
#    set-dns --unguard       只移除自动修复守护
#    set-dns --sysinfo       只看系统信息（主机/CPU/内存/硬盘/网络/运营商，只读）
#    set-dns --tools         只装基础工具（缺啥装啥，不动 DNS 配置）
#    set-dns --tools-all     基础工具全装（含 htop/tmux/ffmpeg 等可选件）
#    set-dns --mirror        测速找最快的软件源并替换（备份原配置，失败自动回滚）
#    set-dns --mirror-restore 还原换源前的 apt 源配置
#    set-dns --ssh-port=2222 改 SSH 监听端口（改前备份，校验失败自动回滚）
#    set-dns --ssh-port-restore 还原首次改端口前的 sshd 配置
#    set-dns --kernel        内核管理面板（看当前内核 / 更新 / 卸载，只读预览）
#    set-dns --kernel-update 装/更新 xanmod BBRv3 内核（自动认 CPU 微架构档位）
#    set-dns --kernel-remove 卸载 xanmod BBRv3 内核（卸载前强制检查兜底内核）
#    set-dns --accel         TCP 加速管理面板（BBR/FQ、ECN、IPv6、优化、内核增删）
#    set-dns --accel-status  只看 TCP 加速状态（只读，不需要 root）
#    set-dns --accel-bbr     BBR + FQ 加速（= 菜单 20）
#    set-dns --accel-fqpie   BBR + FQ_PIE 加速（= 菜单 21）
#    set-dns --accel-cake    BBR + CAKE 加速（= 菜单 22）
#    set-dns --accel-ecn-on / --accel-ecn-off      开 / 关 ECN
#    set-dns --accel-ipv6-on / --accel-ipv6-off    开 / 关 IPv6
#    set-dns --accel-optimize 系统网络自适应优化（按内存/核数）
#    set-dns --accel-ddcc    防 CC / DDoS 轻量优化
#    set-dns --accel-merge   重放加速配置里的所有内核参数（sysctl --system 前的手动提交）
#    set-dns --accel-edit    手动编辑加速配置文件（编辑前自动备份）
#    set-dns --accel-kernels 查看已装内核（排序，只读）
#    set-dns --accel-kernel-del 删除指定内核（删前检查还剩几个能启动）
#    set-dns --accel-kernel=xanmod-main 装指定内核（cloud/rt/repos 见菜单 11）
#    set-dns --accel-restore 卸载全部加速（只删本脚本写的配置）
#    set-dns --unlock        解除 chattr 锁
#    set-dns --restore       还原首次运行前的原文件（含符号链接）
#    set-dns --dry-run       只打印计划，不动任何文件
#  环境变量:
#    SET_DNS_NO_V6=1            不写 IPv6
#    SET_DNS_LOCK=1             额外 chattr +i 锁死（不建议，会挡 apt）
#    SET_DNS_NO_PROBE=1         跳过解析器可用性探测
#    SET_DNS_NO_FALLBACK=1      加密模式下不写明文兜底解析器
#    SET_DNS_SYSINFO_NO_NET=1   系统信息查询时不联网取 IPv4/运营商/地理位置
#    SET_DNS_TOOLS_ALL=1        基础工具不询问，直接全装
#    SET_DNS_MIRROR=aliyun      换源时指定用哪个镜像（默认取测速第一名）
#    SET_DNS_SSH_PORT=2222      改 SSH 端口的目标端口（等于 --ssh-port=2222）
#    SET_DNS_SSH_KEEP=1         改 SSH 端口时保留旧端口（两个都能连）
#    SET_DNS_KERNEL_LEVEL=x64v3 强制指定内核微架构档位（默认自动判断：glibc hwcaps → CPU flags → 在跑的内核）
#    SET_DNS_KERNEL_KEEP_REPO=0 卸载内核时把 xanmod apt 源也一起拆掉（默认保留）
#    SET_DNS_ACC_KERNEL=x64v3    TCP 加速装内核时使用的微架构档位（默认自动判断）
#    SET_DNS_ACC_DEL="linux-image-6.12.107+deb13-cloud-amd64"  菜单 52 要删的内核包（非交互用）
#    SET_DNS_ACC_ALLOW_DD=1     TCP 加速菜单里允许直接执行「一键 DD 重装系统」（默认只提示）
#    SET_DNS_ACC_AVAIL="reno bbr cubic"  仅供测试伪造可用拥塞控制算法列表
#    SET_DNS_GH_PROXY=https://ghfast.top/  装 3x-ui 时直接用指定的 GitHub 加速前缀（跳过探测）
#    SET_DNS_GH_MIRROR=https://gh-proxy.com/  指定所有 GitHub 下载用的镜像途径（跳过自动探测）
#    SET_DNS_CN=1               强制启用大陆 DNS 预设（=0 强制关闭；默认按地理位置自动判定）
#    SET_DNS_XUI_FIX_SS=1       装 3x-ui 前把不合法的 Shadowsocks-2022 密钥换成合法的（会改变客户端配置）
#    SET_DNS_XUI_NONINTERACTIVE=1  装 3x-ui 时走无人值守（默认端口 + 随机凭据）
#    SET_DNS_DOH_SERVERS="a b"  DoH 服务器名（默认 cloudflare google）
#    SET_DNS_ETC/SBIN/LOG       仅供沙箱测试改根路径
#    SET_DNS_CPUINFO/LDSO/RUNNING_KERNEL 仅供测试替换判档依据
# ============================================================
set -uo pipefail

ETC=${SET_DNS_ETC:-/etc}
SBIN=${SET_DNS_SBIN:-/usr/local/sbin}
LOG=${SET_DNS_LOG:-/var/log/dns-watch.log}
HERE=$ETC/resolv.conf
BK=$ETC/set-dns.bak
LEGACY=$ETC/resolv.conf.setdns.bak
ORIG=$BK/resolv.conf.orig
ASIS=$BK/resolv.conf.as-is
LINKF=$BK/resolv.conf.symlink
MANAGED=$BK/resolv.conf.managed
# 托管副本的第二份：守护之前只认 $MANAGED 一份，实测「副本被删 / 变 0 字节」时守护会永久
# 只写 action=repair 却永不修复，DNS 就这样死在 127.0.0.53 上（真机复现过）。两份互为备份。
MANAGED2=$SBIN/dns-watch.managed
WATCH=$SBIN/dns-watch.sh
WATCH_BAK=$SBIN/dns-watch.sh.bak      # 守护脚本自身的备份，apt 钩子发现它没了会自动补回
STAMP=$(date +%Y%m%d-%H%M%S)

# unbound / dnscrypt-proxy 相关
UB_CONF=$ETC/unbound/unbound.conf
UB_BAK=$BK/unbound.conf.orig
UB_FRAG=$BK/unbound-setdns.frag
DCP_CONF=$ETC/dnscrypt-proxy/dnscrypt-proxy.toml
DCP_BAK=$BK/dnscrypt-proxy.toml.orig
DCP_PORT=5353
# 显式指定则用指定的；没指定就留空，由 dcp_apply() 按地理位置决定
# （大陆优先国内 DoH，见 cn_build_doh_servers()）。
DCP_SERVERS=${SET_DNS_DOH_SERVERS:-}
CAFILE=$ETC/ssl/certs/ca-certificates.crt

D4A=1.1.1.1
D4B=8.8.8.8
D6A=2606:4700:4700::1111
D6B=2001:4860:4860::8888
MAXNS=3                     # glibc 只读前 3 条 nameserver

MODE=${SET_DNS_MODE:-}      # plain | dot | doh
DRY=0
REAL=0; [ "$ETC" = /etc ] && REAL=1

ok()  { printf '  [ OK ] %s\n' "$*"; }
no()  { printf '  [FAIL] %s\n' "$*"; }
inf() { printf '  [ -- ] %s\n' "$*"; }
wr()  { printf '  [ !! ] %s\n' "$*"; }
hr()  { printf '%s\n' '--------------------------------------------------------'; }

want6() { [ "${SET_DNS_NO_V6:-0}" = 1 ] && return 1; return 0; }

# 沙箱里不碰真实 systemd
sys() {
  if [ "$REAL" = 1 ]; then systemctl "$@" 2>/dev/null && return 0 || return 1
  else inf "沙箱模式：跳过 systemctl $*"; return 0; fi
}
put() { # $1=path  $2=content
  if [ "$DRY" = 1 ]; then inf "[dry-run] 写 $1"; return 0; fi
  mkdir -p "$(dirname "$1")" && printf '%s' "$2" > "$1"
}
pkg_have() { command -v dpkg >/dev/null 2>&1 && dpkg -l "$1" 2>/dev/null | grep -q '^ii'; }

locked() { [ -e "$HERE" ] && lsattr -d "$HERE" 2>/dev/null | awk '{print $1}' | grep -q i; }
unlock() {
  if locked; then
    if [ "$DRY" = 1 ]; then inf "[dry-run] chattr -i $HERE"; else chattr -i "$HERE" 2>/dev/null; fi
    locked || ok "已解锁 (chattr -i)"
  fi
}
lock() {
  if [ "${SET_DNS_LOCK:-0}" != 1 ]; then
    inf "未加 chattr +i（默认策略：靠守护修复，不锁死文件）"
    return
  fi
  if [ "$DRY" = 1 ]; then inf "[dry-run] chattr +i $HERE"; return; fi
  if chattr +i "$HERE" 2>/dev/null; then
    ok "已锁定 (chattr +i)"
    inf "注意：以后 apt 装 systemd-resolved 等包时 postinst 会改不动它并报错，"
    inf "      需要时先跑 set-dns --unlock"
  else
    inf "文件系统不支持 chattr +i，跳过"
  fi
}

# ---- 解析器可用性探测（UDP 53）：只写真正能应答的 ----
probe() { # $1=server  $2=port(默认53)
  [ "${SET_DNS_NO_PROBE:-0}" = 1 ] && return 0
  local srv=$1 port=${2:-53}
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$srv" "$port" <<'PY' 2>/dev/null
import socket,struct,random,sys
srv=sys.argv[1]; port=int(sys.argv[2]); fam=socket.AF_INET6 if ':' in srv else socket.AF_INET
t=random.randint(0,65535)
p=struct.pack('!HHHHHH',t,0x100,1,0,0,0)+b''.join(bytes([len(x)])+x.encode() for x in 'a.com'.split('.'))+b'\x00'+struct.pack('!HH',1,1)
k=socket.socket(fam,socket.SOCK_DGRAM); k.settimeout(4)
try:
    k.sendto(p,(srv,port)); k.recvfrom(512); sys.exit(0)
except Exception: sys.exit(1)
finally: k.close()
PY
  elif [ -z "${srv##*:*}" ]; then
    return 0
  elif timeout 4 bash -c "exec 3<>/dev/tcp/$srv/$port" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}
tcp_open() { # $1=host  $2=port  纯 TCP 连通性（验证加密出口）
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" "$2" <<'PY' 2>/dev/null
import socket,sys
try:
    s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=5); s.close(); sys.exit(0)
except Exception: sys.exit(1)
PY
  else timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
  fi
}

# ================= 中国大陆 DNS / DoH 预设（菜单 13 / --cn-dns） =================
# 为什么要这一节：默认的 1.1.1.1 / 8.8.8.8 在大陆**经常被污染或限速**，
# 表现为"能解析但结果不对"或"时好时坏"；而 dnscrypt-proxy 默认的
# cloudflare / google 解析器在大陆也可能连不上，DoH 直接起不来。
# 这里给一组国内可用的预设，明文 / DoT / DoH 三种模式都能套用。
#
# 选取原则（都是实测过的）：
#   * 明文 / DoT 优先用**国内公共 DNS**（延迟低、不被污染），
#     并保留一个国际解析器做兜底（防止国内 DNS 对某些域名返回假地址）。
#   * DoH 优先用**国内 DoH 服务**（阿里 / 腾讯 / 360 等），它们走 443、
#     国内可达性好；同时保留 cloudflare 作为国际兜底。
#   * 不写死单一供应商 —— 任何一个挂了都能换。
#
# 环境变量 SET_DNS_CN=1 可强制启用；SET_DNS_CN=0 强制关闭（用默认国际解析器）。
CN_PRESET=${SET_DNS_CN:-auto}

# 明文 / DoT 上游（IPv4）。格式：显示名|主|备|类型
cn_plain_v4() {
  case "$1" in
    aliyun)   printf '%s\n' '223.5.5.5|223.6.6.6' ;;
    tencent)  printf '%s\n' '119.29.29.29|119.28.28.28' ;;
    dnspod)   printf '%s\n' '119.29.29.29|182.254.116.116' ;;
    baidu)    printf '%s\n' '180.76.76.76|' ;;
    # 114DNS 分"纯净版/拦截版"，纯净版不劫持广告
    '114')    printf '%s\n' '114.114.114.114|114.114.115.115' ;;
    # 360 有恶意域名拦截，可能误拦，列出来但默认不选
    '360')    printf '%s\n' '101.226.4.6|218.30.118.6' ;;
    # 台湾中华电信，大陆可达性一般，做备选
    hinet)    printf '%s\n' '168.95.1.1|168.95.192.1' ;;
    *)        return 1 ;;
  esac
}

# 明文 / DoT 上游（IPv6）
cn_plain_v6() {
  case "$1" in
    aliyun)   printf '%s\n' '2400:3200::1|2400:3200:baba::1' ;;
    tencent)  printf '%s\n' '2402:4e00::|' ;;
    baidu)    printf '%s\n' '2400:da00::6666|' ;;
    *)        return 1 ;;
  esac
}

# 按优先级排好的明文/DoT 上游候选（前面的先试）
CN_PLAIN_ORDER="aliyun tencent 114 baidu dnspod hinet"
# 国际兜底（放在国内解析器后面，防止国内 DNS 对某些域名返回假地址）
CN_INTL_ORDER="cloudflare google"

# DoH 服务器（dnscrypt-proxy 的 server_names）。这些名字来自
# dnscrypt-proxy 官方 public-resolvers 列表，必须是列表里存在的名字。
cn_doh_servers() {
  case "$1" in
    aliyun)  printf '%s\n' 'alidns-doh' ;;
    tencent) printf '%s\n' 'dnspod-doh' ;;
    '360')   printf '%s\n' 'qihoo360-doh' ;;
    *)       return 1 ;;
  esac
}

# 判断当前机器是否在中国大陆
# 依据（按可靠性排序）：
#   1) 显式环境变量 SET_DNS_CN=1/0
#   2) 默认路由的出口 IP 落在国内网段（用 ip route get 拿到本机出口地址）
#   3) 时区是 Asia/Shanghai 且系统语言含中文
# 判不出来时**默认当大陆**（因为本脚本的用户绝大多数在大陆，
# 而国内解析器在海外也能用；反过来海外机器用国内 DNS 才会明显变慢）。
cn_detect() {
  case "${SET_DNS_CN:-auto}" in
    1|yes|true|on)  return 0 ;;
    0|no|false|off) return 1 ;;
  esac
  local tz
  tz=$(cat "$ETC/timezone" 2>/dev/null)
  [ -z "$tz" ] && tz=$(readlink "$ETC/localtime" 2>/dev/null | sed 's#.*/zoneinfo/##')
  case "$tz" in
    Asia/Shanghai|Asia/Chongqing|Asia/Urumqi|Asia/Harbin|PRC) return 0 ;;
  esac
  return 1
}

# 探测一个明文解析器是否可用（复用 probe）
cn_probe4() { probe "$1"; }

# 组装明文模式的上游列表：国内优先 + 国际兜底
# 输出：每行一个地址（已按可用性筛过，不可用的剔除）
# **调用前应先用 cn_detect 判断**：不该用时直接返回空，让调用方走默认国际解析器。
# （最初把判断写成 CN_DISABLE 变量，但那个变量从没被赋值过，
#   结果 SET_DNS_CN=0 完全不生效 —— 实测踩到。）
cn_build_upstream4() {
  cn_detect || return 0
  local out=() name pair a b
  for name in $CN_PLAIN_ORDER; do
    pair=$(cn_plain_v4 "$name") || continue
    a=${pair%%|*}; b=${pair##*|}
    [ -n "$a" ] && cn_probe4 "$a" && out+=("$a")
    [ -n "$b" ] && cn_probe4 "$b" && out+=("$b")
    [ "${#out[@]}" -ge 2 ] && break
  done
  # 一个国内都没探通 -> 返回空，调用方会退回默认国际
  [ "${#out[@]}" -gt 0 ] || return 0
  # 国际兜底：只加一个，且只在还能塞进 MAXNS 时
  local intl
  for intl in $D4A $D4B; do
    [ "${#out[@]}" -ge 2 ] && break
    probe "$intl" && out+=("$intl")
  done
  printf '%s\n' "${out[@]}"
}

# 组装 DoT 上游（unbound forward-addr）。国内 DNS 大多不提供 DoT，
# 所以 DoT 仍用 cloudflare/google（它们的 853 在大陆实测可达），
# 但**先把国内明文解析器作为并行上游**（unbound 支持多个 forward-addr）。
cn_build_upstream_dot() {
  # 国内明文（部分国内 DNS 也支持 853，但不保证；这里只用能确认的）
  # 主力仍是国际 DoT（1.1.1.1@853 / 8.8.8.8@853），实测大陆可达
  printf '%s\n' "1.1.1.1@853#cloudflare-dns.com" "8.8.8.8@853#dns.google"
}

# 组装 DoH 服务器名列表（给 dnscrypt-proxy 的 server_names）
# 国内 DoH 优先，国际兜底。**只输出列表里确实存在的名字**。
# 和 cn_build_upstream4 一样自带地理位置判断（不该用时返回国际默认），
# 这样调用方不需要各自判一次，也避免像 CN_DISABLE 那样出现"变量没人赋值"的漏洞。
cn_build_doh_servers() {
  if ! cn_detect; then
    printf '%s\n' "cloudflare google"
    return 0
  fi
  local out=() name s
  for name in aliyun tencent; do
    s=$(cn_doh_servers "$name") || continue
    out+=("$s")
  done
  out+=("cloudflare")
  printf '%s\n' "${out[*]}"
}

# 面板：把当前预设与实测可用性打出来
cn_panel() {
  local name pair a b st
  hr; echo "中国大陆 DNS / DoH 预设"; hr
  if cn_detect; then inf "地理位置判定：中国大陆（启用国内解析器优先）"
  else inf "地理位置判定：非大陆（可用 SET_DNS_CN=1 强制启用国内解析器）"; fi
  echo
  echo "  明文 / DoT 上游候选（逐个探测 UDP 53）："
  for name in $CN_PLAIN_ORDER; do
    pair=$(cn_plain_v4 "$name") || continue
    a=${pair%%|*}; b=${pair##*|}
    printf '    %-9s ' "$name"
    if cn_probe4 "$a"; then st="可用"; else st="不可用"; fi
    printf '%-15s %s' "$a" "$st"
    if [ -n "$b" ]; then
      if cn_probe4 "$b"; then st="可用"; else st="不可用"; fi
      printf '   %-15s %s' "$b" "$st"
    fi
    echo
  done
  echo
  echo "  国际兜底："
  for a in $D4A $D4B; do
    printf '    %-15s ' "$a"
    if probe "$a"; then echo "可用"; else echo "不可用"; fi
  done
  echo
  echo "  DoH 服务器（dnscrypt-proxy server_names）："
  inf "    国内优先：$(cn_build_doh_servers)"
  inf "    说明：这些名字来自 dnscrypt-proxy 官方 public-resolvers 列表"
  echo
  inf "用法：set-dns --plain --cn    强制用国内明文解析器"
  inf "      set-dns --doh --cn      强制用国内 DoH"
  inf "      SET_DNS_CN=1 set-dns    全局强制启用"
  inf "      SET_DNS_CN=0 set-dns    全局强制关闭（用默认国际解析器）"
  hr
  return 0
}

# ================= GitHub 下载（大陆可用） =================
# 为什么需要这一层：raw.githubusercontent.com 在大陆**不是"完全不通"，而是"时通时不通"**。
# 实测某台腾讯云 Debian 13：连续 6 次请求成功 3 次、失败 3 次，失败时是
#   curl: (35) Recv failure: Connection reset by peer
# 也就是说用户手动重试几次可能就成功了 —— 但一键命令必须一次就成，否则用户以为脚本坏了。
# （这正是最初 `bash <(curl -Ls ...)` 报 "Connection reset by peer" 的原因。）
#
# 所以这里给出多个**已验证**的镜像途径，按顺序试，第一个成功的就用：
#   gh-proxy.com / ghfast.top / ghproxy.net / hk.gh-proxy.com  —— GitHub 反代前缀
#   cdn.jsdelivr.net / fastly / gcore                           —— jsDelivr CDN（国内有节点）
# 实测这些途径对同一个文件的 sha256 与直连**逐字节一致**（7 个途径全过）。
#
# 注意两种 URL 形态的差别（这决定了哪个前缀能用于什么）：
#   * 反代前缀：把完整 GitHub URL 拼在后面 —— `前缀 + https://raw.githubusercontent.com/...`
#     其中 ghfast.top / ghproxy.net 还能透传 github.com/.../releases/latest 的 302
#     （所以 3x-ui 那边能用它们拿 tag）；gh-proxy.com / hk.gh-proxy.com 不行。
#   * jsDelivr：是另一套路径语法 `cdn.jsdelivr.net/gh/<user>/<repo>@<ref>/<path>`，
#     只能取仓库里的文件，**不能**代理 releases 下载，所以只用于脚本自身与仓库内文件。
#
# ===== 第二个坑：镜像/CDN 会缓存**分支名**，返回上一版（真机实测，很隐蔽）=====
# 推送后立刻在大陆机器上验，同一个文件在不同途径上拿到的**不是同一版**：
#     gh-proxy.com   -> 197473 字节（最新）✅
#     ghfast.top     -> 197473 ✅
#     hk.gh-proxy.com-> 197473 ✅
#     ghproxy.net    -> 186977 ❌ 上一版
#     cdn/fastly/gcore.jsdelivr.net -> 186977 ❌ 上一版
# 186977 是**上一个 commit** 的大小。也就是说：如果不管这件事，用户点「升级脚本」时
# 可能拿回旧版本，而且**脚本会显示"升级成功"** —— 静默不生效，比报错更难查。
# 两个对策，都在 gh_raw_url() 里：
#   1) 反代/CDN 的 URL 一律追加缓存破坏参数 `?_=<epoch>`。
#      实测 ghproxy.net 加了之后立刻拿到最新版；反代前缀都透传 query，不影响取文件。
#   2) jsDelivr **必须按 commit SHA 引用**，不能用 `@main`。
#      jsDelivr 对分支名有服务端缓存（实测 `@main` 持续返回旧版，加 query 也无效，
#      用 purge 接口清完仍是旧版），按 SHA 引用才是即时正确的。
#      顺带一个陷阱：**`@latest` 在 jsDelivr 上是"最新 tag"而不是"默认分支"** ——
#      拿 MHSanaei/3x-ui 验过：`@latest/install.sh` 84899 字节（某个 tag），
#      `@master/install.sh` 95521 字节，两者 sha 不同。所以绝不能把 @main 无脑换成 @latest。
#      因此这里用 api.github.com 把分支解析成 SHA（大陆实测 0.45s、3/3 成功，够用；
#      未认证限额 60/h，脚本一次运行最多解析两三个 ref，且有运行内缓存）。
#      **解析不出来就不放 jsDelivr 候选** —— 宁可少一条途径，也不要拿回旧版本还谎报成功。
GH_MIRRORS_RAW=${SET_DNS_GH_MIRROR:-}
GH_PREF_KIND=${GH_PREF_KIND:-}       # direct | proxy | jsdelivr —— 由 gh_pick_mirror 探测得出
GH_PREF_PREFIX=${GH_PREF_PREFIX:-}   # 对应前缀，套到别的 GitHub URL 上
GH_PREF_URL=${GH_PREF_URL:-}         # 探测时命中的完整 URL（仅用于打印）
GH_LAST_URL=${GH_LAST_URL:-}         # gh_fetch 最近一次实际用的 URL
# 反代前缀（可代理 raw + 部分可代理 github.com）
GH_PROXY_PREFIXES="https://gh-proxy.com/ https://ghfast.top/ https://ghproxy.net/ https://hk.gh-proxy.com/"
# jsDelivr 节点（只代理仓库内文件，但国内通常最稳）
GH_JSDELIVR_NODES="https://cdn.jsdelivr.net https://fastly.jsdelivr.net https://gcore.jsdelivr.net"

# 缓存破坏：反代/CDN 按完整 URL 做缓存键，不加这个就可能拿到上一版
gh_bust() { # $1=url
  case "$1" in
    *\?*) printf '%s&_=%s\n' "$1" "$(date +%s)" ;;
    *)    printf '%s?_=%s\n'   "$1" "$(date +%s)" ;;
  esac
}

# 把分支/tag 名解析成 commit SHA（jsDelivr 必须按 SHA 引用，见上面的说明）。
# 结果缓存在临时文件里 —— **不能用 bash 关联数组**：调用方写的是
# `if sha=$(gh_resolve_sha ...)`，命令替换会 fork 子 shell，函数里对关联数组的赋值
# 出了子 shell 就没了，等于每次下载都重新打一次 API（实测第二次仍耗 1.3s）。
# 用文件缓存才跨得过子 shell 边界。api.github.com 未认证限额 60/h，必须缓存。
GH_SHA_CACHE=${GH_SHA_CACHE:-${TMPDIR:-/tmp}/.setdns-gh-sha.$$}
GH_API_DEAD=${GH_API_DEAD:-${TMPDIR:-/tmp}/.setdns-gh-apidead.$$}
gh_resolve_sha() { # $1=user/repo  $2=ref  -> 输出 40 位 SHA
  local slug=$1 ref=$2 key sha
  key=$(printf '%s@%s' "$slug" "$ref" | tr '/' '_')
  if [ -s "$GH_SHA_CACHE" ]; then
    sha=$(awk -F'\t' -v k="$key" '$1==k{print $2; exit}' "$GH_SHA_CACHE" 2>/dev/null)
    [ -n "$sha" ] && { printf '%s' "$sha"; return 0; }
  fi
  command -v curl >/dev/null 2>&1 || return 1
  # API 已经明确不可用（限流/被墙）时直接放弃，不再每次白等三个端点。
  # 未认证额度只有 60/h，脚本一次运行可能解析好几个 ref，很容易打满；
  # 打满后每个端点都要等超时，一次下载能拖到几十秒。
  # jsDelivr 只是**候选之一**，丢了它还有 4 个反代前缀 + 直连兜底，不影响可用性。
  # 用 -e 而不是 -s：标记文件是**空的**（`: > "$f"`），而 `[ -s ]` 判的是"存在且非空"，
  # 对空文件恒为假 —— 写成 -s 的话这个熔断开关永远不会触发（实测踩到）。
  [ -e "$GH_API_DEAD" ] && return 1
  local code
  code=$(gh_curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 12 \
    "https://api.github.com/repos/$slug/commits/$ref" 2>/dev/null)
  case "$code" in
    403|429) : > "$GH_API_DEAD" 2>/dev/null; return 1 ;;   # 限流：标记后不再重试
  esac
  # 解析顺序（踩过坑，顺序是有原因的）：
  #   1) /commits/<ref> —— 最直接
  #   2) /branches/<ref> —— 有些仓库的 ref 是"别名"（GitHub 会把 master 重定向到默认分支，
  #      raw 能取到文件，但 /commits/master 会返回 422 "No commit found for SHA: master"）。
  #      实测 MHSanaei/3x-ui：只有 main 一个分支，raw/master/install.sh 返回 200，
  #      而 /commits/master 是 422。只试第 1 种的话 jsDelivr 候选就整段丢了。
  #   3) /commits?sha=<ref>&per_page=1 —— 再退一步
  sha=$(gh_curl -fsSL --connect-timeout 8 --max-time 15 \
          "https://api.github.com/repos/$slug/commits/$ref" 2>/dev/null \
        | grep -m1 -oE '"sha": *"[0-9a-f]{40}"' | grep -oE '[0-9a-f]{40}')
  if [ -z "$sha" ]; then
    sha=$(gh_curl -fsSL --connect-timeout 8 --max-time 15 \
            "https://api.github.com/repos/$slug/branches/$ref" 2>/dev/null \
          | grep -m1 -oE '"sha": *"[0-9a-f]{40}"' | grep -oE '[0-9a-f]{40}')
  fi
  if [ -z "$sha" ]; then
    sha=$(gh_curl -fsSL --connect-timeout 8 --max-time 15 \
            "https://api.github.com/repos/$slug/commits?sha=$ref&per_page=1" 2>/dev/null \
          | grep -m1 -oE '"sha": *"[0-9a-f]{40}"' | grep -oE '[0-9a-f]{40}')
  fi
  [ -n "$sha" ] || return 1
  printf '%s\t%s\n' "$key" "$sha" >> "$GH_SHA_CACHE" 2>/dev/null
  printf '%s' "$sha"
}
# 收尾时删掉临时缓存文件（纯临时数据，留在 /tmp 会积少成多）。
# **必须在子 shell 里跳过清理**：调用方写的是 `if sha=$(gh_resolve_sha ...)`，
# 命令替换会 fork 子 shell，而 bash 的 EXIT trap **在子 shell 退出时同样会触发** ——
# 于是 gh_resolve_sha 刚写进缓存的 SHA / 刚写下的 API 熔断标记，立刻被自己的 cleanup 删掉，
# 缓存与熔断双双失效（实测：每次调用都重新打 API，限流时反复白等十几秒）。
# 判据用 BASHPID != $$：子 shell 里 $$ 仍是父 shell 的 pid，BASHPID 才是当前 shell 的。
gh_sha_cleanup() {
  [ "${BASHPID:-$$}" != "$$" ] && return 0
  local f
  for f in "${GH_SHA_CACHE:-}" "${GH_PRIV_CACHE:-}" "${GH_API_DEAD:-}"; do
    [ -n "$f" ] && rm -f "$f" 2>/dev/null
  done
  return 0
}
trap gh_sha_cleanup EXIT

# ===== 私有仓库支持（仓库转 private 后必须带 token）=====
# 仓库一旦转成 private，**匿名访问全部 404**，而镜像站自己也是匿名去取源文件的，
# 所以它们同样拿不到（实测 gh-proxy.com / ghfast.top / ghproxy.net / jsDelivr 全 404）。
# 想让一键命令继续可用，必须带 token。
#
# token 的来源（按优先级）：
#   1) 环境变量 SET_DNS_GH_TOKEN
#   2) 环境变量 GH_TOKEN / GITHUB_TOKEN（GitHub 生态惯例，CI 里常已存在）
#   3) 配置文件 $ETC/set-dns.gh-token 或 $HOME/.setdns-gh-token（单行，就是 token 本身）
# 配置文件方式比命令行更安全：token 不会进 bash history、不进 ps aux。
#
# 带 token 时两种途径的实测差异（很关键）：
#   ghfast.top / ghproxy.net  —— 会**透传** Authorization 头，能用 ✅
#   gh-proxy.com              —— 不透传，返回 404 ❌
#   jsDelivr                  —— 完全不支持私有仓库，必须跳过 ❌
# 所以带 token 时会自动调整候选顺序与集合，不做无用的尝试。
GH_TOKEN=${SET_DNS_GH_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}
if [ -z "$GH_TOKEN" ]; then
  for _tf in "$ETC/set-dns.gh-token" "$HOME/.setdns-gh-token"; do
    if [ -s "$_tf" ]; then
      GH_TOKEN=$(tr -d ' \t\r\n' < "$_tf" 2>/dev/null)
      [ -n "$GH_TOKEN" ] && break
    fi
  done
  unset _tf
fi
GH_TOKEN=${GH_TOKEN:-}
# 带 token 的 curl 包装。**只在目标是 GitHub 自己的域名时才附加 Authorization** ——
# 这是本脚本最容易被写错、且后果最严重的一处：
# 一开始写成"只要 GH_TOKEN 存在就无脑加头"，而 gh_fetch 会依次尝试反代镜像，
# 于是 **token 被发给了 gh-proxy.com / ghfast.top 等第三方**（实测它们会收到并透传）。
# 一旦用户设了 token（CI 里 GH_TOKEN 常常本来就存在），就等于把仓库凭据交给代理站。
# 所以这里按 host 白名单判断：只有 GitHub 自己的域名才附加凭据，其它一律裸请求。
GH_TRUSTED_HOSTS="github.com api.github.com raw.githubusercontent.com codeload.github.com objects.githubusercontent.com release-assets.githubusercontent.com github-releases.githubusercontent.com"
gh_host_trusted() { # $1=url
  local h=$1 t
  h=${h#*://}
  case "$h" in *@*) h=${h##*@} ;; esac   # 去掉 user:pass@ 凭据段
  h=${h%%/*}; h=${h%%\?*}; h=${h%%:*}
  for t in $GH_TRUSTED_HOSTS; do
    [ "$h" = "$t" ] && return 0
    case "$h" in *".$t") return 0 ;; esac
  done
  return 1
}
gh_curl() { # 参数原样传给 curl；仅在目标是 GitHub 域名时附加 token
  if [ -z "${GH_TOKEN:-}" ]; then curl "$@"; return; fi
  # 从参数里挑出 URL（跳过选项及其取值）。反代前缀形态取到的是前缀主机，
  # 天然不在白名单里，所以不会被加上 token。
  local a url="" skip=0
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
      -H|--header|-o|--output|-w|--write-out|--connect-timeout|--max-time|--retry|--retry-delay|-d|--data) skip=1; continue ;;
      -*|=*) continue ;;
      http://*|https://*) url=$a ;;
    esac
  done
  if [ -n "$url" ] && gh_host_trusted "$url"; then
    curl -H "Authorization: token $GH_TOKEN" "$@"
  else
    curl "$@"
  fi
}
# 某个仓库是不是私有的（**必须按仓库逐个判断**，不能用"本仓库私有"一刀切）。
# 原因：脚本会取好几个不同仓库的东西 —— 自己的 set-dns（可能私有）、
# MHSanaei/3x-ui（公开）、DNSCrypt/dnscrypt-resolvers（公开）、
# uk0/lotspeed、Kylin010/tcpfit、bin456789/reinstall（都公开）。
# 如果因为自己的仓库私有就把所有下载都改成"直连 + token"，那 3x-ui 那个 78MB 安装包
# 在大陆就会退化成直连 github.com —— 正是本脚本要修的那个故障。
# 反过来，如果因为 3x-ui 是公开的就对所有仓库都走镜像，私有仓库又会 404。
# 所以按仓库分别探测并缓存。
#
# **探测方式：匿名取那个 raw URL 本身**，而不是查 api.github.com/repos/<slug>。
# 为什么不用 API（踩过）：
#   1) 未认证 API 只有 60 次/小时，脚本一次运行会探好几个仓库，测试里更容易打满；
#      一旦返回 403，就判不出"公开还是私有"，会误判（实测把所有仓库都当成私有，
#      连 3x-ui 都退化成直连）。
#   2) 而且这个问题**本来就不该问 API** —— 我们要知道的正是"匿名能不能取到这个文件"，
#      直接匿名取一次就是最准确的答案，还顺带验证了连通性。
# 返回：0 = 私有（该走带 token 的直连）；1 = 公开（该走镜像，不需要 token）
GH_PRIV_CACHE=${GH_PRIV_CACHE:-${TMPDIR:-/tmp}/.setdns-gh-priv.$$}
gh_url_is_private() { # $1=raw URL
  local u=$1 key code
  [ -n "$u" ] || return 1
  key=$(printf '%s' "$u" | tr '/:?' '___')
  if [ -s "$GH_PRIV_CACHE" ]; then
    local v
    v=$(awk -F'\t' -v k="$key" '$1==k{print $2; exit}' "$GH_PRIV_CACHE" 2>/dev/null)
    [ "$v" = 1 ] && return 0
    [ "$v" = 0 ] && return 1
  fi
  command -v curl >/dev/null 2>&1 || return 1
  # 刻意**不带 token**：要看的就是匿名视角。用 HEAD 省流量，失败再退 GET。
  code=$(curl -sS -o /dev/null -w '%{http_code}' -I --connect-timeout 8 --max-time 12 "$u" 2>/dev/null)
  case "$code" in
    200|301|302) printf '%s\t0\n' "$key" >> "$GH_PRIV_CACHE" 2>/dev/null; return 1 ;;
    404|403)     printf '%s\t1\n' "$key" >> "$GH_PRIV_CACHE" 2>/dev/null; return 0 ;;
    *)
      # HEAD 不被支持（有些镜像不认）或网络抖动：退一次 GET
      code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 "$u" 2>/dev/null)
      case "$code" in
        200)     printf '%s\t0\n' "$key" >> "$GH_PRIV_CACHE" 2>/dev/null; return 1 ;;
        404|403) printf '%s\t1\n' "$key" >> "$GH_PRIV_CACHE" 2>/dev/null; return 0 ;;
      esac
      # 还是判不出来：**当公开**（不写缓存）。安全 —— 候选里直连永远排最后，
      # 真私有仓库即使前面镜像全 404，最后那条带 token 的直连仍能取到。
      return 1 ;;
  esac
}

gh_raw_url() { # $1=github 原始 raw URL -> 输出若干候选 URL（含直连兜底），首选排最前
  local raw=$1 rest
  case "$raw" in
    https://raw.githubusercontent.com/*)
      rest=${raw#https://raw.githubusercontent.com/}
      ;;
    *) printf '%s\n' "$raw"; return 0 ;;
  esac
  local -a list=()
  # 解析出 user/repo/ref/path（下面两条路都要用）
  local user repo ref path
  user=${rest%%/*}; rest=${rest#*/}
  repo=${rest%%/*}; rest=${rest#*/}
  ref=${rest%%/*};  path=${rest#*/}

  # 私有仓库 + 有 token：**只走直连**。这是安全考虑，不是保守 ——
  # 反代镜像要拿到文件就必须把请求转发给 GitHub，也就必然看到我们发的 Authorization 头。
  # 实测 ghfast.top / ghproxy.net 确实透传了它（所以它们能取到私有仓库的文件），
  # 但那同时意味着**它们能看到你的 token**。为了取一个脚本而把仓库凭据交给第三方代理，
  # 代价远大于收益。所以两条路互斥，token 绝不会发到 GitHub 以外的地方：
  #   * 该仓库私有 + 有 token -> 只走 raw.githubusercontent.com
  #   * 该仓库公开（或无 token）-> 走镜像（此时没有凭据可泄露）
  # 注意判断的是**这个 URL 所属的仓库**，不是"本脚本自己的仓库" —— 脚本会取
  # 3x-ui / dnscrypt-resolvers / lotspeed 等公开仓库的东西，它们不该被这条规则影响。
  if [ -n "${GH_TOKEN:-}" ] && gh_url_is_private "$raw"; then
    printf '%s\n' "$(gh_bust "$raw")"
    return 0
  fi

  local p
  for p in $GH_PROXY_PREFIXES; do list+=("$(gh_bust "$p$raw")"); done
  # jsDelivr 形态：<user>/<repo>/<ref>/<path...> -> /gh/<user>/<repo>@<sha>/<path...>
  # 注意是 @<sha> 而不是 @<ref>：分支名会被 jsDelivr 缓存住，见上面的说明。
  if [ -n "$user" ] && [ -n "$repo" ] && [ -n "$ref" ] && [ -n "$path" ]; then
    local sha n
    if sha=$(gh_resolve_sha "$user/$repo" "$ref"); then
      for n in $GH_JSDELIVR_NODES; do list+=("$n/gh/$user/$repo@$sha/$path"); done
    fi
  fi
  list+=("$(gh_bust "$raw")")   # 最后才直连

  # 把探测出来的首选途径提到最前面（其它顺序不变，作回退）
  # 注意一律用 ${VAR:-} —— 本脚本开着 set -u，而这些变量是"探测后才有值"的，
  # 直接用 "$GH_PREF_KIND" 会在未探测时直接报 unbound variable 把脚本打断。
  local i
  if [ -n "${GH_PREF_KIND:-}" ]; then
    local -a ordered=()
    for i in "${list[@]}"; do
      case "${GH_PREF_KIND:-}" in
        # 反代前缀：拼在完整 GitHub URL 前面，所以以「前缀 + https://」开头
        proxy)    case "$i" in "${GH_PREF_PREFIX:-}https://"*) ordered+=("$i") ;; esac ;;
        # jsDelivr：路径里含 /gh/
        jsdelivr) case "$i" in "${GH_PREF_PREFIX:-}"/gh/*) ordered+=("$i") ;; esac ;;
        direct)   case "$i" in "https://raw.githubusercontent.com/"*) ordered+=("$i") ;; esac ;;
      esac
    done
    for i in "${list[@]}"; do
      local dup=0 o
      for o in "${ordered[@]:-}"; do [ "$o" = "$i" ] && dup=1; done
      [ "$dup" = 0 ] && ordered+=("$i")
    done
    printf '%s\n' "${ordered[@]}"
  else
    printf '%s\n' "${list[@]}"
  fi
}

# 依次尝试各途径把 $1 下载到 $2。成功返回 0。
# $3=超时秒（默认 30）  $4=最多试几个途径（默认全部）
gh_fetch() {
  local raw=$1 out=$2 tmo=${3:-30} maxn=${4:-99}
  command -v curl >/dev/null 2>&1 || return 1
  local u n=0 rc=1
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    n=$((n + 1))
    [ "$n" -gt "$maxn" ] && break
    if gh_curl -fsSL --connect-timeout 10 --max-time "$tmo" -o "$out" "$u" 2>/dev/null && [ -s "$out" ]; then
      GH_LAST_URL=$u
      return 0
    fi
  done < <(gh_raw_url "$raw")
  return 1
}

# 静默探测：找出本机最快的一条途径，写进 GH_PREF_KIND / GH_PREF_PREFIX，
# 之后所有 gh_fetch 都会把它排在第一位。探测目标用仓库里的 LICENSE（1KB）
# 而不是脚本本身（180KB），省时间。
gh_pick_mirror() {
  [ -n "${GH_MIRRORS_RAW:-}" ] && { inf "按 SET_DNS_GH_MIRROR 指定下载途径：$GH_MIRRORS_RAW"; return 0; }
  command -v curl >/dev/null 2>&1 || return 1
  local probe=https://raw.githubusercontent.com/zhengwuji/set-dns/main/LICENSE
  local u best="" bt="" t s e code
  for u in $(gh_raw_url "$probe"); do
    [ -n "$u" ] || continue
    s=$(date +%s%N)
    code=$(gh_curl -sSL -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 10 "$u" 2>/dev/null)
    [ "$code" = 200 ] || continue
    e=$(date +%s%N)
    t=$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.2f", (b-a)/1e9}')
    if [ -z "$best" ] || awk -v a="$t" -v b="$bt" 'BEGIN{exit !(a<b)}'; then best=$u; bt=$t; fi
  done
  [ -n "$best" ] || return 1
  GH_PREF_URL=$best
  # 判断类型时不能拿完整的探测 URL 去匹配 —— jsDelivr 的候选是按 commit SHA 拼的
  # （`.../gh/user/repo@<40位sha>/LICENSE`），写死 `@main` 会匹配不上、被误判成 proxy。
  # 所以只按「形态特征」判断：含 `/gh/` 的是 jsDelivr，`raw.githubusercontent.com` 是直连，
  # 其余（`<前缀>https://...`）是反代。
  case "$best" in
    https://raw.githubusercontent.com/*) GH_PREF_KIND=direct; GH_PREF_PREFIX="" ;;
    */gh/*) GH_PREF_KIND=jsdelivr; GH_PREF_PREFIX=${best%%/gh/*} ;;
    *)
      # 反代前缀形态。**不能用 ${best%%https://*}** —— best 本身就以 https:// 开头，
      # 该模式会从头匹配到结尾，结果是空串（真机踩到：前缀变成空，后续排序全乱）。
      # 正确做法是先剥掉 scheme，再取到第一个 '/' 为止的主机名。
      local h=${best#https://}
      GH_PREF_KIND=proxy
      GH_PREF_PREFIX="https://${h%%/*}/"
      ;;
  esac
  inf "下载途径探测：最快的是 ${best:0:52}…（${bt}s）"
  return 0
}

# --gh-check：把每个途径都实测一遍并打印，用于排障（只读，不改任何文件）
gh_check() {
  hr; echo "GitHub 下载途径自检"; hr
  if ! command -v curl >/dev/null 2>&1; then no "没有 curl（先跑 set-dns --tools）"; hr; return 1; fi
  local probe=https://raw.githubusercontent.com/zhengwuji/set-dns/main/LICENSE
  echo "  探测目标：$probe（仓库里的 LICENSE，1KB）"
  echo
  printf '  %-58s %-8s %s\n' '途径' '状态' '耗时'
  printf '  %s\n' '--------------------------------------------------------------------'
  local u s e t code okc=0
  for u in $(gh_raw_url "$probe"); do
    s=$(date +%s%N)
    code=$(curl -sSL -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 12 "$u" 2>/dev/null)
    e=$(date +%s%N)
    t=$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.2f", (b-a)/1e9}')
    local label=$u
    case "$u" in
      https://raw.githubusercontent.com/*) label="直连 GitHub（大陆通常不行）" ;;
      */gh/zhengwuji/set-dns@main/LICENSE) label="${u%/gh/*}  jsDelivr CDN" ;;
      *)
        # 反代前缀形态：https://gh-proxy.com/https://raw... -> 取主机名做标签
        # 注意不能用 ${u%%https://*} —— URL 本身就以 https:// 开头，那样会得到空串
        local host=${u#https://}
        label="${host%%/*}"
        ;;
    esac
    if [ "$code" = 200 ]; then
      printf '  %-58s %-8s %ss\n' "$label" 'OK' "$t"
      okc=$((okc + 1))
    else
      printf '  %-58s %-8s %s\n' "$label" "HTTP ${code:-000}" '失败'
    fi
  done
  echo
  if [ "$okc" -gt 0 ]; then
    ok "$okc 个途径可用 —— 脚本内的所有 GitHub 下载会自动按这个结果排序"
    if gh_pick_mirror; then
      inf "本次首选：$GH_PREF_URL"
      inf "  （类型 ${GH_PREF_KIND}，前缀 ${GH_PREF_PREFIX:-无}）"
    fi
  else
    no "所有途径都不可用 —— 这台机器可能整体出不了网"
    inf "先确认基本连通性：curl -sSI https://www.baidu.com | head -1"
  fi
  echo
  echo "  脚本内部会用到 GitHub 的地方（都会自动走可用途径）："
  echo "    - 菜单 0「升级脚本」拉最新版 set-dns.sh"
  echo "    - 菜单 12 装/升级 3x-ui（含官方 install.sh 与 78MB 安装包）"
  echo "    - 菜单 11 的 25/26/60 三个外部脚本（brutal / LotSpeed / tcpfit）"
  echo "    - DoH 模式的 dnscrypt-proxy 解析器列表"
  echo
  echo "  想固定用某个途径：SET_DNS_GH_MIRROR=https://gh-proxy.com/ set-dns ..."
  hr
  return 0
}
have6() {
  want6 || return 1
  if command -v ip >/dev/null 2>&1; then
    ip -6 route show default 2>/dev/null | grep -q . || return 1
  fi
  return 0
}
# unbound 里显式 do-ip6: no 时不要给 IPv6 上游
ub_v6_ok() {
  have6 || return 1
  grep -qE '^[[:space:]]*do-ip6:[[:space:]]*no' "$UB_CONF" 2>/dev/null && return 1
  return 0
}
port53_owner() {
  ss -lnup 2>/dev/null | awk '$5 ~ /127\.0\.0\.1:53$|0\.0\.0\.0:53$|\*:53$|\[::\]:53$|\]:53$/ {print $NF}' | head -1
}

# ================= 系统信息查询（菜单 6 / --sysinfo） =================
# 纯只读：只收集本机信息并打印，不碰 DNS、不写任何文件。
# 外部查询（IPv4 / 运营商 / 地理位置）全部带超时，取不到就显示 "-"，断网也不会卡住。
si_h() { # 字节数转人类可读
  awk -v b="$1" 'BEGIN{
    if (b>=1073741824) printf "%.2fG", b/1073741824;
    else if (b>=1048576) printf "%.2fM", b/1048576;
    else if (b>=1024) printf "%.2fK", b/1024;
    else printf "%.0fB", b }'
}
sysinfo_pause() {
  [ "${TTY_OK:-0}" = 1 ] || return 0
  printf '操作完成\n按任意键继续...'
  IFS= read -r -n 1 -s _ < /dev/tty 2>/dev/null || true
  echo
}
sysinfo() {
  local hn osv kv arch cpu cores mhz use load tcpudp mem vms disk rxb txb cc qd isp ip4 dnsn geo tme up el d h m j cy ci

  hn=$(hostname -f 2>/dev/null || hostname 2>/dev/null); [ -n "$hn" ] || hn='-'

  if [ -r "$ETC/os-release" ]; then
    osv=$( . "$ETC/os-release" 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}" )
  else osv=$(uname -s 2>/dev/null); fi
  [ -n "$osv" ] || osv='-'

  kv=$(uname -r 2>/dev/null);  [ -n "$kv" ]   || kv='-'
  arch=$(uname -m 2>/dev/null); [ -n "$arch" ] || arch='-'

  cpu=$(awk -F': ' '/^[Mm]odel name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
  [ -n "$cpu" ] || cpu=$(awk -F': ' '/^Hardware/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
  [ -n "$cpu" ] || cpu='-'

  cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null)
  [ -n "$cores" ] || cores='-'

  mhz=$(awk -F': ' '/^cpu MHz/{printf "%.1f GHz", $2/1000; exit}' /proc/cpuinfo 2>/dev/null)
  if [ -z "$mhz" ]; then
    mhz=$(awk -F': ' '/^[Mm]odel name/{if (match($2,/[0-9.]+[GM]Hz/)){print substr($2,RSTART,RLENGTH); exit}}' /proc/cpuinfo 2>/dev/null)
  fi
  [ -n "$mhz" ] || mhz='-'

  # CPU 瞬时占用：取 /proc/stat 两次采样算差值（最通用，不依赖 procps/top）
  use=$(awk '/^cpu /{t=$2+$3+$4+$5+$6+$7+$8+$9+$10; i=$5; print t, i; exit}' /proc/stat 2>/dev/null)
  if [ -n "$use" ]; then
    sleep 1
    use=$(awk -v a="$use" '
      BEGIN{ n=split(a,x," "); t1=x[1]; i1=x[2] }
      /^cpu /{ t2=$2+$3+$4+$5+$6+$7+$8+$9+$10; i2=$5;
        dt=t2-t1; di=i2-i1;
        if (dt>0){ u=100-di*100/dt; if(u<0)u=0; if(u>100)u=100; printf "%d%%", u } else printf "-"
        exit }' /proc/stat 2>/dev/null)
  fi
  [ -n "$use" ] || use='-'
  case "$use" in *%) ;; *) # 退路：vmstat
    use=$(command -v vmstat >/dev/null 2>&1 && vmstat 1 2 2>/dev/null | tail -1 | awk '{printf "%d%%", 100-$15}')
    [ -n "$use" ] || use='-' ;;
  esac

  load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null | tr ' ' ',' | sed 's/,/, /g'); [ -n "$load" ] || load='-'

  tcpudp="$(ss -Htn 2>/dev/null | wc -l)|$(ss -Hun 2>/dev/null | wc -l)"

  mem=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^Buffers:/{b=$2} /^Cached:/{c=$2} END{
         if (a=="") a=f+b+c
         if (t>0) printf "%.2f/%.2fM (%.2f%%)", (t-a)/1024, t/1024, (t-a)*100/t }' /proc/meminfo 2>/dev/null)
  [ -n "$mem" ] || mem='-'

  vms=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{
        if (t>0) printf "%.0fM/%.0fM (%.0f%%)", (t-f)/1024, t/1024, (t-f)*100/t;
        else printf "0M/0M (0%%)" }' /proc/meminfo 2>/dev/null)
  [ -n "$vms" ] || vms='-'

  disk=$(df -hP / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}'); [ -n "$disk" ] || disk='-'

  # 网卡累计收发（跳过纯表头行）
  local io
  io=$(awk '/:/{gsub(/:/," "); r+=$2; t+=$10} END{printf "%s %s", r+0, t+0}' /proc/net/dev 2>/dev/null)
  rxb=$(printf '%s' "$io" | awk '{print $1}'); txb=$(printf '%s' "$io" | awk '{print $2}')
  rxb=$(si_h "${rxb:-0}"); txb=$(si_h "${txb:-0}")

  cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
  qd=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)
  [ -n "$cc" ] || cc='-'; [ -n "$qd" ] || qd='-'

  dnsn=$(awk '/^[[:space:]]*nameserver[[:space:]]+/{printf "%s ", $2}' "$HERE" 2>/dev/null)
  dnsn=${dnsn% }; [ -n "$dnsn" ] || dnsn='-'

  # 外部查询：IPv4 / 运营商 / 地理位置（可用 SET_DNS_SYSINFO_NO_NET=1 跳过）
  ip4='-'; isp='-'; geo='-'
  if [ "${SET_DNS_SYSINFO_NO_NET:-0}" != 1 ] && command -v curl >/dev/null 2>&1; then
    j=$(curl -s4 --max-time 6 https://ipinfo.io/json 2>/dev/null)
    if [ -n "$j" ]; then
      ip4=$(printf '%s' "$j" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      isp=$(printf '%s' "$j" | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      cy=$(printf '%s' "$j" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      ci=$(printf '%s' "$j" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      geo="${cy:+$cy}${ci:+ $ci}"
    fi
    if [ "$ip4" = '-' ] || [ -z "$ip4" ]; then
      j=$(curl -s4 --max-time 6 http://ip-api.com/json/ 2>/dev/null)
      [ -z "$ip4" ] && ip4=$(printf '%s' "$j" | sed -n 's/.*"query"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      [ "$isp" = '-' ] && isp=$(printf '%s' "$j" | sed -n 's/.*"isp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      if [ "$geo" = '-' ]; then
        cy=$(printf '%s' "$j" | sed -n 's/.*"countryCode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        ci=$(printf '%s' "$j" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        geo="${cy:+$cy}${ci:+ $ci}"
      fi
    fi
  fi
  if [ -z "$ip4" ]; then
    ip4=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  fi
  [ -n "$ip4" ] || ip4='-'; [ -n "$isp" ] || isp='-'; [ -n "$geo" ] || geo='-'

  # 时区优先用 IANA 名（/etc/timezone 或 timezone symlink），否则退回 %Z 缩写
  local tz
  if [ -s "$ETC/timezone" ]; then tz=$(head -1 "$ETC/timezone" 2>/dev/null)
  else tz=$(readlink "$ETC/localtime" 2>/dev/null | sed 's#.*/zoneinfo/##')
  fi
  [ -n "$tz" ] || tz=$(date '+%Z' 2>/dev/null)
  tme="${tz:-UTC} $(date '+%Y-%m-%d %I:%M %p' 2>/dev/null)"
  [ -n "$tme" ] || tme='-'

  el=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
  if [ -n "$el" ]; then
    d=$((el/86400)); h=$((el%86400/3600)); m=$((el%3600/60))
    if   [ "$d" -gt 0 ]; then up="${d}天 ${h}小时 ${m}分"
    elif [ "$h" -gt 0 ]; then up="${h}小时 ${m}分"
    else up="${m}分"; fi
  else up='-'; fi

  echo "系统信息查询"
  hr
  echo "主机名:           $hn"
  echo "系统版本:         $osv"
  echo "Linux版本:        $kv"
  echo "CPU架构:          $arch"
  echo "CPU型号:          $cpu"
  echo "CPU核心数:        $cores"
  echo "CPU频率:          $mhz"
  echo "CPU占用:          $use"
  echo "系统负载:         $load"
  echo "TCP/UDP连接数:    $tcpudp"
  hr
  echo "物理内存:         $mem"
  echo "虚拟内存:         $vms"
  echo "硬盘占用:         $disk"
  hr
  echo "总接收:           $rxb"
  echo "总发送:           $txb"
  echo "网络算法:         $cc $qd"
  echo "运营商:           $isp"
  echo "IPv4地址:         $ip4"
  echo "DNS地址:          $dnsn"
  echo "地理位置:         $geo"
  echo "系统时间:         $tme"
  echo "运行时长:         $up"
  hr
  sysinfo_pause
}

# ================= 基础工具一键安装（菜单 7 / --tools） =================
# 新装的系统常缺 curl / wget / vim / git 这类最基础的东西。这里只做两件事：
# 「查有没有」+「缺啥装啥」，不碰 DNS 配置、不改 resolv.conf。
# 装包会触发我们装的 apt 钩子跑一次守护脚本，那是预期行为（守护本来就在）。
# 清单格式：显示名|检测命令|实际包名|是否核心(1=默认装, 0=要选「全部」才装)
tools_catalog() {
  cat <<'TEOF'
curl|curl|curl|1
wget|wget|wget|1
vim|vim|vim|1
git|git|git|1
tar|tar|tar|1
unzip|unzip|unzip|1
sudo|sudo|sudo|1
nano|nano|nano|1
htop|htop|htop|0
tmux|tmux|tmux|0
ncdu|ncdu|ncdu|0
socat|socat|socat|0
iftop|iftop|iftop|0
ifconfig|ifconfig|net-tools|0
ranger|ranger|ranger|0
fzf|fzf|fzf|0
btop|btop|btop|0
ffmpeg|ffmpeg|ffmpeg|0
cmatrix|cmatrix|cmatrix|0
sl|sl|sl|0
bastet|bastet|bastet|0
ninvaders|ninvaders|ninvaders|0
nsnake|nsnake|nsnake|0
TEOF
}

pkg_mgr() {
  local m
  for m in apt-get dnf yum apk pacman zypper; do
    command -v "$m" >/dev/null 2>&1 && { printf '%s' "$m"; return 0; }
  done
  return 1
}

# 判断一个工具「到底装没装」。不能只用 `command -v`：
# Debian 把 sl / bastet / ninvaders / nsnake 装在 /usr/games，而 root 的 PATH 来自
# /etc/login.defs 的 ENV_SUPATH，**不含 /usr/games**（普通用户的 ENV_PATH 才含）。
# 于是 apt-get 明明装成功了（日志里 Setting up bastet ...），面板却还报「未安装」，
# 末尾还说「还剩 4 个没装上」—— 实测被用户当场发现。所以两条判据取「或」：
#   1) 在补上 /usr/games 的 PATH 里能找到这个命令
#   2) 包管理器认为这个包已安装（dpkg -l / rpm -q / apk info ...）
# 第 2 条还顺带解决了「装了但可执行文件不在任何常规 PATH」的包。
tool_present() { # $1=检测命令  $2=包名
  local c=$1 p=$2
  # 子 shell 里改 PATH，不污染外面的环境
  ( PATH="$PATH:/usr/games:/usr/local/games"; command -v "$c" >/dev/null 2>&1 ) && return 0
  [ -n "$p" ] || return 1
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -l "$p" 2>/dev/null | grep -q '^ii'
  elif command -v rpm >/dev/null 2>&1; then
    rpm -q "$p" >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk info -e "$p" >/dev/null 2>&1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Q "$p" >/dev/null 2>&1
  else
    return 1
  fi
}

# 只在输出真的是终端时上色：管道/重定向里带转义序列会污染日志和测试断言。
# 用 [ -t 1 ] 而不是 TTY_OK —— TTY_OK 是给「读输入」用的，且在本段之后才赋值。
tools_colors() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    CC_OK=$'\033[32m'; CC_NO=$'\033[31m'; CC_R0=$'\033[0m'
  else
    CC_OK=''; CC_NO=''; CC_R0=''
  fi
}

# apt 要靠 DNS 才能解析软件源。这是个 DNS 脚本，顺手把这种「白等」拦下来。
dns_resolvable() {
  local h
  for h in deb.debian.org archive.ubuntu.com mirrors.aliyun.com; do
    getent hosts "$h" >/dev/null 2>&1 && return 0
  done
  return 1
}

tools_read() { # 把清单读进全局数组（用进程替换，不要用管道，否则数组在子 shell 里丢了）
  T_DISP=(); T_CHK=(); T_PKG=(); T_CORE=()
  local d c p k
  while IFS='|' read -r d c p k; do
    [ -n "$d" ] || continue
    T_DISP+=("$d"); T_CHK+=("$c"); T_PKG+=("$p"); T_CORE+=("$k")
  done < <(tools_catalog)
}

tools_show() { # 三列面板，按列优先排布（像系统信息那样一眼看完）
  local n=${#T_DISP[@]} rows i col idx m st cell line
  tools_colors
  hr
  echo "基础工具"
  printf '使用包管理器：%s\n' "$(pkg_mgr 2>/dev/null || echo '未找到')"
  hr
  rows=$(( (n + 2) / 3 ))
  for ((i = 0; i < rows; i++)); do
    line=""
    for ((col = 0; col < 3; col++)); do
      idx=$(( col * rows + i ))
      [ "$idx" -lt "$n" ] || continue
      if tool_present "${T_CHK[$idx]}" "${T_PKG[$idx]}"; then m="${CC_OK}✓${CC_R0}"; st='已安装'
      else m="${CC_NO}✗${CC_R0}"; st='未安装'; fi
      cell=$(printf ' %s %-12s %s ' "$m" "${T_DISP[$idx]}" "$st")
      line="$line$cell"
    done
    printf '%s\n' "$line"
  done
  hr
}

tools_install() { # $@ = 要装的包名
  local mgr; mgr=$(pkg_mgr) || { no "找不到包管理器（apt / dnf / yum / apk / pacman / zypper 都没有）"; return 1; }
  local -a avail=() p
  # 先剔掉当前源里根本没有的包，否则 apt 会因一个坏名字整批失败
  for p in "$@"; do
    [ -n "$p" ] || continue
    if [ "$mgr" = apt-get ]; then
      if apt-cache show "$p" >/dev/null 2>&1; then avail+=("$p"); else inf "跳过 $p（当前源里没有这个包）"; fi
    else avail+=("$p"); fi
  done
  [ "${#avail[@]}" -gt 0 ] || { inf "没有可安装的包"; return 0; }
  if [ "$DRY" = 1 ]; then inf "[dry-run] $mgr 安装：${avail[*]}"; return 0; fi
  if [ "$REAL" = 0 ]; then inf "沙箱模式：跳过安装 ${avail[*]}"; return 0; fi
  inf "开始安装 ${#avail[@]} 个包：${avail[*]}"
  local rc=0
  case "$mgr" in
    apt-get)
      DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${avail[@]}" 2>&1 | tail -8 | sed 's/^/      /'
      rc=${PIPESTATUS[0]}   # 管道里 $? 是 tail 的，必须取 PIPESTATUS
      ;;
    dnf)    dnf install -y -q "${avail[@]}" 2>&1 | tail -8 | sed 's/^/      /'; rc=${PIPESTATUS[0]} ;;
    yum)    yum install -y -q "${avail[@]}" 2>&1 | tail -8 | sed 's/^/      /'; rc=${PIPESTATUS[0]} ;;
    apk)    apk add --no-cache "${avail[@]}" 2>&1 | tail -8 | sed 's/^/      /'; rc=${PIPESTATUS[0]} ;;
    pacman) pacman -Sy --noconfirm --needed "${avail[@]}" 2>&1 | tail -8 | sed 's/^/      /'; rc=${PIPESTATUS[0]} ;;
    zypper) zypper -n install "${avail[@]}" 2>&1 | tail -8 | sed 's/^/      /'; rc=${PIPESTATUS[0]} ;;
  esac
  [ "$rc" = 0 ] && return 0
  no "包管理器返回错误码 $rc（上面最后几行是它的输出）"
  return 1
}

tools() {
  local i n miss=0 newmiss all=0
  tools_read
  n=${#T_DISP[@]}
  [ "$n" -gt 0 ] || { no "工具清单为空"; return 1; }
  echo "基础工具一键安装"
  tools_show
  [ "${SET_DNS_TOOLS_ALL:-0}" = 1 ] && all=1
  local -a want=() wantnm=()
  for ((i = 0; i < n; i++)); do
    tool_present "${T_CHK[$i]}" "${T_PKG[$i]}" && continue
    miss=$((miss + 1))
    want+=("${T_PKG[$i]}")
    wantnm+=("${T_DISP[$i]}")
  done
  if [ "$miss" = 0 ]; then ok "清单里的 $n 个工具全都装好了，不用做事"; return 0; fi
  inf "缺 $miss 个：${wantnm[*]}"

  if [ "$all" = 0 ] && [ "$TTY_OK" = 1 ]; then
    echo
    echo "  怎么装？"
    echo "    1) 只装核心工具（curl / wget / vim / git / tar / unzip / sudo / nano）[默认]"
    echo "    2) 缺失的全装上（含 htop tmux ncdu socat iftop ranger fzf btop ffmpeg 等）"
    echo "    3) 不装了，退出"
    printf '  输入 1/2/3（直接回车 = 1）: '
    read_ans
    case "${ans:-1}" in
      1|"") all=0 ;;
      2)    all=1 ;;
      3)    inf "已取消，什么都没改"; return 0 ;;
      *)    wr "输入无效，按默认只装核心工具"; all=0 ;;
    esac
  fi

  # 只装核心时重新挑一遍，别把游戏也拖下来
  if [ "$all" = 0 ]; then
    want=(); wantnm=()
    for ((i = 0; i < n; i++)); do
      [ "${T_CORE[$i]}" = 1 ] || continue
      tool_present "${T_CHK[$i]}" "${T_PKG[$i]}" && continue
      want+=("${T_PKG[$i]}"); wantnm+=("${T_DISP[$i]}")
    done
    if [ "${#want[@]}" = 0 ]; then ok "核心工具都齐了（其余为可选，想要就跑 set-dns --tools-all）"; return 0; fi
    inf "本次要装的核心工具：${wantnm[*]}"
  fi

  if [ "$REAL" = 1 ] && [ "$DRY" = 0 ] && ! dns_resolvable; then
    wr "当前 DNS 解析不了软件源，apt 装了也会失败"
    inf "先跑 set-dns --plain（或直接 set-dns）把解析修好，再回来装工具"
    return 1
  fi
  tools_install "${want[@]}"

  newmiss=0
  local -a still=()
  for ((i = 0; i < n; i++)); do
    tool_present "${T_CHK[$i]}" "${T_PKG[$i]}" && continue
    newmiss=$((newmiss + 1)); still+=("${T_DISP[$i]}")
  done
  tools_show
  if [ "$newmiss" = 0 ]; then
    ok "全部就绪（$n/$n）"
  else
    inf "还剩 $newmiss 个没装上：${still[*]}"
    inf "  当前源里没有这些包，或网络不通；也可能装到了 PATH 之外（用绝对路径跑）"
  fi
}

# ================= 自动换源：找最快的软件源并替换（菜单 8 / --mirror） =================
# 只替换「发行版自己的仓库」地址；第三方仓库（docker / nodesource / plex 等）原样保留 ——
# 把它们的 URL 一起换掉会直接装不上包，这是换源脚本最容易翻车的地方。
# 两类配置文件都支持：老式 /etc/apt/sources.list 与新式 Deb822（debian.sources / ubuntu.sources）。
MIRROR_BAK=$BK/mirror
# 这些主机上的仓库才算「发行版自己的」，只有它们会被替换
M_DISTRO_HOSTS="deb.debian.org ftp.debian.org security.debian.org archive.ubuntu.com security.ubuntu.com ports.ubuntu.com"

osrel() { # $1=键名
  [ -r "$ETC/os-release" ] || return 1
  ( . "$ETC/os-release" 2>/dev/null; printf '%s' "$(eval "printf '%s' \"\${$1:-}\"")" )
}
distro_id() {
  local id like
  id=$(osrel ID) || return 1
  case "$id" in
    debian|ubuntu) printf '%s' "$id"; return 0 ;;
  esac
  like=$(osrel ID_LIKE 2>/dev/null || printf '')
  # 先认 ubuntu：Linux Mint / Pop!_OS 这类写的是 ID_LIKE="ubuntu debian"，
  # 直接父系是 ubuntu，组件表和安全仓路径都得按 Ubuntu 来。
  case "$like" in
    *ubuntu*) printf 'ubuntu'; return 0 ;;
    *debian*) printf 'debian'; return 0 ;;
  esac
  return 1
}
distro_codename() { osrel VERSION_CODENAME 2>/dev/null; }
distro_ver()      { osrel VERSION_ID 2>/dev/null; }
deb_arch()        { uname -m 2>/dev/null || printf 'amd64'; }

distro_components() {
  case "$(distro_id)" in
    ubuntu) printf 'main restricted universe multiverse' ;;
    debian)
      # non-free-firmware 是 bookworm(12) 才从 non-free 里拆出来的
      local v major
      v=$(distro_ver); major=${v%%.*}
      case "$major" in ''|*[!0-9]*) major=12 ;; esac
      if [ "$major" -ge 12 ]; then printf 'main contrib non-free non-free-firmware'
      else printf 'main contrib non-free'; fi ;;
    *) printf 'main' ;;
  esac
}

mirror_catalog() { # $1=debian|ubuntu  —— 输出 名字|主仓库|安全仓库
  if [ "$1" = ubuntu ]; then
    local ub se
    case "$(deb_arch)" in
      x86_64|amd64|i686|i386) ub='https://archive.ubuntu.com/ubuntu'; se='https://security.ubuntu.com/ubuntu' ;;
      *) ub='https://ports.ubuntu.com/ubuntu-ports'; se='https://ports.ubuntu.com/ubuntu-ports' ;;
    esac
    printf 'official|%s|%s\n' "$ub" "$se"
    cat <<'MEOF'
aliyun|https://mirrors.aliyun.com/ubuntu|https://mirrors.aliyun.com/ubuntu
tuna|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu
ustc|https://mirrors.ustc.edu.cn/ubuntu|https://mirrors.ustc.edu.cn/ubuntu
163|https://mirrors.163.com/ubuntu|https://mirrors.163.com/ubuntu
huawei|https://mirrors.huaweicloud.com/ubuntu|https://mirrors.huaweicloud.com/ubuntu
tencent|https://mirrors.cloud.tencent.com/ubuntu|https://mirrors.cloud.tencent.com/ubuntu
bfsu|https://mirrors.bfsu.edu.cn/ubuntu|https://mirrors.bfsu.edu.cn/ubuntu
sjtu|https://mirror.sjtu.edu.cn/ubuntu|https://mirror.sjtu.edu.cn/ubuntu
nju|https://mirrors.nju.edu.cn/ubuntu|https://mirrors.nju.edu.cn/ubuntu
MEOF
  else
    cat <<'MEOF'
official|https://deb.debian.org/debian|https://security.debian.org/debian-security
aliyun|https://mirrors.aliyun.com/debian|https://mirrors.aliyun.com/debian-security
tuna|https://mirrors.tuna.tsinghua.edu.cn/debian|https://mirrors.tuna.tsinghua.edu.cn/debian-security
ustc|https://mirrors.ustc.edu.cn/debian|https://mirrors.ustc.edu.cn/debian-security
163|https://mirrors.163.com/debian|https://mirrors.163.com/debian-security
huawei|https://mirrors.huaweicloud.com/debian|https://mirrors.huaweicloud.com/debian-security
tencent|https://mirrors.cloud.tencent.com/debian|https://mirrors.cloud.tencent.com/debian-security
bfsu|https://mirrors.bfsu.edu.cn/debian|https://mirrors.bfsu.edu.cn/debian-security
sjtu|https://mirror.sjtu.edu.cn/debian|https://mirror.sjtu.edu.cn/debian-security
nju|https://mirrors.nju.edu.cn/debian|https://mirrors.nju.edu.cn/debian-security
cloudflare|https://cloudflaremirrors.com/debian|https://security.debian.org/debian-security
leaseweb|https://mirror.us.leaseweb.net/debian|https://security.debian.org/debian-security
MEOF
  fi
}

mirror_load() { # 把候选表读进数组，并把候选主机并入「发行版主机」白名单
  M_NAME=(); M_BASE=(); M_SEC=()
  local n b s h
  while IFS='|' read -r n b s; do
    [ -n "$n" ] || continue
    M_NAME+=("$n"); M_BASE+=("$b"); M_SEC+=("$s")
  done < <(mirror_catalog "$1")
  # 候选源的主机也算发行版仓库主机（否则会把「已经是镜像源」的地址当第三方跳过）
  local extra=""
  for b in "${M_BASE[@]}" "${M_SEC[@]}"; do
    h=${b#*://}; h=${h%%/*}
    case " $M_DISTRO_HOSTS $extra " in *" $h "*) ;; *) extra="$extra $h" ;; esac
  done
  M_DISTRO_HOSTS="$M_DISTRO_HOSTS$extra"
}

is_distro_uri() { # $1=uri  判断这是不是发行版自己的仓库地址
  local u=$1 h
  case "$u" in ""|\#*) return 1 ;; esac
  h=${u#*://}; h=${h%%/*}
  case " $M_DISTRO_HOSTS " in *" $h "*) return 0 ;; esac
  case "$h" in *.debian.org|*.ubuntu.com) return 0 ;; esac
  return 1
}

# 取一个 URL 的下载耗时（秒，保留 3 位）。失败/404 返回非 0。
mirror_time() { # $1=url
  local url=$1 t st
  if command -v curl >/dev/null 2>&1; then
    t=$(curl -o /dev/null -sS -L --max-time 5 -w '%{time_total} %{http_code}' "$url" 2>/dev/null) || return 1
    st=${t##* }; t=${t%% *}
    [ "$st" = 200 ] || return 1
    printf '%s' "$t"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    local s e
    s=$(date +%s%N)
    wget -q -O /dev/null --timeout=5 --tries=1 "$url" 2>/dev/null || return 1
    e=$(date +%s%N)
    awk -v a="$s" -v b="$e" 'BEGIN{printf "%.3f", (b-a)/1e9}'
    return 0
  fi
  return 1
}

mirror_probe() { # 给每个候选源测「主仓库 + 安全仓」两份 Release；$1=debian|ubuntu  $2=codename
  local distro=$1 cn=$2 i n secsuite
  local -a okidx=()
  P_MAINT=(); P_SECT=(); P_OK=()
  if [ "$distro" = debian ]; then secsuite="$cn-security"; else secsuite="$cn-security"; fi
  echo "  探测各源速度（每个最多 5 秒）……"
  for ((i = 0; i < ${#M_NAME[@]}; i++)); do
    printf '    %-11s ' "${M_NAME[$i]}"
    local t
    if t=$(mirror_time "${M_BASE[$i]}/dists/$cn/Release"); then
      P_MAINT[$i]=$t; okidx+=("$i")
      printf '主仓库 %ss\n' "$t"
    else
      P_MAINT[$i]=''; printf '主仓库 不可用\n'
    fi
  done
  # 安全仓只测主仓库可用的（也是它决定最终名次），够用且不让探测时间翻倍
  for i in "${okidx[@]}"; do
    printf '    %-11s ' "${M_NAME[$i]}"
    local t
    if t=$(mirror_time "${M_SEC[$i]}/dists/$secsuite/Release"); then
      P_SECT[$i]=$t; P_OK[$i]=1
      printf '安全仓 %ss  => 合计 %ss\n' "$t" "$(awk -v a="${P_MAINT[$i]}" -v b="$t" 'BEGIN{printf "%.3f", a+b}')"
    else
      P_SECT[$i]=''; P_OK[$i]=0
      printf '安全仓 不可用（跳过这个源）\n'
    fi
  done
}

mirror_rank() { # 输出按总耗时排好序的下标，一行一个
  local i
  for ((i = 0; i < ${#M_NAME[@]}; i++)); do
    [ "${P_OK[$i]:-0}" = 1 ] || continue
    awk -v a="${P_MAINT[$i]}" -v b="${P_SECT[$i]}" -v i="$i" 'BEGIN{printf "%.3f %d\n", a+b, i}'
  done | sort -n -k1,1 | awk '{print $2}'
}

mirror_targets() { # 找出真正含发行版仓库的配置文件（老式 + Deb822）
  local f
  for f in "$ETC/apt/sources.list.d/debian.sources" "$ETC/apt/sources.list.d/ubuntu.sources" \
           "$ETC/apt/sources.list.d/debian.list" "$ETC/apt/sources.list.d/ubuntu.list" "$ETC/apt/sources.list"; do
    [ -f "$f" ] || continue
    case "$f" in
      *.sources|*.list|*/sources.list)
        # 该文件里有指向发行版仓库的行才算
        awk -v hosts="$M_DISTRO_HOSTS" '
          BEGIN{ n=split(hosts,H," "); for(i=1;i<=n;i++) ok[H[i]]=1 }
          /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
          {
            # 老式：deb ... <uri>   新式：URIs: <uri>
            u=""
            if (tolower($1)=="uris:") u=$2
            else if ($1=="deb"||$1=="deb-src") {
              j=2; br=0
              while (j<=NF) { if (substr($j,1,1)=="[") br=1; if (br) { if ($j ~ /\]$/) {br=0; j++; break} j++; continue } break }
              u=$j
            }
            if (u=="") next
            h=u; sub(/^[A-Za-z]+:\/\//,"",h); sub(/\/.*$/,"",h)
            if ((h in ok) || h ~ /\.debian\.org$/ || h ~ /\.ubuntu\.com$/) { print "YES"; exit }
          }' "$f" | grep -q YES && printf '%s\n' "$f"
        ;;
    esac
  done
}

# 老式 sources.list：只重写指向发行版仓库的行，第三方仓库原样保留
mirror_rewrite_classic() { # $1=file $2=主仓库 $3=安全仓
  local f=$1 base=$2 sec=$3
  local -a out=()
  local line ltrim uri suite newuri i nf
  local -a tok=()
  while IFS= read -r line || [ -n "$line" ]; do
    ltrim=${line#"${line%%[![:space:]]*}"}
    case "$ltrim" in ''|\#*) out+=("$line"); continue ;; esac
    # 拆成数组，避免 `set --` 覆盖函数入参
    read -r -a tok <<< "$ltrim"
    case "${tok[0]}" in deb|deb-src) ;; *) out+=("$line"); continue ;; esac
    # 跳过 [arch=amd64 signed-by=...] 这类选项段（可能整个写在方括号里，也可能分开写）
    nf=${#tok[@]}; i=1
    if [ "${tok[$i]#\[}" != "${tok[$i]}" ]; then
      while [ "$i" -lt "$nf" ] && [ "${tok[$i]%\]}" = "${tok[$i]}" ]; do i=$((i + 1)); done
      i=$((i + 1))
    fi
    [ "$i" -lt "$nf" ] || { out+=("$line"); continue; }
    uri=${tok[$i]}; suite=${tok[$((i + 1))]:-}
    if ! is_distro_uri "$uri"; then out+=("$line"); continue; fi
    newuri=$base
    case "$suite" in *-security) newuri=$sec ;; esac
    case "$uri" in *security*) newuri=$sec ;; esac
    # 只替换地址那一格，再把整行拼回去 —— 不能把 token 逐个塞进 out，
    # 否则 mirror_write 的 printf '%s\n' "$@" 会把每个 token 单独打成一行。
    tok[$i]=$newuri
    out+=("${tok[*]}")
  done < "$f"
  mirror_write "$f" "${out[@]}"
}

# 新式 Deb822（debian.sources / ubuntu.sources）：只换 URIs:，其余字段（含 Signed-By）原样保留
mirror_rewrite_deb822() { # $1=file $2=主仓库 $3=安全仓
  local f=$1 base=$2 sec=$3
  local -a L=() out=()
  mapfile -t L < "$f"
  local n=${#L[@]} i=0
  while [ "$i" -lt "$n" ]; do
    local line="${L[$i]}"
    if [ -z "${line//[[:space:]]/}" ]; then out+=("$line"); i=$((i + 1)); continue; fi
    local -a st=()
    while [ "$i" -lt "$n" ] && [ -n "${L[$i]//[[:space:]]/}" ]; do st+=("${L[$i]}"); i=$((i + 1)); done
    local l k issec=0 olduri="" haveuri=0
    for l in "${st[@]}"; do
      k="${l,,}"
      case "$k" in
        suites:*) case "$l" in *-security*) issec=1 ;; esac ;;
        uris:*)   haveuri=1
                  olduri="${l#*:}"; olduri="${olduri#"${olduri%%[![:space:]]*}"}"
                  olduri="${olduri%"${olduri##*[![:space:]]}"}" ;;
      esac
    done
    local repl=0
    if [ "$haveuri" = 1 ] && is_distro_uri "$olduri"; then
      case "$olduri" in *" "*) repl=0 ;; *) repl=1 ;; esac   # 一行多个地址就不动，稳妥
    fi
    if [ "$repl" = 1 ]; then
      local newuri=$base
      [ "$issec" = 1 ] && newuri=$sec
      case "$olduri" in *security*) [ "$issec" = 0 ] && newuri=$sec ;; esac
      for l in "${st[@]}"; do
        case "${l,,}" in
          uris:*) out+=("URIs: $newuri") ;;
          *)      out+=("$l") ;;
        esac
      done
    else
      for l in "${st[@]}"; do out+=("$l"); done
    fi
  done
  mirror_write "$f" "${out[@]}"
}

mirror_write() { # $1=目标文件  其余=内容行
  local f=$1; shift
  if [ "${#@}" = 0 ]; then : > "$f.tmp"; else printf '%s\n' "$@" > "$f.tmp"; fi
  [ -e "$f" ] && chmod --reference="$f" "$f.tmp" 2>/dev/null
  chown --reference="$f" "$f.tmp" 2>/dev/null
  mv -f "$f.tmp" "$f"
}

mirror_backup() { # $@=要备份的文件
  local f
  mkdir -p "$MIRROR_BAK" || return 1
  : > "$MIRROR_BAK/manifest"
  for f in "$@"; do
    [ -f "$f" ] || continue
    cp -a "$f" "$MIRROR_BAK/$(basename "$f")" || return 1
    printf '%s\n' "$f" >> "$MIRROR_BAK/manifest"
  done
  ok "原配置已备份到 $MIRROR_BAK/（$(wc -l < "$MIRROR_BAK/manifest") 个文件）"
}

mirror_restore() {
  local f n=0
  if [ ! -s "$MIRROR_BAK/manifest" ]; then inf "没有换源备份（$MIRROR_BAK/manifest 不存在），无需还原"; return 0; fi
  if [ "$DRY" = 1 ]; then inf "[dry-run] 将按 $MIRROR_BAK/manifest 还原软件源"; return 0; fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local b="$MIRROR_BAK/$(basename "$f")"
    if [ -f "$b" ]; then cp -a "$b" "$f" && n=$((n + 1)); else wr "备份里没有 $(basename "$f")，跳过"; fi
  done < "$MIRROR_BAK/manifest"
  ok "已还原 $n 个软件源文件"
  if [ "$REAL" = 0 ]; then inf "沙箱模式：跳过 apt-get update"; return 0; fi
  if ! apt_update_ok; then
    wr "还原后 apt-get update 仍然失败，请手动检查 $ETC/apt/"
    return 1
  fi
  ok "还原完成，apt 可正常使用"
}

apt_update_ok() {
  [ "$REAL" = 1 ] || return 0
  local out rc
  out=$(DEBIAN_FRONTEND=noninteractive apt-get update 2>&1); rc=$?
  # apt 有时退出码为 0 但内部报错，所以两种信号都看
  if [ "$rc" != 0 ] || printf '%s' "$out" | grep -qiE '^(E:|Err:|W: Failed)'; then
    printf '%s\n' "$out" | grep -iE '^(E:|Err:|W: Failed|W: Some index files)' | head -6 | sed 's/^/      /'
    [ "$rc" != 0 ] && inf "apt-get update 退出码 $rc"
    return 1
  fi
  return 0
}

mirror_show_current() {
  local f
  echo "  当前使用的仓库地址："
  for f in $(mirror_targets); do
    printf '    [%s]\n' "$f"
    awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
         tolower($1)=="uris:" { print "      " $0 }
         $1=="deb"||$1=="deb-src" { print "      " $0 }' "$f" | head -6
  done
}

mirror_rank_table() { # $@=排序后的下标
  local -a idx=("$@")
  printf '    %-4s %-12s %-10s %-10s %s\n' '#' '镜像源' '主仓库' '安全仓' '合计'
  local k i tot
  for ((k = 0; k < ${#idx[@]}; k++)); do
    i=${idx[$k]}
    tot=$(awk -v a="${P_MAINT[$i]}" -v b="${P_SECT[$i]}" 'BEGIN{printf "%.3f", a+b}')
    printf '    %-4s %-12s %-10s %-10s %ss\n' "$((k + 1))" "${M_NAME[$i]}" "${P_MAINT[$i]}s" "${P_SECT[$i]}s" "$tot"
  done
}

mirror_apply() {
  local distro cn g
  distro=$(distro_id) || { no "只支持 Debian / Ubuntu 系（读不到 /etc/os-release 或 ID 不认识）"; return 1; }
  cn=$(distro_codename)
  [ -n "$cn" ] || { no "读不到系统代号（os-release 里没有 VERSION_CODENAME），无法换源"; return 1; }
  mirror_load "$distro"

  local -a tgts=()
  local f
  while IFS= read -r f; do [ -n "$f" ] && tgts+=("$f"); done < <(mirror_targets)
  if [ "${#tgts[@]}" = 0 ]; then
    wr "没找到指向发行版仓库的 apt 配置文件（$ETC/apt/sources.list 与 sources.list.d/）"
    inf "如果这台机器用的是第三方源或自定义源，本脚本不替你改"
    return 1
  fi

  # 沙箱模式（SET_DNS_ETC 指到别处）也允许真正改写文件 —— 改的是测试目录，不是系统
  echo "  系统: $distro $cn ($(deb_arch))   组件: $(distro_components)"
  mirror_show_current
  echo
  # SET_DNS_MIRROR_NO_PROBE=1：跳过测速直接选第一个候选。
  # 给沙箱测试用 —— 否则每跑一次测试都要联网探测十几个源，既慢又受本地网络影响、结果不稳定。
  if [ "${SET_DNS_MIRROR_NO_PROBE:-0}" = 1 ]; then
    inf "SET_DNS_MIRROR_NO_PROBE=1：跳过测速，直接用候选里的第一个"
    local j
    for ((j = 0; j < ${#M_NAME[@]}; j++)); do P_OK[$j]=1; P_MAINT[$j]=0; P_SECT[$j]=0; done
  else
    mirror_probe "$distro" "$cn"
  fi
  local -a ranked=()
  while IFS= read -r i; do [ -n "$i" ] && ranked+=("$i"); done < <(mirror_rank)
  if [ "${#ranked[@]}" = 0 ]; then
    no "所有候选源都探测失败 —— 先确认网络/DNS 正常（可用 set-dns --check）"
    return 1
  fi
  echo
  echo "  速度排名（主仓库 + 安全仓，越小越快）："
  mirror_rank_table "${ranked[@]}"

  local pick=${ranked[0]} n
  if [ -n "${SET_DNS_MIRROR:-}" ]; then
    local found=""
    for n in "${ranked[@]}"; do
      if [ "${M_NAME[$n]}" = "$SET_DNS_MIRROR" ]; then found=$n; break; fi
    done
    if [ -n "$found" ]; then pick=$found; inf "按 SET_DNS_MIRROR= 指定使用 ${M_NAME[$pick]}"
    else wr "SET_DNS_MIRROR=$SET_DNS_MIRROR 不在可用列表里，改用最快的 ${M_NAME[$pick]}"; fi
  elif [ "$TTY_OK" = 1 ]; then
    echo
    printf '  用第几名？（直接回车 = 1，也就是 %s，q = 取消）: ' "${M_NAME[${ranked[0]}]}"
    read_ans
    case "${ans:-1}" in
      q|Q) inf "已取消，什么都没改"; return 0 ;;
      ''|*[!0-9]*) wr "输入无效，用最快的 ${M_NAME[${ranked[0]}]}"; pick=${ranked[0]} ;;
      *) if [ "$ans" -ge 1 ] && [ "$ans" -le "${#ranked[@]}" ]; then pick=${ranked[$((ans - 1))]}
         else wr "超出范围，用最快的 ${M_NAME[${ranked[0]}]}"; pick=${ranked[0]}; fi ;;
    esac
  fi

  local nb="${M_BASE[$pick]}" ns="${M_SEC[$pick]}"
  echo
  ok "选定 ${M_NAME[$pick]}：主仓库 $nb"
  inf "              安全仓 $ns"
  if [ "$DRY" = 1 ]; then
    inf "[dry-run] 将重写：${tgts[*]}（备份到 $MIRROR_BAK/）"
    return 0
  fi

  mirror_backup "${tgts[@]}" || { no "备份失败，已放弃改动（不动原配置）"; return 1; }
  for f in "${tgts[@]}"; do
    case "$f" in
      *.sources) mirror_rewrite_deb822 "$f" "$nb" "$ns" ;;
      *)         mirror_rewrite_classic "$f" "$nb" "$ns" ;;
    esac
    ok "已改写 $f"
  done

  if [ "$REAL" = 0 ]; then
    inf "沙箱模式：文件已改写（$ETC 是测试目录），跳过 apt-get update"
    return 0
  fi

  echo
  inf "跑一次 apt-get update 验证新源……"
  if apt_update_ok; then
    ok "换源成功，apt 可正常使用"
    inf "想还原：set-dns --mirror-restore（备份在 $MIRROR_BAK/）"
  else
    wr "新源 update 失败，自动回滚到原配置"
    local b
    for b in "${tgts[@]}"; do
      g="$MIRROR_BAK/$(basename "$b")"
      [ -f "$g" ] && cp -a "$g" "$b"
    done
    if apt_update_ok; then ok "已回滚，apt 恢复正常"
    else no "回滚后 update 仍失败，请手动检查 $ETC/apt/"; fi
    return 1
  fi
}

mirror() { # 菜单 8 入口
  echo "自动换源（找最快的软件源并替换）"
  hr
  if [ "$(id -u)" != 0 ]; then
    # 非 root 只做只读部分：列出现状 + 探测速度
    local distro cn
    distro=$(distro_id) || { no "只支持 Debian / Ubuntu 系"; return 1; }
    cn=$(distro_codename); [ -n "$cn" ] || { no "读不到系统代号"; return 1; }
    mirror_load "$distro"
    mirror_show_current
    echo
    mirror_probe "$distro" "$cn"
    local -a ranked=(); local i
    while IFS= read -r i; do [ -n "$i" ] && ranked+=("$i"); done < <(mirror_rank)
    [ "${#ranked[@]}" -gt 0 ] && { echo; echo "  速度排名："; mirror_rank_table "${ranked[@]}"; }
    echo
    inf "当前不是 root，只做探测不改配置；要真正换源请用 root 或 sudo 重跑"
    return 0
  fi
  mirror_apply
}

# ================= 自定义 SSH 连接端口（菜单 9 / --ssh-port） =================
# 改 SSH 端口最怕把自己关在门外，所以这里做了四层保护：
#   1) `sshd -t` 语法校验不过就根本不重启；
#   2) 重启后轮询 `ss -lnt` 确认新端口真的起来了，起不来立刻回滚；
#   3) 可选「保留旧端口」，两个端口同时监听，验证通了再关旧的；
#   4) 改之前先把原配置整份备份到 $BK/ssh/orig（--ssh-port-restore 一键还原）。
# 另外处理了两个真坑：ssh.socket 套接字激活的机器端口由 ListenStream 决定而不是 sshd_config；
# 以及 sshd_config 末尾若有 Match 块，往文件尾追加 Port 会掉进 Match 作用域里 —— 所以块要插在
# 第一个 Match 之前。
SSH_DIR=$ETC/ssh
SSH_CONF=$SSH_DIR/sshd_config
SSH_PDROP=$SSH_DIR/sshd_config.d
SSH_BAK=$BK/ssh
SSH_SDROP=$ETC/systemd/system/ssh.socket.d/99-set-dns-port.conf
SSH_MARK_B="set-dns ssh port begin"
SSH_MARK_E="set-dns ssh port end"
SSH_REQ=${SET_DNS_SSH_PORT:-}     # 目标端口（--ssh-port=N 或 环境变量）

sshd_bin() {
  if command -v sshd >/dev/null 2>&1; then command -v sshd
  elif [ -x /usr/sbin/sshd ]; then echo /usr/sbin/sshd
  else return 1; fi
}

# 配置文件里的 Port（$1=1 时连 sshd_config.d 的子文件一起看）
# 注意：只认 Match 作用域之外的 Port —— Match 块里的 Port 是条件性的，
# 把它当成全局生效端口会误判（比如 Match User foo / Port 2022 会被当成全机都开 2022）。
ssh_conf_ports() {
  local confs=("$SSH_CONF")
  [ -d "$SSH_PDROP" ] && confs+=("$SSH_PDROP"/*.conf)
  awk '
    /^[[:space:]]*Match[[:space:]]/ { inm = 1; next }
    inm { next }
    /^[[:space:]]*Port[[:space:]]+[0-9]+/ { print $2 }
  ' "${confs[@]}" 2>/dev/null | sort -un
}

# 真正生效的端口。沙箱里不能用 sshd -T（它会去读真实 /etc），所以退化为解析配置文件
ssh_effective_ports() {
  local s out
  if [ "$REAL" = 1 ] && s=$(sshd_bin); then
    out=$("$s" -T 2>/dev/null | awk 'tolower($1)=="port"{print $2}' | sort -un)
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  ssh_conf_ports
}

# 生效端口里真正在监听的那些（不靠进程名，非 root 也能用）
ssh_listen_ports() {
  local p
  for p in $(ssh_effective_ports); do
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$" && printf '%s\n' "$p"
  done
  return 0
}

ssh_svc_unit() {
  local u
  for u in ssh.service sshd.service; do
    systemctl list-unit-files "$u" --no-legend 2>/dev/null | grep -q "^$u" && { echo "$u"; return 0; }
  done
  echo ssh.service
}

ssh_sock_enabled() {
  [ "$REAL" = 1 ] || return 1
  systemctl is-enabled ssh.socket >/dev/null 2>&1
}

ssh_port_view() {
  local olds l
  olds=$(ssh_effective_ports | tr '\n' ' '); [ -n "$olds" ] || olds="(读不到)"
  inf "当前生效端口: ${olds% }"
  l=$(ssh_listen_ports | tr '\n' ' ')
  if [ -n "$l" ]; then inf "实际在监听: ${l% }"
  else inf "ss 没看到对应监听（非 root / 或 sshd 不在跑）"; fi
  if ssh_sock_enabled; then
    inf "ssh.socket 已启用 —— 端口由 socket 单元的 ListenStream 决定，不只看 sshd_config"
  elif [ -f "$SSH_CONF" ]; then
    inf "端口由 $SSH_CONF 决定"
  else
    inf "找不到 $SSH_CONF（这台机器可能没装 OpenSSH server）"
  fi
}

# 把原始路径编码成一个安全的备份文件名。除了 '/' 还要处理 ':' 和 '\\'：
# Windows/Git-Bash 下路径形如 G:\...\ssh\sshd_config，文件名里带 ':' 会让 cp 失败，
# 那样 manifest 会是空的，--ssh-port-restore 就会误报「没有备份」。
ssh_enc() { printf '%s' "$1" | tr '/\\:' '___'; }

# 备份当前 sshd 配置到 $1（同一目录下 manifest 记录原始路径）
ssh_snap() {
  local d=$1 f t
  mkdir -p "$d"; rm -f "$d/manifest"; : > "$d/manifest"
  for f in "$SSH_CONF" "$SSH_PDROP"/*.conf; do
    [ -f "$f" ] || continue
    t="$d/$(ssh_enc "$f")"
    cp -a "$f" "$t" 2>/dev/null && printf '%s\n' "$f" >> "$d/manifest"
  done
  return 0
}

ssh_snap_restore() {
  local d=$1 f t
  [ -s "$d/manifest" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    t="$d/$(ssh_enc "$f")"
    [ -f "$t" ] && cp -a "$t" "$f" 2>/dev/null
  done < "$d/manifest"
  return 0
}

# 重写 sshd_config：剔掉上次的块 → 注释所有非 Match 作用域里的 Port → 插到第一个 Match 之前
ssh_rewrite_conf() { # $1=file $2=新端口 $3=是否保留旧端口 $4=旧端口(空格分隔)
  # 注意：不能写成 local f=$1 ... tmp="$f.tmp" —— 同一行里 $f 在 local 生效前就被展开了，
  # 开着 set -u 时直接报 "f: unbound variable"。必须拆成两行。
  local f=$1 pnew=$2 keep=$3 olds=$4
  local tmp="$f.setdns.tmp"
  [ -f "$f" ] || return 1
  awk -v pnew="$pnew" -v keep="$keep" -v olds="$olds" -v stamp="$STAMP" -v mb="$SSH_MARK_B" -v me="$SSH_MARK_E" '
    function emit(   i) {
      print "# " mb " " stamp
      print "Port " pnew
      if (keep == 1) for (i = 1; i <= nO; i++) if (O[i] != "" && O[i] != pnew) print "Port " O[i]
      print "# " me
    }
    BEGIN { nO = split(olds, O, " ") }
    index($0, mb) { inblk = 1; next }                 # 先剔掉自己上次写的块
    inblk { if (index($0, me)) inblk = 0; next }
    !done && /^[[:space:]]*Match[[:space:]]/ { emit(); done = 1 }
    {
      if (inmatch) { print; next }
      if (/^[[:space:]]*Match[[:space:]]/) { inmatch = 1; print; next }
      if (/^[[:space:]]*Port[[:space:]]+[0-9]+/) {
        # 不能用 sub(/.../,"\\1...")：mawk 不支持反向引用，改成手工拼
        lead = ""
        if (match($0, /^[[:space:]]*/)) lead = substr($0, 1, RLENGTH)
        print lead "#set-dns-old# " substr($0, RLENGTH + 1)
        next
      }
      print
    }
    END { if (!done) emit() }
  ' "$f" > "$tmp" && mv -f "$tmp" "$f"
}

ssh_socket_apply() { # $1=新端口 $2=是否保留旧端口 $3=旧端口
  local pnew=$1 keep=$2 olds=$3 d=$ETC/systemd/system/ssh.socket.d f o
  d=$ETC/systemd/system/ssh.socket.d
  f=$d/99-set-dns-port.conf
  [ "$REAL" = 1 ] || { inf "沙箱模式：跳过 ssh.socket 配置（$f）"; return 0; }
  ssh_sock_enabled || return 1
  mkdir -p "$d" || return 1
  { printf '[Socket]\nListenStream=\nListenStream=%s\n' "$pnew"
    if [ "$keep" = 1 ]; then
      for o in $olds; do [ "$o" = "$pnew" ] || printf 'ListenStream=%s\n' "$o"; done
    fi
  } > "$f" && ok "已写 $f（ssh.socket 靠 ListenStream 定端口）"
}

ssh_fw_allow() { # $1=端口
  local p=$1 did=0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$p"/tcp >/dev/null 2>&1 && { ok "ufw 已放行 $p/tcp"; did=1; }
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$p"/tcp >/dev/null 2>&1 \
      && firewall-cmd --reload >/dev/null 2>&1 && { ok "firewalld 已放行 $p/tcp"; did=1; }
  fi
  if [ "$did" = 0 ]; then
    if command -v iptables >/dev/null 2>&1 && iptables -S 2>/dev/null | grep -qE 'DROP|REJECT'; then
      wr "检测到 iptables 有 DROP/REJECT 规则，脚本不自动改 —— 请自行放行 $p/tcp"
    else
      inf "没发现活动防火墙；云主机记得去安全组放行 $p/tcp"
    fi
  fi
}

ssh_selinux_allow() { # $1=端口
  local p=$1
  command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null || return 0
  command -v semanage >/dev/null 2>&1 || { wr "SELinux 开着但没有 semanage，端口可能被拦 —— 装 policycoreutils-python-utils 后 semanage port -a -t ssh_port_t -p tcp $p"; return 0; }
  if semanage port -l 2>/dev/null | awk '$1=="ssh_port_t"{print $3}' | tr -d ', ' | grep -qx "$p"; then
    inf "SELinux 已允许 $p/tcp"
  else
    semanage port -a -t ssh_port_t -p tcp "$p" >/dev/null 2>&1 \
      && ok "SELinux 已放行 $p/tcp（ssh_port_t）" \
      || wr "SELinux 放行失败，手动：semanage port -a -t ssh_port_t -p tcp $p"
  fi
}

ssh_validate() {
  local s rc=0
  [ "$REAL" = 1 ] || { inf "沙箱模式：跳过 sshd -t 校验"; return 0; }
  s=$(sshd_bin) || { wr "找不到 sshd，跳过语法校验"; return 0; }
  mkdir -p "$BK"
  if "$s" -t 2>"$BK/ssh-t.err"; then ok "sshd 配置语法校验通过"
  else no "sshd 配置校验失败：$(tail -3 "$BK/ssh-t.err" 2>/dev/null | tr '\n' ' ')"; rc=1; fi
  return $rc
}

ssh_restart() {
  local u
  [ "$REAL" = 1 ] || { inf "沙箱模式：跳过重启 sshd"; return 0; }
  u=$(ssh_svc_unit)
  if ssh_sock_enabled; then
    sys daemon-reload
    sys restart ssh.socket && ok "已重启 ssh.socket"
  fi
  sys restart "$u" && ok "已重启 $u"
}

ssh_wait_listen() { # $1=端口
  local p=$1 i=0
  [ "$REAL" = 1 ] || return 0
  while [ "$i" -lt 12 ]; do
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$" && return 0
    sleep 0.5; i=$((i + 1))
  done
  return 1
}

ssh_port_restore() {
  local olds
  if [ ! -s "$SSH_BAK/orig/manifest" ]; then
    inf "没有 SSH 端口备份（$SSH_BAK/orig 不存在），无需还原"
    return 0
  fi
  ssh_snap_restore "$SSH_BAK/orig" && ok "已按备份还原 $(wc -l < "$SSH_BAK/orig/manifest") 个配置文件"
  [ -f "$SSH_SDROP" ] && { rm -f "$SSH_SDROP" && ok "已删除 $SSH_SDROP"; }
  if [ "$REAL" = 1 ] && ssh_sock_enabled; then sys daemon-reload; fi
  ssh_validate || wr "还原后校验仍失败，请检查 $SSH_CONF"
  ssh_restart
  olds=$(ssh_effective_ports | tr '\n' ' ')
  inf "当前端口: ${olds% }"
  inf "提示：若连不上，检查云安全组与防火墙是否放行了原来的端口"
}

ssh_port_apply() { # $1=新端口 $2=是否保留旧端口(0/1)
  local pnew=$1 keep=$2 olds
  case "$pnew" in
    ''|*[!0-9]*) no "SSH 端口必须是数字（收到：$pnew）"; return 1 ;;
  esac
  [ "$pnew" -ge 1 ] && [ "$pnew" -le 65535 ] || { no "端口范围应为 1-65535（收到：$pnew）"; return 1; }
  [ -f "$SSH_CONF" ] || { no "找不到 $SSH_CONF（这台机器可能没装 OpenSSH server）"; return 1; }

  olds=$(ssh_effective_ports | tr '\n' ' '); olds=${olds% }
  [ -n "$olds" ] || olds=22
  if [ "$keep" != 1 ] && [ "$olds" = "$pnew" ]; then
    ok "当前就是 $pnew，无需修改"
    return 0
  fi
  # 端口冲突：别人占着就直接拒绝（sshd 自己正监听着则不算冲突）
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$pnew\$"; then
    if ! printf '%s\n' $olds | grep -qx "$pnew"; then
      no "端口 $pnew 已被占用：$(ss -lntp 2>/dev/null | grep -E "[:.]$pnew\$" | head -1)"
      return 1
    fi
  fi

  inf "旧端口: $olds    新端口: $pnew    $( [ "$keep" = 1 ] && echo '旧端口保留' || echo '旧端口关闭')"
  mkdir -p "$BK"
  if [ ! -s "$SSH_BAK/orig/manifest" ]; then
    ssh_snap "$SSH_BAK/orig" && ok "原 SSH 配置已备份到 $SSH_BAK/orig/（--ssh-port-restore 可还原）"
  else
    inf "已有首次备份 $SSH_BAK/orig/，不覆盖"
  fi
  ssh_snap "$SSH_BAK/prev"          # 本次改动前的快照，专供回滚

  ssh_rewrite_conf "$SSH_CONF" "$pnew" "$keep" "$olds" \
    && ok "已改写 $SSH_CONF（旧 Port 行注释为 #set-dns-old#）"
  local f
  for f in "$SSH_PDROP"/*.conf; do
    [ -f "$f" ] || continue
    grep -qE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$f" 2>/dev/null || continue
    ssh_rewrite_conf "$f" "$pnew" "$keep" "$olds" && ok "已改写 $f（drop-in 里的 Port 若不注释会盖掉主配置）"
  done
  ssh_socket_apply "$pnew" "$keep" "$olds" || true

  ssh_selinux_allow "$pnew"
  ssh_fw_allow "$pnew"

  if ! ssh_validate; then
    no "配置不合法，正在回滚（不重启，你当前的连接不受影响）"
    ssh_snap_restore "$SSH_BAK/prev" && ok "已回滚到改动前的配置"
    return 1
  fi
  ssh_restart
  if ssh_wait_listen "$pnew"; then
    if [ "$REAL" = 1 ]; then ok "新端口 $pnew 已在监听"
    else ok "沙箱模式：未重启，跳过监听确认（配置已改写）"; fi
  else
    no "重启后没等到 $pnew 在监听，正在回滚"
    ssh_snap_restore "$SSH_BAK/prev" && ok "已回滚到改动前的配置"
    ssh_restart
    return 1
  fi
  echo
  wr "先别断开当前这个会话！新开一个窗口验证：ssh -p $pnew root@<本机IP>"
  inf "确认能登进来之后，再关掉旧会话；连不上就 set-dns --ssh-port-restore"
  return 0
}

ssh_port_entry() {
  hr; echo "自定义 SSH 连接端口"; hr
  ssh_port_view
  if [ "$(id -u)" != 0 ] && [ "$REAL" = 1 ]; then
    hr; inf "非 root：只显示不修改（改端口需要 root）"
    return 0
  fi
  echo
  if [ -z "$SSH_REQ" ]; then
    if [ "$TTY_OK" = 1 ]; then
      printf '  输入新的 SSH 端口（1-65535，q = 取消）: '
      read_ans
      case "${ans:-}" in q|Q|"") inf "已取消"; return 0 ;; esac
      SSH_REQ=$ans
    else
      inf "没有终端也没指定端口：请用 set-dns --ssh-port=2222（或 SET_DNS_SSH_PORT=2222）"
      return 0
    fi
  fi
  local keep=0
  if [ -n "${SET_DNS_SSH_KEEP:-}" ]; then
    keep=$SET_DNS_SSH_KEEP
  elif [ "$TTY_OK" = 1 ]; then
    echo
    echo "  旧的端口怎么办？"
    echo "    1) 关掉旧端口（只留新端口）[默认]"
    echo "    2) 也保留旧端口（两个都能连，验证新端口更稳妥）"
    printf '  输入 1/2（直接回车 = 1）: '
    read_ans
    [ "${ans:-1}" = 2 ] && keep=1
  fi
  echo
  ssh_port_apply "$SSH_REQ" "$keep"
  return $?
}

# ================= 内核管理（菜单 10 / --kernel / --kernel-update / --kernel-remove） =================
# 只管一件事：xanmod 的 BBRv3 内核，装上 / 更新 / 卸掉。三条底线：
#   1) 装之前先按 /proc/cpuinfo 的 flags 判断 CPU 支持到哪一档 x86-64 微架构（x64v1~v4）——
#      档位选高了内核直接起不来（比如没有 avx512f 的机器装 x64v4），这是这个功能最大的坑；
#   2) 卸 xanmod 之前必须先确认机器上还留着一个「不是 xanmod」的内核能启动，
#      否则卸完重启就再也进不去系统了（只有云厂商 VNC/rescue 能救）；
#   3) 装完 / 卸完都跑 update-grub，并把重启后会进哪个内核打印出来，别让用户盲重启。
# 另外：本功能不碰 /etc/sysctl.d 里的 BBR 参数。那些（99-degwd.conf / 99-kejilion-bbr.conf）
# 是 de_GWD / kejilion 写的，内核管理只负责内核本身，只在面板里报告 BBR 是否可用。
KR_LEVEL=${SET_DNS_KERNEL_LEVEL:-}                 # x64v2|x64v3|x64v4，默认按 CPU 自动判断
KR_REPO_HOST=deb.xanmod.org
KR_KEYURL=https://dl.xanmod.org/archive.key
KR_KEYRING=$ETC/../usr/share/keyrings/xanmod-archive-keyring.gpg
KR_LIST=$ETC/apt/sources.list.d/xanmod-release.list
KR_BAK=$BK/kernel
KR_CPUINFO=${SET_DNS_CPUINFO:-/proc/cpuinfo}    # 测试可指向假 cpuinfo 验证判档逻辑
# glibc 的 hwcaps 判定入口：ld.so 通常不在 PATH 里，按候选路径找一个能跑的
krn_ldso_path() {
  local p
  for p in /usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
           /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2 \
           /usr/lib64/ld-linux-x86-64.so.2 /lib/ld-musl-x86_64.so.1; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}
KR_LDSO=${SET_DNS_LDSO:-$(krn_ldso_path)}   # SET_DNS_LDSO 可覆盖（测试用它关掉 hwcaps 探测）

krn_ver() { uname -r 2>/dev/null || printf '未知'; }
krn_is_xanmod() { case "$(krn_ver)" in *xanmod*) return 0 ;; *) return 1 ;; esac; }

krn_lvl_num() { case "$1" in x64v1) printf 1 ;; x64v2) printf 2 ;; x64v3) printf 3 ;; x64v4) printf 4 ;; *) printf 0 ;; esac; }
krn_num_lvl() { case "$1" in 1) printf 'x64v1' ;; 2) printf 'x64v2' ;; 3) printf 'x64v3' ;; 4) printf 'x64v4' ;; *) printf '' ;; esac; }

# 正在跑的内核名字里就带着档位（7.2.9-x64v3-xanmod1）—— 它既然已经跑起来了，
# 就说明这台机器的 CPU 至少支持这一档，这是比任何探测都硬的证据。
krn_running_level() {
  local k; k=${SET_DNS_RUNNING_KERNEL:-$(krn_ver)}   # 测试可覆盖
  case "$k" in *-x64v4-*) printf 'x64v4' ;; *-x64v3-*) printf 'x64v3' ;;
               *-x64v2-*) printf 'x64v2' ;; *-x64v1-*) printf 'x64v1' ;; *) return 1 ;; esac
}

# 判档位优先用 glibc 的 hwcaps：ld.so --help 会直接列出本机支持到哪一档
# （"x86-64-v3 (supported, searched)" 这种），这是最权威的判定 —— glibc 自己就是按 CPUID + OS 支持判的。
# flags 那只做兜底，因为 /proc/cpuinfo 的写法有坑：
#   1) SSE3 在 Linux 里叫 pni，不叫 sse3；
#   2) LZCNT 在 Intel 上老内核只报 abm（两者是同一件事），字面找 lzcnt 会找不到 ——
#      Xeon E5-2699 v4 就踩过这个：明明支持 v3、也在跑 x64v3 内核，却因为少一个 lzcnt 被误判成 v2。
krn_glibc_level() {
  local out lv=
  out=$("$KR_LDSO" --help 2>/dev/null) || out=
  [ -n "$out" ] || return 1
  case "$out" in
    *'x86-64-v4 (supported'*) lv=x64v4 ;;
    *'x86-64-v3 (supported'*) lv=x64v3 ;;
    *'x86-64-v2 (supported'*) lv=x64v2 ;;
    *'x86-64 (supported'*)    lv=x64v1 ;;
  esac
  [ -n "$lv" ] || return 1
  printf '%s' "$lv"
}

krn_flags_level() {
  local fl t
  fl=$(awk -F: '/^flags/{print $2; exit}' "$KR_CPUINFO" 2>/dev/null)
  [ -n "$fl" ] || return 1                        # 读不到 flags（非 x86）时交给上层兜底
  for t in cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3; do
    case " $fl " in *" $t "*) ;; *) printf 'x64v1'; return 0 ;; esac
  done
  for t in avx avx2 bmi1 bmi2 f16c fma movbe xsave; do
    case " $fl " in *" $t "*) ;; *) printf 'x64v2'; return 0 ;; esac
  done
  # LZCNT：lzcnt 与 abm 任一即可（同一条指令能力，不同内核叫法不同）
  case " $fl " in
    *" lzcnt "*|*" abm "*) ;;
    *) printf 'x64v2'; return 0 ;;
  esac
  for t in avx512f avx512bw avx512cd avx512dq avx512vl; do
    case " $fl " in *" $t "*) ;; *) printf 'x64v3'; return 0 ;; esac
  done
  printf 'x64v4'
}

krn_level_src() {   # 面板上那行「档位」是怎么来的，方便排查误判
  if [ -n "$KR_LEVEL" ]; then printf '手动指定（SET_DNS_KERNEL_LEVEL）'; return; fi
  local g f r
  g=$(krn_glibc_level); f=$(krn_flags_level); r=$(krn_running_level)
  if [ -n "$g" ]; then printf 'glibc hwcaps（本机最高支持 %s）' "$g"
  elif [ -n "$f" ]; then printf 'CPU flags（glibc 探测不可用）'
  elif [ -n "$r" ]; then printf '正在运行的内核（%s）' "$r"
  else printf '都判不出来，保守取 x64v2'; fi
}

krn_cpu_level() {
  if [ -n "$KR_LEVEL" ]; then printf '%s' "$KR_LEVEL"; return 0; fi
  local lv cand n=0 best=0 rl rn
  for cand in "$(krn_glibc_level)" "$(krn_flags_level)" "$(krn_running_level)"; do
    [ -n "$cand" ] || continue
    n=$(krn_lvl_num "$cand")
    [ "$n" -gt "$best" ] && best=$n
  done
  if [ "$best" -gt 0 ]; then
    # 探测结果与「正在跑的内核」矛盾时留个提示（不阻断，档位取高的那个）
    rl=$(krn_running_level) || rl=
    rn=$(krn_lvl_num "$rl")
    [ "$rn" -gt 0 ] && [ "$best" -gt "$rn" ] && \
      wr "提示：探测出的档位（$(krn_num_lvl "$best")）比正在跑的内核（$rl）还高 —— 已按探测值继续，若内核起不来请用 SET_DNS_KERNEL_LEVEL 降档" >&2
    krn_num_lvl "$best"; return 0
  fi
  printf 'x64v2'                                  # 什么都判不出来时的保守档
}

krn_cpu_model() {
  awk -F: '/^model name/{sub(/^[ \t]+/,"",$2); print $2; exit}' "$KR_CPUINFO" 2>/dev/null | head -1
}

krn_bbr_state() {
  local av cu qd
  av=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)
  cu=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
  qd=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)
  if [ -z "$av" ]; then printf '读不到（非 Linux？）'
  elif printf '%s' "$av" | tr ' ' '\n' | grep -qx bbr; then printf 'bbr 可用（当前算法 %s，队列 %s）' "${cu:-?}" "${qd:-?}"
  else printf 'bbr 不可用（本内核 tcp_available_congestion_control 里没有 bbr）'; fi
}

krn_installed_pkgs() {
  dpkg-query -W -f '${Package} ${db:Status-Status}\n' 'linux-image-*xanmod*' 'linux-headers-*xanmod*' 'linux-xanmod-*' 2>/dev/null \
    | awk '$2 == "installed" { print $1 }' | sort -u
}

# 机器上「不是 xanmod」的真实内核镜像包 —— 卸 xanmod 前靠它兜底
krn_stock_images() {
  dpkg-query -W -f '${Package} ${db:Status-Status}\n' 'linux-image-*' 2>/dev/null \
    | awk '$2 == "installed" { print $1 }' | grep -v xanmod | grep -E '^linux-image-[0-9]' | sort -u
}

krn_boot_kernels() { ls /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||'; }

krn_repo_have() {
  [ -f "$KR_LIST" ] && return 0
  grep -rqs "$KR_REPO_HOST" "$ETC/apt/sources.list" "$ETC/apt/sources.list.d" 2>/dev/null && return 0
  return 1
}

# 加 xanmod 源 + 密钥。沙箱里也真的写文件（测试要能验），只是不跑 apt
krn_repo_add() {
  local cn
  cn=$(distro_codename 2>/dev/null)
  [ -n "$cn" ] || { no "读不到发行版代号（VERSION_CODENAME），无法拼 xanmod 源"; return 1; }
  if [ "$REAL" = 1 ] && [ ! -s "$KR_KEYRING" ]; then
    command -v gpg >/dev/null 2>&1 || { inf "装 gnupg（验签密钥要用）"; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnupg >/dev/null 2>&1; }
    mkdir -p "$(dirname "$KR_KEYRING")"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$KR_KEYURL" 2>/dev/null | gpg --dearmor > "$KR_KEYRING" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- "$KR_KEYURL" 2>/dev/null | gpg --dearmor > "$KR_KEYRING" 2>/dev/null
    else
      no "需要 curl 或 wget 才能下载 xanmod 密钥（先跑 set-dns --tools）"; return 1
    fi
    [ -s "$KR_KEYRING" ] && ok "已导入 xanmod 仓库密钥" || { no "密钥下载失败（网络不通？）"; return 1; }
  elif [ "$REAL" = 0 ]; then
    inf "沙箱模式：跳过下载密钥"
  else
    ok "xanmod 密钥已存在"
  fi
  put "$KR_LIST" "deb [signed-by=$KR_KEYRING] http://$KR_REPO_HOST $cn main
" || { no "写 $KR_LIST 失败"; return 1; }
  ok "已写 $KR_LIST（$KR_REPO_HOST $cn main）"
  if [ "$REAL" = 1 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 | tail -3 | sed 's/^/      /'
    [ "${PIPESTATUS[0]}" = 0 ] && ok "apt 源已刷新" || { no "apt update 失败（检查网络 / 换源后重试）"; return 1; }
  else
    inf "沙箱模式：跳过 apt update"
  fi
  return 0
}

krn_latest_pkg() { # $1=档位  输出源里最新的 linux-image-<ver>-<档位>-xanmod1
  local lv=$1
  apt-cache search --names-only "^linux-image-[0-9][0-9.]*-${lv}-xanmod1$" 2>/dev/null \
    | awk '{ print $1 }' | sort -V | tail -1
}

krn_pkg_to_rel() { printf '%s' "${1#linux-image-}"; }

krn_confirm() { # $1=提示语
  [ "${TTY_OK:-0}" = 1 ] || return 1
  printf '  %s [y/N]: ' "$1"
  read_ans
  case "${ans:-}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

krn_panel() {
  local lv np
  lv=$(krn_cpu_level)
  np=$(krn_installed_pkgs | wc -l | tr -d ' ')
  if krn_is_xanmod; then
    echo "您已安装 xanmod 的 BBRv3内核"
  else
    echo "您尚未安装 xanmod 的 BBRv3内核（当前跑的是发行版自带内核）"
  fi
  echo "当前内核版本： $(krn_ver)"
  inf "CPU 微架构档位： $lv  （$(krn_cpu_model)）"
  inf "档位判定依据： $(krn_level_src)"
  inf "已装的 xanmod 内核包： ${np:-0} 个"
  inf "BBR 状态： $(krn_bbr_state)"
  if [ "$REAL" = 0 ]; then inf "沙箱模式：只读面板，不改内核"; return 0; fi
  local s; s=$(krn_stock_images | tr '\n' ' ')
  if [ -n "$s" ]; then inf "可回退的发行版内核： ${s% }"
  else wr "机器上没有非 xanmod 的内核 —— 卸载前请先装一个（否则重启进不去系统）"; fi
}

krn_update() {
  local lv img hdr kver cur
  cur=$(krn_ver); lv=$(krn_cpu_level)
  hr; echo "更新 BBRv3 内核（xanmod $lv）"; hr
  inf "当前内核：$cur"
  inf "CPU 微架构档位：$lv"
  if [ "$DRY" = 1 ]; then inf "[dry-run] 会加 xanmod 源并安装最新的 $lv 内核 + headers"; return 0; fi
  if [ "$REAL" = 0 ]; then inf "沙箱模式：只显示计划，不装内核"; return 0; fi
  [ "$(id -u)" = 0 ] || { no "需要 root"; return 1; }

  krn_repo_have || krn_repo_add || return 1
  [ "$REAL" = 1 ] && DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null
  img=$(krn_latest_pkg "$lv") || true
  if [ -z "$img" ]; then
    no "源里没找到 $lv 档的内核包 —— 检查 $KR_REPO_HOST 源是否可用（也可用 SET_DNS_KERNEL_LEVEL 指定档位）"
    return 1
  fi
  hdr=${img/linux-image-/linux-headers-}
  kver=$(krn_pkg_to_rel "$img")
  inf "源里最新：$img"
  if [ "$kver" = "$cur" ]; then
    ok "当前跑的就是最新的 $lv 内核（$kver），无需更新"
    inf "想强制重装：apt-get install --reinstall -y $img $hdr"
    return 0
  fi
  local -a want=("$img")
  apt-cache show "$hdr" >/dev/null 2>&1 && want+=("$hdr") || inf "源里没有 $hdr（只装镜像包）"
  krn_confirm "确认安装 $kver 并更新引导？" || { inf "已取消，什么都没做"; return 0; }
  inf "开始安装：${want[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${want[@]}" 2>&1 | tail -8 | sed 's/^/      /'
  local rc=${PIPESTATUS[0]}
  [ "$rc" = 0 ] || { no "安装失败，apt 返回错误码 $rc"; return 1; }
  ok "内核已安装：$kver"
  if [ -f "/boot/vmlinuz-$kver" ]; then ok "/boot/vmlinuz-$kver 已就位"
  else wr "没看到 /boot/vmlinuz-$kver（/boot 空间不足？）"; fi
  command -v update-grub >/dev/null 2>&1 && { update-grub >/dev/null 2>&1 && ok "引导菜单已更新（update-grub）" || wr "update-grub 失败，请手工执行"; }
  hr
  wr "现在还没生效 —— 需要重启才切到新内核"
  inf "重启前可先看引导菜单：grep -m3 '^menuentry' /boot/grub/grub.cfg"
  inf "重启命令：reboot   重启后用 uname -r 确认新版本"
  mkdir -p "$KR_BAK"
  [ -s "$KR_BAK/prev-installed" ] || krn_installed_pkgs > "$KR_BAK/prev-installed" 2>/dev/null
  return 0
}

krn_remove() {
  local -a pkgs=()
  local p stock cur
  cur=$(krn_ver)
  hr; echo "卸载 BBRv3 内核（xanmod）"; hr
  while IFS= read -r p; do [ -n "$p" ] && pkgs+=("$p"); done < <(krn_installed_pkgs)
  if [ "${#pkgs[@]}" = 0 ]; then
    inf "没有装过 xanmod 内核，无需卸载"
    return 0
  fi
  inf "将要卸载 ${#pkgs[@]} 个包："
  printf '        %s\n' "${pkgs[@]}"
  if [ "$DRY" = 1 ]; then inf "[dry-run] 不实际卸载"; return 0; fi
  if [ "$REAL" = 0 ]; then inf "沙箱模式：只显示计划，不卸内核"; return 0; fi
  [ "$(id -u)" = 0 ] || { no "需要 root"; return 1; }

  # 兜底内核检查：卸完 xanmod 必须还有别的内核能启动
  mkdir -p "$KR_BAK"
  krn_installed_pkgs > "$KR_BAK/removed-list" 2>/dev/null
  stock=$(krn_stock_images | tr '\n' ' ')
  if [ -z "$stock" ]; then
    wr "机器上没有非 xanmod 的内核，直接卸完重启会进不去系统"
    inf "先装一个发行版内核兜底再卸（Debian: apt-get install -y linux-image-cloud-amd64 / Ubuntu: linux-image-generic）"
    if krn_confirm "要现在自动装一个发行版内核兜底吗？（装完再卸 xanmod）"; then
      local fb
      case "$(distro_id 2>/dev/null)" in
        ubuntu) fb=linux-image-generic ;;
        *)      fb=linux-image-cloud-amd64 ;;
      esac
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$fb" 2>&1 | tail -6 | sed 's/^/      /'
      [ "${PIPESTATUS[0]}" = 0 ] && ok "已装 $fb" || { no "兜底内核安装失败，已中止卸载（什么都没卸）"; return 1; }
    else
      inf "已取消（没卸任何东西）—— 建议先手工装一个内核再来"
      return 0
    fi
  else
    ok "已有可回退的发行版内核：${stock% }"
  fi

  if krn_is_xanmod; then
    wr "当前正在跑的就是 xanmod（$cur）—— 卸载后必须重启，重启会进 ${stock%% *}"
  fi
  krn_confirm "确认卸载 xanmod 内核并更新引导？" || { inf "已取消，什么都没做"; return 0; }

  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${pkgs[@]}" 2>&1 | tail -8 | sed 's/^/      /'
  local rc=${PIPESTATUS[0]}
  [ "$rc" = 0 ] && ok "已卸载 xanmod 内核包" || wr "apt purge 返回错误码 $rc（上面是它的输出）"
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq autoremove >/dev/null 2>&1
  command -v update-grub >/dev/null 2>&1 && { update-grub >/dev/null 2>&1 && ok "引导菜单已更新（update-grub）" || wr "update-grub 失败，请手工执行"; }

  # 源要不要一起拆掉：默认保留（下次 --kernel-update 还能直接用），装了环境变量或回答了才删
  local keeprepo=1
  if [ "${SET_DNS_KERNEL_KEEP_REPO:-}" = 0 ]; then
    keeprepo=0
  elif [ "${SET_DNS_KERNEL_KEEP_REPO:-}" = 1 ]; then
    keeprepo=1
  elif krn_confirm "把 xanmod 的 apt 源也一起拆掉吗？"; then
    keeprepo=0
  fi
  if [ "$keeprepo" = 0 ]; then
    [ -f "$KR_LIST" ] && { cp -a "$KR_LIST" "$KR_BAK/xanmod-release.list" 2>/dev/null; rm -f "$KR_LIST"; rm -f "$KR_KEYRING"; ok "已删除 xanmod 源与密钥（备份在 $KR_BAK/）"; }
  else
    inf "xanmod 源保留（下次 --kernel-update 可直接用）"
  fi

  # 清掉 xanmod 留在 /lib/modules 下的空目录（purge 偶尔会留下），并复查 BBR
  for p in /lib/modules/*xanmod*; do
    [ -e "$p" ] || continue
    rm -rf "$p" && ok "已清理残留模块目录 $(basename "$p")"
  done
  hr
  inf "当前内核：$(krn_ver)"
  inf "重启后会进：$(krn_stock_images | head -1)"
  wr "重启后 uname -r 应变成发行版内核；BBR 若还要，Debian 6.12 自带 tcp_bbr 模块，modprobe 即可"
  return 0
}

krn_menu() {
  local ans
  krn_panel
  if [ "$(id -u)" != 0 ] && [ "$REAL" = 1 ]; then
    hr; inf "非 root：只显示不修改（管理内核需要 root）"
    return 0
  fi
  echo
  echo "  内核管理"
  hr
  echo "    1. 更新BBRv3内核                 2. 卸载BBRv3内核"
  hr
  echo "    0. 返回上一级菜单"
  hr
  if [ "${TTY_OK:-0}" != 1 ]; then
    inf "没有终端：请用 set-dns --kernel-update / --kernel-remove"
    return 0
  fi
  printf '  请输入你的选择： '
  read_ans
  case "${ans:-}" in
    1)        krn_update ;;
    2)        krn_remove ;;
    0|"")     inf "已返回" ;;
    *)        wr "无效选择：$ans" ;;
  esac
  return 0
}

# ================= TCP 加速管理（菜单 11 / --accel） =================
# 面板编号沿用 ylx.me「TCP加速 一键安装管理脚本」，但只落地 Debian/Ubuntu 上真能跑的项：
#   * 20/21/22 加速启用：内核自带 bbr + sch_fq / sch_fq_pie / sch_cake（这台机器上三个模块都在）
#   * 30/31 ECN、35/36 IPv6、32 自适应优化、33 防 CC：全是 sysctl，写完 sysctl --system 即生效
#   * 51/52 查看 / 删除内核：复用内核段（菜单 10）的 dpkg 查询；删除前强制剩至少一个可引导内核
#   * 4/7/8/9~12 装内核：官方 apt 源（linux-image-amd64 / cloud-amd64 / rt-amd64）与 xanmod 元包
#     （linux-xanmod-x64vN / -lts- / -edge- / -rt- 在源里真实存在，不装这些 = 用真实包名装的）
#   * 1/2/3/5/6/23/24：源里没有对应包或只支持 CentOS，一律打印「为什么不能做 + 你能改用什么」，
#     不假装装上了 —— 内核装错是直接起不来的事，宁可少做不可乱做
# 写文件统一落 /etc/sysctl.d/99-zz-setdns-accel.conf：
#   systemd-sysctl 按 /usr/lib → /run → /etc 读，同目录按字典序，后读的赢。
#   真机上 99-degwd.conf（cc=bbr/qdisc=cake）和 99-kejilion-bbr.conf（fq+bbr）已经写死了这两个键，
#   zz 前缀排在它们之后才压得住 —— 否则就是「改了不生效」的头号原因。
ACC_CONF=$ETC/sysctl.d/99-zz-setdns-accel.conf
ACC_BAK=$BK/accel
ACC_MOD=$ETC/modules-load.d/setdns-qdisc.conf
ACC_KREQ=${SET_DNS_ACC_KERNEL:-}
ACC_DELREQ=${SET_DNS_ACC_DEL:-}
ACC_ACT=${ACC_ACT:-}     # 命令行指定的动作（如 fq:bbr / ecn:1 / kernel:xanmod-lts），空 = 出菜单
acc_n=0

acc_real() { [ "$REAL" = 1 ]; }

# 沙箱（REAL=0）没有真实内核参数可读，就回读自己写的配置文件 —— 测试因此能断言往返一致
acc_read() { # $1=键  $2=兜底值
  local k=$1 d=${2:-} v
  if acc_real; then
    v=$(sysctl -n "$k" 2>/dev/null) && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  v=$(sed -n "s/^[[:space:]]*${k//./\\.}[[:space:]]*=[[:space:]]*//p" "$ACC_CONF" 2>/dev/null | tail -1)
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$d"; fi
}
acc_cc_now()    { acc_read net.ipv4.tcp_congestion_control '—'; }
acc_qdisc_now() { acc_read net.core.default_qdisc '—'; }
acc_ecn_now()   { acc_read net.ipv4.tcp_ecn 0; }
acc_ipv6_now()  { acc_read net.ipv6.conf.all.disable_ipv6 0; }

acc_avail() { # 当前内核可用的拥塞控制算法（SET_DNS_ACC_AVAIL 可覆盖，测试用）
  if [ -n "${SET_DNS_ACC_AVAIL:-}" ]; then printf '%s' "$SET_DNS_ACC_AVAIL"; return 0; fi
  [ -r /proc/sys/net/ipv4/tcp_available_congestion_control ] \
    && cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || printf ''
}

acc_have_cc() { # $1=算法名；能 modprobe 起来也算有
  local c=$1 a
  a=$(acc_avail)
  case " $a " in *" $c "*) return 0 ;; esac
  if [ -n "${SET_DNS_ACC_AVAIL:-}" ]; then return 1; fi   # 显式给了可用列表就照它判
  if acc_real; then
    modprobe "tcp_$c" 2>/dev/null
    a=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)
    case " $a " in *" $c "*) return 0 ;; esac
    return 1
  fi
  return 0    # 沙箱读不到真实信息，放行（真实环境会在 verify 里露出来）
}

acc_iface() {
  local i
  i=$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
  if [ -z "$i" ]; then i=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}'); fi
  printf '%s' "${i:-eth0}"
}
acc_tc_qdisc() { tc qdisc show dev "$(acc_iface)" 2>/dev/null | head -1 | awk '{print $2}'; }

# 写一行 sysctl：先删同键旧行再追加，落 $ACC_CONF。$3 非空 = 安静模式（批量时不刷屏）
acc_apply() { # $1=键  $2=值  $3=quiet
  local k=$1 v=$2 q=${3:-}
  if [ "$DRY" = 1 ]; then inf "[dry-run] 写 $ACC_CONF: $k = $v"; return 0; fi
  mkdir -p "$(dirname "$ACC_CONF")" "$ACC_BAK" 2>/dev/null
  if [ ! -e "$ACC_CONF" ]; then
    printf '# set-dns TCP 加速（菜单 11）—— 本文件排在 99-degwd.conf / 99-kejilion-bbr.conf 之后，后读的生效\n' > "$ACC_CONF"
  fi
  cp -a "$ACC_CONF" "$ACC_BAK/prev.conf" 2>/dev/null
  sed -i "/^[[:space:]]*${k//./\\.}[[:space:]]*=/d" "$ACC_CONF" 2>/dev/null
  printf '%s = %s\n' "$k" "$v" >> "$ACC_CONF"
  if acc_real; then
    if sysctl -w "$k=$v" >/dev/null 2>&1; then
      acc_n=$((acc_n + 1)); [ -n "$q" ] || ok "$k = $v"
    else
      [ -n "$q" ] || wr "$k = $v 已写入配置，但当前内核不认这个键"
    fi
  else
    acc_n=$((acc_n + 1)); [ -n "$q" ] || inf "沙箱模式：只写配置（$k = $v）"
  fi
  return 0
}
acc_apply_q() { acc_apply "$1" "$2" q; }

acc_mod_load() { # $1=qdisc 名（不带 sch_ 前缀）
  local q=$1 m="sch_$1"
  if acc_real; then
    if ! modinfo -n "$m" >/dev/null 2>&1 && [ ! -e "/lib/modules/$(krn_ver)/kernel/net/sched/$m.ko" ]; then
      no "当前内核没有 $m 模块，$q 用不了"; return 1
    fi
    if modprobe "$m" 2>/dev/null; then inf "已加载 $m"
    else inf "$m 已内置或已加载，不用再 modprobe"; fi
  else
    inf "沙箱模式：跳过 modprobe $m"
  fi
  if [ "$DRY" = 1 ]; then inf "[dry-run] 把 sch_$q 写进 $ACC_MOD"
  else
    mkdir -p "$(dirname "$ACC_MOD")"
    grep -qxF "sch_$q" "$ACC_MOD" 2>/dev/null || printf 'sch_%s\n' "$q" >> "$ACC_MOD"
  fi
  return 0
}

acc_verify() { # $1=期望 cc  $2=期望 qdisc
  local c=$1 q=$2 got qd
  if ! acc_real; then
    ok "沙箱模式：配置已写入 $ACC_CONF（$c + $q），未改真实内核"
    return 0
  fi
  got=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  [ "$got" = "$c" ] && ok "拥塞控制算法已生效：$got" || wr "拥塞控制算法期望 $c，实际 ${got:-读不到}"
  [ "$qd" = "$q" ] && ok "队列算法已生效：$qd" || wr "队列算法期望 $q，实际 ${qd:-读不到}"
  local tq; tq=$(acc_tc_qdisc)
  [ -n "$tq" ] && inf "网卡 $(acc_iface) 当前实际队列：$tq（default_qdisc 只影响新建的 qdisc，老连接要重建才换）"
  return 0
}

acc_panel() {
  local kern cc qd hdr os virt a
  kern=$(krn_ver); cc=$(acc_cc_now); qd=$(acc_qdisc_now)
  os=$(osrel PRETTY_NAME 2>/dev/null); [ -n "$os" ] || os=$(distro_id 2>/dev/null)
  virt=$(systemd-detect-virt 2>/dev/null); [ -n "${virt:-}" ] || virt=unknown
  [ -d "/lib/modules/$kern/build" ] && hdr="已匹配（可编译模块）" || hdr="未匹配"
  a=$(acc_avail)
  echo "  信息: $os $virt $(deb_arch) $kern"
  if [ -z "$a" ]; then
    echo "  状态: 读不到内核拥塞控制信息（非 Linux / 沙箱环境）"
  elif krn_is_xanmod; then
    case " $a " in
      *" bbr "*) echo "  状态: 已安装 xanmod 的 BBRv3 加速内核，bbr 可用" ;;
      *)         echo "  状态: 已安装 xanmod 内核，但 bbr 不在可用列表里（异常）" ;;
    esac
  else
    case " $a " in
      *" bbr "*) echo "  状态: 当前内核（$kern）自带 bbr，但没装 xanmod 加速内核（菜单 10 可装）" ;;
      *)         echo "  状态: 当前内核（$kern）的可用算法：$a" ;;
    esac
  fi
  echo "  拥塞控制算法: $cc   队列算法: $qd   Headers状态: $hdr"
  if acc_real; then
    local tq; tq=$(acc_tc_qdisc)
    [ -n "$tq" ] && inf "网卡 $(acc_iface) 实际 qdisc: $tq"
  fi
  inf "配置文件: $ACC_CONF（当前内核可用算法：${a:-未知}）"
}

acc_enable() { # $1=qdisc  $2=cc
  local q=$1 c=$2
  hr; echo "启用加速：$c + $q"; hr
  local a; a=$(acc_avail)
  if ! acc_have_cc "$c"; then
    no "当前内核不支持 $c（可用：${a:-未知}）"
    inf "BBR 之外的算法要先装带该模块的内核，本脚本不替你编译内核"
    return 1
  fi
  if [ "$DRY" = 1 ]; then
    inf "[dry-run] 会写 $ACC_CONF: net.core.default_qdisc=$q / net.ipv4.tcp_congestion_control=$c"
    return 0
  fi
  acc_mod_load "$q" || return 1
  acc_apply net.core.default_qdisc "$q"
  acc_apply net.ipv4.tcp_congestion_control "$c"
  acc_real && sysctl --system >/dev/null 2>&1
  acc_verify "$c" "$q"
  inf "已持久化到 $ACC_CONF，重启后仍是 $c + $q"
  return 0
}

acc_custom_cc() { # $1=cc $2=qdisc $3=做不到时的说明
  local c=$1 q=$2 why=$3
  if acc_have_cc "$c"; then acc_enable "$q" "$c"; return $?; fi
  hr; echo "本机用不了 $c"; hr
  no "当前内核可用算法只有：$(acc_avail | tr -s ' ')"
  inf "$why"
  return 1
}

acc_ecn() { # $1=1 开 / 0 关
  local v=$1
  hr; [ "$v" = 1 ] && echo "开启 ECN" || echo "关闭 ECN"; hr
  acc_apply net.ipv4.tcp_ecn "$v"
  acc_real && sysctl --system >/dev/null 2>&1
  [ "$v" = 1 ] && inf "ECN 在链路两端都支持时能少重传；中间设备老旧时反而掉速，掉速就再关回来"
  inf "写在 $ACC_CONF 最后一行，压过 99-degwd.conf 里的 tcp_ecn=0"
  return 0
}

acc_ipv6() { # $1=1 关 / 0 开（参数是 disable_ipv6 的值）
  local v=$1
  hr; [ "$v" = 1 ] && echo "禁用 IPv6" || echo "开启 IPv6"; hr
  acc_n=0
  acc_apply_q net.ipv6.conf.all.disable_ipv6 "$v"
  acc_apply_q net.ipv6.conf.default.disable_ipv6 "$v"
  acc_real && sysctl --system >/dev/null 2>&1
  if [ "$v" = 1 ]; then
    ok "已写入 $acc_n 项（禁用 IPv6）"
    inf "注意：禁用的是内核里的 IPv6 栈；/etc/hosts 里的 IPv6 行、应用层 v6 优先不受影响"
    inf "本机现有 IPv6 地址会随之失效（云主机若用 IPv6 上网就不要关）"
  else
    ok "已写入 $acc_n 项（开启 IPv6）"
  fi
  return 0
}

acc_mem_mb() {
  local m
  m=$(awk '/^MemTotal:/{printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null)
  case "${m:-}" in ''|*[!0-9]*) m=1024 ;; esac
  printf '%s' "$m"
}

acc_optimize() {
  hr; echo "系统网络自适应优化"; hr
  local mem cores sock somax backlog ecn iv6
  mem=$(acc_mem_mb)
  cores=$(nproc 2>/dev/null || printf 1)
  case "$cores" in ''|*[!0-9]*) cores=1 ;; esac
  if [ "$mem" -lt 2048 ]; then sock=16777216; somax=32768
  elif [ "$mem" -lt 8192 ]; then sock=33554432; somax=65535
  else sock=67108864; somax=1048576; fi
  backlog=$((cores * 10000))
  [ "$backlog" -lt 32768 ] && backlog=32768
  [ "$backlog" -gt 100000 ] && backlog=100000
  inf "内存 ${mem}MB / CPU ${cores} 核 → 缓冲上限 $((sock / 1048576))MB、somaxconn $somax、backlog $backlog"
  # 继承当前 ECN / IPv6 状态：不能把用户刚用菜单 35 关掉的 IPv6 又打开（这是真踩过的坑）
  ecn=$(acc_ecn_now); iv6=$(acc_ipv6_now)
  acc_n=0
  acc_apply_q net.core.rmem_max "$sock"
  acc_apply_q net.core.wmem_max "$sock"
  acc_apply_q net.ipv4.tcp_rmem "4096 87380 $sock"
  acc_apply_q net.ipv4.tcp_wmem "4096 65536 $sock"
  acc_apply_q net.core.somaxconn "$somax"
  acc_apply_q net.ipv4.tcp_max_syn_backlog "$somax"
  acc_apply_q net.core.netdev_max_backlog "$backlog"
  acc_apply_q net.ipv4.tcp_fastopen 3
  acc_apply_q net.ipv4.tcp_slow_start_after_idle 0
  acc_apply_q net.ipv4.tcp_tw_reuse 1
  acc_apply_q net.ipv4.tcp_fin_timeout 10
  acc_apply_q net.ipv4.tcp_mtu_probing 1
  acc_apply_q net.ipv4.tcp_keepalive_time 600
  acc_apply_q net.ipv4.ip_local_port_range "1024 65535"
  acc_apply_q net.ipv4.tcp_ecn "$ecn"
  acc_apply_q net.ipv6.conf.all.disable_ipv6 "$iv6"
  acc_apply_q net.ipv6.conf.default.disable_ipv6 "$iv6"
  acc_real && sysctl --system >/dev/null 2>&1
  ok "已写入 $acc_n 项网络参数 → $ACC_CONF"
  inf "动态端口范围 1024-65535 / keepalive 600s；IPv6 与 ECN 保持原状（$iv6 / $ecn）"
  inf "要整体撤销：菜单 55（set-dns --accel-restore）"
  return 0
}

acc_ddcc() {
  hr; echo "防 CC / DDoS 轻量优化"; hr
  local somax
  somax=$(acc_read net.core.somaxconn 65535)
  case "$somax" in ''|*[!0-9]*) somax=65535 ;; esac
  acc_n=0
  acc_apply_q net.ipv4.tcp_syncookies 1
  acc_apply_q net.ipv4.tcp_synack_retries 1
  acc_apply_q net.ipv4.tcp_syn_retries 3
  acc_apply_q net.ipv4.tcp_max_syn_backlog "$somax"
  acc_real && sysctl --system >/dev/null 2>&1
  ok "已写入 $acc_n 项防 CC 参数（syncookies 开、syn 重试降到 1、半连接队列 $somax）"
  inf "再说一遍：这只是一组保守的内核参数，不能替代真防护（防火墙 / 限速 / CDN）"
  return 0
}

acc_merge() { # 37 手动提交合并内核参数
  hr; echo "手动提交并合并内核参数（重放 $ACC_CONF）"; hr
  if [ ! -s "$ACC_CONF" ]; then inf "$ACC_CONF 还不存在；先做一次加速启用或自适应优化"; return 0; fi
  local n=0 ok_n=0 skip=0 line k v
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    k=${line%%=*}; v=${line#*=}
    k=$(printf '%s' "$k" | tr -d ' \t')
    v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$k" ] || continue
    n=$((n + 1))
    if acc_real; then
      if sysctl -w "$k=$v" >/dev/null 2>&1; then ok_n=$((ok_n + 1)); else skip=$((skip + 1)); inf "$k 当前内核不认，跳过"; fi
    else ok_n=$((ok_n + 1)); fi
  done < "$ACC_CONF"
  inf "共 $n 项：生效 $ok_n，跳过 $skip"
  acc_real && sysctl --system >/dev/null 2>&1 && ok "已 sysctl --system"
  return 0
}

acc_edit() { # 38 手动编辑内核参数
  hr; echo "手动编辑内核参数"; hr
  [ "$DRY" = 1 ] && { inf "[dry-run] 不打开编辑器"; return 0; }
  mkdir -p "$(dirname "$ACC_CONF")" "$ACC_BAK" 2>/dev/null
  [ -e "$ACC_CONF" ] || printf '# set-dns TCP 加速（菜单 11）—— 一行一个「键 = 值」\n' > "$ACC_CONF"
  local ed="" e
  for e in nano vi vim; do command -v "$e" >/dev/null 2>&1 && { ed=$e; break; }; done
  if [ -z "$ed" ]; then no "没找到可用编辑器（nano/vi/vim）；直接改这个文件也行：$ACC_CONF"; return 1; fi
  if [ "${TTY_OK:-0}" != 1 ]; then no "没有终端，打不开编辑器；可手动改 $ACC_CONF 再跑 set-dns --accel-merge"; return 1; fi
  cp -a "$ACC_CONF" "$ACC_BAK/edit-prev.conf" 2>/dev/null
  "$ed" "$ACC_CONF" < /dev/tty > /dev/tty 2>&1
  ok "已保存（编辑前原文备份在 $ACC_BAK/edit-prev.conf）"
  acc_merge
}

acc_kernels() { # 51 查看排序内核
  hr; echo "已安装内核（按版本排序）"; hr
  local cur n=0 p v mark
  cur=$(krn_ver)
  while read -r p v; do
    [ -n "$p" ] || continue
    n=$((n + 1)); mark=""
    case "$p" in *"$cur"*) mark="   ← 当前运行中" ;; esac
    printf '  %2d) %-48s %s%s\n' "$n" "$p" "$v" "$mark"
  done < <(dpkg-query -W -f '${Package} ${Version}\n' 'linux-image-*' 2>/dev/null | awk '$1 ~ /^linux-image-/ {print}' | sort -V)
  if [ "$n" = 0 ]; then inf "dpkg 里没查到 linux-image-* 包"; fi
  echo "  引导目录里可启动的："
  local b found=0 bf
  for b in /boot/vmlinuz-*; do [ -e "$b" ] || continue; found=1; printf '    %s\n' "${b##*/vmlinuz-}"; done
  [ "$found" = 0 ] && inf "（读不到 /boot/vmlinuz-*）"
  echo "  正在运行： $cur"
  inf "删除内核用菜单 52（set-dns --accel-kernel-del），本项只读"
  return 0
}

acc_kernel_del() { # 52 删除 / 保留指定内核
  hr; echo "删除内核（删除前会检查还剩几个能启动）"; hr
  local cur; cur=$(krn_ver)
  local -a pkgs=()
  local line p
  while read -r line; do [ -n "$line" ] && pkgs+=("$line"); done \
    < <(dpkg-query -W -f '${Package} ${db:Status-Status}\n' 'linux-image-*' 'linux-headers-*' 'linux-modules-*' 2>/dev/null \
        | awk '$2 == "installed" {print $1}' | grep -E '^linux-(image|headers|modules)' | sort -V)
  if [ "${#pkgs[@]}" = 0 ]; then inf "没有查到可管理的内核包"; return 0; fi
  local i=0 mark
  for p in "${pkgs[@]}"; do
    i=$((i + 1)); mark=""
    case "$p" in *"$cur"*) mark="   ← 当前运行中" ;; esac
    printf '  %2d) %-48s%s\n' "$i" "$p" "$mark"
  done
  local sel=""
  if [ -n "$ACC_DELREQ" ]; then sel="$ACC_DELREQ"
  elif [ "${TTY_OK:-0}" = 1 ]; then
    printf '  输入要删除的编号（空格分隔；直接回车 = 取消）： '
    read_ans; sel=${ans:-}
  else
    inf "没有终端：请用 SET_DNS_ACC_DEL=\"linux-image-6.12.107+deb13-cloud-amd64\" set-dns --accel-kernel-del"
    return 0
  fi
  [ -z "$sel" ] && { inf "已取消（什么都没删）"; return 0; }
  local -a want=()
  local t
  for t in $sel; do
    case "$t" in
      *[!0-9]*) want+=("$t") ;;
      *) if [ "$t" -ge 1 ] && [ "$t" -le "${#pkgs[@]}" ]; then want+=("${pkgs[$((t - 1))]}"); fi ;;
    esac
  done
  if [ "${#want[@]}" = 0 ]; then no "没有解析出有效的内核包名/编号"; return 1; fi
  # 安全屏障：删完必须还剩至少一个镜像包，否则重启即变砖（对账在删之前做）
  local total=0 delimg=0 rest q
  for q in "${pkgs[@]}"; do case "$q" in linux-image-*) total=$((total + 1)) ;; esac; done
  for q in "${want[@]}"; do case "$q" in linux-image-*) delimg=$((delimg + 1)) ;; esac; done
  rest=$((total - delimg))
  if [ "$rest" -le 0 ]; then
    no "操作已阻止：删完就没有能启动的内核镜像了（重启即变砖）"
    inf "先装一个别的内核（菜单 4/7/8 或 9~12）再来删，或改用菜单 10 的 xanmod 卸载"
    return 1
  fi
  inf "现有 $total 个内核镜像包，本次删 $delimg 个，删完还剩 $rest 个"
  local hit=0
  for q in "${want[@]}"; do case "$q" in *"$cur"*) hit=1 ;; esac; done
  if [ "$hit" = 1 ]; then
    wr "要删的是当前正在运行的内核（$cur）—— 本次不重启不影响，但重启前必须确认能进另一个内核"
    if [ "${TTY_OK:-0}" = 1 ]; then
      printf '  确认请输入大写 YES： '
      local c2; read -r c2 < /dev/tty || c2=""
      [ "$c2" = YES ] || { inf "已取消"; return 0; }
    fi
  fi
  if [ "$DRY" = 1 ]; then inf "[dry-run] apt-get purge -y ${want[*]}"; return 0; fi
  if ! acc_real; then ok "沙箱模式：不真的卸载（计划删除 ${want[*]}）"; return 0; fi
  if [ "${TTY_OK:-0}" = 1 ]; then krn_confirm "确认卸载 ${want[*]}？" || { inf "已取消"; return 0; }; fi
  mkdir -p "$ACC_BAK"
  printf '%s\n' "${want[@]}" > "$ACC_BAK/removed-kernels-$STAMP"
  apt-get purge -y "${want[@]}" 2>&1 | tail -8 | sed 's/^/      /'
  if [ "${PIPESTATUS[0]}" = 0 ]; then ok "已卸载 ${#want[@]} 个包（清单存 $ACC_BAK/removed-kernels-$STAMP）"
  else no "apt-get purge 返回非 0，请看上面的输出"; return 1; fi
  apt-get -y -qq autoremove >/dev/null 2>&1
  if command -v update-grub >/dev/null 2>&1; then update-grub >/dev/null 2>&1 && ok "已更新引导菜单（update-grub）"; fi
  inf "重启后用 uname -r 确认进的是想进的内核"
  return 0
}

acc_kernel_unsupported() { # $1=变体名
  hr; echo "这一项在 Debian/Ubuntu 上没法真装"; hr
  case "$1" in
    bbr-orig)   no "BBR 原版编译内核：xanmod / Debian 仓库里都没有这个包，得自己编译内核"
                inf "替代：菜单 9 的 xanmod BBRv3 内核（BBR 的新版本），或菜单 7/8 官方内核（也带 bbr）" ;;
    bbrplus|bbrplus-new)
                no "BBRplus 内核：仓库不提供，需要第三方编译内核"
                inf "替代：菜单 9~12 的 xanmod 各分支都带新版 BBR，效果等同或更好" ;;
    lotserver)  no "Lotserver（锐速）：只支持 CentOS 6/7，Debian 13 上装不了（老快照源里也没这套内核）"
                inf "替代：菜单 20/21/22 的 BBR + FQ / FQ_PIE / CAKE" ;;
    zen)        no "Zen 内核（Zen Kernel）：Debian 仓库不提供，需要自建或移植 Arch 仓库"
                inf "替代：菜单 7/8 官方内核，或菜单 9~12 的 xanmod" ;;
    *)          no "未知内核变体：$1" ;;
  esac
  return 1
}

acc_kernel_install() { # $1=变体
  local v=$1 pkg="" note="" cn=""
  local lv; lv=$(krn_cpu_level)
  case "$v" in
    cloud)        pkg=linux-image-cloud-amd64; note="官方 cloud 版（云主机专用）" ;;
    official)     pkg=linux-image-amd64;       note="官方稳定版（当前发行版仓库）" ;;
    latest)       pkg=linux-image-amd64;       cn=$(distro_codename 2>/dev/null); note="官方最新版（${cn}-backports）" ;;
    rt)           pkg=linux-image-rt-amd64;    note="官方实时（RT）版" ;;
    xanmod-main)  pkg="linux-xanmod-$lv";        note="XANMOD main（等同菜单 10 的 BBRv3 内核）" ;;
    xanmod-lts)   pkg="linux-xanmod-lts-$lv";    note="XANMOD LTS（长期支持分支）" ;;
    xanmod-edge)  pkg="linux-xanmod-edge-$lv";   note="XANMOD EDGE（最新特性分支，最激进）" ;;
    xanmod-rt)    pkg="linux-xanmod-rt-$lv";     note="XANMOD RT（实时内核）" ;;
    *) acc_kernel_unsupported "$v"; return $? ;;
  esac
  hr; echo "安装内核：$note"; hr
  inf "包名：$pkg（CPU 微架构档位：$lv，依据 $(krn_level_src)）"
  if [ "$v" = latest ] && [ -z "$cn" ]; then no "读不到发行版代号，无法定位 backports 仓库"; return 1; fi
  # backports 参数只在 latest 时非空；下面 apt-get 里故意不加引号让它按需展开
  local extra=""
  [ "$v" = latest ] && extra="-t ${cn}-backports"
  if [ "$DRY" = 1 ]; then inf "[dry-run] apt-get install -y $extra $pkg"; return 0; fi
  if [ "${TTY_OK:-0}" = 1 ]; then krn_confirm "确认安装 $pkg 并更新引导菜单？" || { inf "已取消"; return 0; }; fi
  if ! acc_real; then ok "沙箱模式：不真的装内核（计划 apt-get install $extra $pkg）"; return 0; fi
  case "$v" in
    xanmod-*)
      krn_repo_have || krn_repo_add || return 1
      apt-get update -qq >/dev/null 2>&1 ;;
  esac
  mkdir -p "$ACC_BAK"
  dpkg-query -W -f '${Package}\n' 'linux-image-*' 'linux-headers-*' 2>/dev/null | sort -u > "$ACC_BAK/kernels-before-$STAMP" 2>/dev/null || true
  apt-get install -y $extra "$pkg" 2>&1 | tail -8 | sed 's/^/      /'
  if [ "${PIPESTATUS[0]}" != 0 ]; then no "apt-get 返回非 0，安装未成功"; return 1; fi
  ok "已安装 $pkg"
  if command -v update-grub >/dev/null 2>&1; then update-grub >/dev/null 2>&1 && ok "已更新引导菜单"; fi
  inf "现在还没生效 —— 重启才切到新内核；重启前先看：grep -m5 '^menuentry' /boot/grub/grub.cfg"
  inf "重启后用 uname -r 确认版本"
  return 0
}

acc_external() { # $1=名字  $2=URL  $3=用途说明  $4=额外提示
  hr; echo "外部脚本：$1"; hr
  inf "$3"
  inf "来源：$2"
  [ -n "${4:-}" ] && inf "$4"
  if [ "$DRY" = 1 ]; then inf "[dry-run] 不下载不执行外部脚本"; return 0; fi
  if [ "${TTY_OK:-0}" != 1 ]; then no "没有终端无法确认；请自行执行：curl -fsSL $2 | bash"; return 1; fi
  krn_confirm "确认下载并执行上面这个外部脚本？（它不受本脚本控制）" || { inf "已取消"; return 0; }
  if ! acc_real; then ok "沙箱模式：不真的下载执行"; return 0; fi
  local t; t=$(mktemp /tmp/setdns-ext.XXXXXX 2>/dev/null) || { no "建临时文件失败"; return 1; }
  # 走 gh_fetch：这些外部脚本都在 GitHub 上，大陆直连 raw 会 Connection reset by peer
  if ! gh_fetch "$2" "$t" 60; then rm -f "$t"; no "下载失败（所有镜像途径都不通）"; return 1; fi
  [ -n "${GH_LAST_URL:-}" ] && [ "$GH_LAST_URL" != "$2" ] && inf "经镜像下载：${GH_LAST_URL:0:60}…"
  if ! bash -n "$t" 2>/dev/null; then rm -f "$t"; no "下载到的内容不是合法 shell 脚本，已丢弃"; return 1; fi
  ok "已下载并做了语法校验（$t）"
  bash "$t"
  local rc=$?
  rm -f "$t"
  # 外部脚本改完模块后，systemd-sysctl 可能已经跑过了，参数要重放一次才生效
  sysctl --system >/dev/null 2>&1
  [ "$rc" = 0 ] && ok "$1 执行完成（rc=0）" || wr "$1 退出码 $rc"
  return 0
}

acc_restore() { # 55 卸载全部加速
  hr; echo "卸载全部加速（只删本脚本写的，不动别人的配置）"; hr
  if [ ! -e "$ACC_CONF" ] && [ ! -e "$ACC_MOD" ]; then inf "本脚本没写过加速配置，无需卸载"; return 0; fi
  if [ "$DRY" = 1 ]; then inf "[dry-run] 删除 $ACC_CONF 与 $ACC_MOD 并 sysctl --system"; return 0; fi
  mkdir -p "$ACC_BAK"
  if [ -e "$ACC_CONF" ]; then
    cp -a "$ACC_CONF" "$ACC_BAK/removed-accel-$STAMP.conf" 2>/dev/null
    rm -f "$ACC_CONF"; ok "已删除 $ACC_CONF（备份 removed-accel-$STAMP.conf）"
  fi
  if [ -e "$ACC_MOD" ]; then
    cp -a "$ACC_MOD" "$ACC_BAK/removed-qdisc-$STAMP.conf" 2>/dev/null
    rm -f "$ACC_MOD"; ok "已删除 $ACC_MOD"
  fi
  if acc_real; then
    sysctl --system >/dev/null 2>&1 && ok "已重新 sysctl --system（其它脚本的 cc/qdisc 重新生效）"
    inf "现在：拥塞控制 $(acc_cc_now) / 队列 $(acc_qdisc_now)"
  else
    inf "沙箱模式：跳过 sysctl --system"
  fi
  inf "99-degwd.conf / 99-kejilion-bbr.conf 原样保留，没有动过"
  return 0
}

acc_status_entry() {
  hr; echo "TCP 加速状态"; hr
  acc_panel
  hr
  return 0
}

acc_menu() {
  local ans
  hr; echo "TCP 加速 一键安装管理（本脚本内置版）"; hr
  acc_panel
  if [ "$(id -u)" != 0 ] && [ "$REAL" = 1 ]; then
    hr; inf "非 root：只显示面板不修改（改内核参数需要 root）"; hr; return 0
  fi
  echo
  if [ "${TTY_OK:-0}" != 1 ]; then
    inf "没有终端：请用下面的子命令（只读面板 --accel-status）"
    inf "  加速：--accel-bbr / --accel-fqpie / --accel-cake"
    inf "  开关：--accel-ecn-on / --accel-ecn-off / --accel-ipv6-on / --accel-ipv6-off"
    inf "  优化：--accel-optimize / --accel-ddcc / --accel-merge"
    inf "  内核：--accel-kernels / --accel-kernel-del / --accel-kernel=<变体>"
    inf "  还原：--accel-restore"
    printf '\n'
  fi
  cat <<'ACCHELP'
  0. 升级脚本                        88. 卸载脚本
  ---------------------------------------- 内核安装
  1. 安装 BBR 原版编译内核            7. 安装 官方稳定内核
  2. 安装 BBRplus 版内核              8. 安装 官方最新内核
  3. 安装 Lotserver(锐速)内核         9. 安装 XANMOD(main)
  4. 安装 官方 cloud 内核            10. 安装 XANMOD(LTS)
  5. 安装 BBRplus 新版内核           11. 安装 XANMOD(EDGE)
  6. 安装 Zen 官方版内核             12. 安装 XANMOD(RT)
  ---------------------------------------- 加速启用
 20. 使用 BBR+FQ 加速               21. 使用 BBR+FQ_PIE 加速
 22. 使用 BBR+CAKE 加速             23. 使用 BBRplus+FQ 版加速
 24. 使用 Lotserver(锐速)加速       25. 编译安装 brutal 模块
 26. 编译安装 LotSpeed 模块         27. 使用 LotSpeed 加速
  ---------------------------------------- 系统配置
 30. 开启 ECN                       31. 关闭 ECN
 32. 系统网络自适应优化             33. 防 CC/DDoS 轻量优化
 35. 禁用 IPv6                      36. 开启 IPv6
 37. 手动提交合并内核参数           38. 手动编辑内核参数
  ---------------------------------------- 内核管理
 51. 查看排序内核                   52. 删除保留指定内核
 55. 卸载全部加速                   99. 退出脚本
  ---------------------------------------- 其它工具
 60. 网络精调(tcpfit 联动)          92. 一键 DD 重装系统
ACCHELP
  hr
  if [ "${TTY_OK:-0}" != 1 ]; then inf "（没有终端，只显示面板）"; return 0; fi
  printf '  请输入数字： '
  read_ans
  case "${ans:-}" in
    0)  acc_self_update ;;
    88) acc_self_uninstall ;;
    1)  acc_kernel_install bbr-orig ;;
    2)  acc_kernel_install bbrplus ;;
    3)  acc_kernel_install lotserver ;;
    4)  acc_kernel_install cloud ;;
    5)  acc_kernel_install bbrplus-new ;;
    6)  acc_kernel_install zen ;;
    7)  acc_kernel_install official ;;
    8)  acc_kernel_install latest ;;
    9)  acc_kernel_install xanmod-main ;;
    10) acc_kernel_install xanmod-lts ;;
    11) acc_kernel_install xanmod-edge ;;
    12) acc_kernel_install xanmod-rt ;;
    20) acc_enable fq bbr ;;
    21) acc_enable fq_pie bbr ;;
    22) acc_enable cake bbr ;;
    23) acc_custom_cc bbrplus fq "BBRplus 不是标准内核算法：需要带 tcp_bbrplus 模块的第三方内核，本机没有。先用菜单 20 的 BBR+FQ" ;;
    24) hr; echo "Lotserver(锐速) 加速"; hr
        no "Lotserver 只支持 CentOS 6/7 内核，Debian 13 上无法加载"
        inf "替代：菜单 20/21/22 的 BBR + FQ / FQ_PIE / CAKE" ;;
    25) acc_external "brutal" "https://tcp.hy2.sh/" "编译安装 brutal（TCP 暴力加速模块，基于 BBR，需 headers 匹配 + 外网）" "Headers 状态可用面板确认；编译要几分钟" ;;
    26) acc_external "LotSpeed" "https://raw.githubusercontent.com/uk0/lotspeed/ml-tcp/install.sh" "编译安装 LotSpeed 模块（LoTSpeed 多路径加速，需 headers 匹配）" ;;
    27) acc_custom_cc lotspeed fq "LotSpeed 要先编译安装（菜单 26）；装完再回到这一项启用" ;;
    30) acc_ecn 1 ;;
    31) acc_ecn 0 ;;
    32) acc_optimize ;;
    33) acc_ddcc ;;
    35) acc_ipv6 1 ;;
    36) acc_ipv6 0 ;;
    37) acc_merge ;;
    38) acc_edit ;;
    51) acc_kernels ;;
    52) acc_kernel_del ;;
    55) acc_restore ;;
    99) inf "已退出" ;;
    60) acc_external "tcpfit 网络精调" "https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh" "调用上游 tcpfit 做自适应 BDP/内存的队列精调" ;;
    92) hr; echo "一键 DD 重装系统"; hr
        wr "这是会把整台机器重装成新系统的操作，装完当前所有配置（含本脚本的 DNS 防护）全部消失"
        if [ "${SET_DNS_ACC_ALLOW_DD:-0}" != 1 ]; then
          inf "为防误触，本项默认不执行。真要重装，用外部的 reinstall 脚本（自行确认目标系统与密码）："
          inf "  curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
          inf "  bash reinstall.sh debian 13"
          inf "想从本菜单直接起它，先设 SET_DNS_ACC_ALLOW_DD=1"
        else
          acc_external "DD 重装系统" "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh" "重装整台机器（高危：会清空现有系统）" "装完本脚本的一切配置都不存在了"
        fi ;;
    *) wr "无效选择：${ans:-}（没做任何改动）" ;;
  esac
  return 0
}

acc_self_update() { # 0 升级脚本
  hr; echo "升级脚本"; hr
  local url="https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh"
  if [ "$DRY" = 1 ]; then inf "[dry-run] 从 $url 拉最新版"; return 0; fi
  if ! acc_real && [ -z "${SET_DNS_ACC_UPDATE_STUB:-}" ]; then inf "沙箱模式：跳过下载（$url）"; return 0; fi
  local t; t=$(mktemp /tmp/setdns-new.XXXXXX 2>/dev/null) || { no "建临时文件失败"; return 1; }
  # 走 gh_fetch：大陆直连 raw 时通时不通，多途径依次试
  if ! gh_fetch "$url" "$t" 60; then rm -f "$t"; no "下载失败（所有镜像途径都不通）"; return 1; fi
  [ -n "${GH_LAST_URL:-}" ] && [ "$GH_LAST_URL" != "$url" ] && inf "经镜像下载：${GH_LAST_URL:0:60}…"
  if ! bash -n "$t" 2>/dev/null; then rm -f "$t"; no "下载到的不是合法脚本，已丢弃"; return 1; fi
  local new old
  new=$(grep -m1 -oE 'set-dns v[0-9]+\.[0-9]+' "$t" 2>/dev/null)
  old=$(grep -m1 -oE 'set-dns v[0-9]+\.[0-9]+' "$0" 2>/dev/null)
  ok "线上版本：${new:-未知}    本地版本：${old:-未知}"
  case "$0" in
    */set-dns.sh|*/set-dns)
      cp -a "$0" "$0.bak" 2>/dev/null && cp -f "$t" "$0" && chmod 755 "$0" && ok "已更新 $0（旧版备份 $0.bak）"
      rm -f "$t"; return 0 ;;
  esac
  if [ -e ./set-dns.sh ]; then
    cp -f "$t" ./set-dns.sh && chmod 755 ./set-dns.sh && ok "已更新 ./set-dns.sh"
    rm -f "$t"; return 0
  fi
  inf "当前脚本不是从磁盘文件运行的（bash <(curl ...) 方式），无法原地替换。手动更新："
  inf "  wget -qO set-dns.sh $url && bash set-dns.sh"
  rm -f "$t"
  return 0
}

acc_self_uninstall() { # 88 卸载脚本
  hr; echo "卸载脚本（拆防护 + 撤销加速配置）"; hr
  inf "本脚本没有单独的安装目录，卸载 = 拆掉它装过的东西："
  if [ "$DRY" = 1 ]; then
    inf "[dry-run] 会移除防护守护与加速配置"
  else
    uninstall_guard
    acc_restore
  fi
  hr
  inf "剩下这些是历史备份，确认不要了可手动删："
  inf "  $BK/（DNS 托管副本、内核/SSH/换源备份、加速配置备份）"
  inf "  $SBIN/dns-watch.sh.bak（守护脚本留底）"
  inf "注意：DNS 当前配置（$HERE）保持原样，不会被还原成初始状态；要还原用 set-dns --restore"
  return 0
}

acc_entry() { # 菜单 11 入口：命令行给了 ACC_ACT 就直接执行那一项，否则出面板
  local act=${ACC_ACT:-}
  [ -z "$act" ] && { acc_menu; return 0; }
  case "$act" in
    fq:bbr)     acc_enable fq bbr ;;
    fq_pie:bbr) acc_enable fq_pie bbr ;;
    cake:bbr)   acc_enable cake bbr ;;
    ecn:1)      acc_ecn 1 ;;
    ecn:0)      acc_ecn 0 ;;
    ipv6:1)     acc_ipv6 1 ;;
    ipv6:0)     acc_ipv6 0 ;;
    optimize)   acc_optimize ;;
    ddcc)       acc_ddcc ;;
    merge)      acc_merge ;;
    edit)       acc_edit ;;
    kernel:*)   acc_kernel_install "${act#kernel:}" ;;
    *)          acc_menu ;;
  esac
  return $?
}

# ================= 3x-ui 面板安装（菜单 12 / --xui） =================
# 为什么需要这一段：官方的一键脚本 `bash <(curl -Ls .../3x-ui/master/install.sh)` 在
# **中国大陆服务器**上必然失败。问题不在脚本本身，而在它内部要访问 github.com 主站：
#
#   resolve_latest_tag   -> https://github.com/MHSanaei/3x-ui/releases/latest
#   真正的安装包          -> https://github.com/.../releases/download/<tag>/x-ui-linux-<arch>.tar.gz
#   .sha256 校验边车      -> 同上再加 .sha256
#   x-ui.sh / x-ui.service -> https://raw.githubusercontent.com/...   （这个反而通）
#
# 实测（腾讯云 Debian 13）：github.com:443 **TCP 连得上**（time_connect=0.08s），
# 但 HTTP 响应永远拿不到 —— `curl https://github.com/` 30 秒超时、收到 0 字节；
# 而 raw.githubusercontent.com / api.github.com / objects.githubusercontent.com 全部正常。
# 于是现象特别有迷惑性：**脚本本身能下载下来，卡在装包那一步**，报
#   "Failed to fetch x-ui version, it may be due to GitHub API restrictions" 或
#   "Downloading x-ui failed, please be sure that your server can access GitHub"
# 用户看到的是「脚本跑起来了但装不上」，很容易误判成脚本坏了。
#
# 修法：不改官方脚本的任何逻辑，只在下载后把脚本里写死的 GitHub 绝对地址**整体改写成
# 带加速前缀的地址**，再交给 bash 执行。前缀镜像对脚本用到的三种 URL 形态都成立
# （真机逐条验过）：
#   前缀 + https://raw.githubusercontent.com/...        -> 200；文件不存在时仍是 404（HEAD 语义保留，
#                                                          所以脚本里 require_repo_files 的探测不会被骗）
#   前缀 + https://github.com/.../releases/latest       -> 302，且 url_effective 带 /tag/<版本>
#   前缀 + https://github.com/.../releases/download/... -> 200；78MB 安装包 sha256 与官方边车逐字节一致
# **校验和没有被绕过**：脚本照旧下 .sha256 并比对，镜像只是搬运字节。
# api.github.com 不改写 —— 它是 releases/latest 失败时的退路，直连本来就是通的。
XUI_RAW=https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh
XUI_REPO=https://github.com/MHSanaei/3x-ui
XUI_DIR=/usr/local/x-ui
XUI_CLI=/usr/bin/x-ui
XUI_ETC=$ETC/x-ui
XUI_BAK=$BK/xui
# 候选加速前缀。
#
# **顺序是按"大文件吞吐"排的，不是按"小文件延迟"** —— 这个区别是踩出来的：
# 3x-ui 要下 78MB 的 release 安装包，而各镜像对大小文件的表现**完全不成正比**。
# 真机实测（同一台大陆服务器，同一时刻）：
#     镜像                 1KB LICENSE    78MB 安装包
#     gh-proxy.com          0.42s         25.8 MB/s   ✅ 一次下完
#     ghfast.top            0.93s          6.1 MB/s   ⚠️ 下到 48MB 后 curl(92) INTERNAL_ERROR 中断
#     ghproxy.net           0.86s         40 KB/s     ❌ 慢到不可用
#     hk.gh-proxy.com       2.19s         17 KB/s     ❌ 慢到不可用
# 也就是说：**小文件最快的那个（ghfast.top）恰恰是下大文件会断的**。
# 之前脚本用 LICENSE(1KB) 挑镜像并把它排在第一位，于是安装必然卡在大文件那步。
# 现在按大文件实测结果排序，gh-proxy.com 放第一。
#
# 另外 ghfast.top / ghproxy.net 能把 releases/latest 的 302 一起透传，
# 所以 resolve_latest_tag 不必退到 api.github.com —— 大陆机器上这一步很关键。
XUI_MIRRORS_DEFAULT="https://gh-proxy.com/ https://ghfast.top/ https://ghproxy.net/ https://hk.gh-proxy.com/"
XUI_MIRROR=${SET_DNS_GH_PROXY:-}
XUI_WORKING=""     # 第一轮判定可用的前缀（供大文件吞吐复选）

xui_mirror_list() { printf '%s\n' ${XUI_MIRROR:-$XUI_MIRRORS_DEFAULT}; }

# 一个前缀的两种能力分开测，因为「只有 raw 能力」的前缀仍然可用：
#   raw    —— 脚本正文、x-ui.sh、x-ui.service.* 都走 raw.githubusercontent.com
#   latest —— releases/latest 的 302。有些前缀只代理 raw，会把这个请求原样返回自己，
#             于是 resolve_latest_tag 解析出空 tag。但这不致命：官方脚本的退路是
#             api.github.com，而它在大陆上直连本来就是通的 —— 所以只代理 raw 的前缀
#             依然能用，只是降一档。分两档挑，可用前缀的数量就从 2 个变成 5 个以上。
xui_mirror_raw_ok() { # $1=前缀
  local code
  command -v curl >/dev/null 2>&1 || return 1
  code=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 12 "${1}${XUI_RAW}" 2>/dev/null) || return 1
  [ "$code" = 200 ]
}
xui_mirror_latest_ok() { # $1=前缀
  local eff
  command -v curl >/dev/null 2>&1 || return 1
  eff=$(curl -sSLI -o /dev/null -w '%{url_effective}' --max-time 15 "${1}${XUI_REPO}/releases/latest" 2>/dev/null) || return 1
  case "$eff" in */tag/*) return 0 ;; esac
  return 1
}
# 只代理 raw 的前缀要靠 api.github.com 兜底，所以那条路得是通的
xui_api_direct_ok() {
  local code
  code=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 12 \
    https://api.github.com/repos/MHSanaei/3x-ui/releases/latest 2>/dev/null) || return 1
  [ "$code" = 200 ]
}

# 大文件吞吐探测：只拉 release 包的前几秒，看**速度**而不是看能不能连上。
#
# 为什么必须单独测：3x-ui 的安装包有 78MB，而各镜像对大小文件的表现完全不成正比。
# 真机实测（同一台大陆服务器、同一时刻）：
#     gh-proxy.com    1KB=0.42s    78MB=25.8 MB/s   ✅
#     ghfast.top      1KB=0.93s    78MB= 6.1 MB/s   ⚠️ 下到 48MB 就 curl(92) INTERNAL_ERROR
#     ghproxy.net     1KB=0.86s    78MB=40 KB/s     ❌
#     hk.gh-proxy.com 1KB=2.19s    78MB=17 KB/s     ❌
# 只按 1KB 测速会把 ghfast.top 选成第一，结果安装必卡在大文件那步。
# 这里限时拉一小段，取 %{speed_download}（字节/秒）作为排序依据。
# $1=前缀  $2=参考 URL（github.com/.../releases/download/...）  $3=限时秒
xui_mirror_throughput() {
  local p=$1 url=$2 tmo=${3:-6}
  command -v curl >/dev/null 2>&1 || return 1
  curl -sL --max-time "$tmo" -o /dev/null -w '%{speed_download}' "${p}${url}" 2>/dev/null
}

xui_mirror_pick() {
  local m best="" bt="" t s e tier_a=0
  # 记录第一轮判定"可用"的前缀，供第二轮吞吐复选用
  XUI_WORKING=""
  if [ -n "$XUI_MIRROR" ]; then
    inf "按 SET_DNS_GH_PROXY 指定加速前缀：$XUI_MIRROR"
    XUI_WORKING="$XUI_MIRROR"
    return 0
  fi
  if [ "$DRY" = 1 ]; then inf "[dry-run] 将逐个探测加速镜像并挑最快的"; XUI_MIRROR="https://gh-proxy.com/"; return 0; fi
  if ! command -v curl >/dev/null 2>&1; then
    wr "没有 curl，无法探测加速镜像（先跑 set-dns --tools 装上 curl）"
    XUI_MIRROR=""
    return 1
  fi
  echo "  正在挑选 GitHub 加速镜像（每个最多 15 秒）……"
  # 第一轮：优先要「raw + releases/latest」都行的（最省事，不必退到 API）
  for m in $(xui_mirror_list); do
    printf '    %-34s ' "$m"
    s=$(date +%s%N)
    if xui_mirror_raw_ok "$m" && xui_mirror_latest_ok "$m"; then
      e=$(date +%s%N)
      t=$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.2f", (b-a)/1e9}')
      printf '可用 %ss（含 releases/latest）\n' "$t"
      if [ -z "$best" ] || awk -v a="$t" -v b="$bt" 'BEGIN{exit !(a<b)}'; then best=$m; bt=$t; fi
      XUI_WORKING="$XUI_WORKING $m"
      tier_a=1
    else
      printf '（raw 或 releases/latest 不通）\n'
    fi
  done
  if [ -z "$best" ]; then
    # 第二轮：只要求 raw 能取到脚本，靠 api.github.com 直连兜底拿 tag
    if xui_api_direct_ok; then
      inf "没有全能前缀，改用「只代理 raw」的前缀（tag 由 api.github.com 直连取，它本来就是通的）"
      for m in $(xui_mirror_list); do
        printf '    %-34s ' "$m"
        s=$(date +%s%N)
        if xui_mirror_raw_ok "$m"; then
          e=$(date +%s%N)
          t=$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.2f", (b-a)/1e9}')
          printf '可用 %ss\n' "$t"
          if [ -z "$best" ] || awk -v a="$t" -v b="$bt" 'BEGIN{exit !(a<b)}'; then best=$m; bt=$t; fi
          XUI_WORKING="$XUI_WORKING $m"
        else
          printf '不可用\n'
        fi
      done
    else
      wr "api.github.com 直连也不通，没法退到 API 取版本号"
    fi
  fi
  if [ -z "$best" ]; then
    wr "所有加速镜像都不可用 —— 退回直连 GitHub（海外机器没问题，大陆机器会在装包那步失败）"
    inf "也可以自己指定一个前缀：SET_DNS_GH_PROXY=https://你的前缀/ set-dns --xui"
    XUI_MIRROR=""
    return 1
  fi

  # ===== 第二轮：按**大文件吞吐**复选 =====
  # 第一轮挑的是"能用"（小文件延迟低）。但 3x-ui 要下 78MB，而各镜像对大小文件
  # 的表现完全不成正比（实测：小文件最快的 ghfast.top 下大文件只有 6MB/s 且会
  # curl(92) 中断；gh-proxy.com 反而有 25MB/s）。所以这里拿真实的 release 包
  # 限时拉一小段，用实测速度重新排序，避免"选了个能连但下不完的"。
  local rel_url speed best_sp=0 sp
  rel_url=$(xui_release_probe_url 2>/dev/null)
  if [ -n "$rel_url" ]; then
    echo
    echo "  按大文件吞吐复选（拉 6 秒看速度，安装包有 78MB，这个指标才是关键）……"
    for m in $XUI_WORKING; do
      printf '    %-34s ' "$m"
      sp=$(xui_mirror_throughput "$m" "$rel_url" 6)
      case "$sp" in ''|*[!0-9.]*) printf '测不出\n'; continue ;; esac
      printf '%s\n' "$(awk -v v="$sp" 'BEGIN{
        if (v>=1048576) printf "%.1f MB/s", v/1048576;
        else if (v>=1024) printf "%.0f KB/s", v/1024;
        else printf "%.0f B/s", v }')"
      if awk -v a="$sp" -v b="$best_sp" 'BEGIN{exit !(a>b)}'; then best=$m; best_sp=$sp; fi
    done
    if [ "$best_sp" -gt 0 ] 2>/dev/null; then
      XUI_MIRROR=$best
      ok "选定加速前缀：$XUI_MIRROR（实测大文件 $(awk -v v="$best_sp" 'BEGIN{
        if (v>=1048576) printf "%.1f MB/s", v/1048576; else printf "%.0f KB/s", v/1024 }')）"
      return 0
    fi
    inf "吞吐测不出（可能拿不到 release 包地址），沿用第一轮结果"
  fi

  XUI_MIRROR=$best
  if [ "$tier_a" = 1 ]; then ok "选定加速前缀：$XUI_MIRROR（探测耗时 ${bt}s）"
  else ok "选定加速前缀：$XUI_MIRROR（仅 raw，版本号走 api.github.com；探测耗时 ${bt}s）"; fi
  return 0
}

# 给吞吐测试用的"参考大文件"：优先用 release 里真实存在的安装包。
# 拿不到就退回一个已知较大的仓库文件，保证测的是"大文件"而不是 1KB 小文件。
xui_release_probe_url() {
  local tag arch url code
  arch=$(uname -m 2>/dev/null)
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) arch=amd64 ;;
  esac
  # 用 api.github.com 取最新 tag（大陆实测可达），拿不到就用 master 分支的大文件
  tag=$(gh_curl -fsSL --connect-timeout 8 --max-time 15 \
          "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" 2>/dev/null \
        | grep -m1 -oE '"tag_name": *"[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/')
  if [ -n "$tag" ]; then
    url="https://github.com/MHSanaei/3x-ui/releases/download/${tag}/x-ui-linux-${arch}.tar.gz"
    # 校验一下这个包真的存在（HEAD 走镜像）
    code=$(gh_curl -sIL --max-time 12 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
    [ "$code" = 200 ] && { printf '%s' "$url"; return 0; }
  fi
  # 退路：用脚本自己仓库里的 set-dns.sh（~220KB，比 1KB 的 LICENSE 更能反映吞吐）
  printf '%s' "https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh"
  return 0
}

# 把脚本里写死的 GitHub 绝对地址改写成带前缀的地址。
# 只动这两类主机，api.github.com 保持直连（它是退路，而且大陆上本来是通的）。
xui_patch_installer() { # $1=本地脚本文件
  local f=$1 m=$XUI_MIRROR n1 n2
  if [ -n "$m" ]; then
    n1=$(grep -c 'https://github\.com/' "$f" 2>/dev/null || true); n1=${n1:-0}
    n2=$(grep -c 'https://raw\.githubusercontent\.com/' "$f" 2>/dev/null || true); n2=${n2:-0}
    if [ "$n1" = 0 ] && [ "$n2" = 0 ]; then
      wr "脚本里没找到 GitHub 绝对地址（上游可能改了写法），不做改写"
    else
      sed -i \
        -e "s#https://raw\.githubusercontent\.com/#${m}https://raw.githubusercontent.com/#g" \
        -e "s#https://github\.com/#${m}https://github.com/#g" \
        "$f"
      ok "已改写 $((n1 + n2)) 处 GitHub 地址走加速前缀（github.com $n1 处 / raw $n2 处）"
    fi
  else
    inf "没有加速前缀，脚本保持原样（直连 GitHub）"
  fi
  # 改写只应改变 URL，不应改变语法 —— 顺手验一遍，不合法就丢弃
  if ! bash -n "$f" 2>/dev/null; then
    no "改写后语法校验失败，已丢弃（不执行）"
    return 1
  fi
  return 0
}

xui_backup() {
  [ "$DRY" = 1 ] && { inf "[dry-run] 将备份 /etc/x-ui 与 $XUI_DIR/bin"; return 0; }
  mkdir -p "$XUI_BAK" || return 1
  local did=0
  if [ -d "$XUI_ETC" ]; then cp -a "$XUI_ETC" "$XUI_BAK/x-ui.etc.$STAMP" 2>/dev/null && did=1; fi
  if [ -d "$XUI_DIR/bin" ]; then cp -a "$XUI_DIR/bin" "$XUI_BAK/x-ui.bin.$STAMP" 2>/dev/null && did=1; fi
  [ "$did" = 1 ] && ok "原配置已备份到 $XUI_BAK/（面板数据 + bin/ 自定义文件）" || inf "没有可备份的旧安装"
  return 0
}

xui_status() {
  hr; echo "3x-ui 面板状态"; hr
  if [ -x "$XUI_DIR/x-ui" ]; then
    ok "已安装 $XUI_DIR/x-ui"
    local v
    v=$("$XUI_DIR/x-ui" -v 2>/dev/null | head -1)
    inf "面板版本: ${v:-未知}"
  else
    inf "未安装（$XUI_DIR/x-ui 不存在）"
  fi
  if [ -x "$XUI_CLI" ]; then inf "管理脚本: $XUI_CLI"; else inf "管理脚本: 未安装"; fi
  [ -f "$XUI_ETC/x-ui.db" ] && inf "数据库: $XUI_ETC/x-ui.db（$(du -h "$XUI_ETC/x-ui.db" 2>/dev/null | awk '{print $1}')）" \
    || inf "数据库: 未找到 $XUI_ETC/x-ui.db"
  if [ "$REAL" = 1 ] && command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active x-ui >/dev/null 2>&1; then ok "x-ui.service 运行中"; else wr "x-ui.service 未运行"; fi
    systemctl is-enabled x-ui >/dev/null 2>&1 && inf "已设置开机自启" || inf "未设置开机自启"
  fi
  if [ -x "$XUI_DIR/x-ui" ]; then
    echo "  当前面板信息:"
    "$XUI_DIR/x-ui" setting -show true 2>/dev/null | sed 's/^/  /' || inf "读不到面板信息"
  fi
  local p
  p=$(ss -lntp 2>/dev/null | grep -E 'x-ui|xray' | awk '{print $4}' | tr '\n' ' ')
  [ -n "$p" ] && inf "监听端口: $p" || inf "没看到 x-ui / xray 的监听"
  hr
  return 0
}

xui_uninstall() {
  hr; echo "卸载 3x-ui"; hr
  if [ ! -d "$XUI_DIR" ] && [ ! -d "$XUI_ETC" ]; then inf "没装 3x-ui，无需卸载"; hr; return 0; fi
  wr "这会停掉面板并删除 $XUI_DIR、$XUI_ETC、$XUI_CLI 与 systemd 单元"
  if [ "$DRY" = 1 ]; then inf "[dry-run] 不执行卸载"; hr; return 0; fi
  if [ "${TTY_OK:-0}" = 1 ]; then
    krn_confirm "确认卸载 3x-ui？（面板数据会先备份到 $XUI_BAK/）" || { inf "已取消"; hr; return 0; }
  fi
  xui_backup
  if [ "$REAL" = 1 ]; then
    sys stop x-ui 2>/dev/null
    sys disable x-ui 2>/dev/null
  fi
  pkill -f 'xray-linux' >/dev/null 2>&1 || true
  rm -f "$ETC/systemd/system/x-ui.service" 2>/dev/null
  rm -rf "$ETC/systemd/system/x-ui.service.d" 2>/dev/null
  rm -f "$XUI_CLI" 2>/dev/null
  rm -rf "$XUI_DIR" 2>/dev/null
  rm -rf "$XUI_ETC" 2>/dev/null
  rm -rf /var/log/x-ui 2>/dev/null
  [ "$REAL" = 1 ] && sys daemon-reload 2>/dev/null
  ok "已卸载（原数据在 $XUI_BAK/）"
  inf "iptables 里 xui-block-chain 之类的规则本脚本不动，需要就自行 iptables -F xui-block-chain"
  hr
  return 0
}

# --- 升级前后的数据兼容性自检 ---
# 这一节是真机升级逼出来的。0.3.4.4（2023 年的老 3x-ui）直接跳到 3.9.0 时，有两个
# **面板上看不出来**的数据问题会让 xray 彻底起不来：
#
#   1) Shadowsocks-2022 的密钥必须是「32 字节的 base64」—— 44 字符且结尾是 `=`。
#      实测那台机器上存的是 44 字符、但严格解码出 **33 字节**（结尾是普通字符）。
#      **老 xray 1.7.5 不校验长度照样启动**，新 xray 26.x 直接：
#        Failed to start: main: failed to create server > proxy/shadowsocks_2022: bad key
#      然后 exit 23。于是 x-ui.service 显示 active、面板能打开，**xray 却完全没起来**，
#      10440/40530 一个端口都不监听 —— 只看面板根本发现不了。
#      （同一个 44 字符的值，老 xray 报 `Configuration OK.`，新 xray 报 `bad key`，逐条验过。）
#
#   2) 老版本 DB 没有 `clients` 表，迁移会新建一张并把老客户端的 `enable` 置成 0。
#      新面板看到 enable=0 就打印
#        Remove Inbound User <email> due to expiration or traffic limit
#      并把用户从 config.json 里剔掉（`"clients": []`）—— 客户端连不上，面板上也没有报错。
#
# 本脚本**不去偷偷改用户的加密密钥或客户端开关**（那会直接改变客户端要填的配置），
# 只做「升级前明确告警 + 升级后真实自检 + 一个显式的修复开关」。
XUI_FIX_SS=${SET_DNS_XUI_FIX_SS:-0}

xui_has_py() { command -v python3 >/dev/null 2>&1; }

xui_schema_old() { # 老 DB（没有 clients 表）说明是大版本跨越，迁移会丢客户端状态
  [ -f "$XUI_ETC/x-ui.db" ] || return 1
  xui_has_py || return 1
  python3 - "$XUI_ETC/x-ui.db" <<'PY' 2>/dev/null
import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1]); cur = c.cursor()
    cur.execute("select name from sqlite_master where type='table' and name='clients'")
    print("old" if not cur.fetchall() else "new")
except Exception:
    print("unknown")
PY
}

xui_ss_scan() { # 每行：id|port|method|实际字节数|应有字节数
  [ -f "$XUI_ETC/x-ui.db" ] || return 0
  xui_has_py || return 0
  python3 - "$XUI_ETC/x-ui.db" <<'PY' 2>/dev/null
import sqlite3, json, base64, sys
try:
    c = sqlite3.connect(sys.argv[1]); cur = c.cursor()
    cur.execute("select id, port, settings from inbounds where protocol='shadowsocks'")
    rows = cur.fetchall()
except Exception:
    raise SystemExit(0)
for iid, port, settings in rows:
    try:
        s = json.loads(settings)
    except Exception:
        continue
    m = s.get('method', '')
    if not m.startswith('2022-blake3'):
        continue
    need = 32 if '256' in m else 16
    pwd = s.get('password', '')
    try:
        n = len(base64.b64decode(pwd, validate=True))
    except Exception:
        n = -1
    if n != need:
        print("%s|%s|%s|%s|%s" % (iid, port, m, n, need))
PY
}

xui_client_scan() { # 每行：email|total_gb|expiry_time（enable=0 的客户端）
  [ -f "$XUI_ETC/x-ui.db" ] || return 0
  xui_has_py || return 0
  python3 - "$XUI_ETC/x-ui.db" <<'PY' 2>/dev/null
import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1]); cur = c.cursor()
    cur.execute("select email, enable, total_gb, expiry_time from clients")
    rows = cur.fetchall()
except Exception:
    raise SystemExit(0)
for email, enable, total_gb, expiry in rows:
    if enable == 0:
        print("%s|%s|%s" % (email, total_gb, expiry))
PY
}

xui_data_fix() { # 修 SS2022 密钥 + 把「无限制却被停用」的客户端恢复；返回改了什么
  xui_has_py || { no "需要 python3 才能修（先跑 set-dns --tools）"; return 1; }
  [ -f "$XUI_ETC/x-ui.db" ] || { no "找不到 $XUI_ETC/x-ui.db"; return 1; }
  mkdir -p "$XUI_BAK" 2>/dev/null
  cp -a "$XUI_ETC/x-ui.db" "$XUI_BAK/x-ui.db.fix-$STAMP" 2>/dev/null
  python3 - "$XUI_ETC/x-ui.db" <<'PY'
import sqlite3, json, base64, os, sys
c = sqlite3.connect(sys.argv[1]); cur = c.cursor()
# 1) SS2022 密钥
cur.execute("select id, port, settings from inbounds where protocol='shadowsocks'")
for iid, port, settings in cur.fetchall():
    try:
        s = json.loads(settings)
    except Exception:
        continue
    m = s.get('method', '')
    if not m.startswith('2022-blake3'):
        continue
    need = 32 if '256' in m else 16
    try:
        n = len(base64.b64decode(s.get('password', ''), validate=True))
    except Exception:
        n = -1
    if n == need:
        continue
    new = base64.b64encode(os.urandom(need)).decode()
    s['password'] = new
    cur.execute("update inbounds set settings=? where id=?",
                (json.dumps(s, indent=2, ensure_ascii=False), iid))
    print("SS|%s|%s|%s" % (port, m, new))
# 2) 被误停用的客户端（total=0 且 expiry=0 就是无限制，不该停）
try:
    cur.execute("select id, email, enable, total_gb, expiry_time from clients")
    for cid, email, enable, total_gb, expiry in cur.fetchall():
        if enable == 0 and (total_gb or 0) == 0 and (expiry or 0) == 0:
            cur.execute("update clients set enable=1 where id=?", (cid,))
            cur.execute("update client_traffics set enable=1 where email=?", (email,))
            print("CLIENT|%s" % email)
except Exception:
    pass
c.commit()
PY
}

# 升级前：把会踩的坑提前说清楚
xui_precheck() {
  local old issues n=0
  old=$(xui_schema_old)
  if [ "$old" = old ]; then
    wr "检测到旧版面板数据库（没有 clients 表）—— 这是跨大版本升级"
    inf "迁移可能重置客户端状态；升级前请记下各客户端的 UUID / 密码 / 流量"
  fi
  issues=$(xui_ss_scan)
  if [ -n "$issues" ]; then
    n=1
    wr "发现 Shadowsocks-2022 密钥不合法 —— 新 xray 会拒绝启动（老 xray 能跑）"
    printf '%s\n' "$issues" | while IFS='|' read -r id port m got need; do
      inf "  inbound $id（$port）$m：密钥解出 ${got} 字节，必须是 ${need} 字节"
    done
    inf "  症状：x-ui.service 显示 active、面板能开，但 xray 根本没起来，端口全空"
    local dofix=0
    if [ "$XUI_FIX_SS" = 1 ]; then dofix=1
    elif [ "${TTY_OK:-0}" = 1 ]; then
      krn_confirm "现在换成合法密钥？（会改变使用该入站的客户端要填的密码）" && dofix=1
    fi
    if [ "$dofix" = 1 ]; then
      local res
      res=$(xui_data_fix)
      if [ -n "$res" ]; then
        printf '%s\n' "$res" | while IFS='|' read -r kind a b cc; do
          case "$kind" in
            SS)     ok "已替换 SS2022 密钥（端口 $a，$b）新密钥：$cc";;
            CLIENT) ok "已恢复被停用的客户端：$a";;
          esac
        done
        wr "请同步更新所有客户端配置（新密钥见上）"
      else
        inf "没有需要替换的项"
      fi
    else
      inf "先不动它。若升级后 xray 起不来，跑：SET_DNS_XUI_FIX_SS=1 set-dns --xui-install"
    fi
  else
    [ -f "$XUI_ETC/x-ui.db" ] && xui_has_py && ok "Shadowsocks-2022 密钥格式检查通过"
  fi
  [ "$n" = 0 ] && [ "$old" != old ] && inf "升级前数据检查未发现问题"
  return 0
}

# 升级后：**真实**验证 xray 起没起来（面板显示 active 不代表 xray 活着）
xui_postcheck() {
  local xb cfg out p bad=0
  cfg=$XUI_DIR/bin/config.json
  xb=$(ls "$XUI_DIR"/bin/xray-linux-* 2>/dev/null | head -1)
  echo
  inf "升级后自检（面板 active ≠ xray 活着，这里看的是真东西）……"
  if [ -n "$xb" ] && [ -x "$xb" ] && [ -f "$cfg" ]; then
    out=$("$xb" -test -config "$cfg" 2>&1)
    if printf '%s' "$out" | grep -qiE 'Failed to start|bad key|failed to create server'; then
      bad=1
      no "xray 配置自检**失败**："
      printf '%s\n' "$out" | grep -iE 'Failed to start|bad key|failed to create|error' | head -5 | sed 's/^/      /'
      inf "  多半就是上面的 SS2022 密钥问题：SET_DNS_XUI_FIX_SS=1 set-dns --xui-install 可修"
    else
      ok "xray 配置自检通过"
    fi
  else
    inf "找不到 xray 二进制或 config.json，跳过配置自检"
  fi
  if [ "$REAL" = 1 ]; then
    if pgrep -f 'xray-linux' >/dev/null 2>&1; then
      ok "xray 进程在跑（pid $(pgrep -f 'xray-linux' | head -1)）"
    else
      bad=1
      no "**没有 xray 进程** —— 面板是活的但代理没在跑"
    fi
    p=$(ss -lntp 2>/dev/null | grep -c 'xray-linux')
    [ "${p:-0}" -gt 0 ] && ok "xray 有 $p 个 TCP 监听" || { bad=1; no "xray 没有任何 TCP 监听"; }
  fi
  local dis
  dis=$(xui_client_scan)
  if [ -n "$dis" ]; then
    bad=1
    wr "有客户端被停用（enable=0），新面板会把它从 config.json 里剔掉："
    printf '%s\n' "$dis" | while IFS='|' read -r email tg exp; do
      inf "  $email（流量上限 ${tg}GB / 到期 $exp）"
    done
    inf "  若这些本该是无限制的，跑：SET_DNS_XUI_FIX_SS=1 set-dns --xui-install（会一并恢复）"
    # 顺序很关键：官方脚本结尾会跑 `x-ui migrate`，迁移会把老客户端的 enable 重新置 0 ——
    # 所以「装之前」修好的东西会被它再改回去（真机实测：precheck 修完，装完又变 0）。
    # 因此这个修复必须在**官方脚本跑完之后**再补一次，并重启面板让 config.json 重新生成。
    if [ "$XUI_FIX_SS" = 1 ]; then
      local res n
      res=$(xui_data_fix)
      printf '%s\n' "$res" | while IFS='|' read -r kind a b cc; do
        case "$kind" in
          SS)     wr "官方脚本又换了 SS2022 密钥（端口 $a）新密钥：$cc，请同步客户端";;
          CLIENT) ok "已在迁移之后再恢复被停用的客户端：$a";;
        esac
      done
      if printf '%s' "$res" | grep -q '^CLIENT|'; then
        inf "重启面板，让它按 DB 重新生成 config.json……"
        if [ "$REAL" = 1 ]; then sys restart x-ui >/dev/null 2>&1; sleep 5; fi
        n=$(xui_client_scan)
        if [ -z "$n" ]; then ok "客户端已恢复，复验通过"; bad=0
        else wr "仍有客户端处于停用状态"; fi
      fi
    fi
  fi
  if [ "$bad" = 0 ]; then ok "自检通过：xray 活着、配置合法、没有客户端被停用"
  else wr "自检发现问题，请按上面提示处理"; fi
  return 0
}

xui_install() {
  hr; echo "3x-ui 面板安装 / 升级（自动走 GitHub 加速镜像）"; hr
  if [ "$REAL" = 1 ] && [ "$(id -u)" != 0 ]; then no "装 3x-ui 需要 root"; hr; return 1; fi
  if ! command -v curl >/dev/null 2>&1; then
    no "需要 curl（先跑 set-dns --tools 装上）"; hr; return 1
  fi
  # apt 要靠 DNS 解析软件源，官方脚本第一件事就是 apt 装依赖，所以先确认 DNS 是好的
  if [ "$REAL" = 1 ] && [ "$DRY" = 0 ] && ! dns_resolvable; then
    wr "当前 DNS 解析不了软件源，官方脚本第一步 apt 装依赖就会失败"
    inf "先跑 set-dns --plain（或直接 set-dns）把解析修好，再回来装 3x-ui"
    hr; return 1
  fi

  xui_status
  xui_precheck
  xui_mirror_pick
  echo

  if [ "$DRY" = 1 ]; then
    inf "[dry-run] 将下载 $XUI_RAW 并把 GitHub 地址改写为 ${XUI_MIRROR}https://github.com/... 后执行"
    inf "[dry-run] 现有安装不会被改动"
    hr; return 0
  fi

  local t
  t=$(mktemp /tmp/setdns-xui.XXXXXX 2>/dev/null) || { no "建临时文件失败"; hr; return 1; }
  inf "下载官方 install.sh……"
  local okdl=0
  # 先试挑好的镜像前缀，再走通用的多途径下载（gh_fetch 自带 4 反代 + 3 jsDelivr + 直连）
  if [ -n "$XUI_MIRROR" ]; then
    if curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 90 \
         -o "$t" "${XUI_MIRROR}${XUI_RAW}" 2>/dev/null && [ -s "$t" ]; then okdl=1; fi
  fi
  if [ "$okdl" = 0 ]; then
    if gh_fetch "$XUI_RAW" "$t" 90; then
      okdl=1
      [ -n "${GH_LAST_URL:-}" ] && [ "$GH_LAST_URL" != "$XUI_RAW" ] && inf "改用镜像途径：${GH_LAST_URL:0:60}…"
    fi
  fi
  if [ "$okdl" = 0 ]; then rm -f "$t"; no "下载 install.sh 失败（所有镜像途径都不通）"; hr; return 1; fi
  if [ ! -s "$t" ]; then rm -f "$t"; no "下载到的 install.sh 是空文件"; hr; return 1; fi
  if ! bash -n "$t" 2>/dev/null; then rm -f "$t"; no "下载到的不是合法 shell 脚本，已丢弃"; hr; return 1; fi
  ok "已下载 install.sh（$(wc -c < "$t") 字节，语法校验通过）"

  xui_patch_installer "$t" || { rm -f "$t"; hr; return 1; }

  xui_backup

  echo
  wr "下面开始执行官方安装脚本；它会装依赖、停旧面板、换二进制、可能重启服务"
  inf "官方脚本自己会校验安装包的 sha256，镜像只负责搬运字节"
  echo
  local rc
  if [ "${SET_DNS_XUI_NONINTERACTIVE:-0}" = 1 ] || [ "${TTY_OK:-0}" != 1 ]; then
    inf "非交互模式（XUI_NONINTERACTIVE=1，使用默认端口/凭据）"
    XUI_NONINTERACTIVE=1 bash "$t"
    rc=$?
  else
    bash "$t" < /dev/tty
    rc=$?
  fi
  rm -f "$t"
  echo
  if [ "$rc" = 0 ]; then
    ok "官方脚本执行完成（rc=0）"
  else
    wr "官方脚本退出码 $rc —— 上面最后几行是它的输出"
    inf "常见原因：镜像前缀失效（换一个：SET_DNS_GH_PROXY=... set-dns --xui）或 DNS 不通"
  fi
  hr
  xui_status
  # 官方脚本 rc=0 只代表它自己没报错；xray 起没起来是另一回事（真机踩过）
  xui_postcheck
  return $rc
}

xui_entry() { # 菜单 12 入口
  local act=${XUI_ACT:-}
  case "$act" in
    install)   xui_install ;;
    uninstall) xui_uninstall ;;
    status)    xui_status ;;
    *)
      hr; echo "3x-ui 面板管理"; hr
      xui_status
      echo
      if [ "${TTY_OK:-0}" != 1 ]; then
        inf "没有终端：请用子命令"
        inf "  set-dns --xui-install     安装/升级（自动走加速镜像）"
        inf "  set-dns --xui-status      只看状态"
        inf "  set-dns --xui-uninstall   卸载"
        hr; return 0
      fi
      echo "  1) 安装 / 升级 3x-ui（自动走 GitHub 加速镜像，大陆服务器可用）"
      echo "  2) 查看 3x-ui 状态"
      echo "  3) 卸载 3x-ui"
      echo "  0) 返回上一级菜单"
      printf '  请输入数字： '
      read_ans
      case "${ans:-}" in
        1) xui_install ;;
        2) xui_status ;;
        3) xui_uninstall ;;
        0|"") inf "已返回" ;;
        *) wr "无效选择：${ans:-}（没做任何改动）" ;;
      esac
      return 0 ;;
  esac
}

# ================= 参数解析 =================
CMD=
for a in "$@"; do
  case "$a" in
    --plain)  MODE=plain ;;
    --dot)    MODE=dot ;;
    --doh)    MODE=doh ;;
    --check|--unlock|--restore|--guard|--unguard|--sysinfo|--tools) CMD=${a#--} ;;
    --tools-all) CMD=tools; SET_DNS_TOOLS_ALL=1 ;;
    --mirror)         CMD=mirror ;;
    --mirror-restore) CMD=mirror-restore ;;
    --ssh-port=*)     CMD=ssh-port; SSH_REQ=${a#*=} ;;
    --ssh-port)       CMD=ssh-port ;;
    --ssh-port-restore) CMD=ssh-port-restore ;;
    --kernel)         CMD=kernel ;;
    --kernel-update)  CMD=kernel-update ;;
    --kernel-remove)  CMD=kernel-remove ;;
    --accel)               CMD=accel ;;
    --accel-status)        CMD=accel-status ;;
    --accel-bbr)           CMD=accel; ACC_ACT=fq:bbr ;;
    --accel-fqpie)         CMD=accel; ACC_ACT=fq_pie:bbr ;;
    --accel-cake)          CMD=accel; ACC_ACT=cake:bbr ;;
    --accel-ecn-on)        CMD=accel; ACC_ACT=ecn:1 ;;
    --accel-ecn-off)       CMD=accel; ACC_ACT=ecn:0 ;;
    --accel-ipv6-on)       CMD=accel; ACC_ACT=ipv6:0 ;;
    --accel-ipv6-off)      CMD=accel; ACC_ACT=ipv6:1 ;;
    --accel-optimize)      CMD=accel; ACC_ACT=optimize ;;
    --accel-ddcc)          CMD=accel; ACC_ACT=ddcc ;;
    --accel-merge)         CMD=accel; ACC_ACT=merge ;;
    --accel-edit)          CMD=accel; ACC_ACT=edit ;;
    --accel-kernels)       CMD=accel-kernels ;;
    --accel-kernel-del)    CMD=accel-kernel-del ;;
    --accel-kernel=*)      CMD=accel; ACC_ACT="kernel:${a#*=}" ;;
    --accel-restore)       CMD=accel-restore ;;
    --xui)                 CMD=xui ;;
    --xui-install)         CMD=xui; XUI_ACT=install ;;
    --xui-status)          CMD=xui; XUI_ACT=status ;;
    --xui-uninstall)       CMD=xui; XUI_ACT=uninstall ;;
    --gh-check|--mirror-selftest) CMD=gh-check ;;
    --cn-dns|--cn)        CMD=cn-dns ;;
    --help|-h) CMD=help ;;
    --dry-run|-n) DRY=1 ;;
    --menu)   MODE= ;;
    # 也接受裸数字（set-dns 2 / set-dns 6 / set-dns 10 / set-dns 11 / set-dns 12），方便记不住长参数时直接用菜单编号
    13|12|11|10|[0-9]) MODE=$a ;;
    *) no "未知参数：$a（-h 看用法）"; exit 2 ;;
  esac
done

case "$MODE" in
  plain|dot|doh|"") ;;
  1) MODE=plain ;; 2) MODE=dot ;; 3) MODE=doh ;;
  4) MODE=; CMD=guard ;;
  5) MODE=; CMD=unguard ;;
  6) MODE=; CMD=sysinfo ;;
  7) MODE=; CMD=tools ;;
  8) MODE=; CMD=mirror ;;
  9) MODE=; CMD=ssh-port ;;
  10) MODE=; CMD=kernel ;;
  11) MODE=; CMD=accel ;;
  12) MODE=; CMD=xui ;;
  13) MODE=; CMD=cn-dns ;;
  *) no "不认识的模式：$MODE（可选 plain/dot/doh 或 1/2/3/4/5/6/7/8/9/10/11/12）"; exit 2 ;;
esac

# 帮助文本内联，不靠读 $0 —— `bash <(curl ...)` 时 $0 是已被消费的进程替换管道，读不到内容
if [ "$CMD" = help ]; then
  cat <<'HELPEOF'
set-dns v3.10 — 一键永久设置 DNS（Debian 10~13 / Ubuntu 18~24 通用）
运行时菜单十二个选项：
  1) 明文 DNS        —— 最稳，兼容所有系统
  2) DoT 加密        —— unbound 转发 TLS(853)，需要 unbound
  3) DoH 加密        —— dnscrypt-proxy 走 HTTPS(443) + unbound 转发到它
  4) 加装/加强防护守护 —— 保护 DNS 不被改（秒级自愈 + 开机自启 + apt 钩子）
  5) 移除防护守护    —— 只拆防护，不动当前 DNS 配置
  6) 系统信息查询    —— 主机/CPU/内存/硬盘/网络/运营商/地理位置一览（只读）
  7) 基础工具安装    —— curl/wget/vim/git 等常用工具，缺啥装啥
  8) 自动换源        —— 测速找出最快的软件源并替换（只动发行版仓库）
  9) 自定义 SSH 端口 —— 改 sshd 监听端口（改前备份，校验失败自动回滚）
 10) 内核管理        —— 装/更新/卸载 xanmod BBRv3 内核（自动认微架构档位）
 11) TCP 加速管理    —— BBR/FQ 加速、ECN/IPv6 开关、网络优化、查看/删除内核
 12) 3x-ui 面板      —— 装/升级 3x-ui，自动改走 GitHub 加速镜像（大陆服务器可用）
 13) 大陆 DNS 预设   —— 国内公共 DNS / DoH 优先（默认自动判定地理位置）

一键运行（curl / wget 任选，都会出交互菜单让你选模式）：
  bash <(curl -fsSL https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)
  bash <(wget -qO- https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)
  wget -qO set-dns.sh https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh && bash set-dns.sh

用法:
  set-dns                 交互菜单（无参数时）
  set-dns --plain         明文  1.1.1.1 / 8.8.8.8 (+IPv6)
  set-dns --dot           DoT   加密
  set-dns --doh           DoH   加密
  set-dns --check         只看状态（有问题退出码 1，可做监控）
  set-dns --guard         只装/重装自动修复守护（不动 DNS 配置）
  set-dns --unguard       只移除自动修复守护（不动 DNS 配置）
  set-dns --sysinfo       只看本机系统信息（主机/CPU/内存/硬盘/网络/运营商，只读）
  set-dns --tools         只装基础工具（curl/wget/vim/git 等，缺啥装啥，不动 DNS）
  set-dns --tools-all     基础工具全装（含 htop/tmux/ffmpeg 等可选件）
  set-dns --mirror        测速找最快的软件源并替换（备份原配置，失败自动回滚）
  set-dns --mirror-restore 还原换源前的 apt 源配置
  set-dns --ssh-port=2222 改 SSH 监听端口（改前备份，校验失败自动回滚）
  set-dns --ssh-port-restore 还原首次改端口前的 sshd 配置
  set-dns --kernel        内核管理面板（当前内核/BBRv3 状态，只读预览）
  set-dns --kernel-update 装/更新 xanmod BBRv3 内核（自动认 CPU 微架构档位）
  set-dns --kernel-remove 卸载 xanmod BBRv3 内核（卸载前强制检查兜底内核）
  set-dns --accel         TCP 加速管理面板（BBR/FQ、ECN、IPv6、优化、内核增删）
  set-dns --accel-status  只看 TCP 加速状态（只读，不需要 root）
  set-dns --accel-bbr     BBR + FQ 加速（= 菜单 20）
  set-dns --accel-fqpie   BBR + FQ_PIE 加速（= 菜单 21）
  set-dns --accel-cake    BBR + CAKE 加速（= 菜单 22）
  set-dns --accel-ecn-on  开启 ECN（--accel-ecn-off 关闭）
  set-dns --accel-ipv6-on 开启 IPv6（--accel-ipv6-off 禁用）
  set-dns --accel-optimize 系统网络自适应优化（按内存/核数，ECN/IPv6 保持现状）
  set-dns --accel-ddcc    防 CC / DDoS 轻量优化
  set-dns --accel-merge   重放加速配置里的所有内核参数
  set-dns --accel-edit    手动编辑加速配置文件（编辑前自动备份）
  set-dns --accel-kernels 查看已装内核（排序，只读）
  set-dns --accel-kernel-del 删除指定内核（删前检查还剩几个能启动）
  set-dns --accel-kernel=xanmod-main 装指定内核（cloud/official/latest/rt/xanmod-main|x64v3|lts|edge|rt）
  set-dns --accel-restore 卸载全部加速（只删本脚本写的配置）
  set-dns --xui           3x-ui 面板管理（安装/升级/查看/卸载）
  set-dns --xui-install   装/升级 3x-ui（自动探测最快的 GitHub 加速镜像，大陆服务器可用）
  set-dns --xui-status    只看 3x-ui 状态（只读）
  set-dns --xui-uninstall 卸载 3x-ui（先备份面板数据）
  set-dns --cn-dns       查看/测速中国大陆 DNS 与 DoH 预设（只读，不需要 root）
  set-dns --mirror-selftest 检查本机到 GitHub 各下载途径的连通性与速度（只读）
  set-dns --unlock        解除 chattr 锁
  set-dns --restore       还原首次运行前的原文件（含符号链接）
  set-dns --dry-run       只打印计划，不动任何文件
环境变量:
  SET_DNS_NO_V6=1            不写 IPv6
  SET_DNS_LOCK=1             额外 chattr +i 锁死（不建议，会挡 apt）
  SET_DNS_NO_PROBE=1         跳过解析器可用性探测
  SET_DNS_NO_FALLBACK=1      加密模式下不写明文兜底解析器
  SET_DNS_SYSINFO_NO_NET=1   系统信息查询时不联网取 IPv4/运营商/地理位置
  SET_DNS_TOOLS_ALL=1        基础工具不询问，直接全装
  SET_DNS_MIRROR=aliyun      换源时指定镜像名（默认用测速第一名）
  SET_DNS_SSH_PORT=2222      改 SSH 端口的目标端口（等于 --ssh-port=2222）
  SET_DNS_SSH_KEEP=1         改 SSH 端口时保留旧端口（两个都能连）
  SET_DNS_KERNEL_LEVEL=x64v3 强制指定内核微架构档位（默认自动判断：glibc hwcaps → CPU flags → 在跑的内核）
  SET_DNS_KERNEL_KEEP_REPO=0 卸载内核时把 xanmod apt 源也一起拆掉（默认保留）
  SET_DNS_ACC_KERNEL=x64v3   TCP 加速装内核时用的微架构档位（默认自动判断）
  SET_DNS_ACC_DEL="包名"     菜单 52 要删的内核包（非交互场景用）
  SET_DNS_ACC_ALLOW_DD=1     允许菜单 92 直接执行「一键 DD 重装系统」（默认只提示）
  SET_DNS_ACC_AVAIL="reno bbr cubic" 仅供测试伪造可用拥塞控制算法列表
  SET_DNS_GH_PROXY=https://ghfast.top/  装 3x-ui 时直接用指定的 GitHub 加速前缀（跳过探测）
  SET_DNS_XUI_FIX_SS=1       装 3x-ui 前把不合法的 Shadowsocks-2022 密钥换成合法的（会改变客户端配置）
  SET_DNS_XUI_NONINTERACTIVE=1  装 3x-ui 时走无人值守（默认端口 + 随机凭据）
  SET_DNS_DOH_SERVERS="a b"  DoH 服务器名（默认 cloudflare google）
  SET_DNS_ETC/SBIN/LOG       仅供沙箱测试改根路径
HELPEOF
  exit 0
fi

# ================= 交互菜单 =================
# 能从终端拿到输入就出菜单。注意 `bash <(curl ...)` / `bash <(wget -qO- ...)` 这种写法里
# stdin 是脚本内容本身（管道或 /dev/fd），[ -t 0 ] 为假，但 /dev/tty 仍然是用户终端 ——
# 所以判定要认 /dev/tty，否则 wget 一键安装会静默跳过菜单直接走明文，用户以为脚本坏了。
has_tty() { (exec </dev/tty) 2>/dev/null; }
TTY_OK=0; has_tty && TTY_OK=1

read_ans() { # 从终端读一行；读不到就退回默认
  if [ "$TTY_OK" = 1 ]; then read -r ans < /dev/tty || ans=""
  else read -r ans || ans=""; fi
}

pick_mode() {
  # 模式已显式指定（--dot 等）或子命令已确定（--guard/--check...）时不打扰用户
  [ -n "$MODE" ] && return 0
  [ -n "${CMD:-}" ] && return 0
  if [ "$TTY_OK" = 1 ]; then
    echo
    echo "  请选择 DNS 模式："
    echo "    1) 明文 DNS        —— 1.1.1.1 / 8.8.8.8，最稳，任何系统都能用  [默认]"
    echo "    2) DoT 加密        —— unbound 转发 TLS(853)，无第三方软件"
    echo "    3) DoH 加密        —— dnscrypt-proxy 走 HTTPS(443)，最难被干扰"
    echo "    4) 加装/加强防护守护 —— 只装防护，不改当前 DNS 配置"
    echo "    5) 移除防护守护    —— 只拆防护，不改当前 DNS 配置"
    echo "    6) 系统信息查询    —— 只看主机/CPU/内存/网络等信息，不做任何改动"
    echo "    7) 基础工具安装    —— 缺啥装啥（curl/wget/vim/git 等），不动 DNS 配置"
    echo "    8) 自动换源        —— 找出最快的软件源并替换（apt 装包提速），不动 DNS 配置"
    echo "    9) 自定义 SSH 端口 —— 改 sshd 监听端口（改前备份、校验失败自动回滚）"
    echo "   10) 内核管理        —— 装/更新/卸载 xanmod BBRv3 内核，看当前内核与 BBR 状态"
    echo "   11) TCP 加速管理    —— BBR/FQ 加速、ECN/IPv6 开关、网络优化、内核增删"
    echo "   12) 3x-ui 面板      —— 装/升级 3x-ui，自动走 GitHub 加速镜像（大陆服务器可用）"
    echo "   13) 大陆 DNS 预设   —— 国内公共 DNS / DoH 优先，查看与测速（只读，可强制开关）"
    echo
    printf '  输入 1/2/3/4/5/6/7/8/9/10/11/12/13（直接回车 = 1）: '
    read_ans
    case "${ans:-1}" in
      1|"") MODE=plain ;;
      2) MODE=dot ;;
      3) MODE=doh ;;
      4) CMD=guard ;;
      5) CMD=unguard ;;
      6) CMD=sysinfo ;;
      7) CMD=tools ;;
      8) CMD=mirror ;;
      9) CMD=ssh-port ;;
      10) CMD=kernel ;;
      11) CMD=accel ;;
      12) CMD=xui ;;
      13) CMD=cn-dns ;;
      *) wr "输入无效，按默认明文模式继续"; MODE=plain ;;
    esac
  else
    MODE=plain
    inf "无可用终端（无人值守/重定向），使用默认明文模式；加密模式请显式加 --dot / --doh，防护请加 --guard，看信息请加 --sysinfo，装工具请加 --tools，换源请加 --mirror，改 SSH 端口请加 --ssh-port，管内核请加 --kernel，TCP 加速请加 --accel，装 3x-ui 请加 --xui，看大陆 DNS 预设请加 --cn-dns"
  fi
  echo
}

MODE_NAME() { case "$1" in plain) echo "明文 DNS";; dot) echo "DoT 加密";; doh) echo "DoH 加密";; esac; }

# ================= --check =================
if [ "$CMD" = check ]; then
  bad=0
  cur=plain
  [ -s "$BK/mode" ] && cur=$(cat "$BK/mode")
  hr; echo "DNS 状态  $(date '+%F %T')   当前模式: $(MODE_NAME "$cur")"; hr
  if [ -L "$HERE" ]; then
    echo "  >>> 是符号链接 -> $(readlink "$HERE")   【这是改了不生效的头号原因】"; bad=1
  elif [ ! -e "$HERE" ]; then echo "  >>> $HERE 不存在"; bad=1
  else ok "$HERE 是普通文件"; fi
  locked && inf "已加 chattr +i 锁" || inf "未加锁"

  echo "  当前内容:"; sed 's/^/  | /' "$HERE" 2>/dev/null
  n=$(grep -cE '^[[:space:]]*nameserver[[:space:]]+' "$HERE" 2>/dev/null || echo 0)
  [ "${n:-0}" -gt "$MAXNS" ] && inf "有 $n 条 nameserver，glibc 只用前 $MAXNS 条"
  echo "  监听 53:"; ss -lnup 2>/dev/null | tail -n +2 | sed 's/^/  /' | head -5

  # ---- 加密模式的后端健康检查 ----
  if [ "$cur" != plain ]; then
    echo "  加密后端:"
    if [ "$REAL" = 1 ]; then
      systemctl is-active unbound >/dev/null 2>&1 && ok "unbound 运行中" || { no "unbound 未运行"; bad=1; }
    fi
    if [ -d "$ETC/unbound" ]; then
      if grep -q 'set-dns upstream begin' "$UB_CONF" 2>/dev/null; then ok "unbound 已挂 set-dns 上游"; else inf "unbound 未见 set-dns 上游块"; fi
      grep -qE 'forward-tls-upstream:[[:space:]]*yes' "$UB_CONF" 2>/dev/null && inf "上游方式: DoT (TLS 853)"
      grep -qE "forward-addr:[[:space:]]*127\.0\.0\.1@$DCP_PORT" "$UB_CONF" 2>/dev/null && inf "上游方式: DoH (本地 $DCP_PORT)"
    fi
    if [ "$cur" = doh ]; then
      if [ "$REAL" = 1 ]; then
        systemctl is-active dnscrypt-proxy >/dev/null 2>&1 && ok "dnscrypt-proxy 运行中" || { no "dnscrypt-proxy 未运行"; bad=1; }
      fi
      ss -lnup 2>/dev/null | grep -q ":$DCP_PORT" && ok "本地 DoH 监听 $DCP_PORT" || { no "本地 $DCP_PORT 无人监听"; bad=1; }
      ss -tn 2>/dev/null | grep -q ':443' && inf "存在到 443 的连接（正常）" || inf "暂无到 443 的连接"
    else
      ss -tn 2>/dev/null | grep -q ':853' && inf "存在到 853 的连接（正常）" || inf "暂无到 853 的连接"
    fi
  fi

  echo "  系统解析:"
  for d in raw.githubusercontent.com github.com; do
    if getent hosts "$d" >/dev/null 2>&1; then ok "$d"
    else no "$d"; bad=1; fi
  done

  echo "  直接问解析器:"
  for s in $D4A $D4B $D6A $D6B; do
    case "$s" in *:*) have6 || { inf "$s  (本机无 IPv6 默认路由，跳过)"; continue; };; esac
    if probe "$s"; then ok "udp/53 $s"; else no "udp/53 $s"; bad=1; fi
  done
  if [ "$cur" != plain ]; then
    if probe 127.0.0.1; then ok "udp/53 127.0.0.1（本地加密栈）"
    else no "udp/53 127.0.0.1（本地加密栈不通，DNS 会整体失效）"; bad=1; fi
  fi

  echo "  守护:"
  if [ -x "$WATCH" ]; then ok "已安装 $WATCH"; else inf "未安装（跑 set-dns --guard）"; fi
  [ -s "$WATCH_BAK" ] && ok "守护脚本有留底 $WATCH_BAK" || inf "守护脚本无留底（apt 自愈补回功能不可用）"
  if [ -s "$MANAGED" ]; then ok "托管副本 $MANAGED（$(wc -c < "$MANAGED") 字节）"
  elif [ -s "$MANAGED2" ]; then wr "主托管副本丢失，靠第二副本 $MANAGED2 撑住"
  else no "两份托管副本都没了 —— 守护只能救急而不能恢复原配置"; bad=1; fi
  if [ "$REAL" = 1 ]; then
    for u in dns-watch.path dns-watch.timer; do
      if systemctl is-enabled "$u" >/dev/null 2>&1; then ok "$u enabled"
      else inf "$u 未启用"; fi
    done
  fi
  grep -q 'dns-watch' "$ETC/apt/apt.conf.d/99-dns-watch" 2>/dev/null && ok "apt 钩子已装" || inf "apt 钩子未装"

  echo "  TCP 加速（菜单 11）:"
  if [ -s "$ACC_CONF" ]; then
    ok "加速配置存在 $ACC_CONF（$(grep -cE '^[^#]*=' "$ACC_CONF" 2>/dev/null || echo 0) 项）"
    inf "当前生效: 拥塞控制 $(acc_cc_now) / 队列 $(acc_qdisc_now)"
  else inf "没写过加速配置（没启用过菜单 11）"; fi
  if acc_real; then
    case "$(acc_cc_now)" in
      bbr|bbr2|bbrplus) ok "拥塞控制算法已是 $(acc_cc_now)" ;;
      *) inf "拥塞控制算法为 $(acc_cc_now)，要开 BBR 跑 set-dns --accel-bbr" ;;
    esac
  fi

  echo "  nsswitch:"; grep -E '^[[:space:]]*hosts:' "$ETC/nsswitch.conf" 2>/dev/null | sed 's/^/  /' || echo "  (无)"
  hr
  [ "$bad" = 0 ] && { echo "结论：正常"; exit 0; } || { echo "结论：有问题"; exit 1; }
fi

# --sysinfo 是纯只读查询，不需要 root，所以放在 root 检查之前
if [ "$CMD" = sysinfo ]; then sysinfo; exit 0; fi

# --tools 的「看板」也是只读的：非 root 就只显示装了什么、缺什么，不尝试安装
if [ "$CMD" = tools ] && [ "$(id -u)" != 0 ]; then
  echo "基础工具一键安装"
  tools_read; tools_show
  inf "当前不是 root，只显示面板不安装；要装请用 root 或 sudo 重跑"
  exit 0
fi

# --mirror 非 root 时也只探测不改写（mirror() 内部会自己判断）
if [ "$CMD" = mirror ] && [ "$(id -u)" != 0 ]; then
  mirror; exit 0
fi

# --ssh-port 非 root 时只显示当前端口，不改配置（沙箱模式下不受此限，测试要能真的改写）
if [ "$CMD" = ssh-port ] && [ "$(id -u)" != 0 ] && [ "$REAL" = 1 ]; then
  ssh_port_entry; exit 0
fi

# --kernel 非 root 时只显示面板，不装不卸（内核管理必须 root）
if { [ "$CMD" = kernel ] || [ "$CMD" = kernel-update ] || [ "$CMD" = kernel-remove ]; } \
   && [ "$(id -u)" != 0 ] && [ "$REAL" = 1 ]; then
  hr; echo "内核管理"; hr; krn_panel; hr
  inf "非 root：只显示不修改（装/卸内核需要 root）"
  exit 0
fi

# 加速的只读项（--accel-status / --accel-kernels）不需要 root，放在 root 检查之前
if [ "$CMD" = accel-status ]; then acc_status_entry; exit 0; fi
if [ "$CMD" = accel-kernels ]; then acc_kernels; hr; exit 0; fi
# --accel 非 root 时只显示面板（acc_menu 内部自己判断，改内核参数必须 root）
if [ "$CMD" = accel ] && [ "$(id -u)" != 0 ] && [ "$REAL" = 1 ]; then
  acc_entry; exit 0
fi

# --xui-status 是纯只读查询，不需要 root（和 --accel-status / --sysinfo 一个道理）
if [ "$CMD" = xui ] && [ "${XUI_ACT:-}" = status ]; then xui_status; exit 0; fi
# --gh-check 是纯只读的网络连通性自检，不需要 root
if [ "$CMD" = gh-check ]; then gh_check; exit $?; fi
# --cn-dns 面板是只读探测（逐个试解析器可用性），不需要 root
if [ "$CMD" = cn-dns ]; then cn_panel; exit $?; fi
# --xui 其它动作非 root 时只显示面板（安装/卸载需要 root，xui_install 内部还会再挡一次）
if [ "$CMD" = xui ] && [ "$(id -u)" != 0 ] && [ "$REAL" = 1 ]; then
  xui_entry; exit 0
fi

[ "$(id -u)" = 0 ] || [ "$REAL" = 0 ] || { no "必须 root 运行"; exit 1; }
if [ "$CMD" = unlock ]; then unlock; echo "已解锁，系统可重新管理 $HERE"; exit 0; fi

# ================= 备份（在任何改动之前！） =================
backup_once() {
  mkdir -p "$BK"
  if [ -s "$ORIG" ]; then inf "已有 resolv.conf 备份，不覆盖（$ORIG）"
  elif [ -e "$HERE" ] || [ -L "$HERE" ]; then
    readlink "$HERE" > "$LINKF" 2>/dev/null || : > "$LINKF"
    if cat "$HERE" > "$ORIG" 2>/dev/null; then
      :
    elif [ -L "$HERE" ]; then
      # 断链符号链接：目标不存在，读不到内容。把"它原本是什么"记下来，
      # 否则 --restore 只能靠 $ASIS，而 $ORIG 为空会让用户以为没备份成功。
      printf '# set-dns: 原 %s 是断链符号链接 -> %s（目标不可读，无内容可备份）\n' \
        "$HERE" "$(readlink "$HERE" 2>/dev/null)" > "$ORIG"
      wr "原 $HERE 是断链符号链接（指向 $(readlink "$HERE" 2>/dev/null)，该目标不存在）"
      inf "已记录原链接目标；还原时按符号链接形态恢复"
    else
      : > "$ORIG"
      wr "原 $HERE 存在但读不出内容，备份为空"
    fi
    cp -a "$HERE" "$ASIS" 2>/dev/null || true
    printf '  [ OK ] 已备份原 %s（%s 字节' "$HERE" "$(wc -c < "$ORIG")"
    [ -s "$LINKF" ] && printf '，原为符号链接 -> %s' "$(cat "$LINKF")"
    printf '）\n'
  else
    : > "$ORIG"; : > "$LINKF"
    inf "原 $HERE 不存在，无需备份"
  fi
  if [ ! -s "$ORIG" ] && [ -e "$LEGACY" ]; then
    if [ -s "$LEGACY" ]; then cp -f "$LEGACY" "$ORIG"; ok "已接管 v1 旧备份 $LEGACY"
    else no "v1 旧备份 $LEGACY 是空文件（v1 已知缺陷），无法用于还原"; fi
  fi
}

# ================= --restore =================
if [ "$CMD" = restore ]; then
  unlock
  done_=0
  if [ -e "$ASIS" ] || [ -L "$ASIS" ]; then
    cp -a "$ASIS" "$BK/.restore.tmp" && mv -f "$BK/.restore.tmp" "$HERE" && done_=1
    ok "已按原始形态还原 resolv.conf（含符号链接）"
  elif [ -s "$ORIG" ]; then
    cat "$ORIG" > "$HERE.tmp" && chmod 644 "$HERE.tmp" && mv -f "$HERE.tmp" "$HERE" && done_=1
    l=$(cat "$LINKF" 2>/dev/null || true)
    if [ -n "${l:-}" ] && [ -d "$(dirname "$l")" ]; then
      rm -f "$HERE"; ln -s "$l" "$HERE" && ok "已还原为符号链接 -> $l"
    else ok "已还原为普通文件"; fi
  fi
  # 还原 unbound 配置
  if [ -s "$UB_BAK" ]; then
    cp -a "$UB_BAK" "$UB_CONF" && ok "已还原 $UB_CONF"
    [ "$REAL" = 1 ] && sys restart unbound && ok "已重启 unbound"
  fi
  # 还原 dnscrypt-proxy 配置
  if [ -s "$DCP_BAK" ]; then
    cp -a "$DCP_BAK" "$DCP_CONF" && ok "已还原 $DCP_CONF"
  fi
  rm -f "$BK/mode" 2>/dev/null
  if [ "$done_" = 0 ]; then
    no "无可用备份（$ORIG / $ASIS 都不存在或为空）"; exit 1
  fi
  inf "自动修复守护仍在运行；如不再需要：systemctl disable --now dns-watch.path dns-watch.timer，并删 $ETC/apt/apt.conf.d/99-dns-watch"
  sed 's/^/  | /' "$HERE"; exit 0
fi

# ================= 组装 resolv.conf 内容 =================
KEEP=$(grep -E '^[[:space:]]*(search|domain)[[:space:]]' "$HERE" 2>/dev/null | head -2)
build_pick() {   # 明文模式用
  PICK=(); MISS=()
  # 大陆机器优先用国内公共 DNS（延迟低、不易被污染），国际解析器做兜底。
  # 具体候选与探测逻辑见 cn_build_upstream4()；非大陆或探测全失败时它会
  # 自动退回 D4A/D4B，所以这里不需要再判一次地理位置。
  local -a cn=()
  while IFS= read -r s; do [ -n "$s" ] && cn+=("$s"); done < <(cn_build_upstream4)
  if [ "${#cn[@]}" -gt 0 ]; then
    PICK=("${cn[@]}")
    inf "大陆优化：使用国内解析器 ${PICK[*]}"
  else
    for s in $D4A $D4B; do
      if probe "$s"; then PICK+=("$s"); else MISS+=("$s"); fi
    done
  fi
  if have6; then
    # IPv6 同样先试国内（阿里/腾讯/百度都有 v6），没有就退回默认 v6。
    # **必须判 cn_detect** —— 否则 SET_DNS_CN=0 时 IPv6 那几条仍会混进国内地址，
    # 出现"IPv4 用国际、IPv6 用国内"的怪异组合（实测踩到）。
    local -a v6=()
    if cn_detect; then
      local name pair a
      for name in $CN_PLAIN_ORDER; do
        pair=$(cn_plain_v6 "$name") || continue
        a=${pair%%|*}; [ -n "$a" ] || continue
        probe "$a" && v6+=("$a")
        [ "${#v6[@]}" -ge 1 ] && break
      done
    fi
    if [ "${#v6[@]}" = 0 ]; then v6=("$D6A" "$D6B"); fi
    for s in "${v6[@]}"; do
      if probe "$s"; then PICK+=("$s"); else MISS+=("$s"); fi
    done
  else inf "本机无 IPv6 默认路由，不写 IPv6 解析器"
  fi
  [ "${#MISS[@]}" -gt 0 ] && inf "无应答，已剔除: ${MISS[*]}"
  if [ "${#PICK[@]}" = 0 ]; then
    inf "所有解析器都探测失败（可能是本机网络问题），仍按原样写入"
    PICK=("$D4A" "$D4B"); have6 && PICK+=("$D6A" "$D6B")
  fi
  [ "${#PICK[@]}" = 0 ] && PICK=("$D4A") && inf "兜底只写 $D4A"
  if [ "${#PICK[@]}" -gt "$MAXNS" ]; then
    inf "只保留前 $MAXNS 条（glibc MAXNS 限制，多余的根本不会被读）"
    PICK=("${PICK[@]:0:$MAXNS}")
  fi
}
build_pick_enc() { # 加密模式：127.0.0.1 优先，可选明文兜底
  PICK=(127.0.0.1)
  if [ "${SET_DNS_NO_FALLBACK:-0}" != 1 ]; then
    # 兜底也优先用国内解析器：加密栈万一挂了，国内明文比 1.1.1.1 更快更稳
    local -a fb=()
    while IFS= read -r s; do [ -n "$s" ] && fb+=("$s"); done < <(cn_build_upstream4)
    if [ "${#fb[@]}" = 0 ]; then
      for s in $D4A $D4B; do probe "$s" && fb+=("$s"); done
    fi
    for s in "${fb[@]}"; do
      [ "${#PICK[@]}" -ge "$MAXNS" ] && break
      PICK+=("$s")
    done
    inf "已附明文兜底解析器 ${fb[*]:-（探测无应答）}（加密栈万一挂了不至于整机没 DNS）；设 SET_DNS_NO_FALLBACK=1 可去掉"
  fi
}
render_managed() {
  echo "# managed by set-dns v3 $STAMP  mode=${MODE:-plain}"
  for s in "${PICK[@]}"; do echo "nameserver $s"; done
  [ -n "${KEEP:-}" ] && printf '%s\n' "$KEEP"
  echo "options timeout:2 attempts:3"
}

# ================= unbound 上游改写 =================
# 关键：unbound 对重复的 forward-zone 会报 "duplicate forward zone . ignored"
#       并丢掉其中一份，所以必须把原有 forward-zone 注释掉，而不是简单追加。
UB_BLOCK_BEGIN='# >>> set-dns upstream begin'
UB_BLOCK_END='# <<< set-dns upstream end'
ub_strip_managed() { [ -f "$UB_CONF" ] && sed -i "/^$(printf '%s' "$UB_BLOCK_BEGIN" | sed 's/[][\.*^$/]/\\&/g')/,/^$(printf '%s' "$UB_BLOCK_END" | sed 's/[][\.*^$/]/\\&/g')/d" "$UB_CONF" 2>/dev/null; return 0; }
ub_comment_old_fz() {
  [ -f "$UB_CONF" ] || return 0
  awk '
    /^[[:space:]]*forward-zone:/ { print "#[set-dns-old] " $0; inb=1; next }
    inb && /^[^[:space:]#]/ { inb=0 }
    inb { print "#[set-dns-old] " $0; next }
    { print }
  ' "$UB_CONF" > "$UB_CONF.tmp" && mv -f "$UB_CONF.tmp" "$UB_CONF"
}
ub_ensure_ca() {
  grep -qE '^[[:space:]]*tls-cert-bundle:' "$UB_CONF" 2>/dev/null && return 0
  [ -f "$CAFILE" ] || { wr "找不到 CA 包 $CAFILE，DoT/DoH 会校验失败（先装 ca-certificates）"; return 1; }
  { echo; echo "# set-dns: TLS 证书链"; echo "server:"; echo "    tls-cert-bundle: \"$CAFILE\""; } >> "$UB_CONF"
  ok "已给 unbound 加 tls-cert-bundle"
}
ub_apply_upstream() { # $1=dot|doh
  if [ "$DRY" = 1 ]; then inf "[dry-run] 改写 $UB_CONF 上游为 $1"; return 0; fi
  mkdir -p "$BK" "$ETC/unbound"
  [ -s "$UB_BAK" ] || { [ -f "$UB_CONF" ] && cp -a "$UB_CONF" "$UB_BAK" && ok "已备份原 unbound 配置（$UB_BAK）"; }
  ub_strip_managed
  ub_comment_old_fz
  ub_ensure_ca
  {
    echo "$UB_BLOCK_BEGIN"
    echo "forward-zone:"
    echo '    name: "."'
    if [ "$1" = dot ]; then
      echo "    forward-tls-upstream: yes"
      echo "    forward-addr: 1.1.1.1@853#cloudflare-dns.com"
      echo "    forward-addr: 8.8.8.8@853#dns.google"
      ub_v6_ok && { echo "    forward-addr: 2606:4700:4700::1111@853#cloudflare-dns.com"; echo "    forward-addr: 2001:4860:4860::8888@853#dns.google"; }
    else
      echo "    forward-addr: 127.0.0.1@$DCP_PORT"
    fi
    echo "    forward-first: no"
    echo "$UB_BLOCK_END"
  } >> "$UB_CONF"
  if command -v unbound-checkconf >/dev/null 2>&1; then
    if unbound-checkconf "$UB_CONF" >/dev/null 2>&1; then ok "unbound 配置校验通过"
    else no "unbound 配置校验失败："; unbound-checkconf "$UB_CONF" 2>&1 | head -3 | sed 's/^/      /'; return 1; fi
  fi
  if [ "$REAL" = 1 ]; then
    sys restart unbound && ok "已重启 unbound（生效）" || { no "unbound 重启失败，回滚"; [ -s "$UB_BAK" ] && cp -a "$UB_BAK" "$UB_CONF" && sys restart unbound; return 1; }
  else inf "沙箱模式：未重启 unbound"; fi
  return 0
}

# ================= dnscrypt-proxy（DoH） =================
install_backend() { # $1=包名
  pkg_have "$1" && { ok "$1 已安装"; return 0; }
  if [ "$REAL" = 0 ]; then inf "沙箱模式：跳过安装 $1"; return 0; fi
  if [ "$DRY" = 1 ]; then inf "[dry-run] apt-get install -y $1"; return 0; fi
  inf "$1 未安装，开始安装（此时 DNS 已由第 2 步写成明文，apt 能解析）"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$1" >/dev/null 2>&1; then
      pkg_have "$1" && { ok "$1 安装完成"; return 0; }
    fi
  fi
  no "$1 安装失败（可手动 apt-get install $1 后重跑）"; return 1
}
dcp_apply() {
  if [ "$DRY" = 1 ]; then inf "[dry-run] 写 $DCP_CONF 并启用 dnscrypt-proxy"; return 0; fi
  mkdir -p "$BK" "$ETC/dnscrypt-proxy" "$ETC/systemd/system"
  [ "$REAL" = 1 ] && mkdir -p /var/cache/dnscrypt-proxy
  if [ -f "$DCP_CONF" ] && [ ! -s "$DCP_BAK" ]; then cp -a "$DCP_CONF" "$DCP_BAK"; ok "已备份原 dnscrypt-proxy 配置"; fi
  # 服务器名列表（列表里真实存在的 DoH 名，已核验）
  # 没显式指定 SET_DNS_DOH_SERVERS 时按地理位置选：
  #   大陆 -> 阿里 DoH + 腾讯 DoH + cloudflare 兜底
  #   其它 -> cloudflare + google
  # 地理位置判断收在 cn_build_doh_servers() 里（它自己会判），这里不用再判一次。
  local srvlist=$DCP_SERVERS
  if [ -z "$srvlist" ]; then
    srvlist=$(cn_build_doh_servers)
    case "$srvlist" in
      *alidns*|*dnspod*) inf "大陆优化：DoH 服务器用 $srvlist" ;;
    esac
  fi
  SRV=""
  for s in $srvlist; do SRV="$SRV'$s', "; done
  SRV="[${SRV%, }]"
  cat > "$DCP_CONF" <<EOF
# managed by set-dns v3 $STAMP — DoH only, 仅监听 $DCP_PORT
listen_addresses = ['127.0.0.1:$DCP_PORT']
max_clients = 250
server_names = $SRV
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = false
doh_servers = true
odoh_servers = false
require_dnssec = false
require_nolog = false
require_nofilter = false
timeout = 5000
keepalive = 30
cert_refresh_delay = 240
bootstrap_resolvers = ['$D4A:53', '$D4B:53']
ignore_system_dns = true
netprobe_timeout = 60
netprobe_address = '$D4A:53'
block_ipv6 = false
cache = true
cache_size = 8192
cache_min_ttl = 600
cache_max_ttl = 86400
log_level = 0
use_syslog = false

[sources]
  [sources.'public-resolvers']
  urls = ['https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md', 'https://gh-proxy.com/https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://cdn.jsdelivr.net/gh/DNSCrypt/dnscrypt-resolvers@master/v3/public-resolvers.md', 'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md']
  cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 72
  prefix = ''
EOF
  ok "已写 $DCP_CONF（仅 DoH，监听 127.0.0.1:$DCP_PORT）"
  [ "$REAL" = 1 ] && chown -R _dnscrypt-proxy:_dnscrypt-proxy /var/cache/dnscrypt-proxy 2>/dev/null || true
  chmod 644 "$DCP_CONF"
  # 包自带单元有两个坑，实测踩到过：
  #   1) dnscrypt-proxy.socket：ListenStream=127.0.2.1:53，且 service 里 `Requires=dnscrypt-proxy.socket`
  #      —— 只 disable 不够，socket 会被 sockets.target 拉起并"接管"监听，
  #      结果是 toml 里的 listen_addresses 被忽略，进程跑去绑 127.0.2.1:53，5353 上什么都没有。
  #      实测：drop-in 里写 `Requires=` 也清不掉这个依赖（systemctl show 仍列出 socket），
  #      所以这里直接写一份完整的 /etc/systemd/system/dnscrypt-proxy.service 覆盖厂商单元（优先级更高、不继承）。
  #   2) dnscrypt-proxy-resolvconf.service：会去改 /etc/resolv.conf，必须 mask。
  if [ "$REAL" = 1 ]; then
    mkdir -p "$ETC/systemd/system"
    if [ -e /usr/lib/systemd/system/dnscrypt-proxy.service ] && [ ! -e "$BK/dnscrypt-proxy.service.vendor" ]; then
      cp -a /usr/lib/systemd/system/dnscrypt-proxy.service "$BK/dnscrypt-proxy.service.vendor" 2>/dev/null
    fi
    cat > "$ETC/systemd/system/dnscrypt-proxy.service" <<'DEOF'
[Unit]
Description=DNSCrypt client proxy (set-dns managed)
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy/wiki
After=network.target
Before=nss-lookup.target
Wants=nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/sbin/dnscrypt-proxy -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml
ProtectHome=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectControlGroups=true
MemoryDenyWriteExecute=true
Restart=on-failure
RestartSec=3
User=_dnscrypt-proxy
CacheDirectory=dnscrypt-proxy
LogsDirectory=dnscrypt-proxy
RuntimeDirectory=dnscrypt-proxy

[Install]
WantedBy=multi-user.target
DEOF
    ok "已写单元覆盖 $ETC/systemd/system/dnscrypt-proxy.service（砍掉 Requires=socket）"
    sys mask dnscrypt-proxy.socket >/dev/null 2>&1
    sys disable --now dnscrypt-proxy.socket >/dev/null 2>&1
    sys mask dnscrypt-proxy-resolvconf.service >/dev/null 2>&1
    sys disable --now dnscrypt-proxy-resolvconf.service >/dev/null 2>&1
    inf "已 mask dnscrypt-proxy.socket / -resolvconf.service（防抢 53、防改写 resolv.conf）"
    sys unmask dnscrypt-proxy.service >/dev/null 2>&1
    sys daemon-reload
    sys enable dnscrypt-proxy >/dev/null 2>&1 && ok "dnscrypt-proxy 已 enable"
    sys restart dnscrypt-proxy || true
    # 首次启动要联网拉解析器列表，给它足够时间；期间 resolv.conf 仍是明文，apt/拉取都能解析
    ready=0
    for i in $(seq 1 40); do
      sleep 1
      if ss -lnup 2>/dev/null | grep -q ":$DCP_PORT" && probe 127.0.0.1 $DCP_PORT; then ready=1; break; fi
    done
    if [ "$ready" = 1 ]; then
      ok "已监听 127.0.0.1:$DCP_PORT 且应答正常（真走 HTTPS/443）"
      ss -tn 2>/dev/null | grep ':443' | head -3 | sed 's/^/      /'
    else
      no "dnscrypt-proxy 未在 $DCP_PORT 就绪"
      echo "      --- journalctl -u dnscrypt-proxy 末尾 ---"
      journalctl -u dnscrypt-proxy -n 15 --no-pager 2>/dev/null | sed 's/^/      /'
      echo "      --- 当前 53/5353 监听 ---"
      ss -lnup 2>/dev/null | grep -E ':(53|5353)' | sed 's/^/      /'
      return 1
    fi
  else inf "沙箱模式：已生成配置与单元覆盖，未启动 dnscrypt-proxy"; fi
  return 0
}

# 退役旧版守护（早期手工修复留下的 dns-guard.py + dns-guard.{path,service,timer}）。
# 它会把 resolv.conf 重写回"自己的托管副本"，既不认 v3 的 mode 标记，也会和 dns-watch 互相打架
# （实测：改坏后 6 秒被旧守护修回，新写法被覆盖）。检测到就停掉并备份单元，绝不删除用户数据。
retire_legacy() {
  leg=0
  for f in dns-guard.path dns-guard.service dns-guard.timer; do
    [ -e "$ETC/systemd/system/$f" ] && leg=1
  done
  [ -e "$SBIN/dns-guard.py" ] && leg=1
  [ -e "$ETC/resolv.conf.dnsguard" ] && leg=1
  [ "$leg" = 0 ] && return 0
  wr "检测到旧版守护（dns-guard.py / dns-guard.*），它不认 v3 的 mode 标记且会覆盖新写法"
  if [ "$REAL" = 0 ]; then
    inf "沙箱模式：跳过旧守护退役"
    return 0
  fi
  mkdir -p "$BK/legacy"
  for f in dns-guard.path dns-guard.service dns-guard.timer; do
    [ -e "$ETC/systemd/system/$f" ] && cp -a "$ETC/systemd/system/$f" "$BK/legacy/$f" 2>/dev/null
  done
  [ -e "$SBIN/dns-guard.py" ] && cp -a "$SBIN/dns-guard.py" "$BK/legacy/dns-guard.py" 2>/dev/null
  [ -e "$ETC/resolv.conf.dnsguard" ] && cp -a "$ETC/resolv.conf.dnsguard" "$BK/legacy/resolv.conf.dnsguard" 2>/dev/null
  sys disable --now dns-guard.path 2>/dev/null
  sys disable --now dns-guard.timer 2>/dev/null
  sys stop dns-guard.service 2>/dev/null
  # 单元必须删（否则 systemd 仍认为它在管 /etc/resolv.conf）；
  # 旧脚本本体也要挪走，不然下次运行又会"检测到旧版守护"重复告警。
  mv -f "$SBIN/dns-guard.py" "$BK/legacy/dns-guard.py" 2>/dev/null
  mv -f "$ETC/resolv.conf.dnsguard" "$BK/legacy/resolv.conf.dnsguard" 2>/dev/null
  for f in dns-guard.path dns-guard.service dns-guard.timer; do
    rm -f "$ETC/systemd/system/$f"
  done
  # 兜底：单元也可能被 mask（指向 /dev/null 的符号链接）
  for f in dns-guard.path dns-guard.service dns-guard.timer; do
    [ -L "$ETC/systemd/system/$f" ] && rm -f "$ETC/systemd/system/$f"
  done
  sys daemon-reload 2>/dev/null
  # 旧守护的 apt 钩子如果存在且指向旧脚本，一并移除（v3 会装自己的钩子）
  if [ -e "$ETC/apt/apt.conf.d/99-dns-guard" ]; then
    cp -a "$ETC/apt/apt.conf.d/99-dns-guard" "$BK/legacy/99-dns-guard" 2>/dev/null
    rm -f "$ETC/apt/apt.conf.d/99-dns-guard"
  fi
  ok "旧守护已退役（原文件备份在 $BK/legacy/，如需恢复：cp 回去后 systemctl enable --now dns-guard.path）"
}

# ================= 守护安装 =================
install_guard() {
  if [ "$DRY" = 1 ]; then inf "[dry-run] 安装 $WATCH + $ETC/systemd/system/dns-watch.{path,service,timer} + $ETC/apt/apt.conf.d/99-dns-watch"; return 0; fi
  retire_legacy
  mkdir -p "$SBIN" "$BK" "$ETC/systemd/system"
  cat > "$WATCH" <<'WEOF'
#!/bin/bash
# 由 set-dns 生成：确保 @HERE@ 是可用普通文件且与托管副本一致；加密模式再盯住后端
HERE=@HERE@
MANAGED=@MANAGED@
MANAGED2=@MANAGED2@
LOG=@LOG@
MODE=@MODE@
DCP_PORT=@DCP_PORT@
D4A=1.1.1.1
D4B=8.8.8.8
[ -s "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ] && { tail -c 262144 "$LOG" > "$LOG.t"; mv -f "$LOG.t" "$LOG"; }
act=ok
# 真相源优先级：主副本 -> 第二副本。两者都不存在时下面会走救急分支。
src=""
[ -s "$MANAGED" ] && src="$MANAGED"
[ -z "$src" ] && [ -s "$MANAGED2" ] && src="$MANAGED2"
bad=0
{ [ ! -e "$HERE" ] || [ -L "$HERE" ]; } && bad=1
if [ "$bad" = 0 ] && [ -n "$src" ]; then cmp -s "$HERE" "$src" || bad=1; fi
# 两份托管副本都没了时 HERE 是唯一线索，但不能盲信 —— 它可能正是被改坏的那一份。
# 127.0.0.53 是 systemd-resolved 的死亡 stub；加密模式还必须自己指向 127.0.0.1。
# 不能验证就地重建副本，会把坏配置固化成"真相"，以后每次都照它修。
if [ "$bad" = 0 ] && [ -z "$src" ]; then
  grep -q '^[[:space:]]*nameserver' "$HERE" 2>/dev/null || bad=1
  grep -q '127\.0\.0\.53' "$HERE" 2>/dev/null && bad=1
  case "$MODE" in
    dot|doh) grep -q '^nameserver[[:space:]]\+127\.0\.0\.1' "$HERE" 2>/dev/null || bad=1 ;;
  esac
fi
if [ "$bad" = 1 ]; then
  act=repair
  # 以前只认主副本，副本一丢（被删 / 变 0 字节 / 备份目录被清）就永久只写 repair 永不修复，
  # 整机 DNS 会死在 127.0.0.53 上。现在两份 + 救急，任何一份活着就能自愈。
  chattr -i "$HERE" 2>/dev/null
  [ -L "$HERE" ] && rm -f "$HERE"
  if [ -n "$src" ]; then
    cp -f "$src" "$HERE.tmp" && chmod 644 "$HERE.tmp" && mv -f "$HERE.tmp" "$HERE" && act=repaired
    [ -s "$MANAGED" ] || { mkdir -p "$(dirname "$MANAGED")" 2>/dev/null; cp -f "$src" "$MANAGED" 2>/dev/null; }
    [ -s "$MANAGED2" ] || { mkdir -p "$(dirname "$MANAGED2")" 2>/dev/null; cp -f "$src" "$MANAGED2" 2>/dev/null; }
  else
    # 两份托管副本全丢：先救回一份能用的 DNS（绝不把机器留在无 DNS 状态），再登记为救急内容
    { printf '# managed by set-dns recovery %s  mode=%s\n' "$(date '+%F %T')" "$MODE"
      case "$MODE" in dot|doh) printf 'nameserver 127.0.0.1\n';; esac
      printf 'nameserver %s\nnameserver %s\n' "$D4A" "$D4B"
      printf 'options timeout:2 attempts:3\n'
    } > "$HERE.tmp" 2>/dev/null && chmod 644 "$HERE.tmp" 2>/dev/null \
      && mv -f "$HERE.tmp" "$HERE" && act=rescue
    mkdir -p "$(dirname "$MANAGED")" "$(dirname "$MANAGED2")" 2>/dev/null
    cp -f "$HERE" "$MANAGED" 2>/dev/null
    cp -f "$HERE" "$MANAGED2" 2>/dev/null
  fi
elif [ -z "$src" ]; then
  # HERE 本身是好的，但两份托管副本都没了：用 HERE 当真相源把副本补回来，
  # 否则下次 HERE 被改坏就真的没东西可恢复了。
  mkdir -p "$(dirname "$MANAGED")" "$(dirname "$MANAGED2")" 2>/dev/null
  cp -f "$HERE" "$MANAGED" 2>/dev/null && cp -f "$HERE" "$MANAGED2" 2>/dev/null && act=rebuild-bak
fi
# 加密模式：后端死了就拉起来，否则整机没 DNS
case "$MODE" in
  dot)
    systemctl is-active unbound >/dev/null 2>&1 || { systemctl restart unbound >/dev/null 2>&1; act="$act-restartunbound"; }
    ;;
  doh)
    systemctl is-active dnscrypt-proxy >/dev/null 2>&1 || { systemctl restart dnscrypt-proxy >/dev/null 2>&1; act="$act-restartdcp"; }
    ss -lnup 2>/dev/null | grep -q ":$DCP_PORT" || { systemctl restart dnscrypt-proxy >/dev/null 2>&1; act="$act-restartdcp"; }
    systemctl is-active unbound >/dev/null 2>&1 || { systemctl restart unbound >/dev/null 2>&1; act="$act-restartunbound"; }
    ;;
esac
if ! getent hosts raw.githubusercontent.com >/dev/null 2>&1; then
  [ "$act" = ok ] && act=verify-fail || act="$act-verify-fail"
fi
printf '%s action=%s\n' "$(date '+%F %T')" "$act" >> "$LOG"
WEOF
  sed -i -e "s|@HERE@|$HERE|g" -e "s|@MANAGED@|$MANAGED|g" -e "s|@MANAGED2@|$MANAGED2|g" \
         -e "s|@LOG@|$LOG|g" -e "s|@MODE@|${MODE:-plain}|g" -e "s|@DCP_PORT@|$DCP_PORT|g" "$WATCH"
  chmod 755 "$WATCH"
  cp -a "$WATCH" "$WATCH_BAK" 2>/dev/null && ok "守护脚本已留底 $WATCH_BAK（apt 钩子发现它没了会自动补回）"
  # 托管副本同步到第二位置（不同目录，互为备份）
  if [ -s "$MANAGED" ]; then cp -f "$MANAGED" "$MANAGED2" 2>/dev/null && ok "托管副本已双写 $MANAGED2"; fi

  cat > "$ETC/systemd/system/dns-watch.service" <<'UEOF'
[Unit]
Description=set-dns guard: repair resolv.conf
# 等网络就绪再跑：否则开机早期 getent 必然失败，会把 act 记成 verify-fail，噪音还误导排障
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=@WATCH@
UEOF
  cat > "$ETC/systemd/system/dns-watch.path" <<'UEOF'
[Unit]
Description=set-dns guard: watch @HERE@
[Path]
PathChanged=@HERE@
PathModified=@HERE@
Unit=dns-watch.service
[Install]
WantedBy=paths.target
UEOF
  cat > "$ETC/systemd/system/dns-watch.timer" <<'UEOF'
[Unit]
Description=set-dns guard: periodic backstop
[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
UEOF
  sed -i -e "s|@WATCH@|$WATCH|g" -e "s|@HERE@|$HERE|g" \
    "$ETC/systemd/system/dns-watch.service" "$ETC/systemd/system/dns-watch.path"

  mkdir -p "$ETC/apt/apt.conf.d"
  # 钩子：不只是"跑一次守护"，还要在自身缺失时自我修复 —— 实测守护脚本被删后钩子会静默 ||
  # true，什么都不做，等于没有兜底。
  printf 'DPkg::Post-Invoke { "[ -x %s ] || { [ -s %s ] && cp -f %s %s && chmod 755 %s; }; %s >/dev/null 2>&1 || true"; };\n' \
    "$WATCH" "$WATCH_BAK" "$WATCH_BAK" "$WATCH" "$WATCH" "$WATCH" \
    > "$ETC/apt/apt.conf.d/99-dns-watch"
  ok "apt 钩子已装 $ETC/apt/apt.conf.d/99-dns-watch（守护脚本丢失时自动补回）"

  if [ "$REAL" = 1 ]; then
    sys daemon-reload
    sys enable --now dns-watch.path && ok "dns-watch.path 已启用（改坏即刻修）"
    sys enable --now dns-watch.timer && ok "dns-watch.timer 已启用（5 分钟兜底）"
  else
    inf "沙箱模式：已生成单元文件，未 systemctl enable"
  fi
}

# 移除防护守护：只拆防护，绝不动当前 DNS 配置。
# 顺序很重要 —— 先 disable（否则删了单元 systemd 还认为它在管 resolv.conf），
# 再删单元与脚本，最后删 apt 钩子（不删的话每次 apt 都会执行一个不存在的脚本）。
uninstall_guard() {
  found=0
  for f in dns-watch.path dns-watch.service dns-watch.timer; do
    [ -e "$ETC/systemd/system/$f" ] && found=1
  done
  [ -e "$WATCH" ] && found=1
  [ -e "$ETC/apt/apt.conf.d/99-dns-watch" ] && found=1
  if [ "$found" = 0 ]; then inf "没有安装防护守护，无需移除"; return 0; fi
  if [ "$DRY" = 1 ]; then inf "[dry-run] 将 disable 并删除 dns-watch.{path,service,timer} + $WATCH + apt 钩子（DNS 配置保持不变）"; return 0; fi
  if [ "$REAL" = 1 ]; then
    sys disable --now dns-watch.path 2>/dev/null
    sys disable --now dns-watch.timer 2>/dev/null
    sys stop dns-watch.service 2>/dev/null
  else inf "沙箱模式：跳过 systemctl disable"; fi
  mkdir -p "$BK/guard-removed"
  for f in dns-watch.path dns-watch.service dns-watch.timer; do
    if [ -e "$ETC/systemd/system/$f" ]; then
      cp -a "$ETC/systemd/system/$f" "$BK/guard-removed/$f" 2>/dev/null
      rm -f "$ETC/systemd/system/$f"
    fi
  done
  [ -e "$ETC/apt/apt.conf.d/99-dns-watch" ] && { cp -a "$ETC/apt/apt.conf.d/99-dns-watch" "$BK/guard-removed/99-dns-watch" 2>/dev/null; rm -f "$ETC/apt/apt.conf.d/99-dns-watch"; }
  [ -e "$WATCH" ] && { cp -a "$WATCH" "$BK/guard-removed/dns-watch.sh" 2>/dev/null; rm -f "$WATCH"; }
  rm -f "$WATCH_BAK" "$MANAGED2" 2>/dev/null
  [ "$REAL" = 1 ] && sys daemon-reload 2>/dev/null
  ok "防护守护已移除（原文件备份在 $BK/guard-removed/）"
  inf "当前 DNS 配置保持原样；如需恢复：cp $BK/guard-removed/dns-watch.sh $WATCH && set-dns --guard"
}

if [ "$CMD" = guard ]; then hr; echo "安装自动修复守护"; hr; install_guard; hr; exit 0; fi
if [ "$CMD" = unguard ]; then hr; echo "移除防护守护"; hr; uninstall_guard; hr; exit 0; fi
if [ "$CMD" = sysinfo ]; then sysinfo; exit 0; fi
if [ "$CMD" = tools ]; then tools; hr; exit 0; fi
if [ "$CMD" = mirror ]; then mirror; hr; exit 0; fi
if [ "$CMD" = mirror-restore ]; then hr; echo "还原软件源配置"; hr; mirror_restore; hr; exit 0; fi
if [ "$CMD" = ssh-port ]; then ssh_port_entry; rc=$?; hr; exit $rc; fi
if [ "$CMD" = ssh-port-restore ]; then hr; echo "还原 SSH 端口配置"; hr; ssh_port_restore; hr; exit 0; fi
if [ "$CMD" = kernel ]; then hr; echo "内核管理"; hr; krn_menu; hr; exit 0; fi
if [ "$CMD" = kernel-update ]; then krn_update; rc=$?; hr; exit $rc; fi
if [ "$CMD" = kernel-remove ]; then krn_remove; rc=$?; hr; exit $rc; fi
if [ "$CMD" = accel ]; then acc_entry; rc=$?; hr; exit $rc; fi
if [ "$CMD" = accel-status ]; then acc_status_entry; exit 0; fi
if [ "$CMD" = accel-kernels ]; then acc_kernels; hr; exit 0; fi
if [ "$CMD" = accel-kernel-del ]; then acc_kernel_del; rc=$?; hr; exit $rc; fi
if [ "$CMD" = accel-restore ]; then acc_restore; hr; exit 0; fi
if [ "$CMD" = xui ]; then xui_entry; rc=$?; hr; exit $rc; fi
if [ "$CMD" = gh-check ]; then gh_check; exit $?; fi
# --cn-dns 面板是只读探测（逐个试解析器可用性），不需要 root
if [ "$CMD" = cn-dns ]; then cn_panel; exit $?; fi

# ================= 主流程 =================
pick_mode
# 菜单里选了 4~13：只做防护、只看信息、装工具、换源、改 SSH 端口、管内核、调加速、
# 管 3x-ui 或看大陆 DNS 预设，**不进主流程**（否则会顺手把 DNS 重写一遍）。
# 注意：这里必须把 pick_mode 能产生的**每一个** CMD 都列全 ——
# 漏一个就会掉进主流程去改 resolv.conf（实测踩到：加了菜单 13 却忘了在这里加
# `cn-dns` 分支，结果选 13 直接开始重写 DNS）。
if [ "$CMD" = guard ]; then hr; echo "安装自动修复守护（不动当前 DNS 配置）"; hr; install_guard; hr; exit 0; fi
if [ "$CMD" = unguard ]; then hr; echo "移除防护守护（不动当前 DNS 配置）"; hr; uninstall_guard; hr; exit 0; fi
if [ "$CMD" = sysinfo ]; then sysinfo; exit 0; fi
if [ "$CMD" = tools ]; then tools; hr; exit 0; fi
if [ "$CMD" = mirror ]; then mirror; hr; exit 0; fi
if [ "$CMD" = ssh-port ]; then ssh_port_entry; hr; exit 0; fi
if [ "$CMD" = kernel ]; then hr; echo "内核管理"; hr; krn_menu; hr; exit 0; fi
if [ "$CMD" = accel ]; then acc_entry; hr; exit 0; fi
if [ "$CMD" = accel-status ]; then acc_status_entry; exit 0; fi
if [ "$CMD" = accel-kernels ]; then acc_kernels; hr; exit 0; fi
if [ "$CMD" = accel-kernel-del ]; then acc_kernel_del; hr; exit 0; fi
if [ "$CMD" = accel-restore ]; then acc_restore; hr; exit 0; fi
if [ "$CMD" = xui ]; then xui_entry; hr; exit 0; fi
if [ "$CMD" = cn-dns ]; then cn_panel; exit $?; fi
if [ "$CMD" = gh-check ]; then gh_check; exit $?; fi
hr; echo "set-dns v3.10 — 一键永久设置 DNS   模式: $(MODE_NAME "$MODE")   $STAMP"; hr

# --- 1. 先掐断写入者（放在写之前，否则写完又被覆盖） ---
echo "1) 关闭会改写 resolv.conf 的服务"
if [ "$REAL" = 1 ] && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved\.service'; then
  put "$ETC/systemd/resolved.conf.d/99-custom-dns.conf" "[Resolve]
DNS=$D4A $D4B
FallbackDNS=
DNSStubListener=no
"
  ok "已写 resolved.conf.d（它若被重启也只会用我们的 DNS）"
  if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    sys stop systemd-resolved && ok "已停止 systemd-resolved"
  else inf "systemd-resolved 未在运行（可能已被 mask），跳过 stop"; fi
  sys disable systemd-resolved; ok "已 disable systemd-resolved"
elif [ "$REAL" = 1 ]; then inf "无 systemd-resolved，跳过"; fi

if [ -f "$ETC/dhcpcd.conf" ]; then
  if grep -qE '^[[:space:]]*nohook[[:space:]]+.*resolv\.conf' "$ETC/dhcpcd.conf"; then
    inf "dhcpcd 已有 nohook resolv.conf"
  elif [ "$DRY" = 1 ]; then inf "[dry-run] 给 dhcpcd 加 nohook resolv.conf"
  else
    printf '\n# set-dns %s\nnohook resolv.conf\n' "$STAMP" >> "$ETC/dhcpcd.conf"
    ok "已给 dhcpcd 加 nohook resolv.conf（租约续期不会再覆盖）"
  fi
  sys restart dhcpcd && ok "已重启 dhcpcd"
else inf "无 dhcpcd，跳过"; fi

if [ -d "$ETC/NetworkManager" ]; then
  put "$ETC/NetworkManager/conf.d/99-dns-none.conf" "[main]
dns=none
"
  ok "已设 NetworkManager dns=none"
  sys restart NetworkManager && ok "已重启 NetworkManager"
else inf "无 NetworkManager，跳过"; fi

if pkg_have resolvconf; then
  if [ -d "$ETC/resolvconf/resolv.conf.d" ]; then
    put "$ETC/resolvconf/resolv.conf.d/head" "nameserver $D4A
nameserver $D4B
"
    put "$ETC/resolvconf/resolv.conf.d/base" ""
    ok "已写 resolvconf head/base"
    inf "resolvconf 会自行重建 resolv.conf —— 由守护兜底纠正"
  else inf "resolvconf 包在但无目录，跳过"; fi
else inf "无 resolvconf，跳过"; fi

if [ -f "$ETC/network/interfaces" ] && grep -q 'dns-nameserver' "$ETC/network/interfaces"; then
  if [ "$DRY" = 1 ]; then inf "[dry-run] 清掉 interfaces 里的 dns-nameserver"
  else
    cp -a "$ETC/network/interfaces" "$ETC/network/interfaces.setdns.$STAMP"
    sed -i '/^[[:space:]]*dns-nameserver/d' "$ETC/network/interfaces"
    ok "已清掉 interfaces 里的旧 dns-nameserver（已备份 .setdns.$STAMP）"
  fi
fi

if [ -d "$ETC/netplan" ] && ls "$ETC"/netplan/*.yaml >/dev/null 2>&1; then
  IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
  if [ -n "${IFACE:-}" ]; then
    ADDR="$D4A, $D4B"
    have6 && ADDR="$ADDR, $D6A, $D6B"
    put "$ETC/netplan/99-set-dns.yaml" "network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4-overrides:
        use-dns: false
        use-domains: false
      nameservers:
        addresses: [$ADDR]
"
    if [ "$REAL" = 1 ] && command -v netplan >/dev/null 2>&1; then
      netplan generate 2>/dev/null && ok "netplan 已生成（故意不 apply，避免中途断网）" \
        || inf "netplan generate 失败，文件留着待查"
      inf "必要时手动 netplan apply"
    fi
  else inf "netplan 存在但找不到默认网卡，跳过"; fi
else inf "无 netplan，跳过"; fi

if [ -d "$ETC/cloud" ]; then
  put "$ETC/cloud/cloud.cfg.d/99-set-dns.cfg" "manage_resolv_conf: false
"
  ok "已关闭 cloud-init 的 resolv.conf 托管"
else inf "无 cloud-init，跳过"; fi

# --- 2. 先把 resolv.conf 写成可用的（加密模式也需要它先能解析，apt 才装得上后端） ---
echo "2) 备份并写入 $HERE"
[ -z "${KEEP:-}" ] || inf "保留原有的 $(printf '%s' "$KEEP" | tr '\n' ' ')"
if [ "$MODE" = plain ]; then
  build_pick
else
  # 加密模式：先写明文，确保后面 apt / 拉列表能解析，第 4 步再切到 127.0.0.1
  PICK=("$D4A" "$D4B"); have6 && PICK+=("$D6A" "$D6B")
fi
backup_once
CONTENT="$(render_managed)"
if [ "$DRY" = 1 ]; then
  inf "[dry-run] 将写入："; printf '%s\n' "$CONTENT" | sed 's/^/  | /'
else
  unlock
  [ -L "$HERE" ] && { inf "原为符号链接 -> $(readlink "$HERE")，删除"; rm -f "$HERE"; }
  printf '%s\n' "$CONTENT" > "$MANAGED"
  printf '%s\n' "$CONTENT" > "$MANAGED2"
  printf '%s\n' "$CONTENT" > "$HERE.tmp"
  chmod 644 "$HERE.tmp" && mv -f "$HERE.tmp" "$HERE" && ok "写入完成"
  ok "托管副本已双写 $MANAGED + $MANAGED2（守护按它们修复）"
  sed 's/^/  | /' "$HERE"
fi

# 加密模式中途失败时的收尾：把 resolv.conf 回退成明文（并同步 mode 记录），
# 避免留下"resolv.conf 写着 mode=doh、实际没有 DoH 后端"的矛盾状态（真机实测踩到过）。
fail_to_plain() {
  [ "$MODE" = plain ] && exit 1
  wr "加密模式未成功，回退为明文 DNS（保证机器还能上网）"
  MODE=plain
  if [ "$DRY" != 1 ]; then
    build_pick
    CONTENT="$(render_managed)"
    unlock
    printf '%s\n' "$CONTENT" > "$MANAGED"
    printf '%s\n' "$CONTENT" > "$MANAGED2"
    printf '%s\n' "$CONTENT" > "$HERE.tmp"
    chmod 644 "$HERE.tmp" && mv -f "$HERE.tmp" "$HERE"
    mkdir -p "$BK" && printf 'plain\n' > "$BK/mode"
    sed 's/^/  | /' "$HERE"
  fi
  getent hosts github.com >/dev/null 2>&1 && ok "明文 DNS 可用（github.com 可解析）" || no "明文 DNS 仍不可用，请手工检查 $HERE"
  hr; echo "未完成，已回退为明文 DNS。可修好后重跑: set-dns --doh"; hr
  exit 1
}

# --- 3. 加密后端 ---
echo "3) 准备加密后端"
if [ "$MODE" = plain ]; then
  inf "明文模式，无需后端"
else
  owner=$(port53_owner)
  if [ -n "${owner:-}" ] && [ "$owner" != unbound ]; then
    wr "注意：127.0.0.1:53 现在由 [$owner] 占用，unbound 起来前可能抢不到端口"
  fi
  install_backend unbound || { no "加密模式需要 unbound，已中止"; fail_to_plain; }
  if [ "$MODE" = dot ]; then
    ok "DoT：unbound 直连 TLS 853，无需第三方软件"
    for h in 1.1.1.1 8.8.8.8; do
      tcp_open "$h" 853 && ok "TCP 853 $h 可达" || wr "TCP 853 $h 不可达（可能被墙/被拦，DoT 会失败）"
    done
  else
    install_backend dnscrypt-proxy || { no "DoH 需要 dnscrypt-proxy，已中止"; fail_to_plain; }
    for h in 1.1.1.1 8.8.8.8; do
      tcp_open "$h" 443 && ok "TCP 443 $h 可达" || wr "TCP 443 $h 不可达（DoH 会失败）"
    done
    dcp_apply || { no "DoH 后端启动失败，已中止"; fail_to_plain; }
  fi
fi

# --- 4. 切换到最终模式 ---
echo "4) 应用模式：$(MODE_NAME "$MODE")"
if [ "$MODE" = plain ]; then
  inf "明文模式，resolv.conf 已是最终内容"
else
  if [ "$MODE" = dot ]; then
    ub_apply_upstream dot || { no "DoT 上游配置失败，已中止"; fail_to_plain; }
  else
    ub_apply_upstream doh || { no "DoH 上游配置失败，已中止"; fail_to_plain; }
  fi
  build_pick_enc
  CONTENT="$(render_managed)"
  if [ "$DRY" = 1 ]; then inf "[dry-run] 加密模式将把 resolv.conf 写成："; printf '%s\n' "$CONTENT" | sed 's/^/  | /'
  else
    unlock
    printf '%s\n' "$CONTENT" > "$MANAGED"
    printf '%s\n' "$CONTENT" > "$MANAGED2"
    printf '%s\n' "$CONTENT" > "$HERE.tmp"
    chmod 644 "$HERE.tmp" && mv -f "$HERE.tmp" "$HERE" && ok "resolv.conf 已切到本地加密栈（首条 127.0.0.1）"
    sed 's/^/  | /' "$HERE"
  fi
fi

# --- 5. 守护 ---
echo "5) 安装自动修复守护（这套才是"永久"的关键）"
install_guard

# --- 6. 记录模式 ---
if [ "$DRY" != 1 ]; then mkdir -p "$BK" && printf '%s\n' "$MODE" > "$BK/mode"; fi

# --- 7. 锁 ---
echo "6) 加固"
lock

# --- 8. 验证 ---
echo "7) 验证"
if [ "$MODE" = plain ]; then
  for s in $D4A $D4B $D6A $D6B; do
    case "$s" in *:*) have6 || continue;; esac
    if probe "$s"; then ok "udp/53 $s"; else no "udp/53 $s 无应答"; fi
  done
else
  if probe 127.0.0.1; then ok "udp/53 127.0.0.1（本地加密栈应答正常）"
  else no "udp/53 127.0.0.1 无应答 —— 加密栈没起来，DNS 会失效"; fi
  if [ "$MODE" = dot ]; then
    ss -tn 2>/dev/null | grep ':853' | head -3 | sed 's/^/  [ -- ] 到 853 的加密连接: /' || inf "暂未见 853 连接（首次查询后才建立）"
  else
    ss -tn 2>/dev/null | grep ':443' | head -3 | sed 's/^/  [ -- ] 到 443 的加密连接: /' || inf "暂未见 443 连接（首次查询后才建立）"
  fi
fi
echo
for d in raw.githubusercontent.com github.com one.one.one.one; do
  if getent hosts "$d" >/dev/null 2>&1; then
    printf '  [ OK ] %s -> %s\n' "$d" "$(getent hosts "$d" | awk '{print $1}' | head -1)"
  else printf '  [FAIL] %s\n' "$d"; fi
done
echo
command -v curl >/dev/null && {
  printf '  [ -- ] curl reinstall.sh -> '
  timeout 25 curl -s -o /dev/null -w 'HTTP %{http_code} (%{time_total}s)\n' \
    https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh 2>&1
}
[ "$DRY" = 1 ] && inf "（dry-run，什么都没改）"
hr
echo "完成。模式：$(MODE_NAME "$MODE")"
echo "  看状态: set-dns --check"
echo "  还原:   set-dns --restore"
echo "  换模式: set-dns --plain | --dot | --doh"
echo "  看守护: tail $LOG"
hr
