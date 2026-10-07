# set-dns

一条命令搞定 Linux 的 DNS：**明文 / DoT / DoH 三种模式，带自动修复守护，改坏了会自己修回来。**

适用于 Debian 10~13、Ubuntu 18~24（以及绝大多数使用 `systemd` + glibc 的发行版）。

---

## 这个脚本解决什么问题

生产环境里 DNS 挂掉，八成不是"没配 DNS"，而是**配了之后被别人改回去**：

| 常见坑 | 现象 | set-dns 的处理 |
| --- | --- | --- |
| `systemd-resolved` 装完变符号链接 | 你改的是 `/etc/resolv.conf`，实际读的是 stub，改了不生效 | 先关掉/禁用它，再把文件写成**普通文件** |
| apt 装包触发 postinst 重写 | 装个软件 DNS 就没了，`raw.githubusercontent.com` 解析失败 | 装 `apt` 钩子，事务结束立刻修回来 |
| dhcpcd 租约续期覆盖 | 过一阵子 DNS 又变回运营商的了 | 给 dhcpcd 加 `nohook resolv.conf` |
| NetworkManager / netplan / cloud-init 抢管 | 重启后 DNS 又变 | 逐个关掉它们的 DNS 托管 |
| 上游 DNS 被污染 / 被限速 | 能解析但结果不对，或被 RST | 可选 DoT / DoH 加密模式 |

**核心思路**：不只是"写一次文件"，而是把所有会改写 `resolv.conf` 的写入者一次性掐掉，再加一个毫秒级的守护兜底。

---

## 三种模式

| 模式 | 怎么实现的 | 上游 | 适用 |
| --- | --- | --- | --- |
| **1) 明文 DNS** | 直接写 `resolv.conf` | `1.1.1.1` / `8.8.8.8`，有 IPv6 默认路由时再加 `2606:4700:4700::1111` / `2001:4860:4860::8888` | 最稳，任何机器都能用，**默认选项** |
| **2) DoT 加密** | `unbound` 转发 `TLS 853` | `1.1.1.1@853#cloudflare-dns.com`、`8.8.8.8@853#dns.google`（有 IPv6 时再加对应 v6 地址） | 想加密又不想装第三方软件（`unbound` 本身就够） |
| **3) DoH 加密** | `dnscrypt-proxy` 走 `HTTPS 443`，`unbound` 转发到它（本地 `127.0.0.1:5353`） | 官方解析器列表里挑，默认 `cloudflare` + `google` | 对抗干扰最强，443 端口最不容易被针对 |

> `unbound` 只能做 DoT，做不了 DoH —— 所以 DoH 必须靠 `dnscrypt-proxy`。这也是脚本里两个后端并存的原因。

---

## 快速开始

以 `root` 运行。

### 方式一：真正的一键（curl / wget 都行，会出交互菜单）

**不需要**先下载再 `chmod`。直接跑，脚本会问你选哪种模式：

```bash
# curl
bash <(curl -fsSL https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)

# wget（部分精简系统没有 curl，用这个）
bash <(wget -qO- https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)

# wget 落盘版（想留着反复用，等价于上面但会留下文件）
wget -qO set-dns.sh https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh && bash set-dns.sh
```

> **`bash <(wget -qO- ...)` 里的 stdin 是脚本内容本身（管道）**，所以脚本不能靠 `[ -t 0 ]` 判断有没有终端。
> `set-dns.sh` 改为直接打开 `/dev/tty` 读输入 —— 上面三种写法**都能正常弹出菜单**，不会静默跳过。
> （这是很多一键脚本的通病：`curl | bash` 时菜单直接跳过走默认值。）

跑起来会看到：

```
  请选择 DNS 模式：
    1) 明文 DNS        —— 1.1.1.1 / 8.8.8.8，最稳，任何系统都能用  [默认]
    2) DoT 加密        —— unbound 转发 TLS(853)，无第三方软件
    3) DoH 加密        —— dnscrypt-proxy 走 HTTPS(443)，最难被干扰
    4) 加装/加强防护守护 —— 只装防护，不改当前 DNS 配置
    5) 移除防护守护    —— 只拆防护，不改当前 DNS 配置
    6) 系统信息查询    —— 只看主机/CPU/内存/网络等信息，不做任何改动
    7) 基础工具安装    —— 缺啥装啥（curl/wget/vim/git 等），不动 DNS 配置

  输入 1/2/3/4/5/6/7（直接回车 = 1）:
```

**选 1/2/3 会配置 DNS 并自动装好防护守护**（不用额外操作）；**选 4/5 只动防护，选 6 只看信息，选 7 只装工具**，当前 DNS 配置一个字节都不改。正常装 DNS 时顺带就装了守护，所以 4 主要是给"守护被误删了想补回来"或"想加强一下"用的。

### 方式一补充：系统信息查询（菜单 6 / `--sysinfo`）

只想看一眼机器状态、不想动 DNS 时选这项（或直接 `set-dns --sysinfo`）。它**纯只读**——不碰 `resolv.conf`、不装任何东西、不写文件，也**不需要 root**：

```
系统信息查询
--------------------------------------------------------
主机名:           your-host
系统版本:         Debian GNU/Linux 13 (trixie)
Linux版本:        6.1.0-18-amd64
CPU架构:          x86_64
CPU型号:          Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz
CPU核心数:        2
CPU频率:          2.4 GHz
CPU占用:          1%
系统负载:         0.22, 0.29, 0.26
TCP/UDP连接数:    3|0
--------------------------------------------------------
物理内存:         420.52/958.00M (43.91%)
虚拟内存:         0M/1024M (0%)
硬盘占用:         5.9G/20G (32%)
--------------------------------------------------------
总接收:           572.84M
总发送:           301.86M
网络算法:         bbr fq
运营商:           AS64500 Example ISP
IPv4地址:         203.0.113.10
DNS地址:          127.0.0.1 1.1.1.1 8.8.8.8
地理位置:         US Los Angeles
系统时间:         Asia/Shanghai 2026-01-01 07:27 PM
运行时长:         3小时 0分
--------------------------------------------------------
操作完成
按任意键继续...
```

