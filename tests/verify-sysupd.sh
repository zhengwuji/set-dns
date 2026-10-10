#!/bin/bash
# 单元测：系统更新（--sysupdate / 菜单 14）与系统清理（--sysclean / 菜单 15）
#   - 全程用**桩包管理器**驱动：真跑 apt 会真的升级系统，绝不能在测试里做
#   - 桩会记录每一次调用，于是"到底执行了哪些命令""哪些命令**没**被执行"都可断言
#   - 重点盯三处**与 kejilion.sh 的有意分歧**：不删 /var/log、autoremove 的危险项拦阻、
#     升级后必须报告重启需求与新内核
set -uo pipefail
SRC=${SRC:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/set-dns.sh}
[ -f "$SRC" ] || { echo "找不到待测脚本 $SRC（用 SRC=... 指定）"; exit 2; }

T=$(mktemp -d 2>/dev/null || echo "/tmp/suverify.$$")
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ck(){ if [ "$2" = 1 ]; then PASS=$((PASS+1)); echo "  ok   - $1"; else FAIL=$((FAIL+1)); echo "  FAIL - $1"; fi; }

STUB=$T/bin; mkdir -p "$STUB" "$T/etc"
LOG=$T/calls.log
: > "$LOG"

# ---- 桩包管理器 ----
# 关键：桩跑的 REAL=0 沙箱里 su_* 会提前 return（"不真的升级"），所以桩只用于
# **dry-run 之外的路径探测**不可行 —— 改为直接测函数本身，见下面 msrc 段。
mksrc(){ # $1=输出文件：抽出 su_* 相关函数 + 依赖桩
  {
    echo 'set -uo pipefail'
    echo 'ETC='"$T"'/etc'
    echo 'SBIN='"$T"'/sbin'
    echo 'LOG='"$T"'/dns-watch.log'
    echo 'BK=$ETC/set-dns.bak'
    echo 'DRY=${DRY:-0}'
    echo 'REAL=${REAL:-0}'
    echo 'TTY_OK=${FAKE_TTY:-0}'
    echo 'SU_YES=${SU_YES:-0}'
    echo 'SU_TMP_AGE=${SU_TMP_AGE:-7}'
    echo 'SU_JOURNAL_KEEP=${SU_JOURNAL_KEEP:-200M}'
    echo 'SU_LOG='"$LOG"
    # 必须 export：桩 apt-get 是**子进程**，看不见父 shell 里的普通变量（第一版漏了，
    # 结果日志恒为空，"放行时真的执行了 autoremove" 这条一直假失败）
    echo 'export SU_LOG'
    echo 'ok()  { printf "  [ OK ] %s\n" "$*"; }'
    echo 'no()  { printf "  [FAIL] %s\n" "$*"; }'
    echo 'inf() { printf "  [ -- ] %s\n" "$*"; }'
    echo 'wr()  { printf "  [ !! ] %s\n" "$*"; }'
    echo 'hr()  { printf "%s\n" "--------------------------------------------------------"; }'
    echo 'read_ans() { ans=${FAKE_ANS:-}; }'
    echo 'dns_resolvable() { return 0; }'
    echo 'krn_ver() { printf "%s" "${FAKE_KVER:-6.1.0-18-amd64}"; }'
    echo 'df() { if [ "$1" = "-P" ]; then printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vda1 20971520 5242880 %s 25%% /\n" "${FAKE_AVAIL:-15728640}"; else command df "$@"; fi; }'
    sed -n '/^SU_YES=/,/^su_confirm()/p' "$SRC" | sed '$d'
    sed -n '/^su_confirm()/,/^}$/p' "$SRC"
    sed -n '/^su_mgr()/,/^}$/p' "$SRC"
    sed -n '/^su_apt_need_root()/,/^}$/p' "$SRC"
    sed -n '/^su_fix_dpkg()/,/^}$/p' "$SRC"
    sed -n '/^su_upgradable_count()/,/^}$/p' "$SRC"
    sed -n '/^su_upgradable_list()/,/^}$/p' "$SRC"
    sed -n '/^su_reboot_flag()/,/^}$/p' "$SRC"
    sed -n '/^su_reboot_pkgs()/,/^}$/p' "$SRC"
    sed -n '/^su_autoremove_safe()/,/^}$/p' "$SRC"
    echo 'PASS=0; FAIL=0'
    echo 'ck(){ if [ "$2" = 1 ]; then PASS=$((PASS+1)); echo "  ok   - $1"; else FAIL=$((FAIL+1)); echo "  FAIL - $1"; fi; }'
  } > "$1"
  bash -n "$1" || echo "  [ !! ] 抽出的函数片段语法有问题"
}

