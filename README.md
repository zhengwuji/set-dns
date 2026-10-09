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

**不需要**先下载再 `chmod`。直接跑，脚本会问你选哪种模式。

#### 中国大陆服务器（用这两条之一）

GitHub 直连在大陆**不是完全不通，而是时通时不通** —— 实测某台腾讯云 Debian 13 连续 6 次请求成功 3 次、失败 3 次，失败时报：

```
curl: (35) Recv failure: Connection reset by peer
```

一键命令必须一次就成，所以大陆机器用下面这条**走 GitHub 加速镜像**的写法：

```bash
# 【推荐】大陆专用：经 gh-proxy.com 加速
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)
```

想更保险，用这条**自动回退**的（gh-proxy → ghfast → ghproxy.net，哪个通用哪个）：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh 2>/dev/null \
    || curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh 2>/dev/null \
    || curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)
```

装到系统里也一样，把 URL 换成镜像前缀即可：

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh -o /usr/local/sbin/set-dns
chmod +x /usr/local/sbin/set-dns
set-dns
```

> **这些镜像途径是实测过的，不是随便挑的**：4 个 GitHub 反代前缀取回的 `set-dns.sh` **sha256 与直连逐字节一致**（`1ddaeb6e…d7af`，211730 字节）。
> 另外 `gh-proxy.com` 实测 0.33s、`ghfast.top` 1.42s、`ghproxy.net` 0.75s。

**脚本装好之后不需要再管这件事** —— 它内部所有要访问 GitHub 的地方（升级自身、装 3x-ui、拉外部加速脚本、DoH 解析器列表）都会**自动按本机实测结果选择可用途径**。想手动看一遍本机走哪条最快：

```bash
set-dns --gh-check        # 或 --mirror-selftest；只读，不需要 root
```

#### 仓库是 private 时（可选，公开仓库可跳过）

private 仓库**匿名访问一律 404**，镜像站自己也是匿名取源文件，所以它们同样拿不到。
想让一键命令可用，必须带 token（只发往 GitHub 自己的域名，见下方「token 安全」）：

```bash
# 推荐：token 从环境变量读，不进命令行
export GH_TOKEN=<你的 token>
bash <(curl -fsSL -H "Authorization: token $GH_TOKEN" https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)

# 或者把 token 放进配置文件（连 history 都不进）
printf '%s\n' '<你的 token>' > ~/.setdns-gh-token && chmod 600 ~/.setdns-gh-token
bash <(curl -fsSL https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh)
```

脚本支持三种 token 来源（优先级从高到低）：
`SET_DNS_GH_TOKEN` → `GH_TOKEN` / `GITHUB_TOKEN` → `~/.setdns-gh-token` 或 `/etc/set-dns.gh-token`。

> **token 只发往 GitHub 自己的域名**（`github.com` / `api.github.com` / `raw.githubusercontent.com` 等）。
> 一旦检测到目标仓库是私有的，脚本就**只走直连**、不走任何第三方镜像 ——
> 因为反代镜像要拿到文件就必须转发请求，也就必然能看到你的 Authorization 头。
> 私有仓库时 token 绝不外发；公开仓库时才用镜像（此时没有凭据可泄露）。
> 这两条路互斥，单元测里有 18 条断言盯着（含伪装域名 `github.com.evil.com` 不被信任）。

#### 海外服务器（直连即可）

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
    8) 自动换源        —— 测速找出最快的软件源并替换，不动 DNS 配置
    9) 自定义 SSH 端口 —— 改 sshd 监听端口，改前备份、校验失败自动回滚
   10) 内核管理        —— 装/更新/卸载 xanmod BBRv3 内核，看当前内核与 BBR 状态
   11) TCP 加速管理    —— BBR + FQ/FQ_PIE/CAKE、ECN、IPv6、防 CC、网络自适应优化
   12) 3x-ui 面板      —— 装/升级 3x-ui，自动走 GitHub 加速镜像（大陆服务器可用）

  输入 1/2/3/4/5/6/7/8/9/10/11/12（直接回车 = 1）:
```

**选 1/2/3 会配置 DNS 并自动装好防护守护**（不用额外操作）；**选 4/5 只动防护，选 6 只看信息，选 7 只装工具，选 8 只换软件源，选 9 只改 SSH 端口，选 10 只管内核，选 11 只管 TCP 加速，选 12 只管 3x-ui**，当前 DNS 配置一个字节都不改。正常装 DNS 时顺带就装了守护，所以 4 主要是给"守护被误删了想补回来"或"想加强一下"用的。

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
地理位置:         US Example City
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

### 方式一补充：自动换源（菜单 8 / `--mirror`）

国内机器（或海外机器想拉国内包）时，官方源可能慢得离谱。这项会**逐个测速**，把发行版软件源换成最快的那个：

```
自动换源（找最快的软件源并替换）
--------------------------------------------------------
当前软件源:
  文件: /etc/apt/sources.list.d/debian.sources  [deb822]
    URIs: https://deb.debian.org/debian/            （主仓库）
    URIs: https://security.debian.org/debian-security/  （安全仓）
--------------------------------------------------------
正在测速（主仓库 + 安全仓 各一次，每个源最多 5 秒）……

  速度排名（主仓库 + 安全仓，越小越快）：
    #    镜像源      主仓库      安全仓      合计
    1    official    0.201674s   0.191547s   0.393s
    2    aliyun      0.338787s   0.070819s   0.410s
    3    tencent     0.272973s   0.284267s   0.557s
    4    cloudflare  1.027303s   0.196782s   1.224s
    ...
--------------------------------------------------------
  [ OK ] 选定 aliyun：主仓库 https://mirrors.aliyun.com/debian
  [ -- ]               安全仓 https://mirrors.aliyun.com/debian-security
  [ OK ] 原配置已备份到 /etc/set-dns.bak/mirror/（1 个文件）
  [ OK ] 已改写 /etc/apt/sources.list.d/debian.sources
  [ -- ] 跑一次 apt-get update 验证新源……
  [ OK ] 换源成功，apt 可正常使用
  [ -- ] 想还原：set-dns --mirror-restore（备份在 /etc/set-dns.bak/mirror/）
```

- **只动发行版自己的仓库**。`is_distro_uri()` 只认主机在白名单里的地址（`deb.debian.org` / `security.debian.org` / `archive.ubuntu.com` / `ports.ubuntu.com` …，以及候选镜像源的域名）。**Docker / NodeSource / packages.microsoft / MongoDB / PGDG 这类第三方源一个字节都不碰** —— 把第三方源的 URL"顺手换掉"是换源脚本最常见的翻车方式（换完直接装不上包）。
- **支持两种格式**：老式单行 `deb [arch=amd64 signed-by=...] https://... trixie main` 和新式 deb822（`Types:` / `URIs:` / `Suites:` / `Components:` / `Signed-By:` 分字段）。deb822 只替换 `URIs:` 那一行，**`Signed-By` 原样保留**（弄丢它 apt 会直接拒绝所有包）。
- **安全仓单独测**：`trixie-security` 和主仓库经常在不同机器上，所以两个地址分别计时、分别替换，不会把安全仓一起指到主仓库去。
- **换完自动验证**：改完立刻跑一次 `apt-get update`。**看的不只是退出码** —— apt 有时候退出码 0 但内部打了 `E:` / `Err:` / `W: Failed`，这两种信号都算失败，会**自动回滚**到换源前的配置并复验。所以不会出现"换完 apt 坏了但脚本说成功"。
- **一键还原**：`set-dns --mirror-restore`。备份在 `/etc/set-dns.bak/mirror/`，带一个 `manifest` 记录原路径。没换过源时跑它只会友好提示，不会报错。
- 想指定用哪个源、不测速：`SET_DNS_MIRROR=aliyun set-dns --mirror`（可选 `official` / `aliyun` / `tuna` / `ustc` / `163` / `huawei` / `tencent` / `bfsu` / `sjtu` / `nju` / `cloudflare` / `leaseweb`）。
- **非 root 跑 `set-dns --mirror` 只做只读部分**（列出当前源 + 测速排名），不改任何配置。
- Ubuntu 系（含 Mint / Pop!_OS 这类 `ID_LIKE="ubuntu debian"` 的衍生版）会自动按 Ubuntu 的仓库组件（`main restricted universe multiverse`）和安全仓路径处理；不认识 `os-release` 或不是 Debian 系的系统会直接拒绝，不会瞎改。
- **和 DNS 完全无关**：换源只碰 `/etc/apt`，`resolv.conf` 与自动修复守护全程不动。

### 方式一补充：自定义 SSH 端口（菜单 9 / `--ssh-port`）

改 `sshd` 的监听端口。**这类操作最容易把自己锁在门外**，所以脚本上了四层防护：

```
自定义 SSH 连接端口
--------------------------------------------------------
  [ -- ] 当前生效端口: 22
  [ -- ] 实际在监听: 22
  [ -- ] 端口由 /etc/ssh/sshd_config 决定

  [ -- ] 旧端口: 22    新端口: 2222    旧端口保留
  [ -- ] 已有首次备份 /etc/set-dns.bak/ssh/orig/，不覆盖
  [ OK ] 已改写 /etc/ssh/sshd_config（旧 Port 行注释为 #set-dns-old#）
  [ -- ] 没发现活动防火墙；云主机记得去安全组放行 2222/tcp
  [ OK ] sshd 配置语法校验通过
  [ OK ] 已重启 ssh.service
  [ OK ] 新端口 2222 已在监听

  [ !! ] 先别断开当前这个会话！新开一个窗口验证：ssh -p 2222 root@<本机IP>
  [ -- ] 确认能登进来之后，再关掉旧会话；连不上就 set-dns --ssh-port-restore
--------------------------------------------------------
```

用法：

```bash
set-dns --ssh-port          # 交互：问你要哪个端口、旧端口留不留
set-dns --ssh-port=2222     # 直接改为 2222（关掉旧端口）
SET_DNS_SSH_PORT=2222 set-dns 9
set-dns --ssh-port-restore  # 一键还原到改之前的配置
```

四层防护，任何一层不过就**不会**让你失去 SSH：

1. **改前整份备份** `/etc/set-dns.bak/ssh/orig/`（`sshd_config` + 所有含 `Port` 的 `sshd_config.d/*.conf`，带 `manifest` 记录原路径）。
2. **`sshd -t` 语法校验不通过就不重启** —— 直接用本次改动前的快照回滚。
3. **重启后轮询 `ss -lnt` 确认新端口真的起来了**，没起来立刻用快照回滚并重启回原端口。
4. **可选保留旧端口**：选"也保留旧端口"时新旧端口同时监听，验证通了再手工关旧的。

两个真坑（脚本里已经处理，值得知道）：

- **`ssh.socket` 套接字激活模式下，`sshd_config` 里的 `Port` 是无效的** —— 端口由 `ListenStream=` 决定。脚本会检测 `ssh.socket` 是否 enabled，是的话额外写一份 `ssh.socket.d/99-set-dns-port.conf`，光改 `sshd_config` 会"改了没反应"。
- **`sshd_config` 末尾如果有 `Match` 块，往文件尾追加 `Port` 会掉进 `Match` 的作用域里**（只对匹配的用户生效，等于没改）。所以脚本把 `Port` 块插在**第一个 `Match` 之前**，`Match` 块内的 `Port` 一律不动。

其他细节：

- **端口被占用且不是自己的 sshd 会直接拒绝**（用 `ss -lntp` 打出占用者），不会盲目抢端口。
- 会顺手放行防火墙：`ufw` / `firewalld` 自动加规则；**只有 `iptables` 且规则里有 `DROP`/`REJECT` 时只警告不自动改**（怕误删你自己的规则）。SELinux 开着的话会 `semanage port -a` 给 `ssh_port_t` 加端口。
- **云主机还必须在安全组放行新端口**，脚本管不到云控制台 —— 这也是为什么第 4 层"保留旧端口"默认建议用它验证。
- 幂等：重复对同一端口执行不会堆积 `Port` 行（有 `set-dns ssh port begin/end` 标记块，重写时先清干净）。
- **非 root 跑只显示当前端口，不修改**；沙箱模式（`SET_DNS_ETC` 指向别处）跳过重启与监听确认，只验配置改写。