所有数据都来自本机（`/proc`、`uname`、`df`、`ip`、`/etc/resolv.conf`）；只有 **IPv4 / 运营商 / 地理位置** 三项要联网，走 `curl -s4 --max-time 6`，取不到就显示 `-`，断网时不会卡住也不会报错。想完全离线就用 `SET_DNS_SYSINFO_NO_NET=1`。**DNS 地址那一行显示的就是当前 `resolv.conf` 里生效的解析器**，查完顺手就能确认 DNS 对不对。

> 忘了菜单编号也没关系，`set-dns 1` / `set-dns 6` 这种裸数字写法一样认。

### 方式一补充：基础工具安装（菜单 7 / `--tools`）

刚重装的系统常常连 `curl` / `wget` / `vim` / `git` 都没有，这条会把「有什么、缺什么」列成一张表，缺的直接装：

```
基础工具一键安装
--------------------------------------------------------
基础工具
使用包管理器：apt-get
--------------------------------------------------------
 ✓ curl         已安装  ✗ htop         未安装  ✗ btop         未安装
 ✗ wget         未安装  ✗ tmux         未安装  ✗ ffmpeg       未安装
 ✓ vim          已安装  ✗ ncdu         未安装  ✗ cmatrix      未安装
 ✓ git          已安装  ✗ socat        未安装  ✗ sl           未安装
 ✓ tar          已安装  ✗ iftop        未安装  ✗ bastet       未安装
 ✓ unzip        已安装  ✗ ifconfig     未安装  ✗ ninvaders    未安装
 ✓ sudo         已安装  ✗ ranger       未安装  ✗ nsnake       未安装
 ✓ nano         已安装  ✗ fzf          未安装
--------------------------------------------------------
  [ -- ] 缺 15 个：wget htop tmux ncdu socat iftop ifconfig ranger fzf btop ffmpeg cmatrix sl bastet ninvaders nsnake

  怎么装？
    1) 只装核心工具（curl / wget / vim / git / tar / unzip / sudo / nano）[默认]
    2) 缺失的全装上（含 htop tmux ncdu socat iftop ranger fzf btop ffmpeg 等）
    3) 不装了，退出
  输入 1/2/3（直接回车 = 1）:
```

- **默认只装核心工具**，不会因为你想补个 `wget` 就把 `cmatrix` / `sl` / `bastet` 这些游戏拖下来；想全要就选 2，或者 `set-dns --tools-all`（`SET_DNS_TOOLS_ALL=1` 也行，无人值守用）。
- **自动适配包管理器**：apt-get / dnf / yum / apk / pacman / zypper 都认。
- 装之前会先 `apt-cache show` 剔掉当前源里根本不存在的包 —— 否则一个坏名字会让 apt 整批失败。
- **这是个 DNS 脚本，所以顺手拦了一种白等**：apt 要靠 DNS 才能解析软件源，装之前会先探一下 `deb.debian.org` 这类域名，解析不了就直接告诉你「先跑 `set-dns --plain` 修 DNS，再回来装工具」。
- 非 root 跑 `set-dns --tools` 只显示面板不安装（和 `--sysinfo` 一样），**不碰 `resolv.conf`**。

### 方式二：安装到系统（长期使用推荐）

装到 `/usr/local/sbin/set-dns` 之后就能随时 `set-dns --check`、切模式、还原：

```bash
# curl
curl -fsSL https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh -o /usr/local/sbin/set-dns

# 或者 wget
wget -qO /usr/local/sbin/set-dns https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh

chmod +x /usr/local/sbin/set-dns
set-dns
```

### 非交互式（一条命令直接指定，无人值守/自动化用）

```bash
set-dns --plain     # 明文
set-dns --dot       # DoT 加密
set-dns --doh       # DoH 加密
```

配合一键写法，想跳过菜单直接指定模式：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh) --doh
bash <(wget -qO-  https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh) --doh
```

> 完全无人值守（stdin 和 `/dev/tty` 都不可用，比如 cron / CI）时，脚本会打印一条提示并走**默认明文模式**，不会卡住等输入。

---

## 全部命令

```bash
set-dns                 # 交互菜单：选模式 + 配置 + 装守护（一步到位）
set-dns --plain         # 切明文（并确保守护在位）
set-dns --dot           # 切 DoT 加密（并确保守护在位）
set-dns --doh           # 切 DoH 加密（并确保守护在位）
set-dns --check         # 只看状态；有问题退出码 1（可以直接接监控）
set-dns --guard         # 只安装/重装/加强自动修复守护（不动 DNS 配置）
set-dns --unguard       # 只移除自动修复守护（不动 DNS 配置）
set-dns --sysinfo       # 只看系统信息（主机/CPU/内存/硬盘/网络/运营商，只读，不需要 root）
set-dns --tools         # 只装基础工具（curl/wget/vim/git 等，缺啥装啥，不动 DNS 配置）
set-dns --tools-all     # 基础工具全装（含 htop/tmux/ffmpeg 等可选件），不询问
set-dns --unlock        # 解除 chattr +i 锁
set-dns --restore       # 还原到首次运行前的原文件（含原来的符号链接形态）
set-dns --dry-run       # 只打印计划，一个文件都不动
set-dns -h              # 看用法
```

`--check` 大致长这样：

```
DNS 状态  2026-01-01 12:00:00   当前模式: DoH 加密
--------------------------------------------------------
  [ OK ] /etc/resolv.conf 是普通文件
  [ -- ] 未加锁
  当前内容:
  | # managed by set-dns v3 20260101-120000  mode=doh
  | nameserver 127.0.0.1
  | nameserver 1.1.1.1
  ...
  [ OK ] dnscrypt-proxy 运行中
  [ OK ] 本地 DoH 监听 5353
  [ OK ] udp/53 127.0.0.1（本地加密栈）
  [ OK ] raw.githubusercontent.com