# ---- 桩 apt-get / dpkg / journalctl / find ----
cat > "$STUB/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$SU_LOG"
case "$1" in
  -s)
    # 模拟 autoremove：受 FAKE_SIM_REMOVE 控制要删哪些包
    if [ "${FAKE_SIM_FAIL:-0}" = 1 ]; then echo "E: Could not get lock /var/lib/dpkg/lock-frontend" >&2; exit 100; fi
    for p in ${FAKE_SIM_REMOVE:-}; do echo "Remv $p [1.0]"; done
    exit 0 ;;
  */) : ;;
esac
if [ "${FAKE_APT_FAIL:-0}" = 1 ] && [ "$1" = update ]; then echo "E: boom"; exit 100; fi
exit 0
EOF
cat > "$STUB/dpkg" <<'EOF'
#!/bin/sh
echo "dpkg $*" >> "$SU_LOG"
[ "${FAKE_AUDIT:-0}" = 1 ] && { echo "dpkg: 半装的包"; exit 0; }
exit 0
EOF
cat > "$STUB/journalctl" <<'EOF'
#!/bin/sh
echo "journalctl $*" >> "$SU_LOG"
[ "$1" = --vacuum-size ] && echo "Vacuuming done, freed 5.2M"
exit 0
EOF
chmod +x "$STUB"/*

echo "=== 1. su_mgr 识别包管理器 ==="
S=$T/t1.sh; mksrc "$S"
o=$(PATH="$STUB:$PATH" bash -c '. '"$S"'; su_mgr')
[ "$o" = apt ] && ck "认出 apt（桩 apt-get 在 PATH 里）" 1 || ck "认出 apt（得到「$o」）" 0
o=$(PATH="/usr/bin:/bin" bash -c '. '"$S"'; su_mgr >/dev/null 2>&1; echo rc=$?')
case "$o" in *rc=1*) ck "没有包管理器时返回非 0" 1;; *) ck "没有包管理器时返回非 0（得到 $o）" 0;; esac

echo "=== 2. autoremove 危险项拦阻（本脚本相对 kejilion 的关键加固）==="
# 2a) 模拟要删「正在运行的内核」-> 必须拦住
: > "$LOG"
o=$(PATH="$STUB:$PATH" FAKE_SIM_REMOVE="linux-image-6.1.0-18-amd64 linux-headers-abc" FAKE_KVER=6.1.0-18-amd64 \
    bash -c '. '"$S"'; su_autoremove_safe 2>&1; echo "rc=$?"')
case "$o" in *"正在运行的内核"*) ck "拦住：要删正在运行的内核" 1;; *) ck "拦住：要删正在运行的内核（得到 $(printf '%s' "$o"|tr '\n' ' ')）" 0;; esac
case "$o" in *"rc=1"*) ck "拦住时返回 1（调用方据此跳过）" 1;; *) ck "拦住时返回 1" 0;; esac
# 关键：拦下之后**绝不能**真的执行 autoremove
if grep -q '^apt-get -y autoremove' "$LOG"; then ck "拦住后没有真的执行 autoremove" 0; else ck "拦住后没有真的执行 autoremove" 1; fi

# 2b) 兜底内核元包也要拦
: > "$LOG"
o=$(PATH="$STUB:$PATH" FAKE_SIM_REMOVE="linux-image-amd64" bash -c '. '"$S"'; su_autoremove_safe 2>&1; echo "rc=$?"')
case "$o" in *"兜底内核元包"*) ck "拦住：要删兜底内核元包 linux-image-amd64" 1;; *) ck "拦住：要删兜底内核元包" 0;; esac

# 2c) 本脚本/面板赖以运行的包也要拦
: > "$LOG"
o=$(PATH="$STUB:$PATH" FAKE_SIM_REMOVE="unbound dnscrypt-proxy" bash -c '. '"$S"'; su_autoremove_safe 2>&1; echo "rc=$?"')
case "$o" in *"关键包"*) ck "拦住：要删 unbound/dnscrypt-proxy" 1;; *) ck "拦住：要删 unbound/dnscrypt-proxy" 0;; esac

# 2d) **旧内核必须放行** —— 那是 autoremove 的正常目标，不能一并拦掉
: > "$LOG"
o=$(PATH="$STUB:$PATH" FAKE_SIM_REMOVE="linux-image-6.1.0-10-amd64" FAKE_KVER=6.1.0-18-amd64 \
    bash -c '. '"$S"'; su_autoremove_safe 2>&1; echo "rc=$?"')
case "$o" in *"rc=0"*) ck "放行：旧内核（不是正在跑的那个）" 1;; *) ck "放行：旧内核（得到 $(printf '%s' "$o"|tr '\n' ' ')）" 0;; esac
if grep -q '^apt-get -y autoremove' "$LOG"; then ck "放行时真的执行了 autoremove" 1; else ck "放行时真的执行了 autoremove" 0; fi

# 2e) 没有可删的包 -> 什么都不做
: > "$LOG"
o=$(PATH="$STUB:$PATH" FAKE_SIM_REMOVE="" bash -c '. '"$S"'; su_autoremove_safe 2>&1; echo "rc=$?"')
case "$o" in *"没有可自动清理"*) ck "无孤立依赖时明确提示且返回 0" 1;; *) ck "无孤立依赖时明确提示" 0;; esac
if grep -q '^apt-get -y autoremove' "$LOG"; then ck "无孤立依赖时不执行 autoremove" 0; else ck "无孤立依赖时不执行 autoremove" 1; fi

# 2f) 预演失败（dpkg 锁着）-> 必须跳过，**不能**当成"没问题"往下删
: > "$LOG"
o=$(PATH="$STUB:$PATH" FAKE_SIM_FAIL=1 bash -c '. '"$S"'; su_autoremove_safe 2>&1; echo "rc=$?"')
case "$o" in *"rc=1"*) ck "预演失败时返回 1（不冒险）" 1;; *) ck "预演失败时返回 1（得到 $(printf '%s' "$o"|tr '\n' ' ')）" 0;; esac
if grep -q '^apt-get -y autoremove' "$LOG"; then ck "预演失败时绝不执行 autoremove" 0; else ck "预演失败时绝不执行 autoremove" 1; fi

echo "=== 3. su_confirm 交互（SET_DNS_YES=1 时全自动）==="
# 注意：mksrc 里已经带了一行 `SU_YES=${SET_DNS_YES:-0}`，那是**被抽出来的源码本身**。
# 所以在外面用 `SU_YES=1 bash -c ...` 是无效的（会被那行重新赋成 0）—— 必须用 SET_DNS_YES。
# 第一版就是这么假失败的。
S=$T/t3.sh; mksrc "$S"
o=$(PATH="$STUB:$PATH" SET_DNS_YES=1 bash -c '. '"$S"'; su_confirm "确认？" n; echo rc=$?')
case "$o" in *rc=0*) ck "SET_DNS_YES=1 时默认 n 也放行（无人值守）" 1;; *) ck "SET_DNS_YES=1 时放行（得到 $(printf '%s' "$o"|tr '\n' ' ')）" 0;; esac
o=$(PATH="$STUB:$PATH" SET_DNS_YES=0 FAKE_TTY=0 FAKE_ANS=y bash -c '. '"$S"'; su_confirm "确认？" n; echo rc=$?')
case "$o" in *rc=1*) ck "无终端且未 --yes 时默认拒绝（不误操作）" 1;; *) ck "无终端时默认拒绝" 0;; esac
o=$(PATH="$STUB:$PATH" SET_DNS_YES=0 FAKE_TTY=1 FAKE_ANS=y bash -c '. '"$S"'; su_confirm "确认？" n; echo rc=$?')
case "$o" in *rc=0*) ck "有终端输 y 放行" 1;; *) ck "有终端输 y 放行（得到 $(printf '%s' "$o"|tr '\n' ' ')）" 0;; esac
o=$(PATH="$STUB:$PATH" SET_DNS_YES=0 FAKE_TTY=1 FAKE_ANS=n bash -c '. '"$S"'; su_confirm "确认？" n; echo rc=$?')
case "$o" in *rc=1*) ck "有终端输 n 拒绝" 1;; *) ck "有终端输 n 拒绝" 0;; esac
o=$(PATH="$STUB:$PATH" SET_DNS_YES=0 FAKE_TTY=1 FAKE_ANS= bash -c '. '"$S"'; su_confirm "确认？" y; echo rc=$?')
case "$o" in *rc=0*) ck "默认值 y 时回车即通过" 1;; *) ck "默认值 y 时回车即通过" 0;; esac
o=$(PATH="$STUB:$PATH" SET_DNS_YES=0 FAKE_TTY=1 FAKE_ANS= bash -c '. '"$S"'; su_confirm "确认？" n; echo rc=$?')
case "$o" in *rc=1*) ck "默认值 n 时回车即拒绝" 1;; *) ck "默认值 n 时回车即拒绝" 0;; esac
# --yes 与 SET_DNS_YES=1 必须等价（真脚本里两条路径都要通）
grep -q -- '--yes|-y) SU_YES=1' "$SRC" && ck "--yes 参数能置 SU_YES=1" 1 || ck "--yes 参数能置 SU_YES=1" 0
grep -q 'SU_YES=${SET_DNS_YES:-0}' "$SRC" && ck "SET_DNS_YES 环境变量也能置（两条路径都在）" 1 || ck "SET_DNS_YES 环境变量也能置" 0

echo "=== 4. 危险写法必须不存在（源码级不变式）==="
# 只取**可执行代码**：先去掉整行注释与行尾注释。这一步很关键 ——
# 本段代码上方正好写着"我为什么**不**照抄 kejilion 的 rm -rf /var/log / pkill -9 / vacuum-time=1s"，
# 不剥注释的话断言会命中我自己的说明文字，把"正确"误报成"违规"（第一版就这么误报过）。
frag_raw=$(sed -n '/^# ================= 系统更新 \/ 系统清理/,/^# ================= 自定义 SSH/p' "$SRC")
frag=$(printf '%s\n' "$frag_raw" | sed 's/#.*//')
# 4a) 绝不 blanket 删 /var/log —— kejilion 在 apk/opkg/pkg 分支里就是这么干的，
#     但本脚本自己的守护日志正在 /var/log/dns-watch.log，且 blanket 删会把 apt/dpkg 历史一起抹掉
printf '%s' "$frag" | grep -qE 'rm +-rf? +"?/var/log' && ck "可执行代码里没有删 /var/log" 0 || ck "可执行代码里没有删 /var/log" 1
# 4b) 不用 --vacuum-time=1s（语义是"只留最近 1 秒"= 全清）
printf '%s' "$frag" | grep -q 'vacuum-time=1s' && ck "没有 journalctl --vacuum-time=1s（那是全清语义）" 0 || ck "没有 journalctl --vacuum-time=1s" 1
# 4c) 不用 pkill -9 -f 'apt|dpkg'（会误杀命令行里带 apt 的无关进程，包括脚本自身）
printf '%s' "$frag" | grep -qE 'pkill' && ck "没有 pkill 任何东西" 0 || ck "没有 pkill 任何东西" 1
# 4d) 不删 /etc/set-dns.bak —— 那是本脚本的还原依据
printf '%s' "$frag" | grep -qE 'rm +-rf?.*set-dns\.bak' && ck "清理不会删 /etc/set-dns.bak" 0 || ck "清理不会删 /etc/set-dns.bak" 1
# 4e) 反向确认"注释里确实写了这些坑"（说明是刻意规避，而不是碰巧没写）
printf '%s' "$frag_raw" | grep -q 'rm -rf /var/log' && ck "注释里明确记录了为何不删 /var/log" 1 || ck "注释里记录了为何不删 /var/log" 0