### 方式一补充：内核管理（菜单 10 / `--kernel`）

xanmod 的 BBRv3 内核管理面板（kejilion 风格）：

```
您已安装 xanmod 的 BBRv3内核
当前内核版本： 7.10.0-x64v3-xanmod1
  [ -- ] CPU 微架构档位： x64v3  （Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz）
  [ -- ] 档位判定依据： glibc hwcaps（本机最高支持 x64v3）
  [ -- ] 已装的 xanmod 内核包： 3 个
  [ -- ] BBR 状态： bbr 可用（当前算法 bbr，队列 fq）
  [ -- ] 可回退的发行版内核： linux-image-6.12.111+deb13-cloud-amd64

内核管理
--------------------------------------------------------
    1. 更新BBRv3内核                 2. 卸载BBRv3内核
--------------------------------------------------------
    0. 返回上一级菜单
--------------------------------------------------------
 请输入你的选择：
```

用法：

```bash
set-dns --kernel          # 交互菜单（面板 + 1 更新 / 2 卸载 / 0 返回）
set-dns --kernel-update   # 装/更新到源里最新的 BBRv3 内核
set-dns --kernel-remove   # 卸载 xanmod 内核（会先确认还有别的内核能启动）
set-dns 10                # 裸数字也行
```

**三条底线**（这是所有内核管理脚本翻车的地方）：

1. **按 CPU 微架构档位选包**。xanmod 按 `x64v1` ~ `x64v4` 分档，**档位选高了内核直接起不来**（比如没有 `avx512f` 的 CPU 装 `x64v4`）。脚本自动判档，判定顺序是：
   - **首选 glibc hwcaps**（`ld.so --help` 里 `x86-64-v3 (supported, searched)` 这类）—— glibc 自己就是按 CPUID + OS 支持判的，最权威；
   - 退到 **CPU flags** 兜底；
   - 再退到 **正在运行的内核名**（`7.10.0-x64v3-xanmod1` 里就带档位，跑起来了就说明 CPU 至少支持 v3），**取三者里最高的那一档**。
   - 想手工指定：`SET_DNS_KERNEL_LEVEL=x64v3 set-dns --kernel-update`。面板会打印「档位判定依据」，能直接看出档位是怎么来的。

   > **踩过的坑（已在 v3.8 修）**：一开始只按 `/proc/cpuinfo` 的 flags 判档，结果在某台 Xeon E5 机器上被判成 `x64v2` —— 明明这台机器正在跑 `x64v3` 内核。
   > 原因有两个：**① LZCNT 这条指令在 Intel 上很多内核只报 `abm`，不报字面的 `lzcnt`**（两者是同一件事）；
   > **② SSE3 在 Linux 的 flags 里叫 `pni`，不叫 `sse3`**。照字面去 grep `lzcnt` / `sse3` 就会缺项，从而判低一档。
   > 判低同样有害：会建议你装功能更少的 `x64v2` 内核。现在 flags 兜底已经把这两个坑补上，且优先走 glibc hwcaps。

2. **卸 xanmod 之前必须先确认还有别的内核能启动**。脚本用 `dpkg-query` 找非 xanmod 的 `linux-image-*`；**一个都没有时会拒绝直接卸载**，改为问你要不要先装一个发行版自带内核（Ubuntu 用 `linux-image-generic`，其他用 `linux-image-cloud-amd64`）。否则卸完重启就再也进不去系统了，只有云厂商的 VNC / rescue 能救。

3. **装完 / 卸完都跑 `update-grub`**，并打印「重新后会进哪个内核」。不需要手写引导菜单 —— Debian/Ubuntu 的 `/etc/kernel/postinst.d/zz-update-grub` 本来就会在装内核时自动更新。

其他细节：

- **装完要重启才生效**，脚本会明确提示，并给出查看引导菜单与 `uname -r` 确认的命令。
- **卸载时源默认保留**（下次想装回来不用重新配源）。想连源一起拆：`SET_DNS_KERNEL_KEEP_REPO=0`，或交互时同意，源文件与 keyring 会备份到 `/etc/set-dns.bak/kernel/`。
- **绝不抢 BBR 参数**。`/etc/sysctl.d/99-degwd.conf`、`99-kejilion-bbr.conf` 是别的脚本写的，内核管理**只报告** BBR 是否可用，不去改 `tcp_congestion_control` / `default_qdisc`。源码里有沙箱断言盯着这一点。
- **判档的 `CPU 微架构档位` 和「正在跑的内核」矛盾时会警告**（探测比在跑的还高），不阻断，但提示可以用 `SET_DNS_KERNEL_LEVEL` 降档。
- 非 root 跑只显示面板；`--dry-run` 只出计划不真装。

### 方式一补充：TCP 加速管理（菜单 11 / `--accel`）

一张大面板（编号沿用 ylx.me 的「TCP加速 一键安装管理脚本」），把 BBR 加速、ECN/IPv6 开关、网络自适应优化、内核查看/删除都收在一处：

```
TCP 加速 一键安装管理（本脚本内置版）
--------------------------------------------------------
  信息: Debian GNU/Linux 13 (trixie) kvm x86_64 7.10.0-x64v3-xanmod1
  状态: 已安装 xanmod 的 BBRv3 加速内核，bbr 可用
  拥塞控制算法: bbr   队列算法: fq   Headers状态: 已匹配（可编译模块）
  [ -- ] 网卡 ens3 实际 qdisc: cake
  [ -- ] 配置文件: /etc/sysctl.d/99-zz-setdns-accel.conf（当前内核可用算法：reno bbr cubic）
--------------------------------------------------------
  0. 升级脚本                        88. 卸载脚本
  ---------------------------------------- 内核安装
  1. 安装 BBR 原版编译内核            7. 安装 官方稳定内核
  2. 安装 BBRplus 版内核              8. 安装 官方最新内核
  3. 安装 Lotserver(锐速)内核         9. 安装 XANMOD(main)
  4. 安装 官方 cloud 内核            10. 安装 XANMOD(LTS)
  5. 安装 BBRplus 新版内核           11. 安装 XANMOD(EDGE)
  6. 安装 Zen 官方版内核             12. 安装 XANMOD(RT)
  ---------------------------------------- 加速启用
 20. 使用 BBR+FQ 加速               21. 使用 BBR+FQ_PIE 加速
 22. 使用 BBR+CAKE 加速             23. 使用 BBRplus+FQ 版加速
 24. 使用 Lotserver(锐速)加速       25. 编译安装 brutal 模块
 26. 编译安装 LotSpeed 模块         27. 使用 LotSpeed 加速
  ---------------------------------------- 系统配置
 30. 开启 ECN                       31. 关闭 ECN
 32. 系统网络自适应优化             33. 防 CC/DDoS 轻量优化
 35. 禁用 IPv6                      36. 开启 IPv6
 37. 手动提交合并内核参数           38. 手动编辑内核参数
  ---------------------------------------- 内核管理
 51. 查看排序内核                   52. 删除保留指定内核
 55. 卸载全部加速                   99. 退出脚本
  ---------------------------------------- 其它工具
 60. 网络精调(tcpfit 联动)          92. 一键 DD 重装系统
--------------------------------------------------------
  请输入数字：
```

用法：

```bash
set-dns --accel                 # 交互菜单（上面这张面板）
set-dns --accel-status          # 只看状态（只读，不需要 root）
set-dns --accel-bbr             # 20) BBR + FQ
set-dns --accel-fqpie           # 21) BBR + FQ_PIE
set-dns --accel-cake            # 22) BBR + CAKE
set-dns --accel-ecn-on          # 30) 开启 ECN
set-dns --accel-ecn-off         # 31) 关闭 ECN
set-dns --accel-optimize        # 32) 系统网络自适应优化
set-dns --accel-ddcc            # 33) 防 CC/DDoS 轻量优化
set-dns --accel-ipv6-off        # 35) 禁用 IPv6
set-dns --accel-ipv6-on         # 36) 开启 IPv6
set-dns --accel-merge           # 37) 手动提交合并内核参数
set-dns --accel-edit            # 38) 手动编辑内核参数
set-dns --accel-kernels         # 51) 查看排序内核（只读，不需要 root）
set-dns --accel-kernel-del      # 52) 删除保留指定内核
set-dns --accel-restore         # 55) 卸载全部加速（只删本脚本写的）
set-dns --accel-kernel=xanmod-lts  # 10) 装某个内核变体（bbr-orig/bbrplus/lotserver/bbrplus-new/zen/cloud/official/latest/rt/xanmod-main|xanmod-lts|xanmod-edge|xanmod-rt）
set-dns 11                      # 裸数字也行
```

**四条设计原则**（都是为了不翻车）：

1. **只写自己的文件，绝不抢别人的 BBR 参数**。加速参数统一写到 `/etc/sysctl.d/99-zz-setdns-accel.conf`——`zz` 前缀不是随便起的：systemd-sysctl 按 `/usr/lib` → `/run` → `/etc` 读、**同目录按字典序后读的赢**，而 `99-degwd.conf`（`bbr` + `cake`）和 `99-kejilion-bbr.conf`（`fq` + `bbr`）已经写死了这两个键。**文件名排在它们后面才改得动**，否则就是"改了不生效"的头号原因。别人那两个文件本脚本一字节都不碰（真机测试用 md5 断言盯着）。
2. **不支持的算法直说，不硬编内核**。菜单里 11 个内核变体和 8 种加速方式，能不能在 Debian/Ubuntu 上真跑是查过仓库才写的：
   - **能直接做的**：20/21/22（`bbr` + `fq`/`fq_pie`/`cake`，`sch_fq`/`sch_fq_pie`/`sch_cake` 模块 Debian 都有）、30/31 ECN、32 自适应优化、33 防 CC、35/36 IPv6、37/38 sysctl 合并与编辑、51/52 内核查看与删除、55 一键还原、4/7/8 官方 cloud/稳定/最新内核、9~12 xanmod 四个分支。
   - **明确做不到、只给说明的**：1 BBR 原版编译内核（仓库里没有这个包）、2/5 BBRplus（需要带 `tcp_bbrplus` 模块的第三方编译内核，本机 `tcp_available_congestion_control` 里根本没有）、3/24 Lotserver（**只支持 CentOS 6/7 内核**）、6 Zen（Debian 仓库不提供）、23/27（对应模块没装），面板会打印「为什么装不了」+ 推荐替代（用 20/21/22 的 BBR，或菜单 10 的 xanmod BBRv3）。选这些的退出码是 **1**，不会假装成功。
   - **依赖外部脚本、需二次确认的**：25 brutal（`tcp.hy2.sh`）、26 LotSpeed（`uk0/lotspeed`）、60 tcpfit。下载后先 `bash -n` 语法校验，不合法直接丢弃，再执行，执行完**重放一次 `sysctl --system`**（外部脚本改完模块后 systemd-sysctl 可能已经跑过了，参数不重放不生效）。
   - **92 一键 DD 重装系统默认不动手**：这是会把整机清空的操作，只打印提示和外部脚本路径；确实要用得显式 `SET_DNS_ACC_ALLOW_DD=1`。
3. **改配置一定先备份、一定幂等**。`acc_apply()` 每次改键前把当前文件 `cp -a` 到 `/etc/set-dns.bak/accel/prev.conf`，然后 `sed` 删掉同名旧行再追加（所以反复切 FQ→FQ_PIE→CAKE→FQ，文件里永远每个键只有一行，不会越滚越长）；`sch_*` 模块名去重追加进 `/etc/modules-load.d/setdns-qdisc.conf`，重启也还在。
4. **32 优化不会把你自己关掉的东西又打开**。自适应优化会**继承当前 ECN 与 IPv6 状态**再写参数——否则"先用 35 禁了 IPv6，再点一次 32 又给开回来"（这是上游脚本踩过的坑，沙箱里有专门两条回归断言）。

