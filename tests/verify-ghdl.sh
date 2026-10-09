#!/bin/bash
# 单元测：GitHub 下载层（大陆可用）+ 缓存正确性
set -uo pipefail
SRC=set-dns.sh

STUB=$(mktemp -d)
{
  echo 'set -uo pipefail'
  echo 'ETC=/etc'
  echo 'HOME=${HOME:-/root}'
  echo 'ok()  { printf "  [ OK ] %s\n" "$*"; }'
  echo 'no()  { printf "  [FAIL] %s\n" "$*"; }'
  echo 'inf() { printf "  [ -- ] %s\n" "$*"; }'
  echo 'wr()  { printf "  [ !! ] %s\n" "$*"; }'
  sed -n '/^# ================= GitHub 下载（大陆可用）/,/^have6()/p' "$SRC" | sed '$d'
  cat <<'EOF'

PASS=0; FAIL=0
ck(){ if [ "$2" = 1 ]; then PASS=$((PASS+1)); echo "  ok   - $1"; else FAIL=$((FAIL+1)); echo "  FAIL - $1"; fi; }

RAW=https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh
# 本仓库可能是 private（那样匿名取不到），所以"候选生成"这类断言改用**必定公开**的
# 仓库当样本，才能同时适配公开/私有两种部署状态。私有仓库的专属断言放在第 10 段。
PUBRAW=https://raw.githubusercontent.com/mhsanaei/3x-ui/main/install.sh

echo "=== 1. gh_raw_url 候选生成（用公开仓库当样本，两种部署状态都适用） ==="
gh_raw_url "$PUBRAW" > /tmp/ghdl.cand
n=$(wc -l < /tmp/ghdl.cand)
echo "  候选数: $n"
sed 's/^/    /' /tmp/ghdl.cand
# 4 反代 + 直连 = 至少 5 条；jsDelivr 3 条依赖 api.github.com 解析 SHA。
# 未认证额度只有 60/h，很容易打满 —— 打满时缺 jsDelivr 属**预期行为**（不影响下载，
# 还有 4 个反代前缀 + 直连兜底），所以按"候选里实际有没有 jsDelivr"来分支断言，
# 而不是按 dead 标记（标记是本次运行的临时文件，且生成候选时可能还没打满）。
[ "$n" -ge 5 ] && ck "候选数 >= 5（反代+直连）" 1 || ck "候选数 >= 5" 0
if grep -q 'jsdelivr' /tmp/ghdl.cand; then
  [ "$n" -ge 8 ] && ck "候选数 >= 8（含 jsDelivr）" 1 || ck "候选数 >= 8" 0
else
  echo "  [ -- ] API 限流中，jsDelivr 候选缺失属预期（下载仍有反代+直连兜底）"
fi
grep -q '^https://gh-proxy.com/https://raw' /tmp/ghdl.cand && ck "含 gh-proxy.com 前缀形态" 1 || ck "含 gh-proxy.com 前缀形态" 0
if grep -q 'jsdelivr' /tmp/ghdl.cand; then
  grep -q '^https://cdn.jsdelivr.net/gh/mhsanaei/3x-ui@[0-9a-f]\{40\}/install.sh$' /tmp/ghdl.cand \
    && ck "jsDelivr 按 commit SHA 引用（非分支名）" 1 || ck "jsDelivr 按 commit SHA 引用" 0
else
  echo "  [ -- ] API 限流中，跳过 jsDelivr 形态断言"
fi
tail -1 /tmp/ghdl.cand | grep -q '^https://raw.githubusercontent.com/' && ck "直连排最后（兜底）" 1 || ck "直连排最后" 0
out=$(gh_raw_url "https://example.com/x.sh"); [ "$out" = "https://example.com/x.sh" ] && ck "非 raw URL 原样返回" 1 || ck "非 raw URL 原样返回" 0

echo "=== 2. 缓存破坏参数（防「拿回上一版还谎报成功」） ==="
miss=0
while read -r u; do
  case "$u" in
    https://gh-proxy.com/*|https://ghfast.top/*|https://ghproxy.net/*|https://hk.gh-proxy.com/*|https://raw.githubusercontent.com/*)
      case "$u" in *'?_='*) ;; *) miss=$((miss+1)); echo "     缺缓存破坏: $u" ;; esac ;;
  esac
