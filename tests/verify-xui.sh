#!/bin/bash
# 本地单元测试：只测 xui_mirror_* 与 xui_patch_installer，不执行任何安装
set -uo pipefail
SRC=${1:-set-dns.sh}
SRC=$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")
cd "$(dirname "$0")/.."

# 把 3x-ui 段函数抽出来，配桩环境跑（同 verify-mirror.sh 的思路）
STUB=$(mktemp -d)
mkdir -p "$STUB/etc"
{
  echo 'set -uo pipefail'
  echo 'ETC='"$STUB"'/etc'
  echo 'SBIN='"$STUB"'/sbin'
  echo 'LOG='"$STUB"'/dns-watch.log'
  echo 'BK=$ETC/set-dns.bak'
  echo 'STAMP=teststamp'
  echo 'REAL=0'
  echo 'DRY=0'
  echo 'ok()  { printf "  [ OK ] %s\n" "$*"; }'
  echo 'no()  { printf "  [FAIL] %s\n" "$*"; }'
  echo 'inf() { printf "  [ -- ] %s\n" "$*"; }'
  echo 'wr()  { printf "  [ !! ] %s\n" "$*"; }'
  echo 'hr()  { printf "%s\n" "---"; }'
  echo 'dns_resolvable() { return 0; }'
  echo 'TTY_OK=0'
  echo 'krn_confirm() { return 1; }'
  # 抽函数：从 "# ================= 3x-ui" 到 "# ================= 参数解析"
  sed -n '/^# ================= 3x-ui 面板安装/,/^# ================= 参数解析/p' "$SRC" | sed '$d'
  cat <<'EOF'

PASS=0; FAIL=0
ck(){ if [ "$2" = 1 ]; then PASS=$((PASS+1)); echo "  ok   - $1"; else FAIL=$((FAIL+1)); echo "  FAIL - $1"; fi; }

echo "=== 1. 镜像可用性判定（真联网） ==="
xui_mirror_raw_ok "https://ghfast.top/" && xui_mirror_latest_ok "https://ghfast.top/" && ck "ghfast.top 全能力" 1 || ck "ghfast.top 全能力" 0
xui_mirror_raw_ok "https://ghproxy.net/" && ck "ghproxy.net 至少 raw 可用" 1 || ck "ghproxy.net 至少 raw 可用" 0
xui_mirror_raw_ok "https://example.invalid/" && ck "无效前缀应判不可用" 0 || ck "无效前缀应判不可用" 1

echo "=== 2. 挑选最快前缀 ==="
XUI_MIRROR=""
xui_mirror_pick > /tmp/xui-pick.out 2>&1; rc=$?
sed 's/^/     /' /tmp/xui-pick.out
[ "$rc" = 0 ] && ck "挑选成功" 1 || ck "挑选成功" 0
[ -n "$XUI_MIRROR" ] && ck "选出了前缀: $XUI_MIRROR" 1 || ck "选出了前缀" 0

echo "=== 3. SET_DNS_GH_PROXY 覆盖 ==="
XUI_MIRROR="https://ghfast.top/"
xui_mirror_pick >/dev/null 2>&1
[ "$XUI_MIRROR" = "https://ghfast.top/" ] && ck "指定前缀被尊重" 1 || ck "指定前缀被尊重" 0

echo "=== 4. 改写逻辑（真实 install.sh） ==="
T=$(mktemp /tmp/xui-test.XXXXXX)
curl -fsSL --max-time 60 -o "$T" https://ghfast.top/https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh 2>/dev/null \
  || curl -fsSL --max-time 60 -o "$T" https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh 2>/dev/null
ck "下载 install.sh" $([ -s "$T" ] && echo 1 || echo 0)
before_gh=$(grep -o 'https://github\.com/' "$T" | wc -l)
before_raw=$(grep -o 'https://raw\.githubusercontent\.com/' "$T" | wc -l)
before_api=$(grep -o 'https://api\.github\.com/' "$T" | wc -l)
echo "     改写前: github.com=$before_gh raw=$before_raw api=$before_api"
XUI_MIRROR="https://ghfast.top/"
xui_patch_installer "$T" && ck "改写后语法校验通过" 1 || ck "改写后语法校验通过" 0
after_pref_gh=$(grep -o 'https://ghfast\.top/https://github\.com/' "$T" | wc -l)
after_plain_gh=$(grep -v 'ghfast\.top' "$T" | grep -c 'https://github\.com/' || true)
after_pref_raw=$(grep -o 'https://ghfast\.top/https://raw\.githubusercontent\.com/' "$T" | wc -l)
after_plain_raw=$(grep -v 'ghfast\.top' "$T" | grep -c 'https://raw\.githubusercontent\.com/' || true)
after_api=$(grep -o 'https://api\.github\.com/' "$T" | wc -l)
echo "     改写后: 裸 github.com=$after_plain_gh 带前缀=$after_pref_gh 裸 raw=$after_plain_raw 带前缀raw=$after_pref_raw api=$after_api"
[ "$after_pref_gh" = "$before_gh" ] && ck "github.com 全部加上前缀（$before_gh 处）" 1 || ck "github.com 全部加上前缀" 0
[ "$after_plain_gh" = 0 ] && ck "github.com 没有漏网的裸地址" 1 || ck "github.com 没有漏网的裸地址" 0
[ "$after_pref_raw" = "$before_raw" ] && ck "raw 全部加上前缀（$before_raw 处）" 1 || ck "raw 全部加上前缀" 0
[ "$after_plain_raw" = 0 ] && ck "raw 没有漏网的裸地址" 1 || ck "raw 没有漏网的裸地址" 0
[ "$after_api" = "$before_api" ] && ck "api.github.com 保持直连（未改写）" 1 || ck "api.github.com 保持直连" 0
# 不应误伤 api.github.com 里的 "github.com/"
grep -q 'ghfast.top/https://api.github.com' "$T" && ck "没有误伤 api.github.com" 0 || ck "没有误伤 api.github.com" 1
# 关键：改写后 url_effective 解析仍能拿到 tag
XUI_MIRROR="https://ghfast.top/"
eff=$(curl -sSLI -o /dev/null -w '%{url_effective}' --max-time 20 "${XUI_MIRROR}https://github.com/MHSanaei/3x-ui/releases/latest" 2>/dev/null)
tag=${eff##*/tag/}
[ "$tag" != "$eff" ] && [ -n "$tag" ] && [ "$tag" != "latest" ] && ck "改写后 tag 解析正常（$tag）" 1 || ck "改写后 tag 解析正常" 0
rm -f "$T"

echo "=== 5. 没有前缀时不改写 ==="
T2=$(mktemp /tmp/xui-test2.XXXXXX)
printf 'a=https://github.com/x/y\nb=https://raw.githubusercontent.com/x/y\n' > "$T2"
XUI_MIRROR=""
xui_patch_installer "$T2" >/dev/null 2>&1
grep -q 'https://github.com/x/y' "$T2" && grep -q 'https://raw.githubusercontent.com/x/y' "$T2" && ck "空前缀 -> 保持原样" 1 || ck "空前缀 -> 保持原样" 0
rm -f "$T2"

echo "=== 6. 非合法脚本必须被丢弃 ==="
T3=$(mktemp /tmp/xui-test3.XXXXXX)
printf 'if then fi (((\nhttps://github.com/x/y\n' > "$T3"
XUI_MIRROR="https://ghfast.top/"
xui_patch_installer "$T3" >/dev/null 2>&1
[ $? -ne 0 ] && ck "非法脚本被拒绝" 1 || ck "非法脚本被拒绝" 0
rm -f "$T3"

echo "=== 7. --xui-status 只读 ==="
out=$(XUI_ACT=status xui_entry 2>&1)
echo "$out" | grep -q '3x-ui 面板状态' && ck "--xui-status 打印状态" 1 || ck "--xui-status 打印状态" 0
echo "$out" | grep -q '未安装' && ck "沙箱里报告未安装" 1 || ck "沙箱里报告未安装" 0

echo "=== 8. 备份与卸载在沙箱里不炸 ==="
mkdir -p "$ETC/x-ui" "$ETC/../usr/local/x-ui/bin"
echo x > "$ETC/x-ui/x-ui.db"
out=$(xui_backup 2>&1); echo "$out" | sed 's/^/     /'
[ -d "$BK/xui" ] && ck "备份目录已建" 1 || ck "备份目录已建" 0
rm -rf "${STUB:-/tmp/nonexistent-stub}"
echo "=== XUI_TEST PASS=$PASS FAIL=$FAIL ==="
EOF
} > "$STUB/t.sh"
bash "$STUB/t.sh" 2>&1