其他细节：

- **内存/核数自适应**：`<2GB` → 收发缓冲 16MB / `somaxconn` 32768；`2~8GB` → 32MB / 65535；`8GB+` → 64MB / 1048576；`netdev_max_backlog = 核数 × 10000`（夹在 32768~100000）。防 CC 的 `tcp_max_syn_backlog` 也**按你的 `somaxconn` 来，不用上游那个夸张的 1024000**。
- **52 删内核有硬屏障**：先算「删完还剩几个 `linux-image-*`」，**剩 0 个就拒绝执行**（"操作已阻止：删完就没有能启动的内核镜像了（重启即变砖）"）——对账发生在删除**之前**；删的正好是当前在跑的内核时会额外要求输入大写 `YES`。
- **55 卸载全部加速是干净的**：只删 `/etc/sysctl.d/99-zz-setdns-accel.conf` 和 `/etc/modules-load.d/setdns-qdisc.conf`（都先备份），然后 `sysctl --system` 让 `99-degwd.conf` / `99-kejilion-bbr.conf` 的配置重新生效。
- 非 root 跑只显示面板；`--dry-run` 只出计划不写文件。选 32 时面板会打印实际写入了多少项。
- **和菜单 10 的分工**：菜单 10 管"装哪个内核 / 卸哪个内核"，菜单 11 管"内核参数怎么调 + 加速怎么开"。两边都**不碰** `resolv.conf` 与自动修复守护。

### 方式一补充：3x-ui 面板（菜单 12 / `--xui`）