--------------------------------------------------------
结论：正常
```

守护日志（`tail /var/log/dns-watch.log`）里的 `action` 怎么看：

- `action=ok` —— 一切正常，守护啥都没干
- `action=repaired` —— 刚发现 `resolv.conf` 被改坏（或变成符号链接），已修回
- `action=rescue` —— **两份托管副本都没了**，连恢复依据都丢了，已用内置的 `1.1.1.1` / `8.8.8.8` 救回一份能用的（出现这个请跑一次 `set-dns --guard` 重建副本）
- `action=rebuild-bak` —— `resolv.conf` 正常但托管副本丢了，已按当前内容把副本重建回来
- `action=ok-restartdcp` / `-restartunbound` —— 后端进程死了，已被拉起来
- 带 `-verify-fail` 后缀 —— 修完之后 `getent` 还是解析不了，通常是网络本身不通

---

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `SET_DNS_NO_V6=1` | 不写 IPv6 解析器 |
| `SET_DNS_NO_PROBE=1` | 跳过解析器可用性探测（探测不可达的会被剔除） |
| `SET_DNS_NO_FALLBACK=1` | 加密模式下不附明文兜底解析器（默认会附，防止加密栈挂了整机没 DNS） |
| `SET_DNS_DOH_SERVERS="a b"` | 指定 DoH 服务器名，默认 `cloudflare google` |
| `SET_DNS_SYSINFO_NO_NET=1` | 系统信息查询时不联网取 IPv4 / 运营商 / 地理位置（那几行显示 `-`） |
| `SET_DNS_TOOLS_ALL=1` | 基础工具不询问，直接全装（等同 `--tools-all`） |
| `SET_DNS_LOCK=1` | 额外 `chattr +i` 锁死文件（**不建议**：之后 apt 装包会失败，得先 `--unlock`） |
| `SET_DNS_ETC` / `SET_DNS_SBIN` / `SET_DNS_LOG` | 仅供沙箱测试改根路径 |

例子：

```bash
SET_DNS_NO_FALLBACK=1 set-dns --dot
SET_DNS_DOH_SERVERS="cloudflare google quad9-dnscrypt-ip4-filter-pri" set-dns --doh
```

---

## 自动修复守护是怎么工作的

**默认装、默认开**。选 1/2/3 配 DNS 时脚本会自动把守护装好，不需要你再做任何事。装四样东西，成本极低，互相兜底：

1. **`dns-watch.path`**（毫秒级）—— 监听 `/etc/resolv.conf` 的改动，一被改就立刻比对并修回。这是主力。
2. **`apt` 钩子** `/etc/apt/apt.conf.d/99-dns-watch` —— `DPkg::Post-Invoke`，每次 apt 事务结束跑一次。专治"装个包 DNS 就没了"。它还带**自愈**：守护脚本自身被删了，它会从 `/usr/local/sbin/dns-watch.sh.bak` 补回来（原先钩子只会静默 `|| true`，脚本一删就等于没有兜底）。
3. **`dns-watch.timer`**（5 分钟）—— 兜底轮询，防 `path` 单元漏事件。
4. **托管副本双写** —— 同一份内容存两处，见下。

守护比对的是"托管副本"。**副本存两份**：`/etc/set-dns.bak/resolv.conf.managed` 和 `/usr/local/sbin/dns-watch.managed`（不同目录，互为备份）。恢复逻辑分三级：

| 情况 | 守护的动作 |
| --- | --- |
| `resolv.conf` 与副本不一致 | 用主副本修回 → `action=repaired` |
| 主副本丢了 / 为空 | 用第二副本修回，并把主副本补回 |
| **两份副本都丢了** | 用内置的 `1.1.1.1` / `8.8.8.8` **救急**（加密模式还会先写 `nameserver 127.0.0.1`），并把救急内容回写成新副本 → `action=rescue` |
| `resolv.conf` 好、副本丢 | 反过来按当前内容重建副本 → `action=rebuild-bak` |

这个三级设计是线上实测逼出来的：早先守护只认主副本一份，副本一被删（或变成 0 字节），守护就**永久只写 `action=repair` 却从不修复**，整机 DNS 死在 `127.0.0.53` 上。现在任何一份活着都能自愈，两份全丢也不会把机器留在无 DNS 状态。

加密模式下守护还会检查 `unbound` / `dnscrypt-proxy` 是否活着、5353 有没有在监听，进程死了就重启——否则整机会没 DNS。

`dns-watch.service` 声明了 `After=network-online.target`，避免开机早期网络还没通就跑去 `getent`，把日志刷满 `verify-fail` 噪音。

日志满了会自己截断（超过 1MB 保留最后 256KB）。

不需要守护了就 `set-dns --unguard`（只拆防护，DNS 配置保持不动；原文件备份在 `/etc/set-dns.bak/guard-removed/`，随时 `set-dns --guard` 装回）。

---

## 安全设计：绝不把机器搞到没 DNS

- **顺序保证**：即使是加密模式，**第 2 步也先把 `resolv.conf` 写成明文**，确保后面 `apt` 装后端、`dnscrypt-proxy` 拉解析器列表时能正常解析，第 4 步才切到 `127.0.0.1`。
- **失败回退**：加密模式任何一步失败（装不上后端 / 配置校验不过 / 后端起不来），不会留个"文件写着 `mode=doh`、实际没有 DoH 后端"的矛盾状态——脚本会**自动回退成明文 DNS** 并退出 1，机器至少还能上网。
- **配置校验后再重启**：改 `unbound.conf` 一律先 `unbound-checkconf`，不过就回滚，不会让 `unbound` 起不来。
- **`--dry-run`**：先看要改什么，确认了再跑。
- **`--restore`**：还原到首次运行前的状态，连"原本是符号链接"这个形态都会一起还原。

### 踩过的两个真坑（已在代码里处理）

1. **unbound 的重复 `forward-zone`**
   直接往配置里追加一个 TLS `forward-zone "."`，`unbound-checkconf` **不报错**，但启动日志会出现
   `error: duplicate forward zone . ignored.`
   实际生效哪个取决于解析顺序，非常不可靠。所以脚本会先用 `#[set-dns-old]` 把原有 `forward-zone` 整段注释掉，再写新的。

