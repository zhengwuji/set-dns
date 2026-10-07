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

### 交互式（推荐，会出菜单让你选）

```bash
curl -fsSL https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh -o /usr/local/sbin/set-dns
chmod +x /usr/local/sbin/set-dns
set-dns
```

跑起来会看到：

```
  请选择 DNS 模式：
    1) 明文 DNS      —— 1.1.1.1 / 8.8.8.8，最稳，任何系统都能用  [默认]
    2) DoT 加密      —— unbound 转发 TLS(853)，无第三方软件
    3) DoH 加密      —— dnscrypt-proxy 走 HTTPS(443)，最难被干扰

  输入 1/2/3（直接回车 = 1）:
```

### 非交互式（一条命令直接指定）

```bash
set-dns --plain     # 明文
set-dns --dot       # DoT 加密
set-dns --doh       # DoH 加密
```

不想落盘、想先看一眼再跑：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhengwuji/set-dns/main/set-dns.sh) --doh
```

---

## 全部命令

```bash
set-dns                 # 交互菜单：选模式 + 配置 + 装守护（一步到位）
set-dns --plain         # 切明文
set-dns --dot           # 切 DoT 加密
set-dns --doh           # 切 DoH 加密
set-dns --check         # 只看状态；有问题退出码 1（可以直接接监控）
set-dns --guard         # 只安装/重装自动修复守护
set-dns --unlock        # 解除 chattr +i 锁
set-dns --restore       # 还原到首次运行前的原文件（含原来的符号链接形态）
set-dns --dry-run       # 只打印计划，一个文件都不动
set-dns -h              # 看用法
```

`--check` 大致长这样：

```
DNS 状态  2026-10-07 18:49:42   当前模式: DoH 加密
--------------------------------------------------------
  [ OK ] /etc/resolv.conf 是普通文件
  [ -- ] 未加锁
  当前内容:
  | # managed by set-dns v3 20261007-184939  mode=doh
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
- `action=ok-restartdcp` / `-restartunbound` —— 后端进程死了，已被拉起来

---

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `SET_DNS_NO_V6=1` | 不写 IPv6 解析器 |
| `SET_DNS_NO_PROBE=1` | 跳过解析器可用性探测（探测不可达的会被剔除） |
| `SET_DNS_NO_FALLBACK=1` | 加密模式下不附明文兜底解析器（默认会附，防止加密栈挂了整机没 DNS） |
| `SET_DNS_DOH_SERVERS="a b"` | 指定 DoH 服务器名，默认 `cloudflare google` |
| `SET_DNS_LOCK=1` | 额外 `chattr +i` 锁死文件（**不建议**：之后 apt 装包会失败，得先 `--unlock`） |
| `SET_DNS_ETC` / `SET_DNS_SBIN` / `SET_DNS_LOG` | 仅供沙箱测试改根路径 |

例子：

```bash
SET_DNS_NO_FALLBACK=1 set-dns --dot
SET_DNS_DOH_SERVERS="cloudflare google quad9-dnscrypt-ip4-filter-pri" set-dns --doh
```

---

## 自动修复守护是怎么工作的

装三样东西，成本极低，互相兜底：

1. **`dns-watch.path`**（毫秒级）—— 监听 `/etc/resolv.conf` 的改动，一被改就立刻比对并修回。这是主力。
2. **`apt` 钩子** `/etc/apt/apt.conf.d/99-dns-watch` —— `DPkg::Post-Invoke`，每次 apt 事务结束跑一次。专治"装个包 DNS 就没了"。
3. **`dns-watch.timer`**（5 分钟）—— 兜底轮询，防 `path` 单元漏事件。

守护比对的是"托管副本"`/etc/set-dns.bak/resolv.conf.managed`。加密模式下它还会检查 `unbound` / `dnscrypt-proxy` 是否活着、5353 有没有在监听，进程死了就重启——否则整机会没 DNS。

日志满了会自己截断（超过 1MB 保留最后 256KB）。

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

守护不会自动删，不需要的话：

```bash
systemctl disable --now dns-watch.path dns-watch.timer
rm -f /etc/apt/apt.conf.d/99-dns-watch /usr/local/sbin/dns-watch.sh
rm -f /etc/systemd/system/dns-watch.path /etc/systemd/system/dns-watch.service /etc/systemd/system/dns-watch.timer
systemctl daemon-reload
```

备份都在 `/etc/set-dns.bak/`：

```
resolv.conf.orig                 首次运行前的原始内容
resolv.conf.as-is                原始形态副本（cp -a，含符号链接）
resolv.conf.symlink              原来指向哪（如果原本是符号链接）
resolv.conf.managed              托管副本，守护按它修复
mode                             当前模式（plain / dot / doh）
unbound.conf.orig                unbound 原配置
unbound-setdns.frag              set-dns 写入的上游片段
dnscrypt-proxy.toml.orig         dnscrypt-proxy 原配置
dnscrypt-proxy.service.vendor    厂商单元原件
legacy/                          旧版本守护的备份
```

---

## 怎么跑测试

仓库里有两个测试脚本，都需要 `root`。

### 沙箱测试（推荐，安全，不碰线上）

用 `loop` 挂一个 `ext4` 镜像冒充 `/etc`，脚本以 `SET_DNS_ETC=...` 模式跑，**不会真的动系统服务**：

```bash
bash tests/verify-sandbox.sh
# === V3_DONE PASS=68 FAIL=0 ===
```

覆盖：三种模式、`--check` 识别、反复切换模式的幂等性、`--restore` 回滚、`--dry-run` 零改动、参数校验、交互菜单（用 `script` 模拟真实 pty，测 1/2/3 和直接回车）、空备份时 `--restore` 必须失败、断链符号链接、旧版守护识别。

### 真机测试（会在真实 `/etc` 上操作）

```bash
bash tests/verify-live.sh
```

流程：先写明文兜底 → `--dot` 验到 853 的连接真的建立 → `--doh` 验 `dnscrypt-proxy` 起来了、监听 5353、有到 443 的连接 → `--check` → **手工把 `resolv.conf` 改成坏的，看守护是否几秒内修回**。中间出错随时 `set-dns --restore`。

---

## 实测环境

- Debian 13 (trixie)，内核 `7.2.9-x64v3-xanmod1`，`unbound 1.26.1`
- 沙箱断言：`PASS=68 FAIL=0`
- 真机 DoT：`resolv.conf` 首条 `127.0.0.1`，到 `1.1.1.1:853` / `8.8.8.8:853` 的 ESTAB 连接成立
- 真机 DoH：`dnscrypt-proxy` active，`127.0.0.1:5353` 有监听，到 `1.0.0.1:443` / `8.8.8.8:443` 的 HTTPS 连接成立，日志 `[google] OK (DoH) - rtt: 4ms`
- 抗故障：手工写 `nameserver 127.0.0.53` 后 **6 秒内被守护修回**，`getent` / `curl` 全程可用

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

---

## 更新日志

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