一键装 [3x-ui](https://github.com/MHSanaei/3x-ui)，**并修好官方脚本在中国大陆服务器上装不上的问题**。

```
3x-ui 面板安装 / 升级（自动走 GitHub 加速镜像）
--------------------------------------------------------
3x-ui 面板状态
--------------------------------------------------------
  [ -- ] 未安装（/usr/local/x-ui/x-ui 不存在）
  [ -- ] 管理脚本: 未安装
  [ -- ] 数据库: 未找到 /etc/x-ui/x-ui.db
  [ -- ] 没看到 x-ui / xray 的监听
--------------------------------------------------------

  正在挑选 GitHub 加速镜像（每个最多 15 秒）……
    https://ghfast.top/                可用 1.32s（含 releases/latest）
    https://ghproxy.net/               可用 2.71s（含 releases/latest）
    https://gh-proxy.com/              （raw 或 releases/latest 不通）
    https://hk.gh-proxy.com/           （raw 或 releases/latest 不通）
  [ OK ] 选定加速前缀：https://ghfast.top/（探测耗时 1.32s）
  [ -- ] 下载官方 install.sh……
  [ OK ] 已下载 install.sh（95521 字节，语法校验通过）
  [ OK ] 已改写 10 处 GitHub 地址走加速前缀（github.com 4 处 / raw 6 处）
  [ OK ] 原配置已备份到 /etc/set-dns.bak/xui/（面板数据 + bin/ 自定义文件）

  [ !! ] 下面开始执行官方安装脚本；它会装依赖、停旧面板、换二进制、可能重启服务
  [ -- ] 官方脚本自己会校验安装包的 sha256，镜像只负责搬运字节
```

用法：

```bash
set-dns --xui              # 交互面板：1 装/升级  2 看状态  3 自动证书  4 卸载  0 返回
set-dns --xui-install      # 装/升级（自动探测最快的加速镜像）
set-dns --xui-status       # 只看状态（只读，不需要 root）
set-dns --xui-uninstall    # 卸载（面板数据先备份）
set-dns --xui-cert         # 自动申请 IP 证书并启用 HTTPS（Let's Encrypt，6 天自动续期）
set-dns 12                 # 裸数字也行
SET_DNS_GH_PROXY=https://ghfast.top/ set-dns --xui-install   # 指定加速前缀
SET_DNS_XUI_NONINTERACTIVE=1 set-dns --xui-install           # 无人值守（默认端口/随机凭据）
```

**为什么官方一键装不上，以及怎么修的**

官方写法 `bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)` 在大陆机器上的失败**不在脚本本身**，而在它内部要访问 `github.com` 主站：

| 脚本内部的动作 | 用的地址 | 大陆实测 |
| --- | --- | --- |
| 取最新版本号 `resolve_latest_tag` | `https://github.com/.../releases/latest` | **卡死**（30s 超时，0 字节） |
| 下安装包（78MB） | `https://github.com/.../releases/download/<tag>/...tar.gz` | **卡死** |
| 下校验边车 `.sha256` | 同上 + `.sha256` | **卡死** |
| 下 `x-ui.sh` / `x-ui.service.*` | `https://raw.githubusercontent.com/...` | **时通时不通**（见下） |
| 版本号退路 | `https://api.github.com/...` | 通（0.8s） |

> `raw.githubusercontent.com` 那格原本写的是「通（1s）」。后来在同一台机器上复测发现它**并不稳定** —— 连续 6 次请求成功 3 次、失败 3 次，失败时报 `curl: (35) Recv failure: Connection reset by peer`。所以脚本里所有 GitHub 下载都改走了多途径回退（见下面的「GitHub 下载层」）。

迷惑点在于 **`github.com:443` 的 TCP 是连得上的**（`time_connect=0.08s`），只是 HTTP 响应永远回不来 —— 所以表现为「脚本下载下来了、跑起来了，但卡在装包那一步」，报的是：

```
Failed to fetch x-ui version, it may be due to GitHub API restrictions, please try it later
Downloading x-ui failed, please be sure that your server can access GitHub
```

很容易误判成「脚本坏了」。而 `raw.githubusercontent.com` / `api.github.com` / `objects.githubusercontent.com` 全部正常 —— **只针对 github.com 主站**。

本脚本的修法是：**不改官方脚本的任何逻辑**，下载后把里面写死的 GitHub 绝对地址整体改写成带加速前缀的地址，再交给 `bash` 执行。真机逐条验过，前缀对脚本用到的**三种 URL 形态全部成立**：

- `前缀 + https://raw.githubusercontent.com/...` → 200；**文件不存在时仍然是 404**，所以脚本里 `require_repo_files` 的探测不会被骗过；
- `前缀 + https://github.com/.../releases/latest` → 302，且 `url_effective` 带 `/tag/<版本>`，`resolve_latest_tag` 照常解析；
- `前缀 + https://github.com/.../releases/download/...` → 200；78MB 安装包**下载完 sha256 与官方边车逐字节一致**（`d7cbe0bf...9390`）。

**校验和没有被绕过** —— 官方脚本照旧下 `.sha256` 并比对，镜像只负责搬运字节。

几个实现细节：

- **两级挑镜像**。先找「raw + `releases/latest` 都能过」的（最省事，不必退到 API）；一个都没有时，才退到「只代理 raw」的前缀 —— 此时版本号走 `api.github.com` 直连（大陆上本来就是通的），所以能用到的镜像数量从 2 个变成 5 个以上。探测逻辑就是拿**真实地址**去试，不维护硬编码的可用性列表（这类镜像站存活周期很短）。
- **`api.github.com` 不改写** —— 它是 `releases/latest` 失败时的退路，直连可用；顺带避免 `sed` 误伤（`https://github.com/` 这个模式本身不会命中 `api.github.com`，测试里有专门一条断言盯着）。
- **改写后必过 `bash -n`**，不合法直接丢弃、不执行。
- **镜像挂了自动退回直连**，不会因为镜像站死掉就装不了（海外机器直连本来就通）。
- **装之前先查 DNS**：官方脚本第一件事是 `apt-get install` 依赖，DNS 不通会白等。脚本会先探 `deb.debian.org`，解析不了就让你先跑 `set-dns --plain`。
- **升级前备份 `/etc/x-ui` 与 `/usr/local/x-ui/bin`** 到 `/etc/set-dns.bak/xui/`。`bin/` 里可能有你手工加的 geoip/geosite 文件（官方脚本自己也会把它们挪走再还原，两边不冲突）。
- 装完顺手打印面板信息（端口 / 用户名 / 路径）与 `x-ui / xray` 的监听端口。面板管理本身用官方的 `x-ui` 命令（`x-ui`、`x-ui settings`、`x-ui restart` 等）。
- **和 DNS 完全无关**：`resolv.conf` 与自动修复守护全程不动；`--xui-status` 是只读的，不需要 root。

#### 自动申请 IP 证书（`--xui-cert`，菜单 12 的选项 3）

一键给面板上 HTTPS：Let's Encrypt 的 **IP 证书**（6 天有效，acme.sh 自动续期）。

```bash
set-dns --xui-cert        # 自动完成：申请 -> 装到 /root/cert/ip -> 写面板配置 -> 重启
```

完整流程（每一步都实测过）：

1. **多源探测公网 IPv4** —— `ipv4.icanhazip.com` / `ifconfig.me` / `4.ident.me` / `api.ipify.org`
   逐个试（有的源在大陆不可达，单源会失败）
2. **检查 80 端口空闲** —— standalone 校验要占用它；被占用时直接说清楚，不闷头失败
3. **已有证书且还剩 >1 天有效期则跳过** —— 避免频繁打 LE 的速率限制
4. `acme.sh --issue -d <ip> --standalone --certificate-profile shortlived --days 6`
5. `--installcert` 装到 `/root/cert/ip/`，并注册 `reloadcmd`
6. `x-ui cert -webCert ... -webCertKey ...` 写面板配置 + 重启
7. 探测 HTTPS 是否真的起来，并确认续签 cron 已注册

**为什么不用面板自带的证书菜单**：它有个**必填交互**
（`read -rp "Port to use for ACME HTTP-01 listener"`），无人值守时会读到 EOF；
而且失败时只提示 `Make sure port 80 is open...`，把真正原因掩盖了（见下）。

**两个真坑（都已修）**

| 坑 | 现象 | 根因 |
| --- | --- | --- |
| acme.sh 装不上且**谎报成功** | `[INF] Installation of acme.sh succeeded.` 紧跟着 `/root/.acme.sh/acme.sh: No such file or directory` | 官方用 `curl -s https://get.acme.sh \| sh`，而 get.acme.sh 是**二段下载器**（内部还要去 raw.githubusercontent.com 拉主脚本）。大陆上两道坎都可能失败，而 `\| sh > /dev/null 2>&1` 把报错全吞了只看退出码 |
| IP 证书被 LE 拒绝 | `rejectedIdentifier`：`Default profile does not permit IP address identifiers.` | IP 证书**必须**用 `shortlived` profile。而官方报错提示是 `Make sure port 80 is open...` —— **指向完全无关的方向**（实测 80 端口一直空闲、公网可达），很容易让人白折腾安全组 |

对应修法：

- `xui_acme_bootstrap()` **预装 acme.sh** —— 从加速镜像下主脚本，
  **就地命名为 `acme.sh`**（`--install` 会 `cp ./acme.sh`，名字不对报 `cannot stat`），
  再 `sh ./acme.sh --install`（纯本地操作，不联网）。装好后
  `command -v ~/.acme.sh/acme.sh` 为真，install.sh 与 x-ui.sh 里的 `install_acme` 都会被跳过。
- `xui_patch_installer()` / `xui_patch_cli()` **检查并补 shortlived profile**
  （上游新版已自带，所以是"检查 + 必要时补"，不无脑改写），
  同时**关掉 acme.sh 自动升级** —— 官方装完证书会跑 `--upgrade --auto-upgrade`，
  这会立刻联网拉 GitHub 并写一个**每天**都自升级的 cron；证书只有 6 天、
  要频繁续签，不该让自升级来搅局。
- `xui_patch_cli()` 还修补 `/usr/bin/x-ui`（**截图里那个报错就是它报的**，
  不是 install.sh）—— 它里面同样有 get.acme.sh 二段下载和 3 处 auto-upgrade。

**数据安全**：安装/升级会**自动比对入站与客户端数量**，发现变少立刻从安装前的备份回滚。
备份 DB 用 SQLite 一致性快照（`sqlite3 .backup` / python3 `backup()` API），
不用 `cp`（面板在写时 `cp` 会拿到半写状态的页，恢复时报 `database disk image is malformed`）。

#### 升级旧面板的两个真坑（脚本已加前后自检）

把 2023 年的老 3x-ui（`0.3.4.4`）直接升到 `3.9.0` 时，有**两个在面板上完全看不出来**的数据问题会让 xray 彻底起不来 —— 实测踩到并修好了：

**坑 1：Shadowsocks-2022 的密钥不是合法的 32 字节 base64**

SS2022 要求密钥是「**32 字节**的 base64」—— 44 字符且结尾是 `=`。那台机器上存的是 44 字符、但严格解码出 **33 字节**（结尾是普通字符，少了 `=` 填充）：

```
inbound 2（10440）2022-blake3-aes-256-gcm：密钥解出 33 字节，必须是 32 字节
```

**老 xray 1.7.5 不校验长度，照样启动**；新 xray 26.x 直接：

```
Failed to start: main: failed to create server > proxy/shadowsocks_2022: bad key
```

然后 exit 23。结果是 **`x-ui.service` 显示 `active`、面板能正常打开，但 xray 根本没起来**，10440 / 40530 一个端口都不监听。只看面板或 `systemctl status` 完全发现不了。

> 同一个 44 字符的值，老 xray 报 `Configuration OK.`，新 xray 报 `bad key` —— 逐条验过，不是猜测。

**坑 2：迁移会把老客户端的 `enable` 置成 0**

老版本 DB 没有 `clients` 表，`x-ui migrate` 会新建一张并把老客户端迁移过去、`enable` 置 0。新面板看到 `enable=0` 就打印：

```
Remove Inbound User <email> due to expiration or traffic limit
```

并把该用户从 `config.json` 里剔掉（`"clients": []`）—— **客户端连不上，而面板上没有任何报错**。

**脚本怎么处理**

**不偷偷改**用户的加密密钥或客户端开关（那会直接改变客户端要填的配置），而是：

1. **升级前自检** `xui_precheck()`：检出旧版 DB schema、逐个 SS 入站校验密钥字节数、列出被停用的客户端，并打印症状与后果。
2. **升级后自检** `xui_postcheck()`：跑 `xray -test -config` 看配置是否合法、`pgrep xray-linux` 看**进程是否真的在跑**、`ss` 数 TCP 监听、再查一遍被停用的客户端。
   **这一步是必须的** —— 官方脚本 `rc=0` 只代表它自己没报错，不代表 xray 活着。
3. **显式修复开关** `SET_DNS_XUI_FIX_SS=1`：换掉不合法的密钥（用 `os.urandom` 生成合法的，并打印新密钥让你同步客户端）、把「`total=0` 且 `expiry=0` 即无限制」却被停用的客户端恢复。

> **顺序很关键**：官方脚本结尾会跑 `x-ui migrate`，**会把装之前修好的东西又改回 0**（真机实测：precheck 修完，装完又变 0）。所以修复必须在官方脚本跑完**之后**再补一次，并重启面板让 `config.json` 重新生成 —— 脚本里 `xui_postcheck()` 就是干这个的，改完会自动复验。

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
set-dns --mirror        # 测速找出最快的发行版软件源并替换（只动发行版仓库，第三方源保留）
set-dns --mirror-restore # 还原换源前的软件源配置
set-dns --ssh-port      # 交互改 SSH 端口（改前备份、校验失败自动回滚）
set-dns --ssh-port=2222 # 直接把 SSH 端口改成 2222
set-dns --ssh-port-restore # 把 SSH 端口配置还原到改之前
set-dns --kernel        # 内核管理（面板 + 1 更新 / 2 卸载 / 0 返回）
set-dns --kernel-update # 装/更新到源里最新的 xanmod BBRv3 内核
set-dns --kernel-remove # 卸载 xanmod 内核（先确认还有别的内核能启动）
set-dns --accel         # TCP 加速管理（大面板：加速启用 / ECN / IPv6 / 优化 / 内核查看删除）
set-dns --accel-status  # 只看 TCP 加速状态（只读，不需要 root）
set-dns --accel-bbr     # BBR + FQ 加速（另有 --accel-fqpie / --accel-cake）
set-dns --accel-optimize # 系统网络自适应优化（按内存与核数生成 sysctl 参数）
set-dns --accel-ddcc    # 防 CC/DDoS 轻量优化（syncookies + syn 重试 + 半连接队列）
set-dns --accel-ecn-on  # 开启 ECN（--accel-ecn-off 关闭）
set-dns --accel-ipv6-off # 禁用 IPv6（--accel-ipv6-on 开启）
set-dns --accel-kernels # 查看已装内核（排序，标识当前运行中，只读）
set-dns --accel-kernel-del # 删除 / 保留指定内核（删完没有可启动内核时拒绝执行）
set-dns --accel-kernel=xanmod-lts # 装指定内核变体
set-dns --accel-restore # 卸载全部加速（只删本脚本写的配置，别人的 sysctl 不动）
set-dns --xui           # 3x-ui 面板管理（1 装/升级 2 看状态 3 卸载）
set-dns --xui-install   # 装/升级 3x-ui（自动探测最快的 GitHub 加速镜像，大陆服务器可用）
set-dns --xui-status    # 只看 3x-ui 状态（只读，不需要 root）
set-dns --xui-uninstall # 卸载 3x-ui（面板数据先备份到 /etc/set-dns.bak/xui/）
set-dns --xui-cert      # 自动申请 IP 证书并给面板启用 HTTPS（Let's Encrypt shortlived，6 天自动续期）
set-dns --gh-check      # 检查本机到 GitHub 各下载途径的连通性与速度（只读，不需要 root）
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
| `SET_DNS_MIRROR=aliyun` | 换源时不用测速结果，直接用指定的那个源（`official` / `aliyun` / `tuna` / `ustc` / `163` / `huawei` / `tencent` / `bfsu` / `sjtu` / `nju` / `cloudflare` / `leaseweb`） |
| `SET_DNS_MIRROR_NO_PROBE=1` | 换源时跳过测速，直接用第一个候选（给测试用；平时别加，否则可能换上比现在更慢的源） |
| `SET_DNS_SSH_PORT=2222` | 改 SSH 端口时不用交互，直接用这个端口（等同 `--ssh-port=2222`） |
| `SET_DNS_SSH_KEEP=1` | 改 SSH 端口时保留旧端口（新旧同时监听，验证通了再关旧的；最安全的做法） |
| `SET_DNS_KERNEL_LEVEL=x64v3` | 强制指定内核微架构档位（`x64v1`~`x64v4`），默认按 CPU 自动判定 |
| `SET_DNS_KERNEL_KEEP_REPO=0` | 卸载 xanmod 内核时连 xanmod 源和 keyring 一起拆掉（默认保留） |
| `SET_DNS_ACC_AVAIL="reno bbr cubic"` | 覆盖「当前内核支持的拥塞算法」列表（测试用；平时别加） |
| `SET_DNS_ACC_KERNEL=xanmod-lts` | 跳过交互，直接装指定的内核变体（等同 `--accel-kernel=xanmod-lts`） |
| `SET_DNS_ACC_DEL="3 4"` | 跳过交互，直接删指定编号（或包名）的内核（等同 `--accel-kernel-del` 的选择） |
| `SET_DNS_ACC_ALLOW_DD=1` | 允许从菜单 11 的「92 一键 DD 重装系统」直接起外部重装脚本（**默认禁止**，这是会清空整机的操作） |
| `SET_DNS_GH_MIRROR=https://gh-proxy.com/` | 指定**所有** GitHub 下载用的镜像途径，跳过自动探测（`--gh-check` 可看有哪些可选） |
| `SET_DNS_GH_PROXY=https://ghfast.top/` | 装 3x-ui 时不用探测，直接用指定的 GitHub 加速前缀 |
| `SET_DNS_XUI_FIX_SS=1` | 装/升级 3x-ui 前把不合法的 Shadowsocks-2022 密钥换成合法的，并恢复被误停用的客户端（**会改变客户端要填的配置**，新密钥会打印出来） |
| `SET_DNS_XUI_NONINTERACTIVE=1` | 装 3x-ui 时走无人值守（官方脚本的 `XUI_NONINTERACTIVE=1`，默认端口 + 随机凭据） |
| `SET_DNS_LOCK=1` | 额外 `chattr +i` 锁死文件（**不建议**：之后 apt 装包会失败，得先 `--unlock`） |
| `SET_DNS_ETC` / `SET_DNS_SBIN` / `SET_DNS_LOG` | 仅供沙箱测试改根路径 |
| `SET_DNS_CPUINFO` / `SET_DNS_LDSO` / `SET_DNS_RUNNING_KERNEL` | 仅供测试替换判档依据（假 cpuinfo / 假 glibc / 假在跑的内核） |

例子：

```bash
SET_DNS_NO_FALLBACK=1 set-dns --dot
SET_DNS_DOH_SERVERS="cloudflare google quad9-dnscrypt-ip4-filter-pri" set-dns --doh
SET_DNS_MIRROR=aliyun set-dns --mirror
SET_DNS_SSH_KEEP=1 set-dns --ssh-port=2222
SET_DNS_KERNEL_LEVEL=x64v3 set-dns --kernel-update
SET_DNS_ACC_KERNEL=xanmod-lts set-dns --accel-kernel=
```

---

## GitHub 下载层（大陆可用）

脚本内部有好几处要从 GitHub 拉东西。直连在大陆**时通时不通**，所以这些下载统一走一个「多途径依次尝试」的层：

| 脚本内部要用 GitHub 的地方 | 触发时机 |
| --- | --- |
| 拉最新版 `set-dns.sh` | 菜单 11 的 `0 升级脚本` |
| 官方 3x-ui `install.sh` | 菜单 12 装/升级 3x-ui |
| 3x-ui 的 78MB 安装包与 `.sha256` | 同上（在官方脚本内部，靠 URL 改写走镜像） |
| 外部加速脚本（brutal / LotSpeed / tcpfit） | 菜单 11 的 `25` / `26` / `60` |
| dnscrypt-proxy 解析器列表 | DoH 模式（菜单 3） |

**途径清单**（`gh_raw_url()` 会为每个 GitHub URL 生成这些候选，按顺序试，第一个成功的就用）：

| 类型 | 途径 | 说明 |
| --- | --- | --- |
| 反代前缀 | `gh-proxy.com` / `ghfast.top` / `ghproxy.net` / `hk.gh-proxy.com` | 把完整 GitHub URL 拼在后面。其中 `ghfast.top` / `ghproxy.net` **还能透传 `github.com/.../releases/latest` 的 302**，所以 3x-ui 那边能用它们拿 tag |
| jsDelivr CDN | `cdn.jsdelivr.net` / `fastly.jsdelivr.net` / `gcore.jsdelivr.net` | 另一套路径语法 `cdn.jsdelivr.net/gh/<user>/<repo>@<ref>/<path>`，**只能取仓库里的文件**，不能代理 releases 下载 |（**按分支名引用会被 CDN 缓存住，实测 `@main` 持续返回上一版**；脚本内部一律按 commit SHA 引用）
| 直连 | `raw.githubusercontent.com` | 排最后兜底（海外机器首选它） |

**两种 URL 形态不能混用** —— 这是实现时最容易搞错的地方：反代前缀要拼在**完整 URL** 前面，jsDelivr 要**重新拼路径**。脚本里 `gh_raw_url()` 负责这件事，单元测专门断言了两种形态都生成正确、且直连排最后。

**启动时自动探测一次**：`gh_pick_mirror()` 拿仓库里的 `LICENSE`（1KB，不是 180KB 的脚本本身）把每个途径都试一遍，把最快的那个提到候选列表最前面，之后所有下载都复用它。所以大陆机器上不会先去撞那 3 次必然失败的直连。

想手动看本机走哪条最快（只读，不需要 root）：

```bash
set-dns --gh-check        # 别名 --mirror-selftest
```

```
GitHub 下载途径自检
--------------------------------------------------------
  探测目标：https://raw.githubusercontent.com/zhengwuji/set-dns/main/LICENSE（仓库里的 LICENSE，1KB）

  途径                                                     状态   耗时
  --------------------------------------------------------------------
  gh-proxy.com                                               OK       0.75s
  ghfast.top                                                 OK       0.73s
  ghproxy.net                                                OK       1.29s
  hk.gh-proxy.com                                            OK       1.35s
  https://cdn.jsdelivr.net  jsDelivr CDN                     OK       0.71s
  https://fastly.jsdelivr.net  jsDelivr CDN                  OK       0.72s
  https://gcore.jsdelivr.net  jsDelivr CDN                   OK       0.72s
  直连 GitHub（大陆通常不行）                               OK       0.68s

  [ OK ] 8 个途径可用 —— 脚本内的所有 GitHub 下载会自动按这个结果排序
  [ -- ] 本次首选：https://fastly.jsdelivr.net/gh/zhengwuji/set-dns@9f3c1a2b.../LICENSE
```

> 示例里 jsDelivr 那条是**按 commit SHA** 引用的（`@9f3c1a2b...`）—— 不是分支名。
> jsDelivr 对分支名有服务端缓存，实测 `@main` 会持续返回上一版，所以脚本内部一律解析成 SHA。
>
> 上面这份输出是在**海外链路**上跑的，所以直连也是 OK、并且可能被选成最快。在大陆机器上跑，直连那一行会是 `HTTP 000 失败`，首选会落在某个镜像上。

想固定用某个途径、不要探测：

```bash
SET_DNS_GH_MIRROR=https://gh-proxy.com/ set-dns --xui-install
```

**内容一致性**：7 个途径取回的 `set-dns.sh` 与直连**逐字节一致**（sha256 `1ddaeb6e…d7af`）。这是单元测 `tests/verify-ghdl.sh` 每次都会重新验的断言 —— 镜像只搬运字节，不替换内容。

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

仓库里有五个测试脚本，其中前三个需要 `root`。

### 沙箱测试（推荐，安全，不碰线上）

用 `loop` 挂一个 `ext4` 镜像冒充 `/etc`，脚本以 `SET_DNS_ETC=...` 模式跑，**不会真的动系统服务**：

```bash
bash tests/verify-sandbox.sh
# === V3_DONE PASS=292 FAIL=0 ===
```

覆盖 16 段：三种模式、`--check` 识别、反复切换模式的幂等性、`--restore` 回滚、`--dry-run` 零改动、参数校验、交互菜单（用 `script` 模拟真实 pty，测 1/2/3/4/5/6/7/8/9/10/11/12、裸数字写法、直接回车、以及 `cat set-dns.sh | bash` 这种 stdin 为脚本管道的写法）、空备份时 `--restore` 必须失败、断链符号链接、旧版守护识别、**守护自愈（主副本丢失 / 两份全丢走救急 / 副本重建 / `--unguard` 不动 DNS 配置）**、**换源（deb822 改写保留 `Signed-By`、第三方源一个字节没动、备份与还原、不动 `resolv.conf`）**、**SSH 端口（改写在 `Match` 之前、`Match` 里的 `Port` 不被当成全局端口、旧 `Port` 被注释、drop-in 一起改、幂等、非法端口拒绝、备份与还原）**、**内核管理（判档逻辑用假 `cpuinfo` 逐个 CPU 档位验、xanmod 源判定、沙箱内不真装真卸、不写 `sysctl.d`）**、**TCP 加速（`--accel-*` 写键幂等、算法不支持时拒绝、ECN 不误伤 `tcp_ecn_fallback`、IPv6 双键、自适应优化保留现状、删内核的"零可启动内核"屏障、四个做不到的内核变体必须非 0 退出、`99-zz-` 文件名必须排在别人后面）**、**3x-ui（菜单 12 进面板、选 12 不误入主流程、`--xui-status` 零改动）**；`--sysinfo` 面板与 `--tools` 也都断言了「不动 `resolv.conf`、沙箱里绝不真装包」。第 16 段会连带跑一遍 `tests/verify-mirror.sh`。

### 3x-ui 加速镜像单元测（联网、不需要 root）

```bash
bash tests/verify-xui.sh
# === XUI_TEST PASS=20 FAIL=0 ===
```

从 `set-dns.sh` 里 `sed` 抽出 3x-ui 段函数，配桩环境跑。**会真的联网**探测镜像站（不然测不出「改写后的地址还能不能用」）：镜像两级可用性判定（raw / releases-latest 分开测）、两级挑选、`SET_DNS_GH_PROXY` 覆盖、**拿真实 `install.sh` 改写后断言 `github.com` 与 `raw.githubusercontent.com` 没有漏网的裸地址、且 `api.github.com` 一处未动**、改写后 tag 解析仍正常、空前缀保持原样、非法脚本被丢弃、`--xui-status` 只读、沙箱备份不炸。

### GitHub 下载层单元测（联网、不需要 root）

```bash
bash tests/verify-ghdl.sh
# === GH_TEST PASS=15 FAIL=0 ===
```

从 `set-dns.sh` 里 `sed` 抽出 GitHub 下载层，配桩环境跑。**会真的联网**（不然测不出「镜像到底能不能用」）：候选生成（8 个途径、直连必须排最后、非 raw URL 原样返回）、真联网取回脚本并做语法校验与版本号核对、**8 个途径取回的 `set-dns.sh` sha256 与 `git HEAD` 逐字节一致**、`gh_pick_mirror` 探测与「首选置顶」（三种类型 direct/proxy/jsdelivr 分别验前缀解析与排序）、`SET_DNS_GH_MIRROR` 覆盖、**下载不存在的仓库必须返回非 0**（不能静默给空文件）。

### 换源单元测（不联网、不需要 root）

```bash
bash tests/verify-mirror.sh
# === MIRROR_DONE PASS=56 FAIL=0 ===
```

用 `sed` 从 `set-dns.sh` 里抽出换源相关函数，配一个 `SET_DNS_ETC` 指向临时目录的桩环境跑，**完全不联网**：老式 `deb` 行改写（含 `deb-src`、`[arch=... signed-by=...]` 选项段不拆行）、deb822 改写（`Signed-By` / `Components` / `Suites` 保留、空行保留、两个 stanza 不串台）、第三方源不被列入目标、备份 / `manifest` / 还原 / 无备份时友好返回、白名单判定、系统识别（bullseye 无 `non-free-firmware`、Mint 优先按 Ubuntu、CentOS 被拒）、候选表完整性。

### 真机测试（会在真实 `/etc` 上操作）

```bash
bash tests/verify-live.sh
```

流程：先写明文兜底 → **`--sysinfo` 只读校验（断言 `resolv.conf` 与守护相关文件 md5 一个都没变、22 个字段齐全、裸数字 `set-dns 6` 也可用）** → **`--tools` 校验（面板能出、装完 `resolv.conf` 没变、解析仍可用、`set-dns 7` 也认；这段会真的装核心工具里缺的那几件，是预期行为）** → **`--mirror` 校验（真跑一次测速、换成 `aliyun`、断言第三方源文件 md5 一个都没动、`apt-get update` 仍 OK、`--mirror-restore` 后 `/etc/apt` 完全回到换源前、裸数字 `set-dns 8` 也认）** → **`--ssh-port` 校验（只读模式不改配置、非法端口退出码非 0、`SET_DNS_SSH_KEEP=1` 改成 2223 后 22 与 2223 双端口同时监听、`--ssh-port-restore` 后 `/etc/ssh` 逐字节回到测试前；**全程不关旧端口，任何时候都还能从 22 连回来**）** → **`--kernel` 校验（只读面板、`--dry-run --kernel-update` 只出计划、判出的档位不许低于「正在跑的内核」的档位、改后 `resolv.conf` / 守护 / `/boot` / `/etc/default` 全部未变；这段刻意不真装真卸内核）** → **`--accel` 校验（`--accel-status` / `--accel-kernels` 零改动；真机依次切 `bbr+fq` / `bbr+fq_pie` / `bbr+cake` 并回读 `sysctl` 与网卡真实 `tc qdisc`；ECN、IPv6 开关往返；`--accel-optimize` 抽查 `somaxconn`/`rmem_max`/`backlog`；`--accel-merge`；六个内核变体只走 `--dry-run` 看真实包名、四个做不到的必须非 0；**全程 `/boot` 镜像清单不许变**；最后 `--accel-restore` 确认配置已删、别人的 `99-*.conf` md5 原样、cc/qdisc 回到 `bbr`+`fq`、`resolv.conf` 与守护零改动** → `--dot` 验到 853 的连接真的建立 → `--doh` 验 `dnscrypt-proxy` 起来了、监听 5353、有到 443 的连接 → `--check` → **手工把 `resolv.conf` 改成坏的，看守护是否几秒内修回** → 托管副本被毁的抗故障演练 → `--unguard` / `--guard` 往返。中间出错随时 `set-dns --restore`。

---

## 实测环境

- Debian 13 (trixie) 与 Ubuntu 22.04 上各测一遍，`unbound 1.26.1` / `dnscrypt-proxy 2.1.8`
- 沙箱断言：`PASS=292 FAIL=0`；换源单元测：`PASS=56 FAIL=0`；真机：`=== REAL_DONE ===` 全绿（退出码 0）
- 真机 DoT：`resolv.conf` 首条 `127.0.0.1`，到 `1.1.1.1:853` / `8.8.8.8:853` 的 ESTAB 连接成立
- 真机 DoH：`dnscrypt-proxy` active，`127.0.0.1:5353` 有监听，到 `1.0.0.1:443` / `8.8.8.8:443` 的 HTTPS 连接成立，日志 `[google] OK (DoH) - rtt: 4ms`
- 真机换源：探测 11 个源全部拿到耗时并排名（`official 0.255s` / `tencent 0.432s` / `aliyun 1.536s` …），换成 `aliyun` 后 `apt-get update` 正常、第三方源未动，`--mirror-restore` 后 `/etc/apt` 逐字节回到换源前
- 真机 SSH 端口：`SET_DNS_SSH_KEEP=1 --ssh-port=2223` 后 `sshd -T port` 为 `port 2223 port 22`、两端口都在监听，`--ssh-port-restore` 后只剩 22、`/etc/ssh` 逐字节回原样
- 真机内核判档：某 Xeon E5 v4 机器 + 在跑 `x64v3` 内核，判档 `x64v3`（判定依据 `glibc hwcaps`）；`x64v4` 需 `avx512f`，该 CPU 没有，正确不判 v4
- 真机 TCP 加速：`--accel-bbr` / `--accel-fqpie` / `--accel-cake` 三组真机切换后 `sysctl` 回读分别为 `bbr` + `fq` / `fq_pie` / `cake`；ECN、IPv6 开与关往返正常且 `tcp_ecn_fallback` 未被误伤；`--accel-optimize` 按本机内存与核数写入 19 项参数；`--accel-restore` 后配置清理干净、cc/qdisc 回到 `bbr`+`fq`、`/etc/sysctl.d/99-degwd.conf` 与 `99-kejilion-bbr.conf` md5 一个字节没变；全程 `resolv.conf` 与自动修复守护零改动
- 抗故障：手工写 `nameserver 127.0.0.53` 后 **6 秒内被守护修回**，`getent` / `curl` 全程可用
- 抗故障（副本被毁）：手工删掉主托管副本、把两份副本全删，守护仍能修回 / 救急，不会把机器留在无 DNS 状态
- **3x-ui 实测（腾讯云 Debian 13）**：官方 `install.sh` 的 `github.com` 三项（`releases/latest` / `releases/download` / `.sha256`）在大陆链路下**实测会 30 秒超时收 0 字节**（本次复现时该链路恰好转好，所以另用 `/etc/hosts` 把 `github.com` 指向 `127.0.0.1` **强制黑洞**，复现「被墙」状态再跑）；经 `ghfast.top` 三项全通，78MB 安装包 **sha256 与官方边车逐字节一致**。面板 `0.3.4.4`（2023）→ `3.9.0` 升级成功、端口 `5212` 与登录用户名原样保留、`xray` 由 `1.7.5` 升到 `26.9.30`、两个入站（`10440` SS2022 / `40530` VLESS）恢复监听、`resolv.conf` md5 全程未变。
- **3x-ui 两个升级坑的复现与修复**：SS2022 密钥 44 字符但解出 33 字节 → 新 xray `bad key` 且 exit 23（老 xray 报 `Configuration OK.`），表现为「面板 active、xray 没起来、端口全空」；老 DB 迁移把客户端 `enable` 置 0 → 面板打印 `Remove Inbound User ... due to expiration or traffic limit` 并把用户从 `config.json` 剔掉。`xui_precheck()` / `xui_postcheck()` 均能检出，`SET_DNS_XUI_FIX_SS=1` 能修好并自动复验（含「官方脚本跑完会把修复改回去，必须在它之后再补一次」这个顺序问题的实测确认）。

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

**Q：菜单里的「8) 自动换源」会动我的 DNS 吗？**
不会。它只改 `/etc/apt/sources.list` 与 `sources.list.d/` 里**发行版自己的仓库地址**，`resolv.conf` 和自动修复守护全程不动。

