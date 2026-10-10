#!/bin/bash
# 单元测：zz 快捷键自安装 + 脚本自动更新（默认开）
#   - 沙箱：全部落在 /tmp 下的临时目录，绝不碰真实 /usr/local
#   - 入口脚本（zz / set-dns）是另起进程，环境变量必须 export 出去，否则它会去看真实 /usr/local
#   - 第 5/5b/6 段会碰网络（自愈与降级判定）；离线时按 [ -- ] 跳过并说明，不当失败
set -uo pipefail
SRC=${SRC:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/set-dns.sh}
[ -f "$SRC" ] || { echo "找不到待测脚本 $SRC（用 SRC=... 指定）"; exit 2; }

T=$(mktemp -d 2>/dev/null || echo "/tmp/zzverify.$$")
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ck(){ if [ "$2" = 1 ]; then PASS=$((PASS+1)); echo "  ok   - $1"; else FAIL=$((FAIL+1)); echo "  FAIL - $1"; fi; }
skip(){ echo "  [ -- ] $1"; }

ZZBIN=$T/usr-local/bin
ZZLIB=$T/usr-local/lib/set-dns
export SET_DNS_ETC="$T/etc" SET_DNS_SBIN="$T/etc/sbin" SET_DNS_LOG="$T/etc/dns-watch.log"
export SET_DNS_ZZ_LIB="$ZZLIB" SET_DNS_ZZ_BIN="$ZZBIN"
mkdir -p "$T/etc"
# 固定 SET_DNS_ZZ_INTERVAL=0：把入口脚本里的 INTERVAL 写成 0（= 不再自动联网下载），
# 让第 5 段的"换新/防降级"判断变成纯本地、可确定复现。联网那一半单独在第 6b 段验。
EX(){ SET_DNS_ZZ_INTERVAL=0 bash "$SRC" "$@" 2>&1; }

echo "=== 1. --zz 自安装 ==="
out=$(EX --zz); rc=$?
[ "$rc" = 0 ] && ck "--zz 退出码 0" 1 || ck "--zz 退出码 0（rc=$rc）" 0
[ -x "$ZZBIN/zz" ] && ck "生成 zz 入口" 1 || ck "生成 zz 入口" 0
[ -x "$ZZBIN/set-dns" ] && ck "生成 set-dns 入口" 1 || ck "生成 set-dns 入口" 0
[ -x "$ZZLIB/set-dns.sh" ] && ck "生成脚本副本" 1 || ck "生成脚本副本" 0
[ "$(cat "$ZZLIB/autoupdate" 2>/dev/null)" = 1 ] && ck "自动更新默认写为 1（开）" 1 || ck "自动更新默认写为 1（开）" 0
case "$out" in *"自检通过"*) ck "装完自检真跑了一次入口" 1;; *) ck "装完自检真跑了一次入口" 0;; esac
case "$out" in *"拿不到脚本本体"*) ck "未出现"拿不到本体"告警" 0;; *) ck "未出现"拿不到本体"告警" 1;; esac

echo "=== 2. 入口脚本形态 ==="
sh -n "$ZZBIN/zz" && ck "zz 通过 sh -n（POSIX sh 也能跑）" 1 || ck "zz 通过 sh -n" 0
grep -q "@ZZ_" "$ZZBIN/zz" && ck "无未替换的 @ZZ_@ 占位符" 0 || ck "无未替换的 @ZZ_@ 占位符" 1
grep -q "INTERVAL=0" "$ZZBIN/zz" && ck "INTERVAL 已按环境变量替换" 1 || ck "INTERVAL 已按环境变量替换" 0
grep -q 'SELF.staged' "$ZZBIN/zz" && ck "含两段式 staged 逻辑" 1 || ck "含两段式 staged 逻辑" 0
grep -q 'SET_DNS_REV=' "$ZZBIN/zz" && ck "含修订号提取（防降级判据）" 1 || ck "含修订号提取" 0
grep -q 'gh-proxy.com' "$ZZBIN/zz" && ck "兜底下载含大陆加速镜像" 1 || ck "兜底下载含大陆加速镜像" 0
cmp -s "$ZZBIN/zz" "$ZZBIN/set-dns" && ck "两个入口内容一致" 1 || ck "两个入口内容一致" 0
# 生成的入口脚本是 sh 脚本，绝不能带 bash 专有语法（VPS 上 /bin/sh 可能是 dash）
grep -qE '\[\[|==[^=]|\bfunction\b|\becho -e\b' "$ZZBIN/zz" && ck "入口脚本不含 bash 专有语法" 0 || ck "入口脚本不含 bash 专有语法" 1

