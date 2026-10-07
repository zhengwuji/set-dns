#!/usr/bin/env bash
# 换源功能的单元测试：不需要 root、不需要联网，任何机器（含 Windows Git-Bash）都能跑。
#
# 思路：换源逻辑全是「文本改写」，所以从 set-dns.sh 里把镜像相关函数抽出来，
# 手工把 ETC / BK 指到一个临时目录，然后喂假的源文件进去，断言改写结果。
# 这样既不用碰真实 /etc/apt，也不受本机网络速度影响（不然跑一次要探测十几个源、结果还不稳定）。
set -u

SRC=${1:-$(cd "$(dirname "$0")/.." && pwd)/set-dns.sh}
[ -f "$SRC" ] || { echo "找不到 $SRC"; exit 2; }

W=${TMPDIR:-/tmp}/mirror-verify.$$
rm -rf "$W"; mkdir -p "$W/apt/sources.list.d" "$W/set-dns.bak"
trap 'rm -rf "$W"' EXIT

# 抽出函数定义。范围：MIRROR_BAK 赋值那行 → mirror() 定义之前。
sed -n '/^MIRROR_BAK=/,/^mirror() {/p' "$SRC" | head -n -1 > "$W/fn.sh"
[ -s "$W/fn.sh" ] || { echo "没能从 $SRC 抽出换源函数（函数名或分隔标记变了？）"; exit 2; }

# 函数依赖的全局与输出助手。BK 必须由 ETC 派生 —— 曾经因为 BK 写死 /etc/set-dns.bak
# 而把测试文件写进真实 /etc（Git-Bash 下真的建了目录），这里保留该教训。
cat > "$W/pre.sh" <<'PEOF'
ETC=${SET_DNS_ETC:-/etc}
BK=$ETC/set-dns.bak
MIRROR_BAK=$BK/mirror
DRY=0; REAL=1; TTY_OK=0
ok(){ :; }; inf(){ :; }; wr(){ :; }
no(){ printf '  [NO] %s\n' "$*"; }
PEOF

export SET_DNS_ETC=$W
# shellcheck disable=SC1090
. "$W/pre.sh"
# shellcheck disable=SC1090
. "$W/fn.sh"
MIRROR_BAK=$BK/mirror
if [ "$BK" != "$W/set-dns.bak" ]; then
  echo "致命：BK=$BK 不在测试目录里，会污染真实系统，中止"; exit 2
fi

PASS=0; FAIL=0
ck() { if [ "$2" = 0 ]; then PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; fi; }

echo "===== M1. 老式 sources.list 改写 ====="
cat > "$W/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free
deb http://security.debian.org/debian-security trixie-security main contrib non-free
deb http://ftp.debian.org/debian trixie-backports main contrib non-free
deb-src http://deb.debian.org/debian trixie main
deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable

# 注释行也不能动
deb http://deb.debian.org/debian trixie-proposed-updates main
EOF
n_before=$(wc -l < "$W/apt/sources.list")
mirror_rewrite_classic "$W/apt/sources.list" "https://mirrors.aliyun.com/debian" "https://mirrors.aliyun.com/debian-security"
O=$(cat "$W/apt/sources.list")
grep -q 'mirrors.aliyun.com/debian trixie main' <<<"$O" && ck "主仓库已换成 aliyun" 0 || ck "主仓库已换成 aliyun" 1
grep -q 'mirrors.aliyun.com/debian trixie-updates' <<<"$O" && ck "trixie-updates 也换" 0 || ck "trixie-updates 也换" 1
grep -q 'mirrors.aliyun.com/debian-security trixie-security' <<<"$O" && ck "security 走安全仓" 0 || ck "security 走安全仓" 1
grep -q 'mirrors.aliyun.com/debian trixie-backports' <<<"$O" && ck "backports 换主仓库" 0 || ck "backports 换主仓库" 1
grep -q '^deb-src https://mirrors.aliyun.com/debian trixie main' <<<"$O" && ck "deb-src 行也换" 0 || ck "deb-src 行也换" 1
grep -q 'download.docker.com/linux/debian trixie stable' <<<"$O" && ck "第三方 docker 源原样保留" 0 || ck "第三方 docker 源原样保留" 1
grep -q 'signed-by=/usr/share/keyrings/docker.gpg' <<<"$O" && ck "docker 的 signed-by 没被破坏" 0 || ck "docker 的 signed-by 没被破坏" 1
grep -q '^\[arch=amd64' <<<"$O" && ck "选项段没被拆成独立行" 1 || ck "选项段没被拆成独立行" 0
grep -q '^# 注释行也不能动' <<<"$O" && ck "注释保留" 0 || ck "注释保留" 1
n=$(grep -c 'deb\.debian\.org\|security\.debian\.org\|ftp\.debian\.org' "$W/apt/sources.list" || true)
[ "${n:-0}" = 0 ] && ck "旧地址已全部清掉（$n 处残留）" 0 || ck "旧地址已全部清掉（$n 处残留）" 1
n=$(wc -l < "$W/apt/sources.list")
[ "$n" = "$n_before" ] && ck "行数不变（$n 行）" 0 || ck "行数不变（改写前 $n_before -> 改写后 $n）" 1