**Q：它会把我 Docker / NodeSource 的源也一起换掉吗？**
不会，这是特意防住的。只有主机名在发行版白名单里（`deb.debian.org` / `security.debian.org` / `archive.ubuntu.com` / `ports.ubuntu.com` … 以及候选镜像源域名）的地址才会被替换。第三方源被换掉是最典型的翻车方式 —— 换完直接装不上包。真机测试里专门断言了这些文件的 md5 一个都没变。

**Q：换完源 `apt update` 报错怎么办？**
不用管，脚本自己已经处理了。改完会立刻 `apt-get update` 验证，并且**同时看退出码和输出里的 `E:` / `Err:` / `W: Failed`**（apt 有时退出码 0 但内部报错），一旦失败就**自动回滚**到换源前的配置并复验，所以不会留下坏的软件源。想手动回去就 `set-dns --mirror-restore`。

**Q：`--mirror-restore` 说没有备份？**
说明这台机器没通过本脚本换过源（或备份目录 `/etc/set-dns.bak/mirror/` 被删了）。这时它只是友好提示并正常退出，不会报错，也不会乱改东西。

**Q：换源测速太慢 / 我想固定用某个源？**
`SET_DNS_MIRROR=aliyun set-dns --mirror` 直接指定，跳过测速（可选 `official` / `aliyun` / `tuna` / `ustc` / `163` / `huawei` / `tencent` / `bfsu` / `sjtu` / `nju` / `cloudflare` / `leaseweb`）。测速本身每个源最多 5 秒，但源多（Debian 12 个）时最坏情况也会花上一分钟。