2. **`dnscrypt-proxy.socket` 抢监听**
   Debian 包里 `/usr/lib/systemd/system/dnscrypt-proxy.service` 带 `Requires=dnscrypt-proxy.socket`，而那个 socket 单元监听的是 `127.0.2.1:53`。
   **只 `disable` 不够**：socket 会被 `sockets.target` 拉起来并"接管"监听，结果是配置里的 `listen_addresses = ['127.0.0.1:5353']` 被忽略，进程跑去绑 `127.0.2.1:53`，5353 上什么都没有。
   而且实测**在 drop-in 里写 `Requires=` 也清不掉**（`systemctl show -p Requires` 仍然列出那个 socket）。
   所以脚本直接写一份**完整的** `/etc/systemd/system/dnscrypt-proxy.service` 覆盖厂商单元（`/etc` 优先级更高、不继承原单元），再去 `mask` 掉 socket 和 `-resolvconf.service`。

---

## 卸载 / 回滚

```bash
set-dns --restore     # 还原 resolv.conf、unbound.conf、dnscrypt-proxy.toml
```

守护不会自动删。要拆有两档：

```bash
set-dns --unguard     # 推荐：只拆防护，DNS 配置不动，原文件备份在 /etc/set-dns.bak/guard-removed/
```

手动拆也行（效果同上）：

```bash
systemctl disable --now dns-watch.path dns-watch.timer
rm -f /etc/apt/apt.conf.d/99-dns-watch /usr/local/sbin/dns-watch.sh /usr/local/sbin/dns-watch.sh.bak /usr/local/sbin/dns-watch.managed
rm -f /etc/systemd/system/dns-watch.path /etc/systemd/system/dns-watch.service /etc/systemd/system/dns-watch.timer
systemctl daemon-reload
```

备份都在 `/etc/set-dns.bak/`：

```
resolv.conf.orig                 首次运行前的原始内容
resolv.conf.as-is                原始形态副本（cp -a，含符号链接）
resolv.conf.symlink              原来指向哪（如果原本是符号链接）
resolv.conf.managed              托管副本（主），守护按它修复
mode                             当前模式（plain / dot / doh）
unbound.conf.orig                unbound 原配置
unbound-setdns.frag              set-dns 写入的上游片段
dnscrypt-proxy.toml.orig         dnscrypt-proxy 原配置
dnscrypt-proxy.service.vendor    厂商单元原件
guard-removed/                   --unguard 拆下来的守护文件（可原样装回）
legacy/                          旧版本守护的备份
```

守护相关还有两个文件在 `/usr/local/sbin/`：

```
dns-watch.sh                     守护脚本本体
dns-watch.sh.bak                 它的留底，apt 钩子发现本体没了会自动补回
dns-watch.managed                托管副本（第二份，与 /etc/set-dns.bak/ 那份互为备份）
```

---

## 怎么跑测试

仓库里有两个测试脚本，都需要 `root`。

### 沙箱测试（推荐，安全，不碰线上）

用 `loop` 挂一个 `ext4` 镜像冒充 `/etc`，脚本以 `SET_DNS_ETC=...` 模式跑，**不会真的动系统服务**：

```bash
bash tests/verify-sandbox.sh
# === V3_DONE PASS=126 FAIL=0 ===
```

覆盖 15 段：三种模式、`--check` 识别、反复切换模式的幂等性、`--restore` 回滚、`--dry-run` 零改动、参数校验、交互菜单（用 `script` 模拟真实 pty，测 1/2/3/4/5/6/7、裸数字写法、直接回车、以及 `cat set-dns.sh | bash` 这种 stdin 为脚本管道的写法）、空备份时 `--restore` 必须失败、断链符号链接、旧版守护识别、**守护自愈（主副本丢失 / 两份全丢走救急 / 副本重建 / `--unguard` 不动 DNS 配置）**；`--sysinfo` 面板与 `--tools` 也都断言了「不动 `resolv.conf`、沙箱里绝不真装包」。

### 真机测试（会在真实 `/etc` 上操作）

```bash
bash tests/verify-live.sh
```