echo "=== 5. /var/log 只报告不删除 ==="
nv=$(printf '%s' "$frag" | grep -cE 'find +/var/log')
[ "$nv" -ge 1 ] && ck "有 /var/log 的大文件检查（find）" 1 || ck "有 /var/log 的大文件检查" 0
# 关键：rm 必须是**真正的命令词**。第一版用 `rm .*/var/log` 是错的 ——
# `su_confirm "……和 /var/log）"` 里 su_confi**rm **后面正好跟着空格，
# 于是"函数名的一部分"被当成 rm 命令，把正确的代码误报成违规。
# 所以要求 rm 前面不能是字母/数字/下划线（`[^[:alnum:]_]rm`），这才是命令词边界。
printf '%s' "$frag" | grep -qE '(^|[^[:alnum:]_])rm[[:space:]].*/var/log' \
  && ck "可执行代码里 /var/log 下没有任何 rm" 0 || ck "可执行代码里 /var/log 下没有任何 rm" 1

echo "=== 6. 升级后必须报告重启需求与新内核 ==="
printf '%s' "$frag" | grep -q '/var/run/reboot-required' && ck "检查 /var/run/reboot-required" 1 || ck "检查 /var/run/reboot-required" 0
printf '%s' "$frag" | grep -q 'reboot-required.pkgs' && ck "列出触发重启的包" 1 || ck "列出触发重启的包" 0
printf '%s' "$frag" | grep -qE 'kbefore.*kafter|krn_ver.*->' && ck "比对升级前后内核并提示重启生效" 1 || ck "比对升级前后内核" 0
printf '%s' "$frag" | grep -q 'WATCH' && ck "升级后复查自动修复守护是否还在" 1 || ck "升级后复查守护" 0
printf '%s' "$frag" | grep -q '99-dns-watch' && ck "升级后复查 apt 钩子是否还在" 1 || ck "升级后复查 apt 钩子" 0