done < /tmp/ghdl.cand
[ "$miss" = 0 ] && ck "反代/直连全部带 ?_= 缓存破坏参数" 1 || ck "反代/直连带缓存破坏参数（缺 $miss 个）" 0
gh_bust "https://a/b" | grep -q '^https://a/b?_=[0-9]*$' && ck "gh_bust 无 query 时用 ?" 1 || ck "gh_bust 无 query 时用 ?" 0
gh_bust "https://a/b?x=1" | grep -q '^https://a/b?x=1&_=[0-9]*$' && ck "gh_bust 已有 query 时用 &" 1 || ck "gh_bust 已有 query 时用 &" 0

echo "=== 3. SHA 解析与缓存（用公开仓库） ==="
# 注意：未认证 api.github.com 只有 60 次/小时，很容易打满（尤其反复跑测试时）。
# 打满后 gh_resolve_sha 会失败并触发熔断 —— 这**不影响下载可用性**（jsDelivr 只是
# 候选之一，还有 4 个反代前缀 + 直连兜底），所以这里在 API 不可用时标记为跳过，
# 而不是报 FAIL（否则测试会因为"额度用尽"这种环境因素长期假红）。
s1=$(gh_resolve_sha mhsanaei/3x-ui main)
if [ -z "$s1" ]; then
  echo "  [ -- ] API 不可用（多半是未认证额度 60/h 用尽），跳过 SHA 相关断言"
  echo "         这不影响下载：候选里还有镜像与直连兜底"
else
  echo "  3x-ui@main -> $s1"
  [ "${#s1}" = 40 ] && ck "解析出 40 位 SHA" 1 || ck "解析出 40 位 SHA" 0
  case "$s1" in *[!0-9a-f]*) ck "SHA 只含十六进制字符" 0 ;; *) ck "SHA 只含十六进制字符" 1 ;; esac
  t0=$(date +%s%N); s2=$(gh_resolve_sha mhsanaei/3x-ui main); t1=$(date +%s%N)
  [ "$s1" = "$s2" ] && ck "两次解析结果一致" 1 || ck "两次解析结果一致" 0
  ms=$(( (t1 - t0) / 1000000 ))
  echo "  第二次耗时 ${ms}ms（命中缓存应 < 200ms）"
  [ "$ms" -lt 500 ] && ck "第二次走缓存（未再打 API，${ms}ms）" 1 || ck "第二次走缓存（${ms}ms）" 0
  gh_resolve_sha mhsanaei/3x-ui no-such-ref-xyz-zzz >/dev/null 2>&1 && ck "不存在的 ref 应失败" 0 || ck "不存在的 ref 应失败" 1
fi

echo "=== 4. 真联网取脚本（公开仓库） ==="
T=$(mktemp /tmp/ghf.XXXXXX)
if gh_fetch "$PUBRAW" "$T" 30; then
  ck "取到内容" 1
  sz=$(wc -c < "$T"); echo "  字节数: $sz"; echo "  途径: $GH_LAST_URL"
  bash -n "$T" 2>/dev/null && ck "取到的脚本语法合法" 1 || ck "取到的脚本语法合法" 0
  # PUBRAW 是 3x-ui 的 install.sh，断言它自己的特征串（不是 set-dns 的版本号）
  grep -q 'MHSanaei/3x-ui' "$T" && ck "取到的是 3x-ui install.sh" 1 || ck "取到的是 3x-ui install.sh" 0
else ck "取到内容" 0; fi
rm -f "$T"