echo
echo "===== M2. 新式 Deb822（debian.sources）改写 ====="
cat > "$W/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
mirror_rewrite_deb822 "$W/apt/sources.list.d/debian.sources" \
  "https://mirrors.tuna.tsinghua.edu.cn/debian" "https://mirrors.tuna.tsinghua.edu.cn/debian-security"
O=$(cat "$W/apt/sources.list.d/debian.sources")
grep -q 'URIs: https://mirrors.tuna.tsinghua.edu.cn/debian$' <<<"$O" && ck "主仓库 URIs 已换" 0 || ck "主仓库 URIs 已换" 1
grep -q 'URIs: https://mirrors.tuna.tsinghua.edu.cn/debian-security' <<<"$O" && ck "安全仓 URIs 已换" 0 || ck "安全仓 URIs 已换" 1
grep -q 'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' <<<"$O" && ck "Signed-By 原样保留（否则 apt 直接失效）" 0 || ck "Signed-By 原样保留" 1
grep -q 'Components: main contrib non-free non-free-firmware' <<<"$O" && ck "Components 原样保留" 0 || ck "Components 原样保留" 1
grep -q 'Suites: trixie-security' <<<"$O" && ck "Suites 原样保留" 0 || ck "Suites 原样保留" 1
grep -q 'Types: deb' <<<"$O" && ck "Types 字段保留" 0 || ck "Types 字段保留" 1
n=$(grep -c 'deb\.debian\.org\|security\.debian\.org' "$W/apt/sources.list.d/debian.sources" || true)
[ "${n:-0}" = 0 ] && ck "旧地址已清掉（$n 处残留）" 0 || ck "旧地址已清掉（$n 处残留）" 1
# deb822 靠空行分段，空行丢了第二个 stanza 会被并进第一段，Signed-By 就串了
blank=$(awk '/^$/{c++} END{print c+0}' "$W/apt/sources.list.d/debian.sources")
[ "$blank" -ge 1 ] && ck "stanza 之间的空行保留（$blank 个）" 0 || ck "stanza 之间的空行保留" 1
# 两个 stanza 的 URIs 必须不同（一个主仓库一个安全仓），串了就等于配置错
u1=$(grep -m1 '^URIs:' "$W/apt/sources.list.d/debian.sources")
u2=$(grep -m2 '^URIs:' "$W/apt/sources.list.d/debian.sources" | tail -1)
[ "$u1" != "$u2" ] && ck "两个 stanza 的 URIs 没被写成同一个" 0 || ck "两个 stanza 的 URIs 没被写成同一个" 1

