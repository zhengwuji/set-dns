#!/bin/bash
# 单元测：zz 快捷键（任何脚本调用都会自动装）+ 脚本自动更新（每次调用 zz 当场查、当场换）
#   - 沙箱：全部落在 mktemp 出来的临时目录，绝不碰真实 /usr/local
#   - 入口脚本（zz / set-dns）是另起进程，环境变量必须 export 出去，否则它会去看真实 /usr/local
#   - 联网那一半用**假 curl** 驱动：真去联网的话"有没有新版""下载失败"都不可控，
#     断言会变成看天气。假 curl 能精确造出 高修订号 / 低修订号 / 语法坏 / 直接失败 四种响应。
set -uo pipefail
SRC=${SRC:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/set-dns.sh}
[ -f "$SRC" ] || { echo "找不到待测脚本 $SRC（用 SRC=... 指定）"; exit 2; }

T=$(mktemp -d 2>/dev/null || echo "/tmp/zzverify.$$")
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ck(){ if [ "$2" = 1 ]; then PASS=$((PASS+1)); echo "  ok   - $1"; else FAIL=$((FAIL+1)); echo "  FAIL - $1"; fi; }
skip(){ echo "  [ -- ] $1"; }
revof(){ awk '/^SET_DNS_REV=/{sub(/^SET_DNS_REV=/,"");sub(/[^0-9].*/,"");print;exit}' "$1"; }

ZZBIN=$T/usr-local/bin
ZZLIB=$T/usr-local/lib/set-dns
export SET_DNS_ETC="$T/etc" SET_DNS_SBIN="$T/etc/sbin" SET_DNS_LOG="$T/etc/dns-watch.log"
export SET_DNS_ZZ_LIB="$ZZLIB" SET_DNS_ZZ_BIN="$ZZBIN"
mkdir -p "$T/etc"
# 固定 SET_DNS_ZZ_NO_UPDATE=1：安装过程本身不做按需更新检查，保证可确定复现。
# "每次调用都查更新"那部分单独用假 curl 精确驱动（第 5 段）。
EX(){ SET_DNS_ZZ_NO_UPDATE=1 bash "$SRC" "$@" 2>&1; }

BASE_REV=$(revof "$SRC")
echo "（被测脚本修订号 $BASE_REV）"

# ---- 假 curl ----
# 从参数里找 -o 后面的落点，按 $FAKE_MODE 写内容；每次调用都往 $FAKE_COUNT 记一行，
# 这样"到底有没有真的发起下载"是可断言的。
FAKE=$T/fakebin; mkdir -p "$FAKE"
cat > "$FAKE/curl" <<'FAKEEOF'
#!/bin/sh
out=; while [ $# -gt 0 ]; do case "$1" in -o) shift; out=$1 ;; esac; shift; done
[ -n "$out" ] || exit 1
printf 'x\n' >> "$FAKE_COUNT"
case "$FAKE_MODE" in fail) exit 7 ;; esac
cp -f "$FAKE_PAYLOAD" "$out" || exit 1
exit 0
FAKEEOF
chmod +x "$FAKE/curl"
export FAKE_COUNT="$T/curlcount"

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
grep -qE '\[\[|==[^=]|\bfunction\b|\becho -e\b' "$ZZBIN/zz" && ck "入口脚本不含 bash 专有语法" 0 || ck "入口脚本不含 bash 专有语法" 1
grep -q 'FAILED=' "$ZZBIN/zz" && ck "含失败冷却标记（网络不通时不反复卡超时）" 1 || ck "含失败冷却标记" 0
grep -q 'NOUPD=' "$ZZBIN/zz" && ck "含 SET_DNS_ZZ_NO_UPDATE 开关" 1 || ck "含 SET_DNS_ZZ_NO_UPDATE 开关" 0
grep -q 'COOLDOWN=' "$ZZBIN/zz" && ck "含可调冷却秒数" 1 || ck "含可调冷却秒数" 0
grep -q '\.staged' "$ZZBIN/zz" && ck "已移除两段式 staged 机制" 0 || ck "已移除两段式 staged 机制" 1
grep -qE '(^|[^_A-Z])INTERVAL=' "$ZZBIN/zz" && ck "已移除旧的间隔定时器" 0 || ck "已移除旧的间隔定时器" 1
grep -q 'zz-last-check' "$ZZBIN/zz" && ck "已移除旧的检查时间戳文件" 0 || ck "已移除旧的检查时间戳文件" 1
cmp -s "$ZZBIN/zz" "$ZZBIN/set-dns" && ck "两个入口内容一致" 1 || ck "两个入口内容一致" 0