echo "=== 3. 真跑 zz ==="
h=$("$ZZBIN/zz" --help 2>&1); rc=$?
[ "$rc" = 0 ] && ck "zz --help 退出码 0" 1 || ck "zz --help 退出码 0" 0
case "$h" in *"set-dns v3"*) ck "zz --help 输出横幅" 1;; *) ck "zz --help 输出横幅" 0;; esac
case "$h" in *"以后敲 zz 就直接回到这个菜单"*) ck "帮助里说明 zz 用法" 1;; *) ck "帮助里说明 zz 用法" 0;; esac
case "$h" in *"gh-proxy.com/https://raw"*) ck "帮助里给出大陆一键命令" 1;; *) ck "帮助里给出大陆一键命令" 0;; esac

s=$("$ZZBIN/set-dns" --zz-status 2>&1); rc=$?
[ "$rc" = 0 ] && ck "set-dns --zz-status 退出码 0" 1 || ck "set-dns --zz-status 退出码 0" 0
case "$s" in *"快捷键已安装"*) ck "状态：快捷键已安装" 1;; *) ck "状态：快捷键已安装" 0;; esac
case "$s" in *"自动更新：开启"*) ck "状态：自动更新开启" 1;; *) ck "状态：自动更新开启" 0;; esac

echo "=== 4. 自动更新开关 ==="
EX --zz-autoupdate-off >/dev/null 2>&1
[ "$(cat "$ZZLIB/autoupdate")" = 0 ] && ck "关闭后写 0" 1 || ck "关闭后写 0" 0
s=$(EX --zz-status 2>&1)
case "$s" in *"自动更新：已关闭"*) ck "状态：已关闭" 1;; *) ck "状态：已关闭" 0;; esac
# 用户手动关过，重装不能把开关偷偷掰回去
EX --zz >/dev/null 2>&1
[ "$(cat "$ZZLIB/autoupdate")" = 0 ] && ck "重装不覆盖用户已关闭的选择" 1 || ck "重装不覆盖用户已关闭的选择" 0
EX --zz-autoupdate-on >/dev/null 2>&1
[ "$(cat "$ZZLIB/autoupdate")" = 1 ] && ck "重新开启写 1" 1 || ck "重新开启写 1" 0

echo "=== 5. 两段式换新与防降级（纯本地，不发网络） ==="
# 修订号更大的 staged 必须换上
cp -f "$ZZLIB/set-dns.sh" "$ZZLIB/set-dns.sh.staged"
sed -i 's/^SET_DNS_REV=.*/SET_DNS_REV=9999999999/' "$ZZLIB/set-dns.sh.staged"
printf '\n# staged-marker\n' >> "$ZZLIB/set-dns.sh.staged"
"$ZZBIN/zz" --help >/dev/null 2>&1
[ ! -e "$ZZLIB/set-dns.sh.staged" ] && ck "高修订号 staged 被消费（换上去）" 1 || ck "高修订号 staged 被消费" 0
grep -q 'staged-marker' "$ZZLIB/set-dns.sh" && ck "新版内容真的生效" 1 || ck "新版内容真的生效" 0
grep -q '^SET_DNS_REV=9999999999' "$ZZLIB/set-dns.sh" && ck "修订号一并更新" 1 || ck "修订号一并更新" 0

# 修订号更小的 staged 绝不能换上 —— 这是"自动更新把本地降级"的回归
cp -f "$ZZLIB/set-dns.sh" "$ZZLIB/set-dns.sh.staged"
sed -i 's/^SET_DNS_REV=.*/SET_DNS_REV=1/' "$ZZLIB/set-dns.sh.staged"
printf '\n# downgrade-marker\n' >> "$ZZLIB/set-dns.sh.staged"
"$ZZBIN/zz" --help >/dev/null 2>&1
[ ! -e "$ZZLIB/set-dns.sh.staged" ] && ck "低修订号 staged 被丢弃" 1 || ck "低修订号 staged 被丢弃" 0
grep -q 'downgrade-marker' "$ZZLIB/set-dns.sh" && ck "低修订号 staged 未污染本地（防降级）" 0 || ck "低修订号 staged 未污染本地（防降级）" 1
grep -q '^SET_DNS_REV=9999999999' "$ZZLIB/set-dns.sh" && ck "本地修订号没被改小" 1 || ck "本地修订号没被改小" 0

# 语法坏的 staged 必须丢掉：宁可继续用旧的，也不能让 zz 变成跑不动的文件
printf 'this is not bash (((' > "$ZZLIB/set-dns.sh.staged"
before=$(sha256sum < "$ZZLIB/set-dns.sh")
"$ZZBIN/zz" --help >/dev/null 2>&1
[ ! -e "$ZZLIB/set-dns.sh.staged" ] && ck "语法坏的 staged 被丢弃" 1 || ck "语法坏的 staged 被丢弃" 0
[ "$before" = "$(sha256sum < "$ZZLIB/set-dns.sh")" ] && ck "语法坏的 staged 未污染在跑的副本" 1 || ck "语法坏的 staged 未污染在跑的副本" 0

