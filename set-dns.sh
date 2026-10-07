#!/bin/bash
# ============================================================
#  set-dns v3.0 — 一键永久设置 DNS（Debian 10~13 / Ubuntu 18~24 通用）
#    支持三种模式，运行时菜单选择：
#      1) 明文 DNS   —— 最稳，兼容所有系统
#      2) DoT 加密   —— unbound 转发 TLS(853)，需要 unbound
#      3) DoH 加密   —— dnscrypt-proxy 走 HTTPS(443) + unbound 转发到它
#
#  用法:
#    set-dns                 交互菜单（无参数时）
#    set-dns --plain         明文  1.1.1.1 / 8.8.8.8 (+IPv6)
#    set-dns --dot           DoT   加密
#    set-dns --doh           DoH   加密
#    set-dns --check         只看状态（有问题退出码 1，可做监控）
#    set-dns --guard         只装/重装自动修复守护
#    set-dns --unlock        解除 chattr 锁
#    set-dns --restore       还原首次运行前的原文件（含符号链接）
#    set-dns --dry-run       只打印计划，不动任何文件
#  环境变量:
#    SET_DNS_NO_V6=1            不写 IPv6
#    SET_DNS_LOCK=1             额外 chattr +i 锁死（不建议，会挡 apt）
#    SET_DNS_NO_PROBE=1         跳过解析器可用性探测
#    SET_DNS_NO_FALLBACK=1      加密模式下不写明文兜底解析器
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
WATCH=$SBIN/dns-watch.sh
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

# ================= 参数解析 =================
CMD=
for a in "$@"; do
  case "$a" in
    --plain)  MODE=plain ;;
    --dot)    MODE=dot ;;
    --doh)    MODE=doh ;;
    --check|--unlock|--restore|--guard) CMD=${a#--} ;;
    --help|-h) CMD=help ;;
    --dry-run|-n) DRY=1 ;;
    --menu)   MODE= ;;
    *) no "未知参数：$a（-h 看用法）"; exit 2 ;;
  esac
done

case "$MODE" in
  plain|dot|doh|"") ;;
  1) MODE=plain ;; 2) MODE=dot ;; 3) MODE=doh ;;
  *) no "不认识的模式：$MODE（可选 plain/dot/doh 或 1/2/3）"; exit 2 ;;
esac

if [ "$CMD" = help ]; then sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0; fi

# ================= 交互菜单 =================
pick_mode() {
  [ -n "$MODE" ] && return 0
  if [ -t 0 ] && [ -t 1 ]; then
    echo
    echo "  请选择 DNS 模式："
    echo "    1) 明文 DNS      —— 1.1.1.1 / 8.8.8.8，最稳，任何系统都能用  [默认]"
    echo "    2) DoT 加密      —— unbound 转发 TLS(853)，无第三方软件"
    echo "    3) DoH 加密      —— dnscrypt-proxy 走 HTTPS(443)，最难被干扰"
    echo
    printf '  输入 1/2/3（直接回车 = 1）: '
    read -r ans || ans=1
    case "${ans:-1}" in
      1|"") MODE=plain ;;
      2) MODE=dot ;;
      3) MODE=doh ;;
      *) wr "输入无效，按默认明文模式继续"; MODE=plain ;;
    esac
  else
    MODE=plain
    inf "非交互环境（管道/重定向），使用默认明文模式；加密模式请显式加 --dot / --doh"
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
LOG=@LOG@
MODE=@MODE@
DCP_PORT=@DCP_PORT@
[ -s "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ] && { tail -c 262144 "$LOG" > "$LOG.t"; mv -f "$LOG.t" "$LOG"; }
act=ok
[ -e "$HERE" ] && [ ! -L "$HERE" ] && cmp -s "$HERE" "$MANAGED" || act=repair
if [ "$act" = repair ]; then
  chattr -i "$HERE" 2>/dev/null
  [ -L "$HERE" ] && rm -f "$HERE"
  if [ -s "$MANAGED" ]; then
    cp -f "$MANAGED" "$HERE.tmp" && chmod 644 "$HERE.tmp" && mv -f "$HERE.tmp" "$HERE" && act=repaired
  fi
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
  sed -i -e "s|@HERE@|$HERE|g" -e "s|@MANAGED@|$MANAGED|g" -e "s|@LOG@|$LOG|g" \
         -e "s|@MODE@|${MODE:-plain}|g" -e "s|@DCP_PORT@|$DCP_PORT|g" "$WATCH"
  chmod 755 "$WATCH"

  cat > "$ETC/systemd/system/dns-watch.service" <<'UEOF'
[Unit]
Description=set-dns guard: repair resolv.conf
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
  printf 'DPkg::Post-Invoke { "%s >/dev/null 2>&1 || true"; };\n' "$WATCH" \
    > "$ETC/apt/apt.conf.d/99-dns-watch"
  ok "apt 钩子已装 $ETC/apt/apt.conf.d/99-dns-watch"

  if [ "$REAL" = 1 ]; then
    sys daemon-reload
    sys enable --now dns-watch.path && ok "dns-watch.path 已启用（改坏即刻修）"
    sys enable --now dns-watch.timer && ok "dns-watch.timer 已启用（5 分钟兜底）"
  else
    inf "沙箱模式：已生成单元文件，未 systemctl enable"
  fi
}

if [ "$CMD" = guard ]; then hr; echo "安装自动修复守护"; hr; install_guard; hr; exit 0; fi

# ================= 主流程 =================
pick_mode
hr; echo "set-dns v3.0 — 一键永久设置 DNS   模式: $(MODE_NAME "$MODE")   $STAMP"; hr

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
  printf '%s\n' "$CONTENT" > "$HERE.tmp"
  chmod 644 "$HERE.tmp" && mv -f "$HERE.tmp" "$HERE" && ok "写入完成"
  ok "托管副本已存 $MANAGED（守护按它修复）"
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
