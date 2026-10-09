#!/bin/bash
# 单元测：GitHub 下载层（大陆可用）
set -uo pipefail
SRC=set-dns.sh

STUB=$(mktemp -d)
{
  echo 'set -uo pipefail'
  echo 'ok()  { printf "  [ OK ] %s\n" "$*"; }'
  echo 'no()  { printf "  [FAIL] %s\n" "$*"; }'
  echo 'inf() { printf "  [ -- ] %s\n" "$*"; }'
  echo 'wr()  { printf "  [ !! ] %s\n" "$*"; }'
  # 抽出 GitHub 下载层（从标题注释到 have6 之前）
  sed -n '/^# ================= GitHub 下载（大陆可用）/,/^have6()/p' "$SRC" | sed '$d'
  cat <<'EOF'

PASS=0; FAIL=0
ck(){ if [ "$2" = 1 ]; then PASS=$((PASS+1)); echo "  ok   - $1"; else FAIL=$((FAIL+1)); echo "  FAIL - $1"; fi; }

echo "=== 1. gh_raw_url 候选生成 ==="
RAW=https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh
n=$(gh_raw_url "$RAW" | wc -l)
echo "  候选数: $n"
gh_raw_url "$RAW" | sed 's/^/    /'
[ "$n" -ge 8 ] && ck "候选数 >= 8（4 反代 + 3 jsDelivr + 直连）" 1 || ck "候选数 >= 8" 0
gh_raw_url "$RAW" | grep -q '^https://gh-proxy.com/https://raw.githubusercontent.com/' && ck "含 gh-proxy.com 前缀形态" 1 || ck "含 gh-proxy.com 前缀形态" 0
gh_raw_url "$RAW" | grep -q '^https://cdn.jsdelivr.net/gh/zhengwuji/set-dns@main/set-dns.sh$' && ck "含 jsDelivr 形态" 1 || ck "含 jsDelivr 形态" 0
gh_raw_url "$RAW" | tail -1 | grep -q '^https://raw.githubusercontent.com/' && ck "直连排最后（兜底）" 1 || ck "直连排最后" 0
# 非 raw URL 原样返回
out=$(gh_raw_url "https://example.com/x.sh")
[ "$out" = "https://example.com/x.sh" ] && ck "非 raw URL 原样返回" 1 || ck "非 raw URL 原样返回" 0

echo "=== 2. gh_fetch 真联网取脚本（大陆可用性） ==="
T=$(mktemp /tmp/ghf.XXXXXX)
if gh_fetch "$RAW" "$T" 30; then
  ck "取到内容" 1
  sz=$(wc -c < "$T")
  echo "  字节数: $sz"
  echo "  实际用的途径: $GH_LAST_URL"
  [ "$sz" -gt 100000 ] && ck "内容大小合理" 1 || ck "内容大小合理" 0
  bash -n "$T" 2>/dev/null && ck "取到的脚本语法合法" 1 || ck "取到的脚本语法合法" 0
  # 内容必须与仓库版本一致（用 LICENSE 做小样本校验更省事，这里比对版本号）
  grep -q 'set-dns v3\.10' "$T" && ck "版本号正确（v3.10）" 1 || ck "版本号正确" 0
else
  ck "取到内容" 0
fi
rm -f "$T"

echo "=== 3. 全部途径内容一致性（sha256 与直连对比） ==="
EXP=$(git show HEAD:set-dns.sh 2>/dev/null | sha256sum | awk '{print $1}')
echo "  期望（git HEAD）: ${EXP:-取不到}"
okc=0; badc=0
for u in $(gh_raw_url "$RAW"); do
  f=$(mktemp /tmp/ghc.XXXXXX)
  if curl -fsSL --connect-timeout 8 --max-time 20 -o "$f" "$u" 2>/dev/null && [ -s "$f" ]; then
    h=$(sha256sum "$f" | awk '{print $1}')
    if [ -n "$EXP" ] && [ "$h" = "$EXP" ]; then okc=$((okc+1)); st="✅"
    elif [ -n "$EXP" ]; then badc=$((badc+1)); st="❌ 不一致"
    else st="(无基准)"; fi
  else st="取不到"; fi
  printf '    %-70s %s\n' "${u:0:70}" "$st"
  rm -f "$f"
done
[ "$badc" = 0 ] && ck "所有可取到的途径内容都与 git 一致（$okc 个）" 1 || ck "内容一致性（$okc 一致 / $badc 不一致）" 0

echo "=== 4. gh_pick_mirror 探测 ==="
GH_PREF_KIND=""; GH_PREF_PREFIX=""; GH_PREF_URL=""
if gh_pick_mirror; then
  ck "探测成功" 1
  echo "  kind=$GH_PREF_KIND  prefix=$GH_PREF_PREFIX"
  [ -n "${GH_PREF_KIND:-}" ] && ck "记录了途径类型" 1 || ck "记录了途径类型" 0
  # 探测出首选后，gh_raw_url 必须把它排第一
  first=$(gh_raw_url "$RAW" | head -1)
  echo "  首选后第一个候选: ${first:0:70}"
  case "$GH_PREF_KIND" in
    direct)   echo "$first" | grep -q '^https://raw.githubusercontent.com/' && ck "首选已置顶（direct）" 1 || ck "首选已置顶" 0 ;;
    proxy)    echo "$first" | grep -q "^$GH_PREF_PREFIX" && ck "首选已置顶（proxy）" 1 || ck "首选已置顶" 0 ;;
    jsdelivr) echo "$first" | grep -q "^$GH_PREF_PREFIX/gh/" && ck "首选已置顶（jsdelivr）" 1 || ck "首选已置顶" 0 ;;
  esac
else
  ck "探测成功" 0
fi

echo "=== 5. SET_DNS_GH_MIRROR 覆盖 ==="
GH_MIRRORS_RAW="https://custom.example/"
out=$(gh_pick_mirror 2>&1)
echo "$out" | grep -q 'SET_DNS_GH_MIRROR' && ck "覆盖被识别" 1 || ck "覆盖被识别" 0

echo "=== 6. 下载失败必须返回非 0（不静默给空文件） ==="
T2=$(mktemp /tmp/ghbad.XXXXXX)
GH_PROXY_PREFIXES="https://invalid.invalid/"
GH_JSDELIVR_NODES="https://invalid.invalid"
if gh_fetch "https://raw.githubusercontent.com/nonexistent-user-xyz/nope/main/nope.sh" "$T2" 5; then
  ck "不存在的仓库应失败" 0
else
  ck "不存在的仓库应失败" 1
fi
rm -f "$T2"

echo "=== GH_TEST PASS=$PASS FAIL=$FAIL ==="
EOF
} > "$STUB/t.sh"
bash "$STUB/t.sh" 2>&1
rm -rf "$STUB"