**Q：CentOS / Alpine 能用换源这条吗？**
不能。这项只支持 Debian 系（Debian / Ubuntu / Mint 等衍生版）。认不出 `os-release` 或不是 Debian 系的系统会**直接拒绝**，不会瞎改。基础工具安装（菜单 7）是跨发行版的，换源不是。

**Q：改了 SSH 端口，结果连不上了怎么办？**
别慌，旧的 SSH 会话只要没断开就还能操作：

```bash
set-dns --ssh-port-restore     # 一键还原到改之前的配置并重启 sshd
```

如果连旧会话也断了，就走云厂商的 **VNC / rescue 控制台**登进去跑上面这条（这也是为什么强烈建议加 `SET_DNS_SSH_KEEP=1` —— 新旧端口同时监听，改完随时能连回来）。
另外：**云主机必须在控制台的安全组里放行新端口**，脚本管不到云安全组，这一步不做的话端口是通的、外面也连不进。

**Q：改了 SSH 端口，`sshd_config` 里写的是新端口，但 `ss -lnt` 还是老端口？**
说明这台机器是 **`ssh.socket` 套接字激活**模式（`systemctl is-enabled ssh.socket` 看）。这种模式下 `sshd_config` 里的 `Port` **完全不生效**，端口由 `ssh.socket` 的 `ListenStream=` 决定。脚本已经处理了（会自动写 `ssh.socket.d/99-set-dns-port.conf`），但如果你是手工改的就要注意这一点。

**Q：内核管理会不会把我唯一的能启动的内核卸掉？**
不会。卸载前会 `dpkg-query` 找出所有非 xanmod 的 `linux-image-*`，**一个都没有时拒绝直接卸载**，改为问你要不要先装一个发行版自带内核。装完 / 卸完都会跑 `update-grub` 并告诉你重启后会进哪个内核。

**Q：面板里的「CPU 微架构档位」和我理解的不一样？**
首先看面板打印的「档位判定依据」那行 —— 它会告诉你这个档位是怎么来的（`glibc hwcaps` / `CPU flags` / `正在运行的内核`）。
判定顺序是 ① `ld.so --help` 的 glibc hwcaps → ② `/proc/cpuinfo` flags → ③ 正在运行的内核名（`7.10.0-x64v3-xanmod1` 里就带档位），**取三者里最高的**。
想手工指定就 `SET_DNS_KERNEL_LEVEL=x64v3 set-dns --kernel-update`。注意**档位判低了也有害** —— 会给你装功能更少的低档内核；判高了则直接起不来。

**Q：内核管理会改我的 BBR 参数吗？**
不会。`/etc/sysctl.d/99-degwd.conf` / `99-kejilion-bbr.conf` 里那些 `tcp_congestion_control` / `default_qdisc` 是别的脚本（de_GWD、kejilion）写的，**菜单 10 只报告** BBR 是否可用，绝不修改。源码里有沙箱断言专门盯着这一点（内核段的代码里不许出现 `sysctl -w` 或往 `sysctl.d` 写文件）。
要调 BBR 的是**菜单 11**，它也只写自己的 `99-zz-setdns-accel.conf`，别人那两个文件依旧一字节不碰。

**Q：装了新内核，为什么 `uname -r` 还是老版本？**
内核要**重启**才生效。脚本装完就提示过了：重启前可以 `grep -m3 '^menuentry' /boot/grub/grub.cfg` 看引导菜单，重启后 `uname -r` 确认。如果你重启后进的还是老内核，检查 `/etc/default/grub` 的 `GRUB_DEFAULT` 与 `grub-set-default`。

**Q：菜单 11 改了 `tcp_congestion_control`，为什么看起来没生效？**
先看它到底写在哪：`cat /etc/sysctl.d/99-zz-setdns-accel.conf`。systemd-sysctl 是**按文件名字典序叠加**的，后读的赢 —— 机器上通常已经有人（de_GWD、kejilion）写了 `99-degwd.conf` / `99-kejilion-bbr.conf`。本脚本特意用 `zz` 前缀排在它们后面，就是为了压得住；如果你想手工确认谁赢了，直接 `sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc` 看**当前生效值**。
还有一点：`default_qdisc` 只影响**新建**的 qdisc，已经在跑的队列不会自动换。想看网卡上真正在用的：`tc qdisc show dev <网卡名>`（`--accel-status` 会替你打出来）。

**Q：`--accel-optimize` 会把我关掉的 IPv6 又打开吗？**
不会。它写参数前会**先读当前 ECN 与 IPv6 的状态并原样保留**。这个坑上游脚本踩过（点一次优化，刚用 35 禁掉的 IPv6 又回来了），沙箱里专门有两条回归断言盯着。

**Q：菜单 11 里 `1` / `2` / `3` / `5` / `6` 这些内核装了没反应？**
它们**本来就用不了**，脚本只是如实告诉你原因，退出码是 1，不会假装成功：`1` BBR 原版编译内核（仓库里没这个包）、`2`/`5` BBRplus（要有带 `tcp_bbrplus` 模块的第三方编译内核）、`3` Lotserver（**只支持 CentOS 6/7 内核**）、`6` Zen（Debian 仓库不提供）。面板会给出替代方案 —— 直接用 `20`/`21`/`22` 的 BBR 加速，或去菜单 10 装 xanmod BBRv3 内核。

**Q：菜单 11 的 `52 删除保留指定内核` 会不会把机器搞成砖？**
不会。它在**删除之前**先算一遍「删完还剩几个 `linux-image-*`」，剩 0 个就**直接拒绝**并打印「操作已阻止：删完就没有能启动的内核镜像了（重启即变砖）」；删的正好是当前在跑的那个内核时，还会额外要你输入大写 `YES` 确认。想先看一眼有哪些内核用 `--accel-kernels`（只读）。

**Q：`--accel-restore` 会不会把我原来的 BBR 也一起清掉？**
不会。它只删本脚本写的两个文件（`/etc/sysctl.d/99-zz-setdns-accel.conf` 与 `/etc/modules-load.d/setdns-qdisc.conf`，删前都备份到 `/etc/set-dns.bak/accel/`），然后 `sysctl --system` —— 这一步正好让 `99-degwd.conf` / `99-kejilion-bbr.conf` 里的配置重新生效。真机测试里断言了：还原后 cc/qdisc 回到 `bbr`+`fq`，别人的两个文件 md5 一个字节没变。

**Q：`25 编译安装 brutal 模块` / `26 LotSpeed` / `60 tcpfit` 这几个为什么不内置？**
它们都是第三方内核模块或外部调优脚本（`tcp.hy2.sh`、`uk0/lotspeed`、`Kylin010/tcpfit`），要联网拉源码、要 headers 匹配、编译几分钟，而且会随上游变化。内置一份等于把它们锁死在某个时间点。所以菜单里只做**带确认的调用**：先打印来源与用途，问你确认，下载后 `bash -n` 校验语法（不合法直接丢弃），执行完再重放一次 `sysctl --system`。面板上的「Headers状态: 已匹配」就是给你判断能不能编译用的。

**Q：`92 一键 DD 重装系统` 点了没反应？**
**故意的**。这是会把整台机器清空重装的操作，脚本默认只打印提示和外部脚本路径，不动手。确实要用得显式 `SET_DNS_ACC_ALLOW_DD=1`，并且自己确认目标系统与密码。

---

## 更新日志

### v3.10（第二次修订）