流程：先写明文兜底 → **`--sysinfo` 只读校验（断言 `resolv.conf` 与守护相关文件 md5 一个都没变、22 个字段齐全、裸数字 `set-dns 6` 也可用）** → **`--tools` 校验（面板能出、装完 `resolv.conf` 没变、解析仍可用、`set-dns 7` 也认；这段会真的装核心工具里缺的那几件，是预期行为）** → `--dot` 验到 853 的连接真的建立 → `--doh` 验 `dnscrypt-proxy` 起来了、监听 5353、有到 443 的连接 → `--check` → **手工把 `resolv.conf` 改成坏的，看守护是否几秒内修回** → 托管副本被毁的抗故障演练 → `--unguard` / `--guard` 往返。中间出错随时 `set-dns --restore`。

---

## 实测环境

- Debian 13 (trixie) 与 Ubuntu 22.04 上各测一遍，`unbound 1.26.1` / `dnscrypt-proxy 2.1.8`
- 沙箱断言：`PASS=126 FAIL=0`
- 真机 DoT：`resolv.conf` 首条 `127.0.0.1`，到 `1.1.1.1:853` / `8.8.8.8:853` 的 ESTAB 连接成立
- 真机 DoH：`dnscrypt-proxy` active，`127.0.0.1:5353` 有监听，到 `1.0.0.1:443` / `8.8.8.8:443` 的 HTTPS 连接成立，日志 `[google] OK (DoH) - rtt: 4ms`
- 抗故障：手工写 `nameserver 127.0.0.53` 后 **6 秒内被守护修回**，`getent` / `curl` 全程可用
- 抗故障（副本被毁）：手工删掉主托管副本、把两份副本全删，守护仍能修回 / 救急，不会把机器留在无 DNS 状态

---

## 常见问题

**Q：改完 `/etc/resolv.conf` 不生效？**
先看它是不是符号链接（`ls -l /etc/resolv.conf`）。指向 `../run/systemd/resolve/stub-resolv.conf` 的话你改的是假文件。`set-dns --check` 会直接告警这一条。

**Q：装完 `apt` DNS 就挂了？**
`systemd-resolved` 的 postinst 会把 `resolv.conf` 重建成指向 `127.0.0.53` 的符号链接，而那个 stub 服务又被停掉了。脚本装的 apt 钩子就是治这个的。

**Q：`Operation not permitted`？**
文件被 `chattr +i` 锁了：`set-dns --unlock`。

**Q：以后又坏了，最快怎么救？**
```bash
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
```
三条注意：① 报 `Operation not permitted` 就先 `chattr -i`；② 写进去没效果说明它是符号链接，先 `rm -f` 再写；③ 下次 `apt` 还会改坏——所以要靠守护。

**Q：DoH 起不来？**
脚本失败时会自己把 `journalctl -u dnscrypt-proxy -n 15` 和 `ss -lnup | grep -E ':(53|5353)'` 打出来。最常见就是 53 端口被别的解析器占着，或者机器出不去 443。

**Q：加密模式下为什么要保留明文兜底解析器？**
因为 `resolv.conf` 第一条是 `127.0.0.1`，万一本地加密栈没起来，glibc 会顺延到后面的明文解析器，机器不至于完全断网。不想要就 `SET_DNS_NO_FALLBACK=1`。

**Q：`bash <(wget -qO- ...)` 跑起来没弹菜单，直接装了明文？**
老版本会这样。因为这种写法下 stdin 是**脚本内容本身**，脚本用 `[ -t 0 ]` 判断"有没有终端"时得到的是"没有"，于是静默走了默认模式。现在脚本直接打开 `/dev/tty` 读输入，`curl` / `wget` / 管道三种写法都能正常弹菜单。用的是新版还跳过菜单，说明确实没有可用终端（cron、CI、`ssh -T` 等），这时走明文属预期行为。

