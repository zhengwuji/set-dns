#!/bin/bash
# ============================================================
#  set-dns v3.6 — 一键永久设置 DNS（Debian 10~13 / Ubuntu 18~24 通用）
#    运行时菜单八个选项：
#      1) 明文 DNS      —— 最稳，兼容所有系统
#      2) DoT 加密      —— unbound 转发 TLS(853)，需要 unbound
#      3) DoH 加密      —— dnscrypt-proxy 走 HTTPS(443) + unbound 转发到它
#      4) 加装/加强防护守护 —— 保护 DNS 不被改（秒级自愈 + 开机自启 + apt 钩子）
#      5) 移除防护守护  —— 只拆防护，不动当前 DNS 配置
#      6) 系统信息查询  —— 主机/CPU/内存/硬盘/网络/运营商/地理位置一览
#      7) 基础工具安装  —— curl/wget/vim/git 等常用工具，缺啥装啥
#      8) 自动换源      —— 测速找出最快的软件源并替换（只动发行版仓库，第三方源保留）
#
#  一键运行（curl / wget 任选，都会出交互菜单让你选模式）:
#    bash <(curl -fsSL https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)
#    bash <(wget -qO- https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)
#    wget -qO set-dns.sh https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh && bash set-dns.sh
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
#    SET_DNS_DOH_SERVERS="a b"  DoH 服务器名（默认 cloudflare google）
#    SET_DNS_ETC/SBIN/LOG       仅供沙箱测试改根路径
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
DCP_SERVERS=${SET_DNS_DOH_SERVERS:-"cloudflare google"}
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
    --help|-h) CMD=help ;;
    --dry-run|-n) DRY=1 ;;
    --menu)   MODE= ;;
    # 也接受裸数字（set-dns 2 / set-dns 6），方便记不住长参数时直接用菜单编号
    [0-9])    MODE=$a ;;
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
  *) no "不认识的模式：$MODE（可选 plain/dot/doh 或 1/2/3/4/5/6/7/8）"; exit 2 ;;
esac

# 帮助文本内联，不靠读 $0 —— `bash <(curl ...)` 时 $0 是已被消费的进程替换管道，读不到内容
if [ "$CMD" = help ]; then
  cat <<'HELPEOF'
set-dns v3.6 — 一键永久设置 DNS（Debian 10~13 / Ubuntu 18~24 通用）
运行时菜单八个选项：
  1) 明文 DNS        —— 最稳，兼容所有系统
  2) DoT 加密        —— unbound 转发 TLS(853)，需要 unbound
  3) DoH 加密        —— dnscrypt-proxy 走 HTTPS(443) + unbound 转发到它
  4) 加装/加强防护守护 —— 保护 DNS 不被改（秒级自愈 + 开机自启 + apt 钩子）
  5) 移除防护守护    —— 只拆防护，不动当前 DNS 配置
  6) 系统信息查询    —— 主机/CPU/内存/硬盘/网络/运营商/地理位置一览（只读）
  7) 基础工具安装    —— curl/wget/vim/git 等常用工具，缺啥装啥
  8) 自动换源        —— 测速找出最快的软件源并替换（只动发行版仓库）

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
    echo
    printf '  输入 1/2/3/4/5/6/7/8（直接回车 = 1）: '
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
      *) wr "输入无效，按默认明文模式继续"; MODE=plain ;;
    esac
  else
    MODE=plain
    inf "无可用终端（无人值守/重定向），使用默认明文模式；加密模式请显式加 --dot / --doh，防护请加 --guard，看信息请加 --sysinfo，装工具请加 --tools，换源请加 --mirror"
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

[ "$(id -u)" = 0 ] || { no "必须 root 运行"; exit 1; }

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
  for s in $D4A $D4B; do
    if probe "$s"; then PICK+=("$s"); else MISS+=("$s"); fi
  done
  if have6; then
    for s in $D6A $D6B; do
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
    for s in $D4A $D4B; do
      [ "${#PICK[@]}" -ge "$MAXNS" ] && break
      probe "$s" && PICK+=("$s")
    done
    inf "已附明文兜底解析器（加密栈万一挂了不至于整机没 DNS）；设 SET_DNS_NO_FALLBACK=1 可去掉"
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
  SRV=""
  for s in $DCP_SERVERS; do SRV="$SRV'$s', "; done
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
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
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

# ================= 主流程 =================
pick_mode
# 菜单里选了 4/5/6/7/8：只做防护、只看信息、装工具或换源，不进主流程
# （否则会顺手把 DNS 重写一遍）
if [ "$CMD" = guard ]; then hr; echo "安装自动修复守护（不动当前 DNS 配置）"; hr; install_guard; hr; exit 0; fi
if [ "$CMD" = unguard ]; then hr; echo "移除防护守护（不动当前 DNS 配置）"; hr; uninstall_guard; hr; exit 0; fi
if [ "$CMD" = sysinfo ]; then sysinfo; exit 0; fi
if [ "$CMD" = tools ]; then tools; hr; exit 0; fi
if [ "$CMD" = mirror ]; then mirror; hr; exit 0; fi
hr; echo "set-dns v3.6 — 一键永久设置 DNS   模式: $(MODE_NAME "$MODE")   $STAMP"; hr

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