echo "=== 3. 真跑 zz ==="
h=$(SET_DNS_ZZ_NO_UPDATE=1 "$ZZBIN/zz" --help 2>&1); rc=$?
[ "$rc" = 0 ] && ck "zz --help 退出码 0" 1 || ck "zz --help 退出码 0" 0
case "$h" in *"set-dns v3"*) ck "zz --help 输出横幅" 1;; *) ck "zz --help 输出横幅" 0;; esac
case "$h" in *"以后敲 zz 就直接回到这个菜单"*) ck "帮助里说明 zz 用法" 1;; *) ck "帮助里说明 zz 用法" 0;; esac
case "$h" in *"gh-proxy.com/https://raw"*) ck "帮助里给出大陆一键命令" 1;; *) ck "帮助里给出大陆一键命令" 0;; esac

s=$(SET_DNS_ZZ_NO_UPDATE=1 "$ZZBIN/set-dns" --zz-status 2>&1); rc=$?
[ "$rc" = 0 ] && ck "set-dns --zz-status 退出码 0" 1 || ck "set-dns --zz-status 退出码 0" 0
case "$s" in *"快捷键已安装"*) ck "状态：快捷键已安装" 1;; *) ck "状态：快捷键已安装" 0;; esac
case "$s" in *"每次敲 zz 都会查一次"*) ck "状态：说明每次调用都查" 1;; *) ck "状态：说明每次调用都查" 0;; esac
case "$s" in *"入口脚本世代 $BASE_REV（与本版一致）"*) ck "状态：报出入口世代且与本版一致" 1;; *) ck "状态：报出入口世代（得到：$(printf '%s' "$s" | grep 世代 | head -1)）" 0;; esac

echo "=== 3b. 入口脚本世代自愈（本版修掉的真缺陷）==="
# 自动更新只换本体、从不重写入口 -> 入口里的逻辑改动到不了已装机器。
# 真机验证过：本体换过 3 次，入口还停在几小时前。现在靠 ZZDEN 比对来自愈。
grep -qE '^ZZDEN=[0-9]+$' "$ZZBIN/zz" && ck "入口脚本自带世代号 ZZDEN" 1 || ck "入口脚本自带世代号 ZZDEN" 0
[ "$(grep -m1 '^ZZDEN=' "$ZZBIN/zz" | cut -d= -f2)" = "$BASE_REV" ] \
  && ck "世代号就是本脚本修订号（$BASE_REV）" 1 || ck "世代号就是本脚本修订号" 0
sed -i 's/^ZZDEN=.*/ZZDEN=old000/' "$ZZBIN/zz"
before=$(sha256sum < "$ZZLIB/set-dns.sh")
o=$(EX --sysinfo 2>&1)
case "$o" in *"入口脚本已刷新到本世代"*) ck "旧世代入口被自动刷新" 1;; *) ck "旧世代入口被自动刷新（输出：$(printf '%s' "$o" | grep -c 世代)处提及）" 0;; esac
[ "$(grep -m1 '^ZZDEN=' "$ZZBIN/zz" | cut -d= -f2)" = "$BASE_REV" ] && ck "刷新后世代号跟上本版" 1 || ck "刷新后世代号跟上本版" 0
[ "$before" = "$(sha256sum < "$ZZLIB/set-dns.sh")" ] && ck "刷新入口时本体不被重新下载" 1 || ck "刷新入口时本体不被重新下载" 0
# 没有世代号的老入口（比"世代号过期"更旧）也要能刷新
sed -i '/^ZZDEN=/d' "$ZZBIN/zz"
EX --sysinfo >/dev/null 2>&1
grep -qE '^ZZDEN=[0-9]+$' "$ZZBIN/zz" && ck "完全没有世代号的老入口也能刷新" 1 || ck "完全没有世代号的老入口也能刷新" 0