echo "=== 5. 所有途径内容必须与 git HEAD 一致（缓存陈旧会在这里暴露） ==="
EXP=$(curl -fsSL --max-time 25 "$PUBRAW" 2>/dev/null | sha256sum | awk '{print $1}')
echo "  基准（直连公开仓库）: ${EXP:-取不到}"
okc=0; badc=0
while read -r u; do
  f=$(mktemp /tmp/ghc.XXXXXX)
  if curl -fsSL --connect-timeout 8 --max-time 25 -o "$f" "$u" 2>/dev/null && [ -s "$f" ]; then
    h=$(sha256sum "$f" | awk '{print $1}')
    if [ -n "$EXP" ] && [ "$h" = "$EXP" ]; then okc=$((okc+1)); st="OK"
    elif [ -n "$EXP" ]; then badc=$((badc+1)); st="陈旧/不一致"; else st="(无基准)"; fi
  else st="取不到"; fi
  printf '    %-64s %s\n' "${u:0:64}" "$st"
  rm -f "$f"
done < /tmp/ghdl.cand
[ "$badc" = 0 ] && ck "所有可取到的途径都与 git HEAD 逐字节一致（$okc 个）" 1 || ck "内容一致性（$okc 一致 / $badc 陈旧）" 0

echo "=== 6. gh_pick_mirror 探测与置顶 ==="
GH_PREF_KIND=""; GH_PREF_PREFIX=""; GH_PREF_URL=""
if gh_pick_mirror; then
  ck "探测成功" 1
  echo "  kind=$GH_PREF_KIND  prefix=$GH_PREF_PREFIX"
  first=$(gh_raw_url "$RAW" | head -1)
  case "$GH_PREF_KIND" in
    direct)   echo "$first" | grep -q '^https://raw.githubusercontent.com/' && ck "首选已置顶（direct）" 1 || ck "首选已置顶" 0 ;;
    proxy|jsdelivr) echo "$first" | grep -q "^$GH_PREF_PREFIX" && ck "首选已置顶（$GH_PREF_KIND）" 1 || ck "首选已置顶" 0 ;;
  esac
else echo "  [ -- ] 探测失败（多为 API 限流），跳过"; fi

echo "=== 7. SET_DNS_GH_MIRROR 覆盖 ==="
# 同样用子 shell，避免污染后续段落
(GH_MIRRORS_RAW="https://custom.example/"
 gh_pick_mirror 2>&1 | grep -q 'SET_DNS_GH_MIRROR') && ck "覆盖被识别" 1 || ck "覆盖被识别" 0

echo "=== 8. 下载失败必须非 0 ==="
T2=$(mktemp /tmp/ghbad.XXXXXX)
# 注意：这里**临时**把前缀改成无效值来验证"全失败要返回非 0"，
# 但必须用子 shell 包裹，否则会把全局的 GH_PROXY_PREFIXES/GH_JSDELIVR_NODES 改坏，
# 导致后面第 9/10 段（安全断言、混合场景）拿到错误的候选列表而误报。
# 这是初版测试自己的 bug：第 8 段污染全局，第 10 段"公开仓库仍走镜像"就假失败了。
(
  GH_PROXY_PREFIXES="https://invalid.invalid/"
  GH_JSDELIVR_NODES="https://invalid.invalid"
  gh_fetch "https://raw.githubusercontent.com/nonexistent-user-xyz/nope/main/nope.sh" "$T2" 5
) && ck "不存在的仓库应失败" 0 || ck "不存在的仓库应失败" 1
rm -f "$T2" /tmp/ghdl.cand

echo "=== 9. token 绝不能发往第三方镜像（安全红线） ==="
# 背景：初版 gh_curl 写成"只要 GH_TOKEN 存在就无脑加 Authorization 头"，
# 而 gh_fetch 会依次尝试反代镜像 —— 于是 token 被发给了 gh-proxy.com / ghfast.top。
# 用户只要设了 token（CI 里 GH_TOKEN 常常本来就有），就等于把仓库凭据交给代理站。
# 现在按 host 白名单判断，这里逐条断言。
for h in "https://raw.githubusercontent.com/a/b" "https://api.github.com/repos/x/y" \
         "https://github.com/a/b" "https://codeload.github.com/a/b"; do
  gh_host_trusted "$h" && ck "受信: ${h%%/*}//${h#*://}" 1 || ck "受信: $h" 0