echo "=== 7. 菜单与分发都接上了 ==="
bash "$SRC" --help 2>/dev/null | grep -q '14) 系统更新' && ck "帮助里列出菜单 14" 1 || ck "帮助里列出菜单 14" 0
bash "$SRC" --help 2>/dev/null | grep -q '15) 系统清理' && ck "帮助里列出菜单 15" 1 || ck "帮助里列出菜单 15" 0
bash "$SRC" --help 2>/dev/null | grep -q 'set-dns --sysupdate' && ck "帮助里列出 --sysupdate" 1 || ck "帮助里列出 --sysupdate" 0
bash "$SRC" --help 2>/dev/null | grep -q 'set-dns --sysclean' && ck "帮助里列出 --sysclean" 1 || ck "帮助里列出 --sysclean" 0
bash "$SRC" --help 2>/dev/null | grep -q '运行时菜单十五个选项' && ck "帮助标题已改成十五个选项" 1 || ck "帮助标题已改成十五个选项" 0
# 分发链路分三段，逐段断言（第一版把菜单号和执行函数硬拼成一条 pattern，两段都假失败）：
#   解析：--sysupdate -> CMD=sysupdate ｜ 裸数字 14 -> MODE=14
#   归一：case $MODE 的 14) MODE=; CMD=sysupdate
#   菜单：pick_mode 的 14) CMD=sysupdate
#   执行：if [ "$CMD" = sysupdate ]; then su_update ...
for pat in \
  '--sysupdate|--sys-update|--update)  CMD=sysupdate' \
  '--sysclean|--sys-clean|--clean)     CMD=sysclean' \
  '15|14|13|12|11|10|[0-9]) MODE=$a' \
  '14) MODE=; CMD=sysupdate' \
  '15) MODE=; CMD=sysclean' \
  '14) CMD=sysupdate' \
  '15) CMD=sysclean' \
  '"$CMD" = sysupdate ]; then su_update' \
  ; do
  grep -qF -- "$pat" "$SRC" && ck "分发已接：$pat" 1 || ck "分发已接：$pat" 0