**Q：机器上没有 `curl` 怎么办？**
用 wget 版：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)
```

**Q：`set-dns -h` 输出的帮助和以前不一样了？**
帮助文本现在是脚本内联的。以前靠 `sed -n '3,26p' "$0"` 读文件头，而 `bash <(curl ...)` 场景下 `$0` 是**已被消费的进程替换管道**，读不出内容，`-h` 会输出空。内联后任何运行方式都能正常显示。

**Q：我装完 DNS 就完事了，还要手动装守护吗？**
不用。选 1/2/3 配 DNS 时守护会**自动装好并启用**。`set-dns --guard` 是给"守护被误删了想补回来"或"想重装一下"用的。

**Q：怎么知道守护在正常工作？**
```bash
set-dns --check          # 会列出守护脚本、留底、托管副本、path/timer 启用状态、apt 钩子
tail -5 /var/log/dns-watch.log
```
大部分时候日志末行会是 `action=ok`。偶尔出现 `repaired` 属正常（说明确实有东西想改它，被拦下来了）。

**Q：日志里出现 `action=rescue` 严重吗？**
说明两份托管副本都没了（比如 `/etc/set-dns.bak/` 被整个删掉、备份盘满），守护已经用内置的 `1.1.1.1` / `8.8.8.8` 把 DNS 救回来了，**机器不会断网**，但"原来的配置内容"已经找不回来了。跑一次 `set-dns --dot`（或 `--doh` / `--plain`）重配即可恢复完整状态。

**Q：`--unguard` 会把我的 DNS 设置也拆掉吗？**
不会。它只停用并删除 `dns-watch` 相关的单元、脚本和 apt 钩子，`/etc/resolv.conf` 与加密后端配置原样不动。拆下来的文件备份在 `/etc/set-dns.bak/guard-removed/`，`set-dns --guard` 可以装回来。

**Q：菜单里的「6) 系统信息查询」会改我的 DNS 吗？**
不会，它是**纯只读**的：不写任何文件、不装软件、不调用 `systemctl`，连 root 都不需要（脚本里放在 root 检查之前拦截）。只有 IPv4 / 运营商 / 地理位置三项会联网，且都带 6 秒超时、失败就显示 `-`。它顺便会把当前生效的 `DNS地址` 打出来，常用来快速确认"我这台机器的 DNS 现在到底是什么"。

**Q：`--sysinfo` 卡住了 / 我不想让它联网？**
用 `SET_DNS_SYSINFO_NO_NET=1 set-dns --sysinfo`，只显示本机信息，IPv4 / 运营商 / 地理位置显示 `-`（IPv4 会退回从 `ip route get` 取内网地址）。正常情况下三项联网各最多 6 秒，不会更久。

**Q：菜单里的「7) 基础工具安装」会改我的 DNS 吗？**
不会。它只查「命令在不在」+ 缺的用包管理器装上，**不碰 `resolv.conf`、不改任何 DNS 文件**。非 root 跑的话只显示面板、不安装。

**Q：我只想补一个 `wget`，它会给我装一堆游戏吗？**
不会。默认走的是「只装核心工具」（curl / wget / vim / git / tar / unzip / sudo / nano）这条；`cmatrix` / `sl` / `bastet` 这些属于可选件，只有你主动选 2 或跑 `--tools-all` 才会装。

**Q：装工具报错说有包找不到？**
脚本会先 `apt-cache show` 过一遍，当前源里没有的包会被跳过并在面板上提示，不会让一个坏名字拖垮整批安装。如果**一个都没装成**，多半是 DNS 解析不了软件源 —— 脚本会在动手前就探一次 `deb.debian.org` 并直接提示你先跑 `set-dns --plain`。

**Q：非 Debian 系（CentOS / Alpine / Arch）能用装工具这条吗？**
能。`--tools` 会按顺序探测 `apt-get` / `dnf` / `yum` / `apk` / `pacman` / `zypper` 并调用找到的那个；面板顶部那行「使用包管理器」会告诉你它挑中了谁。

**Q：装完了面板还显示「未安装」怎么办？**
v3.5 前有这个 bug：`sl` / `bastet` / `ninvaders` / `nsnake` 装在 `/usr/games`，而 root 的 `PATH` 里没有它，旧代码只用 `command -v` 判断就会误报。现在判据是「`/usr/games` 也认」+「包管理器说装了就算装了」两条取或，所以装成功就一定会显示 `✓`。如果**现在**还看到 `✗`，那多半是真没装上——注意看它上面有没有 `[FAIL] 包管理器返回错误码 N`，以及末尾「还剩 N 个没装上」后面列出的名字。要确认某个包到底装没装，直接 `dpkg -l 包名 | grep ^ii`。

---

## 更新日志

### v3.4

- **新增菜单项 7「基础工具安装」与 `--tools` / `--tools-all` 子命令**：新装的系统常有连 `curl` / `wget` / `vim` / `git` 都没有的情况。这条会把清单里的工具列成三栏面板，逐个标 `✓ 已安装` / `✗ 未安装`，然后缺啥装啥。
  - **默认只装核心工具**（curl / wget / vim / git / tar / unzip / sudo / nano），不会因为想补个 `wget` 就把 `cmatrix` / `sl` / `bastet` / `ninvaders` / `nsnake` 这些游戏拖下来；想全要选 2，或直接 `--tools-all`（无人值守用 `SET_DNS_TOOLS_ALL=1`）。
  - **自动适配包管理器**：apt-get / dnf / yum / apk / pacman / zypper 都认，不是只写死 apt。
  - 装之前先 `apt-cache show` 剔掉当前源里根本不存在的包 —— 否则一个坏名字会让 apt 整批失败（清单里 `ifconfig` 实际对应 `net-tools`，就是靠这层映射）。
  - **顺手拦下一次白等**：apt 要靠 DNS 才能解析软件源，所以装之前会先探 `deb.debian.org` / `archive.ubuntu.com` / `mirrors.aliyun.com`，解析不了就直接告诉你「先跑 `set-dns --plain` 修 DNS，再回来装工具」，而不是让你等 apt 超时。
  - **不动 DNS**：不碰 `resolv.conf`、不改任何 DNS 相关文件；非 root 跑 `--tools` 只显示面板不安装（和 `--sysinfo` 一个待遇）。
- **版本横幅统一为 v3.4**，菜单提示改 `输入 1/2/3/4/5/6/7（直接回车 = 1）`。
- **测试**：沙箱断言 105 → **117 项**（`PASS=117 FAIL=0`），新增 `--tools` 面板 / 状态标记 / 沙箱不真装包 / 不动 `resolv.conf` / `set-dns 7` 裸数字 / `--tools-all` 断言，菜单 pty 测试扩到 1/2/3/4/5/6/7（选 7 后喂一个 `3` 表示不装，并断言"选 7 未误入主流程"）。真机新增 S0c 段。

### v3.5

- **修复：工具明明装上了，面板却报「未安装」**（用户实测发现）。Debian 把 `sl` / `bastet` / `ninvaders` / `nsnake` 装在 **`/usr/games`**，而 root 的 `PATH` 来自 `/etc/login.defs` 的 `ENV_SUPATH`，**不含 `/usr/games`**（只有普通用户的 `ENV_PATH` 才含）。旧代码只靠 `command -v` 判断，于是在 root 下：`apt-get` 明明装成功（日志里 `Setting up bastet (0.43-2) ...` 一行不落），面板却仍显示 `✗ 未安装`，末尾还补一句「还剩 4 个没装上（多半是当前源里没有，或网络不通）」—— 把用户往错误方向带。
  - 新增统一的 `tool_present()` 判据，两条取「或」：① 在补上 `/usr/games:/usr/local/games` 的 `PATH` 里能找到该命令；② **包管理器认为这个包已装**（`dpkg -l` / `rpm -q` / `apk info -e` / `pacman -Q`）。判据 ② 还顺带覆盖了「装了但可执行文件不在任何常规 `PATH`」的包。
  - 四处检测点全部换用它：面板格子、缺失计数、核心工具重挑、装完的复查。
- **安装失败不再静默**：原先 `apt-get install | tail -6` 里 `$?` 取到的是 `tail` 的退出码，包管理器真报错也会被当成成功。现在用 `${PIPESTATUS[0]}` 取包管理器自己的退出码，非 0 时明确打 `[FAIL] 包管理器返回错误码 N`；输出尾部也从 6 行放到 8 行。
- **末尾提示说清是哪些**：原先只说「还剩 4 个没装上」，现在会列出具体名字，并提示「也可能装到了 `PATH` 之外（用绝对路径跑）」。
- **测试**：沙箱断言 117 → **126 项**（`PASS=126 FAIL=0`）。新增本 bug 的回归断言，核心是那条不变式——**只要 `dpkg` 认为包已装，面板就不许显示「未安装」**（逐项对账，0 处矛盾）；另外直接单元测 `tool_present` 的 dpkg 回退分支（命令名故意不存在、包已装，必须判为已安装）与 `/usr/games` 在 `PATH` 外仍被认出，并断言源码里不再有裸 `command -v` 做安装判断。

### v3.3

- **新增菜单项 6「系统信息查询」与 `--sysinfo` 子命令**：打印主机名 / 系统版本 / 内核 / CPU 型号·核心数·频率·瞬时占用 / 负载 / TCP·UDP 连接数 / 物理·虚拟内存 / 硬盘 / 累计收发 / 拥塞算法 / 运营商 / IPv4 / 当前 DNS / 地理位置 / 系统时间 / 运行时长。
  - **纯只读**：不碰 `resolv.conf`、不装软件、不写任何文件，**也不需要 root**（所以放在 root 检查之前拦），选 6 绝不误入主流程把 DNS 重写一遍。
  - 数据全部取自本机（`/proc/stat`、`/proc/meminfo`、`/proc/net/dev`、`uname`、`df -hP`、`ip route get`、`/etc/resolv.conf`、`/etc/os-release`、`/etc/timezone`）；只有 IPv4 / 运营商 / 地理位置三项联网，`curl -s4 --max-time 6` 双源（`ipinfo.io` → `ip-api.com`）且失败显示 `-`，断网不卡死。想完全离线用 `SET_DNS_SYSINFO_NO_NET=1`。
  - CPU 占用用 `/proc/stat` 两次采样算差值（只依赖内核，不需要 procps / top），时区优先显示 IANA 名（如 `Asia/Shanghai`）而非 `CST` 缩写，`df -hP` 保证字段位置固定。
  - 面板末尾 `按任意键继续` 只在有终端时出现（无 tty 直接返回，不阻塞脚本化调用）。
- **支持裸数字参数**：`set-dns 1` / `set-dns 6` 等价于菜单编号（原先只有 `--plain` 这样的长参数，1/2/3/4/5/6 只在 `MODE` 别名表里、命令行传不进来）。
- **测试**：沙箱断言 99 → **105 项**（`PASS=105 FAIL=0`），新增 `--sysinfo` 面板与关键字段断言、`set-dns 6` 裸数字断言，菜单 pty 测试从 1/2/3/4/5 扩到 1/2/3/4/5/6 并断言"选 6 未误入主流程"。

### v3.2

- **默认安装自带防护守护**：选 1/2/3 配 DNS 时会自动把守护装好并启用，不需要再手动跑一次 `--guard`。
- **新增菜单项 4「加装/加强防护守护」与 5「移除防护守护」**：菜单从三选变五选。**选 4/5 只动防护，当前 DNS 配置一个字节都不改**（实现上是在 `pick_mode` 之后再拦一次 `guard` / `unguard`，否则会顺手把 DNS 重写一遍）。
- **新增 `--unguard` 子命令**：只停用并移除守护（先 `disable` 再删单元，否则 systemd 仍认为它在管 `resolv.conf`），DNS 配置不动；拆下来的文件存 `/etc/set-dns.bak/guard-removed/`，`--guard` 可原样装回。
- **修复守护的致命盲区：托管副本丢失后永不修复**（线上实测发现）。原先守护只认 `/etc/set-dns.bak/resolv.conf.managed` 一份，一旦它被删或变成 0 字节，守护就**永久只写 `action=repair` 却从不修复**，整机 DNS 死在 `127.0.0.53` 上。现在改成：
  - 托管副本**双写两处**（`/etc/set-dns.bak/resolv.conf.managed` + `/usr/local/sbin/dns-watch.managed`，不同目录互为备份）；
  - 恢复按 主副本 → 第二副本 → 内置救急内容 三级降级，缺失的副本会自动补回；
  - 两份全丢时用内置 `1.1.1.1` / `8.8.8.8` **救急**（加密模式先写 `127.0.0.1`），绝不把机器留在无 DNS 状态；日志区分 `repaired` / `rescue` / `rebuild-bak`。
  - **关键细节**：两份副本都没了时不能盲信 `resolv.conf` 的内容去重建副本——它可能正是被改坏的那一份（比如 `127.0.0.53`）。脚本会先检查它是否含可用 `nameserver`、是否指向死亡 stub、加密模式下首条是否为 `127.0.0.1`，判定不可信就走救急。否则会把坏配置固化成"真相"，以后每次都照它修。
- **修复 apt 钩子静默失效**：原先钩子是 `DPkg::Post-Invoke { "脚本 >/dev/null 2>&1 || true"; }`，守护脚本一旦被删，钩子什么都不做、也从不报错，等于没有兜底。现在钩子会先检查脚本是否存在，不在就从 `/usr/local/sbin/dns-watch.sh.bak` 补回。
- **`dns-watch.service` 增加 `After=network-online.target`**：避免开机早期网络未通就 `getent`，把日志刷满 `verify-fail` 噪音、误导排障。
- **`--check` 增强**：新增守护脚本留底检查、托管副本三态报告（正常 / 只剩第二副本 / 两份全丢并计为 `bad`）。
- **测试**：新增第 15 段"守护自愈"共 23 项断言（主副本丢失、两份全丢走救急、救急内容回写、副本重建、`--unguard` 不动 DNS 配置、重复 `--unguard` 友好提示、`--guard` 装回），沙箱断言从 68 项增至 **99 项**（`PASS=99 FAIL=0`）；菜单测试同步覆盖 4/5 并断言"未误入主流程"。

### v3.1

- **新增 wget 一键运行支持**：`bash <(wget -qO- ...)` / `wget -qO set-dns.sh ... && bash set-dns.sh` 均可，README 把 curl 与 wget 两套写法并列给出（精简系统常只有 wget）。
- **修复一键运行时交互菜单被跳过**：`bash <(curl ...)` 和 `bash <(wget ...)` 这类写法里 **stdin 是脚本内容本身**，原先用 `[ -t 0 ] && [ -t 1 ]` 判断终端，结果判定为"无终端"，菜单被静默跳过、直接按明文安装。现在改为**直接打开 `/dev/tty` 读取**（`has_tty()` + `read < /dev/tty`），三种一键写法都能正常弹出菜单；确实没有终端时（cron / CI / `ssh -T`）才回退默认明文并打印提示。
- **修复 `bash <(curl ...)` 下 `--help` 输出为空**：帮助文本原先是 `sed -n '3,26p' "$0"` 从文件头读的，而这种写法下 `$0` 是已被消费的进程替换管道，读不出内容。改为**内联 here-doc 帮助文本**，任何运行方式都能正常显示，也不再依赖固定行号。
- **脚本头部注释同步补充一键运行示例**。

### v3.0

- **新增 DoT 加密模式**：基于 `unbound` 的 `forward-tls-upstream`，不需要任何第三方软件。
- **新增 DoH 加密模式**：`dnscrypt-proxy` 走 HTTPS/443，本地监听 `127.0.0.1:5353`，`unbound` 转发给它；解析器列表走官方 `[sources]` 自动拉取，默认选 `cloudflare` + `google`。
- **新增运行时交互菜单**：不带参数运行会问你要哪种模式（1 明文 / 2 DoT / 3 DoH，回车默认明文）；非交互环境（管道/重定向）自动降级为明文，不会卡住。
- **新增 `--plain` / `--dot` / `--doh` / `--menu`** 子命令，以及 `SET_DNS_MODE` / `SET_DNS_DOH_SERVERS` / `SET_DNS_NO_FALLBACK` 环境变量。
- **修复 unbound 重复 `forward-zone` 的坑**：改写前先把原 `forward-zone` 整段注释掉（`#[set-dns-old]`），否则会静默报 `duplicate forward zone . ignored.` 并按不可预测的顺序择一生效。
- **修复 `dnscrypt-proxy.socket` 抢监听**：改为写完整单元覆盖厂商单元并 mask socket（drop-in 清 `Requires=` 实测无效）。
- **新增失败回退**：加密模式任一步失败自动退回明文 DNS，绝不留"文件与后端不一致"的状态。
- **新增旧版守护退役**：识别早期的 `dns-guard.py` / `dns-guard.*` 并存档、停用，避免两套守护互相打架。
- **`--check` 全面增强**：识别当前模式、报出上游方式（DoT / 本地 5353）、检查后端进程与监听端口。
- **健壮性**：备份改为 `cp -a` 保形态；断链符号链接不再静默留空备份；`unbound.conf` 改动前一律 `unbound-checkconf` 校验，不过就回滚。
- **测试**：新增沙箱测试（loop ext4，68 项断言，含 pty 模拟交互菜单）与真机端到端测试。