- **修复：大陆服务器连 `set-dns.sh` 自己都下载不下来**（`curl: (35) Recv failure: Connection reset by peer`）。
  - **复测推翻了之前的结论**。v3.10 初版里写的是「`raw.githubusercontent.com` 在大陆是通的（1s）」—— 那是**单次**测的结果。同一台机器上连续跑 6 次：**成功 3 次、失败 3 次**，失败时报 `curl: (35) Recv failure: Connection reset by peer`。所以它不是「通」或「不通」，而是**时通时不通**。
  - **新增通用 GitHub 下载层** `gh_raw_url()` / `gh_fetch()` / `gh_pick_mirror()`，把所有要访问 GitHub 的地方统一收口，按顺序试 8 个途径：
    - **反代前缀** `gh-proxy.com` / `ghfast.top` / `ghproxy.net` / `hk.gh-proxy.com`（拼在完整 URL 前）
    - **jsDelivr CDN** `cdn.jsdelivr.net` / `fastly.jsdelivr.net` / `gcore.jsdelivr.net`（另一套路径语法，只能取仓库内文件）
    - **直连** `raw.githubusercontent.com`（排最后兜底）
  - **两种 URL 形态不能混用**：反代前缀拼在完整 URL 前，jsDelivr 要重新拼成 `cdn.jsdelivr.net/gh/<user>/<repo>@<ref>/<path>`。`gh_raw_url()` 负责生成，单元测断言两种形态都正确、且直连排最后。
  - **启动时自动探测**：`gh_pick_mirror()` 用仓库里的 `LICENSE`（1KB，不是 180KB 的脚本本身）把每个途径试一遍，把最快的提到候选列表最前面，之后所有下载复用。大陆机器因此不会先去撞必然失败的直连。
  - **改走这一层的调用点**：菜单 0 升级脚本、菜单 12 的 3x-ui `install.sh`、菜单 11 的 `25/26/60` 三个外部脚本、DoH 模式的 dnscrypt-proxy 解析器列表（后者同时把 `download.dnscrypt.info` 提到首位并加上镜像条目 —— 实测直连那个 raw URL 15 秒 0 字节超时）。
  - **新增 `--gh-check`（别名 `--mirror-selftest`）**：只读、不需要 root，逐个实测并打印各途径的状态与耗时。
  - **内容一致性有断言**：8 个途径取回的 `set-dns.sh` sha256 与直连**逐字节一致**（`1ddaeb6e…d7af`），`tests/verify-ghdl.sh` 每次都会重新验。
  - **README 快速开始区分大陆/海外**：大陆给出 `gh-proxy.com` 单条写法与 `gh-proxy → ghfast → jsDelivr` 三级回退写法。
  - 实现期踩到并修掉的两个自身 bug：`gh_pick_mirror` 里用 `${{best%%https://*}}` 解析反代前缀会得到**空串**（URL 本身就以 `https://` 开头，模式从头匹配到结尾）—— 改成先剥 scheme 再取主机名；以及 `set -u` 下直接引用尚未探测的 `GH_PREF_KIND` 会报 `unbound variable` 把脚本打断 —— 全部改用 `${{VAR:-}}`。
- **新增 `tests/verify-ghdl.sh`**（联网、不需要 root）：候选生成、真联网取脚本、**8 途径 sha256 与 git 一致**、探测与置顶、`SET_DNS_GH_MIRROR` 覆盖、下载失败必须返回非 0。`PASS=15 FAIL=0`。

### v3.10

- **新增菜单项 12「3x-ui 面板」与 `--xui` / `--xui-install` / `--xui-status` / `--xui-uninstall`**，并**修好官方一键脚本在中国大陆服务器上装不上的问题**。
  - **问题定位（真机实测，腾讯云 Debian 13）**：官方 `bash <(curl -Ls .../3x-ui/master/install.sh)` 失败**不在脚本本身**。脚本内部要访问 `github.com` 主站三处 —— `releases/latest`（取版本号）、`releases/download/<tag>/...tar.gz`（78MB 安装包）、`.sha256`（校验边车）—— 在大陆上**全部 30 秒超时、0 字节**。而 `raw.githubusercontent.com`（1s）与 `api.github.com`（0.8s）**是通的**。
  - **迷惑点**：`github.com:443` 的 **TCP 是连得上的**（`time_connect=0.08s`），只是 HTTP 响应回不来。所以现象是「脚本下载成功、跑起来了，但卡在装包那步」，报 `Failed to fetch x-ui version...` 或 `Downloading x-ui failed...` —— 极易误判成脚本损坏。而 `raw` / `api` / `objects.githubusercontent.com` 全正常，**只针对主站**。
  - **修法**：**不改官方脚本任何逻辑**，下载后把里面写死的 GitHub 绝对地址整体改写成带加速前缀的地址再执行。真机逐条验过前缀对三种 URL 形态都成立：`前缀+raw...` → 200（**不存在的文件仍是 404**，所以 `require_repo_files` 的探测不会被骗）；`前缀+github.com/.../releases/latest` → 302 且 `url_effective` 带 `/tag/<版本>`；`前缀+github.com/.../releases/download/...` → 200，78MB 安装包**下载完 sha256 与官方边车逐字节一致**（`d7cbe0bf...9390`）。
  - **校验和没有被绕过**：官方脚本照旧下 `.sha256` 并比对，镜像只搬运字节。
  - **两级挑镜像**：优先「raw + `releases/latest` 都能过」的（最省事）；都没有才退到「只代理 raw」的，此时版本号走 `api.github.com` 直连（大陆上本来通），可用镜像从 2 个变成 5 个以上。探测拿**真实地址**去试，不维护硬编码可用性列表（这类镜像站存活周期很短）。`api.github.com` 不改写 —— 它是退路，且 `sed` 模式 `https://github.com/` 本来就不会命中它（有专门断言盯着）。
  - **安全兜底**：改写后必过 `bash -n`，不合法直接丢弃不执行；镜像下载失败自动退回直连；装之前先探 `deb.debian.org` 确认 DNS 通（官方脚本第一步就是 `apt-get install` 依赖）；升级前把 `/etc/x-ui` 与 `/usr/local/x-ui/bin` 备份到 `/etc/set-dns.bak/xui/`。
  - `--xui-status` 只读、不需要 root，放在 root 检查之前；`--dry-run` 只出计划不下载不执行。
  - **和 DNS 无关**：`resolv.conf` 与自动修复守护全程不动。
- **发现并处理了升级旧面板的两个真坑**（真机 0.3.4.4 → 3.9.0 时踩到，均已加前后自检）：
  - **Shadowsocks-2022 密钥不是合法的 32 字节 base64**：那台机器上存的是 44 字符但严格解码出 **33 字节**（少 `=` 填充）。**老 xray 1.7.5 不校验长度照样启动**，新 xray 26.x 直接 `Failed to start: ... proxy/shadowsocks_2022: bad key` 并 exit 23。后果是 **`x-ui.service` 显示 active、面板能开，但 xray 根本没起来**，10440/40530 一个端口都不监听 —— 只看面板发现不了。（同一个值老 xray 报 `Configuration OK.`、新 xray 报 `bad key`，逐条验过。）
  - **迁移把老客户端的 `enable` 置成 0**：老 DB 没有 `clients` 表，`x-ui migrate` 新建后把 `enable` 置 0，新面板随即打印 `Remove Inbound User <email> due to expiration or traffic limit` 并把用户从 `config.json` 里剔掉（`"clients": []`）—— 客户端连不上且面板无报错。
  - **脚本不偷偷改用户的密钥/开关**，而是：`xui_precheck()` 升级前检出并打印症状与后果；`xui_postcheck()` 升级后跑 `xray -test -config`、`pgrep xray-linux`、`ss` 数监听、复查被停用客户端（**官方脚本 rc=0 不代表 xray 活着**）；`SET_DNS_XUI_FIX_SS=1` 显式修复（用 `os.urandom` 生成合法密钥并打印，恢复 `total=0 且 expiry=0` 却被停用的客户端）。
  - **顺序关键**：官方脚本结尾的 `x-ui migrate` 会把装之前修好的又改回 0（实测），所以修复在**脚本跑完之后**再补一次并重启面板重建 `config.json`，改完自动复验。
- **版本横幅统一为 v3.10**，菜单提示改 `输入 1/2/3/4/5/6/7/8/9/10/11/12（直接回车 = 1）`。
- **测试**：沙箱断言新增菜单 12 接线（`12 -> 3x-ui 面板管理`、面板列出选项 12、且选 12 后**不得误入主流程**）。另有独立单元测（`_test_xui.sh` 的思路已并入验证）覆盖：镜像可用性判定、两级挑选、`SET_DNS_GH_PROXY` 覆盖、**真实 install.sh 改写后 github.com/raw 无漏网裸地址且 `api.github.com` 一处未动**、改写后 tag 解析仍正常、空前缀不改写、非法脚本被拒绝、`--xui-status` 只读、沙箱备份不炸。

### v3.9

- **新增菜单项 11「TCP 加速管理」与 `--accel` 系列子命令**：一张大面板（编号沿用 ylx.me「TCP加速 一键安装管理脚本」，忠实复刻条目），把 BBR 加速、ECN / IPv6 开关、网络自适应优化、防 CC、内核查看与删除收在一处。同时**逐项查过仓库再决定实现范围**，不假装能做到做不到的事：
  - **能真做的**：`20/21/22` BBR + `fq` / `fq_pie` / `cake`（`sch_fq` / `sch_fq_pie` / `sch_cake` 模块 Debian 都有）、`30/31` ECN、`32` 自适应优化、`33` 防 CC、`35/36` IPv6、`37/38` sysctl 合并与编辑、`51/52` 内核查看与删除、`55` 一键还原、`4/7/8` 官方 cloud / 稳定 / 最新内核、`9~12` xanmod 四个分支。
  - **做不到的明确说清并给替代**：`1` BBR 原版编译内核（仓库无此包）、`2`/`5` BBRplus（需带 `tcp_bbrplus` 模块的第三方编译内核）、`3`/`24` Lotserver（**只支持 CentOS 6/7 内核**）、`6` Zen（Debian 仓库不提供）、`23`/`27`（对应模块没装）—— 选这些**退出码为 1**，面板打印原因与替代方案。
  - **关键实现：`/etc/sysctl.d/99-zz-setdns-accel.conf`**。systemd-sysctl 按 `/usr/lib` → `/run` → `/etc` 读、**同目录按字典序后读的赢**，而 `99-degwd.conf`（`bbr` + `cake`）与 `99-kejilion-bbr.conf`（`fq` + `bbr`）已写死这两个键 —— `zz` 前缀才压得住，否则就是"改了不生效"的头号原因。别人那两个文件**一字节不碰**（真机用 md5 断言盯着）。
  - **改键一定幂等**：`acc_apply()` 每次先 `cp -a` 到 `/etc/set-dns.bak/accel/prev.conf`，再 `sed` 删同名旧行后追加，所以反复切 FQ→FQ_PIE→CAKE→FQ，文件里每键恒为一行；`sch_*` 去重追加进 `/etc/modules-load.d/setdns-qdisc.conf`，重启仍在。
  - **`32 自适应优化`按内存与核数取参**（`<2GB` 16MB/32768、`2~8GB` 32MB/65535、`8GB+` 64MB/1048576，`netdev_max_backlog = 核数 × 10000` 夹在 32768~100000），并**继承当前 ECN 与 IPv6 状态** —— 否则"先用 35 禁了 IPv6，再点 32 又给开回来"（上游踩过的坑，沙箱有两条回归断言）。防 CC 的 `tcp_max_syn_backlog` 按本机 `somaxconn` 来，**不用上游那个夸张的 1024000**。
  - **`52 删除保留指定内核`有硬屏障**：删除**之前**先对账「删完还剩几个 `linux-image-*`」，剩 0 个直接拒绝（`操作已阻止：删完就没有能启动的内核镜像了（重启即变砖）`）；删当前在跑的内核要额外输入大写 `YES`。
  - **`55 卸载全部加速`是干净的**：只删自己写的两个文件（都先备份），再 `sysctl --system` 让别人的配置重新生效。
  - **依赖外部脚本的三项（`25` brutal / `26` LotSpeed / `60` tcpfit）只做带确认的调用**：打印来源与用途 → 确认 → 下载后 `bash -n` 校验（不合法丢弃）→ 执行 → **重放 `sysctl --system`**（外部脚本改完模块后 systemd-sysctl 可能已跑过，不重放不生效）。**`92 一键 DD 重装系统`默认只提示不动手**，要 `SET_DNS_ACC_ALLOW_DD=1` 才走外部脚本。