done
# su_clean 那行有两个空格（对齐用的），不能用固定字符串匹配 —— 用正则容忍空格
grep -qE '" \$CMD" = sysclean.*su_clean|"[$]CMD" = sysclean.*su_clean' "$SRC" \
  && ck '分发已接："$CMD" = sysclean -> su_clean' 1 || ck '分发已接：sysclean -> su_clean' 0
# 未知菜单号仍要拒绝
o=$(bash "$SRC" 99 2>&1; echo rc=$?)
case "$o" in *"rc=2"*) ck "菜单号 99 仍被拒绝（退出码 2）" 1;; *) ck "菜单号 99 仍被拒绝" 0;; esac

echo "=== 8. --dry-run 与沙箱都不动真格 ==="
: > "$LOG"
o=$(PATH="$STUB:$PATH" DRY=1 bash -c '. '"$S"'; su_autoremove_safe 2>&1' ; true)
o=$(PATH="$STUB:$PATH" REAL=1 bash -n "$SRC" >/dev/null 2>&1; echo rc=$?)
case "$o" in *rc=0*) ck "主脚本语法合法" 1;; *) ck "主脚本语法合法" 0;; esac
# set-dns --sysclean --dry-run 在沙箱（REAL=0）里必须只说计划、不调包管理器
: > "$LOG"
out=$(SET_DNS_ETC=$T/etc SET_DNS_ZZ_LIB=$T/lib SET_DNS_ZZ_BIN=$T/bin SET_DNS_ZZ_NO_UPDATE=1 \
      PATH="$STUB:$PATH" bash "$SRC" --sysclean --dry-run 2>&1)
case "$out" in *"dry-run"*) ck "--sysclean --dry-run 打印计划" 1;; *) ck "--sysclean --dry-run 打印计划" 0;; esac
if grep -q '^apt-get -y autoremove' "$LOG"; then ck "--dry-run 不真的执行 autoremove" 0; else ck "--dry-run 不真的执行 autoremove" 1; fi
case "$out" in *"/var/log"*) ck "dry-run 里说明不会删 /var/log" 1;; *) ck "dry-run 里说明不会删 /var/log" 0;; esac

echo "=== SU_TEST PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