echo
echo "===== M3. 第三方源文件绝不能被碰 ====="
cat > "$W/apt/sources.list.d/docker.list" <<'EOF'
deb [arch=amd64] https://download.docker.com/linux/debian trixie stable
EOF
cat > "$W/apt/sources.list.d/nodesource.list" <<'EOF'
deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main
EOF
before=$(md5sum "$W/apt/sources.list.d/docker.list" "$W/apt/sources.list.d/nodesource.list" | md5sum)
tg=$(mirror_targets | grep -c 'docker.list\|nodesource.list' || true)
[ "${tg:-0}" = 0 ] && ck "纯第三方源文件不被列入改写目标" 0 || ck "纯第三方源文件不被列入改写目标" 1
after=$(md5sum "$W/apt/sources.list.d/docker.list" "$W/apt/sources.list.d/nodesource.list" | md5sum)
[ "$before" = "$after" ] && ck "第三方源文件内容未变" 0 || ck "第三方源文件内容未变" 1

echo
echo "===== M4. 备份与还原 ====="
mirror_backup "$W/apt/sources.list" "$W/apt/sources.list.d/debian.sources" >/dev/null 2>&1
[ -f "$W/set-dns.bak/mirror/sources.list" ] && ck "备份了 sources.list" 0 || ck "备份了 sources.list" 1
[ -f "$W/set-dns.bak/mirror/debian.sources" ] && ck "备份了 debian.sources" 0 || ck "备份了 debian.sources" 1
[ -s "$W/set-dns.bak/mirror/manifest" ] && ck "写了 manifest（还原靠它）" 0 || ck "写了 manifest（还原靠它）" 1
n=$(wc -l < "$W/set-dns.bak/mirror/manifest")
[ "$n" = 2 ] && ck "manifest 记录了 2 个文件" 0 || ck "manifest 记录了 $n 个文件（应为 2）" 1
# 备份里存的必须是「已换源」的版本（备份发生在改写前，所以这里重新备份一次换源后状态验证还原路径）
echo "deb http://broken.invalid/x trixie main" > "$W/apt/sources.list"
mirror_restore >/dev/null 2>&1
grep -q 'mirrors.aliyun.com' "$W/apt/sources.list" && ck "还原回备份内容" 0 || ck "还原回备份内容" 1
grep -q 'broken.invalid' "$W/apt/sources.list" && ck "坏地址已被覆盖" 1 || ck "坏地址已被覆盖" 0
# 没有备份时必须友好提示而不是报错退出
rm -f "$W/set-dns.bak/mirror/manifest"
mirror_restore >/dev/null 2>&1 && ck "无备份时 --mirror-restore 友好返回 0" 0 || ck "无备份时 --mirror-restore 友好返回 0" 1

echo
echo "===== M5. 发行版主机白名单判定 ====="
for u in http://deb.debian.org/debian https://security.debian.org/debian-security \
         https://archive.ubuntu.com/ubuntu http://ftp.debian.org/debian https://ports.ubuntu.com/ubuntu-ports; do
  is_distro_uri "$u" && r=0 || r=1
  ck "认出发行版仓库: $u" $r
done
for u in https://download.docker.com/linux/debian https://deb.nodesource.com/node_20.x \
         https://packages.microsoft.com/repos/code https://repo.mongodb.org/apt/debian; do
  is_distro_uri "$u" && r=1 || r=0
  ck "第三方源不误判: $u" $r
done
# 候选镜像源的主机会被并进白名单 —— 否则在「已经是镜像源」的机器上重复换源会认不出自己的地址
mirror_load debian >/dev/null 2>&1
is_distro_uri "https://mirrors.aliyun.com/debian" && ck "候选镜像源主机在换源时算发行版仓库" 0 || ck "候选镜像源主机在换源时算发行版仓库" 1