echo "=== 3c. 已是最新时必须有可见回执 ==="
# 静默成功 = 用户没法确认这条路是通的（这次反馈的问题：敲了 zz 什么都看不到，
# 分不清"已是最新"还是"根本没查"）。所以三个分支都要有回执。
o=$("$ZZBIN/zz" --help 2>&1 >/dev/null)
case "$o" in *"已是最新版"*) ck "已是最新时有可见回执（含修订号）" 1;; *) ck "已是最新时有可见回执（得到：$(printf '%s' "$o"|head -1)）" 0;; esac
case "$o" in *"$BASE_REV"*) ck "回执里带上修订号" 1;; *) ck "回执里带上修订号" 0;; esac
# 冷却分支也要说一声
date +%s > "$ZZLIB/.zz-update-failed"
o=$("$ZZBIN/zz" --help 2>&1 >/dev/null)
case "$o" in *"冷却中"*) ck "冷期内也有可见回执（不是静默跳过）" 1;; *) ck "冷期内也有可见回执（得到：$(printf '%s' "$o"|head -1)）" 0;; esac
rm -f "$ZZLIB/.zz-update-failed"

echo "=== 4. 自动更新开关 ==="
EX --zz-autoupdate-off >/dev/null 2>&1
[ "$(cat "$ZZLIB/autoupdate")" = 0 ] && ck "关闭后写 0" 1 || ck "关闭后写 0" 0
s=$(EX --zz-status 2>&1)
case "$s" in *"自动更新：已关闭"*) ck "状态：已关闭" 1;; *) ck "状态：已关闭" 0;; esac
EX --zz >/dev/null 2>&1
[ "$(cat "$ZZLIB/autoupdate")" = 0 ] && ck "重装不覆盖用户已关闭的选择" 1 || ck "重装不覆盖用户已关闭的选择" 0
EX --zz-autoupdate-on >/dev/null 2>&1
[ "$(cat "$ZZLIB/autoupdate")" = 1 ] && ck "重新开启写 1" 1 || ck "重新开启写 1" 0

echo "=== 5. 每次调用当场更新（假 curl 精确驱动）==="
NEW=$T/new.sh; sed "s/^SET_DNS_REV=.*/SET_DNS_REV=9999999999/" "$SRC" > "$NEW"
OLD=$T/old.sh; sed 's/^SET_DNS_REV=.*/SET_DNS_REV=1/' "$SRC" > "$OLD"
BROKEN=$T/broken.sh; printf 'this is not bash (((\n' > "$BROKEN"
export FAKE_PAYLOAD="$NEW" FAKE_MODE=ok

: > "$FAKE_COUNT"
PATH="$FAKE:$PATH" "$ZZBIN/zz" --help >/dev/null 2>&1
[ "$(revof "$ZZLIB/set-dns.sh")" = 9999999999 ] \
  && ck "敲一次 zz 就把新版换上了（不用等下一次）" 1 || ck "敲一次 zz 就把新版换上了（得到 $(revof "$ZZLIB/set-dns.sh")）" 0
[ -s "$ZZLIB/set-dns.sh.bak" ] && ck "旧版留底 .bak" 1 || ck "旧版留底 .bak" 0
[ -s "$ZZLIB/update.log" ] && ck "更新写进 update.log" 1 || ck "更新写进 update.log" 0
PATH="$FAKE:$PATH" "$ZZBIN/zz" --help 2>&1 | grep -q 'set-dns v3' && ck "换上的新版能正常跑" 1 || ck "换上的新版能正常跑" 0
cp -f "$ZZLIB/set-dns.sh.bak" "$ZZLIB/set-dns.sh"; rm -f "$ZZLIB/set-dns.sh.bak" "$ZZLIB/update.log"