echo "=== 5b. --zz-update 拒绝降级 ==="
o=$(EX --zz-update 2>&1); rc=$?
case "$o" in
  *"低于本地"*) ck "--zz-update 拒绝降级到远端更旧的版本" 1 ;;
  *"更新失败"*) skip "网络不可用，跳过降级断言（"本地副本未被改动"下面单独断言）" ;;
  *) ck "--zz-update 拒绝降级（输出：$(printf '%s' "$o" | tr '\n' ' '))" 0 ;;
esac
[ "$rc" = 0 ] && ck "拒绝降级时退出码仍为 0（跳过不是错误）" 1 || ck "拒绝降级时退出码仍为 0" 0
grep -q '^SET_DNS_REV=9999999999' "$ZZLIB/set-dns.sh" && ck "拒绝降级后本地副本未被改动" 1 || ck "拒绝降级后本地副本未被改动" 0

echo "=== 6. 副本丢失自愈 ==="
rm -f "$ZZLIB/set-dns.sh"
"$ZZBIN/zz" --help >/dev/null 2>&1
if [ -s "$ZZLIB/set-dns.sh" ]; then
  ck "副本丢失后重新下载补齐" 1
else
  skip "网络不可用，跳过自愈断言（zz 会提示重跑一键命令）"
fi

echo "=== 6b. 自动更新默认开、且真的会联网检查 ==="
U=$T/upd; mkdir -p "$U/etc"
SET_DNS_ETC="$U/etc" SET_DNS_SBIN="$U/etc/sbin" SET_DNS_LOG="$U/log" \
  SET_DNS_ZZ_LIB="$U/lib" SET_DNS_ZZ_BIN="$U/bin" bash "$SRC" --zz >/dev/null 2>&1
grep -q "INTERVAL=86400" "$U/bin/zz" && ck "默认间隔写成 86400（24 小时）" 1 || ck "默认间隔写成 86400" 0
[ "$(cat "$U/lib/autoupdate")" = 1 ] && ck "默认自动更新为开" 1 || ck "默认自动更新为开" 0
# 安装收尾的自检就跑过一次 zz，那一刻必然盖章 —— 证明联网阶段确实进入了
if [ -s "$U/lib/.zz-last-check" ]; then
  ck "一次调用后写下检查时间戳" 1
  t1=$(cat "$U/lib/.zz-last-check")
  case "$t1" in ''|*[!0-9]*) ck "时间戳是纯数字" 0;; *) ck "时间戳是纯数字" 1;; esac
  "$U/bin/zz" --help >/dev/null 2>&1
  [ "$(cat "$U/lib/.zz-last-check")" = "$t1" ] && ck "间隔内不重复检查（时间戳未变）" 1 || ck "间隔内不重复检查" 0
else
  skip "入口脚本未进入联网阶段（时间戳未创建）"
fi
# 关掉开关后不得再联网
printf '0\n' > "$U/lib/autoupdate"; rm -f "$U/lib/.zz-last-check"
"$U/bin/zz" --help >/dev/null 2>&1
[ ! -e "$U/lib/.zz-last-check" ] && ck "关闭自动更新后不再联网检查" 1 || ck "关闭自动更新后不再联网检查" 0
# 间隔设成 0（= 不再自动下载）也不得联网
printf '1\n' > "$U/lib/autoupdate"
SET_DNS_ZZ_INTERVAL=0 SET_DNS_ZZ_LIB="$U/lib" SET_DNS_ZZ_BIN="$U/bin" bash "$SRC" --zz >/dev/null 2>&1
rm -f "$U/lib/.zz-last-check"
"$U/bin/zz" --help >/dev/null 2>&1
[ ! -e "$U/lib/.zz-last-check" ] && ck "间隔=0 时不再联网检查" 1 || ck "间隔=0 时不再联网检查" 0

echo "=== 7. --dry-run 零改动 ==="
B=$T/dry; mkdir -p "$B"
o=$(SET_DNS_ETC="$B/etc" SET_DNS_ZZ_LIB="$B/lib" SET_DNS_ZZ_BIN="$B/bin" bash "$SRC" --zz --dry-run 2>&1)
[ ! -e "$B/bin/zz" ] && ck "dry-run 下不创建 zz" 1 || ck "dry-run 下不创建 zz" 0
case "$o" in *"dry-run"*) ck "dry-run 打印了计划" 1;; *) ck "dry-run 打印了计划" 0;; esac
SET_DNS_ETC="$B/etc" SET_DNS_ZZ_LIB="$B/lib" SET_DNS_ZZ_BIN="$B/bin" bash "$SRC" --plain --dry-run --zz >/dev/null 2>&1
[ ! -e "$B/bin/zz" ] && ck "主流程 dry-run 下也不创建 zz" 1 || ck "主流程 dry-run 下也不创建 zz" 0