done
for h in "https://gh-proxy.com/https://raw.githubusercontent.com/a/b" \
         "https://ghfast.top/https://raw.githubusercontent.com/a/b" \
         "https://ghproxy.net/https://raw.githubusercontent.com/a/b" \
         "https://hk.gh-proxy.com/https://raw.githubusercontent.com/a/b" \
         "https://cdn.jsdelivr.net/gh/a/b@sha/c" \
         "https://evil.example.com/x" \
         "https://github.com.evil.com/x"; do
  gh_host_trusted "$h" && ck "不受信（应为 0）: $h" 0 || ck "不受信: ${h:0:34}" 1
done
# 实际请求头验证：镜像请求不得带 Authorization
probe_auth() { gh_curl -sS -o /dev/null -v --max-time 12 "$1" 2>&1 | grep -qi 'authorization:' && echo yes || echo no; }
[ "$(probe_auth 'https://ghfast.top/https://raw.githubusercontent.com/zhengwuji/set-dns/main/LICENSE')" = no ] \
  && ck "镜像请求不带 Authorization" 1 || ck "镜像请求不带 Authorization" 0
# 只有设了 token 时直连才会带 Authorization；无 token 时不该带（否则反而是 bug）
if [ -n "${GH_TOKEN:-}" ]; then
  [ "$(probe_auth 'https://raw.githubusercontent.com/zhengwuji/set-dns/main/LICENSE')" = yes ] \
    && ck "GitHub 直连带 Authorization" 1 || ck "GitHub 直连带 Authorization" 0
else
  [ "$(probe_auth 'https://raw.githubusercontent.com/zhengwuji/set-dns/main/LICENSE')" = no ] \
    && ck "无 token 时直连不带 Authorization" 1 || ck "无 token 时直连不带 Authorization" 0
fi

echo "=== 10. 私有仓库走直连、公开仓库仍走镜像（混合场景） ==="
# **不能靠 SET_DNS_GH_TOKEN 触发私有分支**：本仓库现在是公开的，gh_url_is_private
# 会如实判成"公开"，私有分支根本不会走到（旧版测试就是这样，一旦仓库转公开就静默失去覆盖）。
# 改用 GH_PRIV_CACHE 打桩 —— gh_url_is_private 第一件事就是查这个缓存文件，
# 直接写进 "key<TAB>1" 即可确定性地把某个仓库钉成私有，与仓库真实可见性无关。
PRIVSTUB=${TMPDIR:-/tmp}/ghdl-priv.$$
priv_key() { printf '%s' "$1" | tr '/:?' '___'; }
printf '%s\t1\n' "$(priv_key "$RAW")" > "$PRIVSTUB"
export GH_PRIV_CACHE=$PRIVSTUB SET_DNS_GH_TOKEN=dummy-token-for-test GH_TOKEN=dummy-token-for-test
PRIV=$(gh_raw_url "$RAW")
npriv=$(printf '%s\n' "$PRIV" | wc -l)
echo "  私有仓库候选数: $npriv"
printf '%s\n' "$PRIV" | sed 's/^/    /'
# 安全红线：**一个第三方都不能有**。允许的只有 GitHub 自己的两个域名。
bad=$(printf '%s\n' "$PRIV" | grep -vcE '^https://(raw\.githubusercontent\.com|api\.github\.com)/' || true)
[ "$bad" = 0 ] && ck "私有仓库候选里没有第三方（token 不外发）" 1 || ck "私有仓库候选里没有第三方" 0
# 私有分支必须同时给出 raw 与 api 两条 GitHub 自有途径
printf '%s\n' "$PRIV" | grep -q '^https://raw\.githubusercontent\.com/' \
  && ck "私有候选含 raw 直连" 1 || ck "私有候选含 raw 直连" 0