echo "=== 5b. 防降级 / 语法闸（同一条路径）==="
export FAKE_PAYLOAD="$OLD"
PATH="$FAKE:$PATH" "$ZZBIN/zz" --help >/dev/null 2>&1
[ "$(revof "$ZZLIB/set-dns.sh")" = "$BASE_REV" ] && ck "远端修订号更小：不换（防降级）" 1 || ck "远端修订号更小：不换（防降级）" 0
[ ! -e "$ZZLIB/set-dns.sh.bak" ] && ck "未降级时不留 .bak" 1 || ck "未降级时不留 .bak" 0

export FAKE_PAYLOAD="$BROKEN"
before=$(sha256sum < "$ZZLIB/set-dns.sh")
PATH="$FAKE:$PATH" "$ZZBIN/zz" --help >/dev/null 2>&1
[ "$before" = "$(sha256sum < "$ZZLIB/set-dns.sh")" ] && ck "语法坏的副本绝不落位" 1 || ck "语法坏的副本绝不落位" 0

echo "=== 5c. 管理命令不自我更新 ==="
export FAKE_PAYLOAD="$NEW"
for sub in --zz-status --zz-autoupdate-off --zz-remove; do
  : > "$FAKE_COUNT"
  PATH="$FAKE:$PATH" "$ZZBIN/zz" $sub >/dev/null 2>&1
  [ ! -s "$FAKE_COUNT" ] && ck "$sub 不触发更新下载" 1 || ck "$sub 不触发更新下载" 0
  EX --zz >/dev/null 2>&1     # 上一条 --zz-remove 会删掉入口，补回来
done

echo "=== 5d. 下载失败 -> 冷却，不反复卡超时 ==="
export FAKE_MODE=fail
rm -f "$ZZLIB/.zz-update-failed"
: > "$FAKE_COUNT"
PATH="$FAKE:$PATH" "$ZZBIN/zz" --help >/dev/null 2>&1
[ -s "$ZZLIB/.zz-update-failed" ] && ck "失败后写下冷却时间戳" 1 || ck "失败后写下冷却时间戳" 0
n1=$(wc -l < "$FAKE_COUNT")
[ "$n1" -ge 1 ] && ck "失败这次确实发起了下载尝试" 1 || ck "失败这次确实发起了下载尝试" 0
PATH="$FAKE:$PATH" "$ZZBIN/zz" --help >/dev/null 2>&1
[ "$(wc -l < "$FAKE_COUNT")" -eq "$n1" ] && ck "冷期内不再重试（没有新下载）" 1 || ck "冷期内不再重试" 0
rm -f "$ZZLIB/.zz-update-failed"
export FAKE_MODE=ok

echo "=== 5e. NO_UPDATE 与总开关都能拦住 ==="
export FAKE_PAYLOAD="$NEW"
: > "$FAKE_COUNT"
SET_DNS_ZZ_NO_UPDATE=1 PATH="$FAKE:$PATH" "$ZZBIN/zz" --help >/dev/null 2>&1
[ ! -s "$FAKE_COUNT" ] && ck "SET_DNS_ZZ_NO_UPDATE=1 时不联网" 1 || ck "SET_DNS_ZZ_NO_UPDATE=1 时不联网" 0
printf '0\n' > "$ZZLIB/autoupdate"; : > "$FAKE_COUNT"
PATH="$FAKE:$PATH" "$ZZBIN/zz" --help >/dev/null 2>&1
[ ! -s "$FAKE_COUNT" ] && ck "总开关关闭时不联网" 1 || ck "总开关关闭时不联网" 0
printf '1\n' > "$ZZLIB/autoupdate"