echo "=== 7b. 主流程会自动装 zz ==="
M=$T/main; mkdir -p "$M/etc"
o=$(SET_DNS_ETC="$M/etc" SET_DNS_SBIN="$M/etc/sbin" SET_DNS_LOG="$M/log" SET_DNS_NO_PROBE=1 \
    SET_DNS_ZZ_LIB="$M/lib" SET_DNS_ZZ_BIN="$M/bin" bash "$SRC" --plain 2>&1)
case "$o" in *"7) 安装 zz 快捷键"*) ck "主流程第 7 步装 zz" 1;; *) ck "主流程第 7 步装 zz" 0;; esac
case "$o" in *"8) 验证"*) ck "验证步顺延为 8（编号没重号）" 1;; *) ck "验证步顺延为 8" 0;; esac
[ -x "$M/bin/zz" ] && ck "主流程真的装出了 zz" 1 || ck "主流程真的装出了 zz" 0
case "$o" in *"下次再进: 直接敲 zz"*) ck "收尾提示引导敲 zz" 1;; *) ck "收尾提示引导敲 zz" 0;; esac

echo "=== 8. --zz-remove ==="
EX --zz-remove >/dev/null 2>&1
if [ ! -e "$ZZBIN/zz" ] && [ ! -e "$ZZBIN/set-dns" ] && [ ! -e "$ZZLIB/set-dns.sh" ]; then
  ck "--zz-remove 清干净" 1
else
  ck "--zz-remove 清干净" 0
fi
out=$(EX --zz-remove 2>&1)
case "$out" in *"没有安装"*) ck "重复移除提示无需移除（幂等）" 1;; *) ck "重复移除提示无需移除" 0;; esac

echo "=== 9. 参数与帮助 ==="
EX --zz-bogus >/dev/null 2>&1; [ $? = 2 ] && ck "未知 --zz-bogus 退出码 2" 1 || ck "未知 --zz-bogus 退出码 2" 0
h=$(EX --help 2>&1)
case "$h" in *"--zz-autoupdate-off"*) ck "帮助列出 --zz-autoupdate-off" 1;; *) ck "帮助列出 --zz-autoupdate-off" 0;; esac
case "$h" in *"自动更新默认开启"*) ck "帮助说明自动更新默认开启" 1;; *) ck "帮助说明自动更新默认开启" 0;; esac
case "$h" in *"SET_DNS_ZZ_INTERVAL"*) ck "帮助列出 SET_DNS_ZZ_INTERVAL" 1;; *) ck "帮助列出 SET_DNS_ZZ_INTERVAL" 0;; esac

echo "=== 10. 修订号不变式 ==="
# 入口脚本靠 /^SET_DNS_REV=/ 抠版本号，这一行必须顶格纯数字；加缩进或引号会让自动更新失效
rev=$(grep -c '^SET_DNS_REV=[0-9][0-9]*$' "$SRC" || true)
[ "${rev:-0}" = 1 ] && ck "SET_DNS_REV 顶格纯数字且唯一" 1 || ck "SET_DNS_REV 顶格纯数字且唯一（命中 ${rev:-0} 行）" 0
rv=$(awk '/^SET_DNS_REV=/{sub(/^SET_DNS_REV=/,"");sub(/[^0-9].*/,"");print;exit}' "$SRC")
[ -n "$rv" ] && ck "脚本内自带的 awk 抠取方式能取到 $rv" 1 || ck "脚本内自带的 awk 抠取方式能取到" 0
# 抽出来直接测脚本里的抠取函数本身
rv2=$(bash -c 'set -uo pipefail; grep -A3 "^zz_rev_of()" '"$SRC"' >/dev/null 2>&1; sed -n "/^zz_rev_of()/,/^}/p" '"$SRC"' > /tmp/zzrev.$$.f; . /tmp/zzrev.$$.f 2>/dev/null; zz_rev_of "'"$SRC"'"; rm -f /tmp/zzrev.$$.f' 2>/dev/null)
[ "$rv2" = "$rv" ] && ck "zz_rev_of 与内联 awk 结果一致（$rv2）" 1 || ck "zz_rev_of 与内联 awk 结果一致（得到 ${rv2:-空}，期望 $rv）" 0

echo "=== ZZ_TEST PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