echo
echo "===== M6. 系统与代号识别 ====="
cat > "$W/os-release" <<'EOF'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
ID=debian
VERSION_ID="13"
VERSION_CODENAME=trixie
EOF
ETC="$W"
[ "$(distro_id)" = debian ] && ck "Debian 识别" 0 || ck "Debian 识别（得到 $(distro_id)）" 1
[ "$(distro_codename)" = trixie ] && ck "代号识别 trixie" 0 || ck "代号识别 trixie" 1
[ "$(distro_components)" = "main contrib non-free non-free-firmware" ] && ck "trixie 组件含 non-free-firmware" 0 || ck "trixie 组件: $(distro_components)" 1
cat > "$W/os-release" <<'EOF'
ID=debian
VERSION_ID="11"
VERSION_CODENAME=bullseye
EOF
[ "$(distro_components)" = "main contrib non-free" ] && ck "bullseye 组件不含 non-free-firmware（那是 12 才拆出来的）" 0 || ck "bullseye 组件: $(distro_components)" 1
cat > "$W/os-release" <<'EOF'
ID=ubuntu
VERSION_ID="22.04"
VERSION_CODENAME=jammy
EOF
[ "$(distro_id)" = ubuntu ] && ck "Ubuntu 识别" 0 || ck "Ubuntu 识别" 1
[ "$(distro_components)" = "main restricted universe multiverse" ] && ck "Ubuntu 四组件" 0 || ck "Ubuntu 组件: $(distro_components)" 1
cat > "$W/os-release" <<'EOF'
ID=linuxmint
ID_LIKE="ubuntu debian"
VERSION_CODENAME=vera
EOF
[ "$(distro_id)" = ubuntu ] && ck "ID_LIKE 派生发行版优先认 ubuntu（Mint/Pop!_OS）" 0 || ck "ID_LIKE 识别得到 $(distro_id)" 1
cat > "$W/os-release" <<'EOF'
ID=centos
VERSION_ID="9"
EOF
distro_id >/dev/null 2>&1 && ck "非 Debian 系应被拒绝" 1 || ck "非 Debian 系应被拒绝" 0
rm -f "$W/os-release"
distro_id >/dev/null 2>&1 && ck "没有 os-release 时应被拒绝" 1 || ck "没有 os-release 时应被拒绝" 0

echo
echo "===== M7. 候选表完整性 ====="
mirror_load debian >/dev/null 2>&1
nd=${#M_NAME[@]}
[ "$nd" -ge 5 ] && ck "Debian 候选源 $nd 个（够挑）" 0 || ck "Debian 候选源只有 $nd 个" 1
for nm in official aliyun tuna ustc; do
  printf '%s\n' "${M_NAME[@]}" | grep -qx "$nm" && ck "Debian 候选含 $nm" 0 || ck "Debian 候选含 $nm" 1
done
mirror_load ubuntu >/dev/null 2>&1
nu=${#M_NAME[@]}
[ "$nu" -ge 5 ] && ck "Ubuntu 候选源 $nu 个" 0 || ck "Ubuntu 候选源只有 $nu 个" 1
# 每个候选的主仓库与安全仓都必须非空、且是 http(s) URL，否则写进 sources.list 就是坏的
bad=0
for ((i = 0; i < ${#M_NAME[@]}; i++)); do
  case "${M_BASE[$i]}" in https://*|http://*) ;; *) bad=$((bad + 1)) ;; esac
  case "${M_SEC[$i]}" in https://*|http://*) ;; *) bad=$((bad + 1)) ;; esac
done
[ "$bad" = 0 ] && ck "所有候选的仓库地址都是合法 URL（$bad 个异常）" 0 || ck "所有候选的仓库地址都是合法 URL（$bad 个异常）" 1
# Ubuntu 的安全仓通常与主仓库同域（除 official 外），不该出现 debian-security 这种串台
mirror_load debian >/dev/null 2>&1
bad=0
for ((i = 0; i < ${#M_NAME[@]}; i++)); do
  case "${M_NAME[$i]}" in
    official|cloudflare|leaseweb) ;;   # 这三个安全仓用 security.debian.org，属正常
    *) case "${M_SEC[$i]}" in *debian*) ;; *) bad=$((bad + 1)) ;; esac ;;
  esac
done
[ "$bad" = 0 ] && ck "除官方/Cloudflare/Leaseweb 外，Debian 安全仓都指向自己的 -security" 0 || ck "有 $bad 个候选的安全仓指向了别家" 1

echo
echo "=== MIRROR_DONE PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ] || exit 1