echo "=== 6. 副本丢失自愈 ==="
rm -f "$ZZLIB/set-dns.sh"
if SET_DNS_ZZ_NO_UPDATE=1 "$ZZBIN/zz" --help >/dev/null 2>&1 && [ -s "$ZZLIB/set-dns.sh" ]; then
  ck "副本丢失后重新下载补齐" 1
else
  skip "网络不可用，跳过自愈断言（zz 会提示重跑一键命令）"
fi

echo "=== 7. --zz-update 防降级 ==="
EX --zz-remove >/dev/null 2>&1; EX --zz >/dev/null 2>&1
sed -i 's/^SET_DNS_REV=.*/SET_DNS_REV=9999999999/' "$ZZLIB/set-dns.sh"
o=$(EX --zz-update 2>&1); rc=$?
case "$o" in
  *"低于本地"*) ck "--zz-update 拒绝降级到远端更旧的版本" 1 ;;
  *"更新失败"*) skip "网络不可用，跳过降级断言（本地副本未被改动下面单独断言）" ;;
  *) ck "--zz-update 拒绝降级（输出：$(printf '%s' "$o" | tr '\n' ' ')）" 0 ;;
esac
[ "$rc" = 0 ] && ck "拒绝降级时退出码仍为 0（跳过不是错误）" 1 || ck "拒绝降级时退出码仍为 0" 0
grep -q '^SET_DNS_REV=9999999999' "$ZZLIB/set-dns.sh" && ck "拒绝降级后本地副本未被改动" 1 || ck "拒绝降级后本地副本未被改动" 0

echo "=== 8. 任何脚本调用都会顺带装好 zz（不用先跑完整安装）==="
E=$T/ensure; mkdir -p "$E/etc"
for arg in --sysinfo --cn-dns --gh-check --check --mirror --kernel --accel-status --tools; do
  rm -rf "$E/usr-local"
  SET_DNS_ETC="$E/etc" SET_DNS_SBIN="$E/etc/sbin" SET_DNS_LOG="$E/log" \
  SET_DNS_ZZ_LIB="$E/usr-local/lib/set-dns" SET_DNS_ZZ_BIN="$E/usr-local/bin" \
  SET_DNS_ZZ_NO_UPDATE=1 SET_DNS_NO_PROBE=1 SET_DNS_SYSINFO_NO_NET=1 \
    bash "$SRC" $arg >/dev/null 2>&1
  [ -x "$E/usr-local/bin/zz" ] && ck "$arg 也顺带装好了 zz" 1 || ck "$arg 也顺带装好了 zz" 0
done
rm -rf "$E/usr-local"
SET_DNS_ETC="$E/etc" SET_DNS_ZZ_LIB="$E/usr-local/lib/set-dns" SET_DNS_ZZ_BIN="$E/usr-local/bin" \
  SET_DNS_ZZ_NO_UPDATE=1 bash "$SRC" --sysinfo >/dev/null 2>&1
SET_DNS_ETC="$E/etc" SET_DNS_ZZ_LIB="$E/usr-local/lib/set-dns" SET_DNS_ZZ_BIN="$E/usr-local/bin" \
  SET_DNS_ZZ_NO_UPDATE=1 bash "$SRC" --zz-remove >/dev/null 2>&1
[ ! -e "$E/usr-local/bin/zz" ] && ck "--zz-remove 之后不会被顺手装回来" 1 || ck "--zz-remove 之后不会被顺手装回来" 0
rm -rf "$E/usr-local"
SET_DNS_ETC="$E/etc" SET_DNS_ZZ_LIB="$E/usr-local/lib/set-dns" SET_DNS_ZZ_BIN="$E/usr-local/bin" \
  SET_DNS_ZZ_NO_UPDATE=1 bash "$SRC" --plain --dry-run >/dev/null 2>&1
[ ! -e "$E/usr-local/bin/zz" ] && ck "dry-run 下不装 zz" 1 || ck "dry-run 下不装 zz" 0