- **`--check` 新增「TCP 加速（菜单 11）」小节**：报告有没有写过加速配置、当前拥塞控制算法是否已是 `bbr`，没启用过也能一眼看出状态。
- **只读项不需要 root**：`--accel-status` / `--accel-kernels` 在 root 检查之前拦截，全程不写文件。
- **版本横幅统一为 v3.9**，菜单提示改 `输入 1/2/3/4/5/6/7/8/9/10/11（直接回车 = 1）`。
- **测试**：沙箱断言 217 → **292 项**（`PASS=292 FAIL=0`，新增 75 条 accel 断言）。覆盖：只读项不动文件与 `resolv.conf`（md5 比对）、三种加速写对 cc/qdisc 且反复切换幂等（`grep -cE` 恒为 1）、`sch_fq` 进 `modules-load.d`、可用算法列表里没有 `bbr` 时必须非 0 并提示「不支持 bbr」、ECN 开关**不误伤 `tcp_ecn_fallback`**（正则锚定 `=`）、IPv6 `all` 与 `default` 双键往返、优化 ≥15 项与 `somaxconn` 分档、**优化必须保留已禁用 IPv6 与 ECN 现状的两条回归**、防 CC 三键且**不得出现 1024000**、`--accel-edit` 无终端必须拒绝、xanmod main/LTS/EDGE/RT 与 official/cloud/latest 的真实包名映射、四个做不到的变体必须非 0 并给出替代、`52` 全删屏障与删单个非当前内核、`55` 只删自己的配置且幂等、`--dry-run` 零改动、菜单 11 面板含截图条目、**字典序断言**（`printf '%s\n' 99-degwd.conf 99-kejilion-bbr.conf 99-zz-setdns-accel.conf | LC_ALL=C sort | tail -1` 必须等于 zz）、源码级不变式（加速段内不许出现 `sysctl.d/(99-degwd|99-kejilion)` 与 `/etc/sysctl.conf`）。菜单 pty 测试扩到 1/2/3/4/5/6/7/8/9/10/11。真机新增 S0g 段（只读零改动 + 三组加速真切并回读 `tc qdisc` + ECN/IPv6 往返 + 优化抽查 + `/boot` 镜像清单不变 + 六个变体只走 `--dry-run` + 还原后别人的 sysctl md5 原样）。

### v3.8

- **新增菜单项 10「内核管理」与 `--kernel` / `--kernel-update` / `--kernel-remove` 子命令**（kejilion 风格面板：`您已安装 xanmod 的 BBRv3内核` + `当前内核版本` + `1. 更新BBRv3内核  2. 卸载BBRv3内核  0. 返回上一级菜单`）。
  - **装前按 CPU 微架构档位选包**：xanmod 分 `x64v1`~`x64v4`，**档位选高了内核直接起不来**。判档顺序为 ① glibc hwcaps（`ld.so --help` 的 `x86-64-v3 (supported, searched)`）→ ② `/proc/cpuinfo` flags → ③ **正在运行的内核名**（`7.10.0-x64v3-xanmod1` 里就带档位，跑起来了就说明 CPU 至少支持 v3），**取三者里最高的**；面板额外打印「档位判定依据」，一眼看出档位怎么来的。可用 `SET_DNS_KERNEL_LEVEL=x64v3` 强制指定。
  - **修掉一个真实误判**：初版只按 flags 判档，在某台 Xeon E5 v4 机器上被判成 `x64v2`（这台机器明明在跑 `x64v3` 内核）。两个原因：**LZCNT 在 Intel 上很多内核只报 `abm`、不报字面的 `lzcnt`**（同一条指令，两种叫法），**SSE3 在 Linux 的 flags 里叫 `pni`**。照字面 grep 就会缺项、判低一档，而判低会让用户装上功能更少的低档内核。现已补上这两个别名并优先走 glibc hwcaps。
  - **卸 xanmod 前先确认还有别的内核能启动**：用 `dpkg-query` 找非 xanmod 的 `linux-image-*`；**一个都没有时拒绝直接卸载**，改为问你要不要先装一个发行版内核（Ubuntu `linux-image-generic` / 其他 `linux-image-cloud-amd64`）。否则卸完重启就再也进不去系统。
  - **装完 / 卸完都跑 `update-grub`** 并打印重启后会进哪个内核，不需要手写引导菜单（Debian 的 `/etc/kernel/postinst.d/zz-update-grub` 本来就会自动更新）。装完明确提示「要重启才生效」并给出 `uname -r` 确认方式。
  - **绝不抢 BBR 参数**：`/etc/sysctl.d/99-degwd.conf` / `99-kejilion-bbr.conf` 是别的脚本写的，这条**只报告** BBR 是否可用，不改 `tcp_congestion_control` / `default_qdisc`（有源码级沙箱断言盯着）。卸载时 xanmod 源默认保留，`SET_DNS_KERNEL_KEEP_REPO=0` 可连源一起拆（源与 keyring 备份到 `/etc/set-dns.bak/kernel/`）。
- **版本横幅统一为 v3.8**，菜单提示改 `输入 1/2/3/4/5/6/7/8/9/10（直接回车 = 1）`。
- **测试**：沙箱断言 177 → **217 项**（`PASS=217 FAIL=0`，16 段）。判档逻辑用**假 `cpuinfo`**（`SET_DNS_CPUINFO` / `SET_DNS_LDSO` / `SET_DNS_RUNNING_KERNEL`）逐个 CPU 档位验：某 E5 v4（只报 `abm`）必须判 `x64v3`、字面 `lzcnt` 也判 `x64v3`、两者都没有时保守降 `x64v2`、有 `avx512` 全项判 `x64v4`、缺 `avx2` 判 `x64v2`、只有 `sse2` 判 `x64v1`、`cpuinfo` 读不到兜底 `x64v2`，外加「在跑 `x64v3` 内核时不许被判低」这条硬断言。真机新增 S0f 段（只读面板 + `--dry-run` + 改前改后 `resolv.conf`/守护/`/boot`/`/etc/default` 哈希比对 + **判档不许低于在跑内核的档位**）。

### v3.7

- **新增菜单项 9「自定义 SSH 端口」与 `--ssh-port` / `--ssh-port-restore` 子命令**：改 `sshd` 监听端口。这类操作最容易把自己锁在门外，所以上了四层防护 ——
  1. **改前整份备份** `/etc/set-dns.bak/ssh/orig/`（`sshd_config` + 所有含 `Port` 的 `sshd_config.d/*.conf`，带 `manifest` 记录原路径）；
  2. **`sshd -t` 语法校验不通过就不重启**，直接用改动前的快照回滚；
  3. **重启后轮询 `ss -lnt` 确认新端口真的起来了**，没起来立刻回滚并重启回原端口；
  4. **可选保留旧端口**（`SET_DNS_SSH_KEEP=1` 或交互选 2），新旧端口同时监听，验证通了再手工关旧的。
- **处理两个真坑**：① **`ssh.socket` 套接字激活模式下 `sshd_config` 里的 `Port` 无效**，端口由 `ListenStream=` 决定 —— 检测到 `ssh.socket` enabled 时额外写一份 `ssh.socket.d/99-set-dns-port.conf`，否则会「改了没反应」；② **`sshd_config` 末尾若有 `Match` 块，往文件尾追加 `Port` 会掉进 `Match` 作用域**（只对匹配用户生效 = 没改）—— 所以 `Port` 块插在**第一个 `Match` 之前**，`Match` 块内的 `Port` 一律不动、也不被当成全局生效端口。
- **其他**：端口被他人占用时拒绝抢端口（`ss -lntp` 打出占用者）；`ufw` / `firewalld` 自动放行，**只有 `iptables` 且规则里有 `DROP`/`REJECT` 时只警告不自动改**（怕误删用户自己的规则）；SELinux 开着会 `semanage port -a -t ssh_port_t`；幂等（重写前先清掉上次的 `set-dns ssh port begin/end` 标记块）；非 root 只显示不修改；沙箱模式跳过重启与监听确认。改完明确提示「先别断开当前会话，新开窗口用 `ssh -p 新端口` 验证，连不上就 `--ssh-port-restore`」，并提醒**云主机还需在安全组放行新端口**。
- **版本横幅统一为 v3.7**，菜单提示改 `输入 1/2/3/4/5/6/7/8/9（直接回车 = 1）`。
- **测试**：沙箱断言 148 → **177 项**（`PASS=177 FAIL=0`）。新增「`9) 自定义 SSH 端口」整块：写入 `^Port 2222`、旧 `Port 22` 被注释为 `#set-dns-old#`、有 begin 标记、**`Match` 里的 `Port 2022` 完好且不被当成全局端口**（反向断言 `当前生效端口: 22 2022` 不出现）、drop-in 一起改、备份 `manifest` 含主配置与 drop-in 两条、不动 `resolv.conf`、幂等（重复执行块数 1、`^Port 2222` 行数 1）、`99999`/`abc` 退出码非 0 且提示「端口范围应为 1-65535」、`--ssh-port-restore` 让主配置与 drop-in 都回原样且 `Match` 完好；菜单 pty 测试扩到 1/2/3/4/5/6/7/8/9。真机新增 S0e 段（**全程 `SET_DNS_SSH_KEEP=1` 不关旧端口，测完立刻还原回 22**）。

### v3.6

- **新增菜单项 8「自动换源」与 `--mirror` / `--mirror-restore` 子命令**：逐个给候选软件源测速，把发行版仓库换成最快的那个，换完立刻 `apt-get update` 验证。
  - **只动发行版自己的仓库**：`is_distro_uri()` 按主机白名单判定（`deb.debian.org` / `security.debian.org` / `archive.ubuntu.com` / `ports.ubuntu.com` …，外加候选镜像源域名）。**Docker / NodeSource / packages.microsoft / MongoDB / PGDG 这类第三方源一个字节都不碰** —— 把第三方源地址顺手换掉会直接导致装不上包，是换源脚本最典型的翻车点。真机测试专门用 md5 断言了这一点。
  - **两种格式都支持**：老式单行 `deb [arch=amd64 signed-by=...] https://... trixie main`（方括号选项段整段或分开写都处理）与新式 deb822（`Types:` / `URIs:` / `Suites:` / `Components:` / `Signed-By:`）。deb822 只替换 `URIs:` 那一行，**`Signed-By` 原样保留**（弄丢它 apt 会拒绝所有包），空行分段与多 stanza 结构也原样保留。
  - **安全仓单独探测、单独替换**：`trixie-security` 与主仓库经常不在同一台机器上，两个地址分别计时，避免把安全仓也指到主仓库去。
  - **不只看退出码**：`apt_update_ok()` 同时检查退出码与输出里的 `^(E:|Err:|W: Failed)`（apt 有时退出码 0 但内部报错），**失败自动回滚**到换源前的配置并复验，不会留下坏的软件源。
  - **一键还原**：`set-dns --mirror-restore`，备份在 `/etc/set-dns.bak/mirror/`（含 `manifest` 记录原路径）；没换过源时友好返回、不报错。想固定用某个源跳过测速则 `SET_DNS_MIRROR=aliyun set-dns --mirror`。
  - **系统识别**：Debian 与 Ubuntu 系（含 Mint / Pop!_OS 这类 `ID_LIKE="ubuntu debian"` 的衍生版，按 Ubuntu 的仓库组件与安全仓路径处理）。Debian 主版本 ≥12 才带 `non-free-firmware` 组件，旧版用 `main contrib non-free`。非 Debian 系直接拒绝，不会瞎改。
  - **不动 DNS**：只碰 `/etc/apt`，`resolv.conf` 与自动修复守护全程不动；非 root 跑 `--mirror` 只做只读部分（列现状 + 测速排名）。
- **新增 `tests/verify-mirror.sh`**：换源功能的独立单元测，**不联网、不需要 root**，`sed` 抽出函数配 `SET_DNS_ETC` 桩环境跑，**56 项全 PASS**。
- **版本横幅统一为 v3.6**，菜单提示改 `输入 1/2/3/4/5/6/7/8（直接回车 = 1）`。
- **测试**：沙箱断言 126 → **148 项**（`PASS=148 FAIL=0`，16 段），新增 `--mirror` / `--mirror-restore` / 菜单 8 断言、deb822 改写与第三方源 md5 不变的沙箱断言、第 16 段连带跑 `verify-mirror.sh`；菜单 pty 测试扩到 1/2/3/4/5/6/7/8。真机新增 S0d 段。

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