printf '%s\n' "$PRIV" | grep -q '^https://api\.github\.com/repos/zhengwuji/set-dns/contents/set-dns\.sh?ref=main' \
  && ck "私有候选含 api.github.com contents 回退" 1 || ck "私有候选含 api contents 回退" 0
# 两条都要带缓存破坏参数。注意参数形状不同：raw 是 `?_=`，api 是 `?ref=main&_=`
# （api 本来就有 query，gh_bust 会正确追加 `&`）—— 所以这里断言的是"含有 _=" 而不是 `?_=`。
missp=0
while read -r u; do case "$u" in *'_='*) ;; *) missp=$((missp+1)); echo "     缺缓存破坏: $u" ;; esac; done <<< "$PRIV"
[ "$missp" = 0 ] && ck "私有候选全部带缓存破坏参数" 1 || ck "私有候选带缓存破坏参数（缺 $missp 个）" 0
# 公开仓库不受私有规则拖累
PUB=$(gh_raw_url "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh")
printf '%s\n' "$PUB" | grep -qE '^https://(gh-proxy|ghfast|ghproxy|hk\.gh-proxy)' \
  && ck "公开仓库仍保留镜像候选（不被私有规则拖累）" 1 || ck "公开仓库仍保留镜像候选" 0
printf '%s\n' "$PUB" | grep -q '^https://api\.github\.com/' \
  && ck "公开仓库不该混入 api contents 候选" 0 || ck "公开仓库不混入 api contents 候选" 1
# 缓存里判成私有的那个仓库之外，其它仓库不该被连带
printf '%s\t1\n' "$(priv_key "$RAW")" > "$PRIVSTUB"
printf '%s\n' "$PUB" | grep -qE '^https://gh-proxy' && ck "私有判定只作用于该仓库本身" 1 || ck "私有判定只作用于该仓库本身" 0

echo "=== 11. gh_api_contents_url 形态（私有回退的构造器） ==="
a=$(gh_api_contents_url "https://raw.githubusercontent.com/u/r/main/dir/f.sh")
[ "$a" = "https://api.github.com/repos/u/r/contents/dir/f.sh?ref=main" ] \
  && ck "raw -> api contents（含子目录路径）" 1 || ck "raw -> api contents（含子目录路径）: 得到 $a" 0
a=$(gh_api_contents_url "https://github.com/u/r/raw/main/f.sh")
[ -z "$a" ] && ck "非 raw URL 不产出 api 候选" 1 || ck "非 raw URL 不产出 api 候选" 0
a=$(gh_api_contents_url "https://raw.githubusercontent.com/u/r")
[ -z "$a" ] && ck "路径不完整时不产出 api 候选" 1 || ck "路径不完整时不产出 api 候选" 0
# 媒体类型头：只在 /contents/ 上加，不能污染 /commits/（否则 SHA 解析拿回非 JSON）
hv=$(gh_curl -sS -o /dev/null -v --max-time 12 'https://api.github.com/repos/zhengwuji/set-dns/contents/LICENSE?ref=main' 2>&1 | grep -ci 'accept: application/vnd.github.raw' || true)
[ "${hv:-0}" -ge 1 ] && ck "contents 请求带 raw 媒体类型头" 1 || ck "contents 请求带 raw 媒体类型头" 0
hc=$(gh_curl -sS -o /dev/null -v --max-time 12 'https://api.github.com/repos/zhengwuji/set-dns/commits/main' 2>&1 | grep -ci 'application/vnd.github.raw' || true)
[ "${hc:-0}" = 0 ] && ck "commits 请求不带 raw 媒体类型头（SHA 解析不被污染）" 1 || ck "commits 请求不带 raw 媒体类型头" 0
unset GH_PRIV_CACHE SET_DNS_GH_TOKEN GH_TOKEN
rm -f "$PRIVSTUB"

echo "=== GH_TEST PASS=$PASS FAIL=$FAIL ==="
EOF
} > "$STUB/t.sh"
bash "$STUB/t.sh" 2>&1
rm -rf "$STUB"