echo "=== 8b. PATH 里更靠前的旧副本会被接管 ==="
SH=$T/sbin; mkdir -p "$SH"
cp -f "$SRC" "$SH/set-dns"
out=$(PATH="$SH:$PATH" EX --zz 2>&1)
case "$out" in *"已接管更靠前的旧副本"*) ck "识别为本脚本旧副本并接管" 1;; *) ck "识别为本脚本旧副本并接管（输出：$(printf '%s' "$out" | tr '\n' ' ')）" 0;; esac
head -1 "$SH/set-dns" | grep -q '^#!/bin/sh' && ck "接管后变成入口脚本（不再是整份脚本）" 1 || ck "接管后变成入口脚本" 0
[ -s "$T/etc/set-dns.bak/zz-removed/set-dns.sbin" ] && ck "旧副本已备份到 zz-removed/" 1 || ck "旧副本已备份到 zz-removed/" 0
PATH="$SH:$PATH" SET_DNS_ZZ_NO_UPDATE=1 "$SH/set-dns" --help >/dev/null 2>&1 && ck "接管后的 set-dns 真能用" 1 || ck "接管后的 set-dns 真能用" 0

FOREIGN=$T/foreign; mkdir -p "$FOREIGN"
printf '#!/bin/sh\necho "i am someone elses set-dns"\n' > "$FOREIGN/set-dns"; chmod +x "$FOREIGN/set-dns"
before=$(sha256sum < "$FOREIGN/set-dns")
out=$(PATH="$FOREIGN:$PATH" EX --zz 2>&1)
after=$(sha256sum < "$FOREIGN/set-dns")
[ "$before" = "$after" ] && ck "别人的同名 set-dns 一个字节没动" 1 || ck "别人的同名 set-dns 一个字节没动" 0
case "$out" in *"不像是本脚本"*) ck "对别人的同名程序只提示不接管" 1;; *) ck "对别人的同名程序只提示不接管" 0;; esac

echo "=== 9. 参数与帮助 ==="
EX --zz-bogus >/dev/null 2>&1; [ $? = 2 ] && ck "未知 --zz-bogus 退出码 2" 1 || ck "未知 --zz-bogus 退出码 2" 0
h=$(EX --help 2>&1)
case "$h" in *"--zz-autoupdate-off"*) ck "帮助列出 --zz-autoupdate-off" 1;; *) ck "帮助列出 --zz-autoupdate-off" 0;; esac
case "$h" in *"每次敲 zz 都"*) ck "帮助说明每次敲 zz 都会更新" 1;; *) ck "帮助说明每次敲 zz 都会更新" 0;; esac
case "$h" in *"SET_DNS_ZZ_NO_UPDATE"*) ck "帮助列出 SET_DNS_ZZ_NO_UPDATE" 1;; *) ck "帮助列出 SET_DNS_ZZ_NO_UPDATE" 0;; esac
case "$h" in *"SET_DNS_ZZ_INTERVAL"*) ck "帮助已移除过期的 SET_DNS_ZZ_INTERVAL" 0;; *) ck "帮助已移除过期的 SET_DNS_ZZ_INTERVAL" 1;; esac

echo "=== 10. 修订号不变式 ==="
rev=$(grep -c '^SET_DNS_REV=[0-9][0-9]*$' "$SRC" || true)
[ "${rev:-0}" = 1 ] && ck "SET_DNS_REV 顶格纯数字且唯一" 1 || ck "SET_DNS_REV 顶格纯数字且唯一（命中 ${rev:-0} 行）" 0
rv=$(revof "$SRC")
[ -n "$rv" ] && ck "内联 awk 能取到修订号 $rv" 1 || ck "内联 awk 能取到修订号" 0
sed -n "/^zz_rev_of()/,/^}/p" "$SRC" > "$T/rev.f"; . "$T/rev.f"; rv2=$(zz_rev_of "$SRC")
[ "$rv2" = "$rv" ] && ck "zz_rev_of 与内联 awk 一致（$rv2）" 1 || ck "zz_rev_of 与内联 awk 一致（得到 ${rv2:-空}）" 0

echo "=== ZZ_TEST PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