### v2.0

- 新增自动修复守护三件套：`dns-watch.path` + apt 钩子 + `dns-watch.timer`。
- 新增 `--check` / `--guard` / `--unlock` / `--restore` / `--dry-run`。
- 解析器写入前先探测可用性，不可达的自动剔除；遵守 glibc `MAXNS=3` 限制。
- 备份与还原改为保形态（含符号链接）。

### v1.0

- 一条命令写入 `1.1.1.1` / `8.8.8.8`（含 IPv6）。
- 关闭 `systemd-resolved` / `dhcpcd` / `NetworkManager` / `netplan` / `cloud-init` 对 `resolv.conf` 的托管。
- 基础备份与 `--restore`。

---

## 免责声明

脚本会修改 `/etc/resolv.conf`、`/etc/unbound/`、`/etc/dnscrypt-proxy/`、`/etc/systemd/system/`、`/etc/apt/apt.conf.d/` 等系统位置，并会停止/禁用 `systemd-resolved`、`dhcpcd` 等相关服务。

- 请在生产环境使用前，先在测试机或快照上跑一遍 `--dry-run`。
- 首次运行前建议确认你能通过控制台 / VNC 访问机器，以防网络配置意外中断。
- 所有改动都有备份（`/etc/set-dns.bak/`），`set-dns --restore` 可还原。

作者不对任何因使用本脚本造成的数据丢失或服务中断负责。

**请只在你有权管理的机器上使用。**

---

## 许可

[MIT](LICENSE)
