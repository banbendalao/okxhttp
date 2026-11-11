# okxhttp

Debian / Alpine 通用的 Xray 一键部署脚本（单文件、纯 POSIX sh）。一个 Xray 内核跑三种协议，可任意组合，带管理命令与自动续期。

## 特性

| 协议 | 暴露方式 | 说明 |
|---|---|---|
| **VLESS + XHTTP**（源站不加密） | Argo 隧道 | 固定隧道输出 `h2` + `h3` 两个节点；临时隧道用 WS（原因见[已知限制](#已知限制)） |
| **VLESS + TCP + REALITY + Vision** | 直连 | REALITY 目标站点默认 `pic.bstarstatic.com` |
| **Hysteria2** | 直连（UDP） | 证书可选自签或 Let's Encrypt 真实 IP 证书，自动续期；自签证书的 CN/SAN 直接用伪装域名（与 REALITY 同一个），链接里靠 `pinSHA256` 校验 |
| **WARP 出站**（可选） | Cloudflare WARP | 自动注册免费账号；按嗅探结果把 BT 流量送 WARP |
| **订阅** | AnyNote | 安装生成 UUID key，节点变化由调度服务自动推送；菜单里可重置 key（清空旧内容） |

其它：交互菜单 + 环境变量双模式、systemd/OpenRC/nohup 三分支托管（Alpine 用 `supervise-daemon` 自动拉起）、定时任务走自托管调度服务（不依赖系统 cron）、配置写盘前 `xray run -test` 校验、失败自动回滚、卸载干净。

## 一键运行

```sh
# curl
sh -c "$(curl -fsSL https://raw.githubusercontent.com/banbendalao/okxhttp/main/okxhttp)" okxhttp

# wget
sh -c "$(wget -qO- https://raw.githubusercontent.com/banbendalao/okxhttp/main/okxhttp)" okxhttp

# 带参数（例如直接非交互安装）
sh -c "$(curl -fsSL https://raw.githubusercontent.com/banbendalao/okxhttp/main/okxhttp)" okxhttp --status
```

> 用 `sh -c "$(...)"` 而不是 `curl ... | sh`：脚本的交互菜单要从 stdin 读输入，管道会把脚本本身喂给 stdin。
>
> 末尾的 `okxhttp` 是给脚本的 `$0`。这种跑法本地没有脚本文件，安装时脚本会从上面这个 URL 取回一份装成命令（`SELF_URL` 可覆盖）。
>
> 安装完成后脚本会把自己装成命令 `/usr/local/bin/okxhttp`，之后直接 `okxhttp` 进入菜单。

## 版本与自动升级

脚本内置版本号（`SCRIPT_VERSION`），每次安装会把版本写到 `$STACK_DIR/version` 并随生成的命令一起落地。

版本号由仓库的 `.githooks/pre-commit` 自动维护：只要一次提交改了 `okxhttp` 而版本没变，hook 会自动 patch+1（手动升 minor/major 时则尊重手动的值）。启用方式（clone 后执行一次）：

```sh
git config core.hooksPath .githooks
```

**每次运行都会自检**（任何子命令、包括直接 `okxhttp` 进菜单）：拉一次仓库里的脚本，比 `SCRIPT_VERSION`。

- 远端更新时，交互运行会问一句，回车即更新，输 `n` 跳过：

```
发现新版本 v1.1.36（当前 v1.1.35），现在更新？[Y/n]
```

- 非交互运行（`--yes` / 无 TTY）直接更新，不打断流程。
- 更新是原子的：先写 `okxhttp.new` → 校验里面确实是目标版本 → `mv` 覆盖，正在运行的进程不受影响。
- 一键方式运行（stdin）更新后会**用新版重新执行**，这次的操作就按新逻辑跑；以命令/文件方式运行时更新后下次运行生效。
- 离线、超时、内容不完整（缺 `main "$@"` 或版本号对不上）→ 静默跳过，不报错、不写坏命令。
- 只替换命令本身，不会重装/重启服务；配置层面的变更仍需跑一次安装。

```sh
okxhttp --version              # 当前脚本版本
okxhttp --status               # 同时显示「脚本版本 / 已安装命令版本」
sh -c "$(curl -fsSL https://raw.githubusercontent.com/banbendalao/okxhttp/main/okxhttp)" okxhttp
#   发现新版本 v1.1.36（当前 v1.1.35），现在更新？[Y/n]
#   [*] 已更新到 v1.1.36: /usr/local/bin/okxhttp
#   [*] 用新版重新执行…
```

## 非交互安装

```sh
# 临时隧道（Argo 随机域名），三协议全开
XHTTP=yes REALITY=yes HY2=yes ARGO_MODE=temp YES=1 okxhttp

# 固定隧道（token 模式）
ARGO_MODE=token ARGO_AUTH='<你的 tunnel token>' ARGO_DOMAIN='<你的域名>' \
XHTTP=yes REALITY=yes HY2=yes YES=1 okxhttp

# Hysteria2 用 LE 真实 IP 证书 + BT 流量走 WARP
HY2_CERT=le LE_EMAIL='<你的邮箱>' WARP=yes WARP_ROUTE=bittorrent YES=1 okxhttp

# 只要 REALITY
XHTTP=no HY2=no REALITY=yes YES=1 okxhttp
```

## 菜单与命令

直接运行 `okxhttp` 会先打印当前状态，再给一层扁平的操作列表（没有嵌套子菜单）：

```
$ okxhttp

===== 部署状态 =====
脚本版本   : v1.1.37（已安装命令: v1.1.37）
节点名     : node1
协议       : xhttp reality hy2
端口       : xhttp=2087 reality=443/tcp hy2=443/udp
服务       : xray=running argo=running 调度=running  init=systemd
实际监听   : xhttp reality hy2
证书       : CN=pic.bstarstatic.com，到期 …
订阅       : https://note.linkof.link/<key>

---------------- 操作 ----------------
 1) 重启服务        2) 查看日志       3) 节点链接
 4) 订阅地址        5) 同步订阅       6) 重置订阅 key
 6) 修改直连端口    7) 修改节点名     8) 证书信息
 9) 立即续期        r) 重装（沿用当前） u) 卸载
 0) 退出
```

未部署时只有 `1) 安装  0) 退出`。所有子动作都在这一层，`2)`、`5)`、`u)` 只会追问一次「看哪个日志 / 是否确认」，不再有多级菜单。

节点名默认取主机名，安装时可直接填，装好后用 `7) 修改节点名` 改（只影响链接与订阅，不重启服务；名称里不能有空白和 `#?&/`）。

```
okxhttp --status             # 只打印状态（脚本化用）
okxhttp --info               # 打印节点链接（由当前 config.json 实时推导）
okxhttp --restart            # 重启 xray 与 argo
okxhttp --log[=xray|argo]    # 看日志（LOG_LINES 控制行数）
okxhttp --cert-info          # 证书签发者/有效期/SAN/指纹/续期计划
okxhttp --renew              # 立即续期（当前证书是 LE 签发时才有效）
okxhttp --sub-reset          # 重置订阅 key：清空旧 key 内容 → 生成新 key → 推送当前节点
okxhttp --version            # 脚本版本
okxhttp --uninstall          # 卸载，保留证书目录
okxhttp --purge              # 卸载并删除证书
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `XHTTP` / `REALITY` / `HY2` | `yes` | 协议开关 |
| `ARGO_MODE` | `temp` | `temp` 临时隧道 / `token` 固定隧道 / `off` 不走隧道（XHTTP 直接公网） |
| `ARGO_AUTH` / `ARGO_DOMAIN` | 空 | 固定隧道 token / 域名（首次传入后写入 `stack.conf`，重装自动复用；面板 ingress 端口会被自动对齐） |
| `ARGO_PROTO` | `auto` | 连接器协议；`auto` 交给 cloudflared 自己（先试 quic，失败自动回退 http2），也可强制 `quic` / `http2`。不持久化，重装默认 auto。注册等待上限 240s——cloudflared 自身从 quic 回退到 http2 实测可达 ~3 分钟 |
| `TEMP_TRANSPORT` | `ws` | 临时隧道暴露方式：`ws`（可用）/ `xhttp`（quick tunnel 下实测不可用） |
| `XHTTP_PORT` / `REALITY_PORT` / `HY2_PORT` | 2087 / 443 / 443 | 端口；temp 模式且该入站不存在时自动取 10000-65535 随机空闲端口。交互安装时会直接问 REALITY / Hysteria2 端口（回车用默认或上次的值）；装好后想改不用重装：菜单 `2) 管理 → 7) 修改直连端口`（改完校验配置、重启内核、链接与订阅自动跟着变） |
| `WS_PORT` | `XHTTP_PORT+1` | WS 入站端口（temp 模式下同样随机） |
| `REALITY_SNI` | `pic.bstarstatic.com` | REALITY 目标站点（需 TLS1.3 + h2）；自签 hy2 证书的 CN/SAN 也用它，链接 `sni=` 同值 |
| `HY2_CERT` / `LE_EMAIL` | `self` / `ops@no-reply.dev` | 自签或 LE 证书；LE 会拒绝 `example.com` 这类保留域名 |
| `WARP` / `WARP_ROUTE` | `no` / `bittorrent` | 启用 WARP 出站；承载 `bittorrent` 或 `all`。启用时会自动加两条把 DoH 端点（域名 + IP）钉到 direct 的规则，避免「全部走 WARP」时 DoH 被路由进 WARP 形成死循环 |
| `SUB` / `SUB_URL` | `yes` / `https://note.linkof.link` | 生成订阅：把节点链接写到 AnyNote（`POST /set`），读 `GET /<key>` 即得纯文本节点列表 |
| `DNS_DOH` | `yes` | 目标域名由 **Xray 内置 DNS** 经 DoH 解析（1.1.1.1 / 8.8.8.8），不依赖系统 DNS；`no` 则回退系统 DNS |
| `NODE_NAME` / `PUBLIC_IP` / `PUBLIC_IP6` | 主机名 / 自动探测 / 自动探测 | 节点名（链接后缀 `#<name>-v4-<协议>`）、公网 v4 / v6；探测到 v6 时直连协议会额外出一条 v6 链接 |
| `LOG_LINES` / `FORCE_FETCH` | `50` / 空 | `--log` 行数、强制重新下载内核 |

## 订阅（临时隧道域名会变，用订阅自动跟）

安装时生成一个 UUID 作为 key，把当前节点链接推到 [AnyNote](https://note.linkof.link)（Cloudflare Workers + KV 的文本托管，`POST /set` 写、`GET /<key>` 读原文）：

```
订阅地址: https://note.linkof.link/<uuid>     # 客户端里当订阅 URL 用，内容是纯文本 vless:// / hysteria2://
```

- **双栈**：探测到公网 v6 时，REALITY 与 Hysteria2 各出两条链接（`<name>-v4-…` / `<name>-v6-…`），v6 宿主名用 `[]` 包裹
- **监听地址统一**：公网入站（REALITY / Hysteria2 / 隧道关闭时的 XHTTP）一律 `::`（Linux 默认双栈，v4 照样能连）；隧道入站（XHTTP / WS）一律 `::1`，只回环，cloudflared 也连 `[::1]`。需要内核开启 IPv6（没有 `/proc/net/if_inet6` 时安装会告警）

- **自动更新**：安装的调度服务（`okxhttp --daemon`，受 systemd/OpenRC/nohup 托管）每 60s 把当前节点链接算指纹跟上次比，**变了才推**（临时隧道换域名自动跟；没变化不发请求）。
- **重置 key**：管理菜单 `6) 订阅` 或 `okxhttp --sub-reset`。会先给旧 key 写入空值（把内容清掉），再生成新 key 并推送当前节点。
- **卸载不留垃圾**：`--uninstall` / `--purge` 会把当前 key 的内容清空，并移除调度服务。

> AnyNote 的 key 就是路径，猜不到但公开可读；节点里若含敏感信息请自行加长 key 或换自建实例。

## 固定隧道（token 模式）

首次用 `ARGO_MODE=token` 装好后，`ARGO_AUTH`（token）与 `ARGO_DOMAIN` 会写入 `stack.conf`（600，仅 root 可读），**重装不需要再传**；想换 token/域名就显式传值（env 或菜单里填写），**回车才表示复用**：

```sh
# 第一次
ARGO_MODE=token ARGO_AUTH='<token>' ARGO_DOMAIN='<域名>' YES=1 okxhttp
# 之后（自动复用 token/域名，只改其它参数也安全）
XHTTP=yes REALITY=yes HY2=yes YES=1 okxhttp
# 换 token/域名（env 优先于记忆值）
ARGO_AUTH='<新 token>' ARGO_DOMAIN='<新域名>' YES=1 okxhttp
```

菜单里问到域名/token 时方括号显示当前值，直接回车保持、输入新值即覆盖。`--status` 只显示 `[token 已保存]`，不回显明文；`--purge` 会连同状态一起删除。

**协议选择同样会记忆**：装过一次后，重装不传 `XHTTP/REALITY/HY2` 就沿用上次的选择；交互菜单里的勾选也从上一次的配置开始，而不是一律全开。

## 输出物

脚本只产出服务端资产，不生成任何客户端配置文件；分享链接不落盘，由 `--info` / 安装结束时从 `config.json`、`argo.log`、证书现场推导：

```
/usr/local/etc/xray-stack/
├── config.json   # 服务端配置（600；写前校验，失败不覆盖）
├── certs/        # 证书（cert.pem / key.pem）
├── stack.conf    # 部署状态（600）
├── warp.json     # WARP 凭据（600，启用 WARP 时）
├── lego.log      # LE 签发/续期日志（仅 HY2_CERT=le）
└── xray.log / argo.log / renew.log
```

## WARP 出站（BT 分流）

`WARP=yes` 时自动向 Cloudflare 注册免费 WARP 账号（凭据存 `warp.json`，重装复用），并加两条出站：

| tag | 作用 |
|---|---|
| `x-warp` | `wireguard` 出站（WARP） |
| `warp` | `freedom` + `streamSettings.sockopt.dialerProxy: x-warp`（供域名目标） |

路由规则 `{"type":"field","protocol":["bittorrent"],"outboundTag":"warp"}` —— 依赖入站 sniffing 识别 BT 协议。注意 `destOverride` **不需要也不支持**写 `bittorrent`（它只负责改写目标地址，而 BT 没有域名）。

TUN 自动检测：优先内核 TUN（更快），要求 `CAP_NET_ADMIN` + `/dev/net/tun`（缺失时尝试 `modprobe tun` / `mknod`）；不满足则用内置 TCP/IP 栈（`noKernelTun: true`），启动失败还会自动回落重试一次。

## 证书与自动续期

| 模式 | 有效期 | 续期 |
|---|---|---|
| `HY2_CERT=self`（默认） | 365 天 | 不自动续期（换证会改指纹） |
| `HY2_CERT=le` | 约 6.5 天（shortlived） | 每天检查，剩 <4 天时签发；证书没变不重启服务；失败保留旧证书 |

- 重装会**复用**仍有效的 LE 证书（剩余 >2 天且 SAN 匹配当前 IP），不会重复签发（LE 对同一 IP 限 5 张 / 168 小时）。
- 续期用 `timeout 180` 兜底（lego 遇 429 会无限退避重试）。

## 网络环境适配（都交给内核）

脚本只在**内核做不到**的地方补逻辑，能交给内核的一律交给内核：

| 需求 | 谁来做 | 说明 |
|---|---|---|
| Argo 连接器走 quic/http2 | **cloudflared** | `--protocol auto`：先试 quic，失败自动回退 http2（脚本不再自己重试/判断） |
| 连接 CF 边缘用 v4 还是 v6 | **cloudflared** | `--edge-ip-version auto` |
| 找到 CF 边缘地址 | 脚本解析 → **cloudflared 连接** | 用 DoH 查 `region1/2.v2.argotunnel.com` 的 A/AAAA，通过 cloudflared 的 `--edge <ip>:7844` 直接指定，跳过它的 SRV 查询 → **不依赖系统 DNS**；DoH 也失败才回退 SRV |
| 目标域名解析 | **Xray 内置 DNS** | 域名 DoH + `dns.hosts` bootstrap，`queryStrategy` 用内核默认 |
| 解析结果选哪一族去拨 | **Xray 拨号策略** | `sockopt.domainStrategy` = `UseIPv4` / `UseIPv6` / `UseIP`（按探测到的可用族）；WARP 包装出站同理 `ForceIPv4`/`ForceIPv6` |
| 有 TUN 就走内核 TUN | **Xray wireguard** | 有 `CAP_NET_ADMIN` + `/dev/net/tun` → 内核 TUN；否则 `noKernelTun` 内置栈 |
| WARP 端点解析 | **Xray 内置 DNS** | wireguard 出站带 `sockopt.domainStrategy`，`engage.cloudflareclient.com` 由 Xray 的 DoH 解析，不走系统 DNS |
| 临时隧道的 `api.trycloudflare.com` | 脚本（仅兜底） | 系统 DNS 挂了才用 DoH 写 `/etc/hosts` 托管块 |
| REALITY 的 dest 回退 | **系统 DNS**（内核行为） | REALITY 探测/回退要解析 `REALITY_SNI`（默认 `pic.bstarstatic.com`），这条不走 Xray 的 DoH。系统 DNS 完全不可用时 reality 节点会拒绝连接（xhttp/hy2 不受影响） |


## DNS

服务端解析目标域名默认走 **Xray 内置 DNS + 域名 DoH**，DoH 域名本身用 `dns.hosts` 里的一对 IPv4/IPv6 做 bootstrap（这就是 bootdns 的作用）：

```json
"dns": {
  "servers": ["https://cloudflare-dns.com/dns-query", "https://dns.google/dns-query"],
  "hosts": {
    "cloudflare-dns.com": ["1.1.1.1", "2606:4700:4700::1111"],
    "dns.google":           ["8.8.8.8", "2001:4860:4860::8888"]
  },
}
```

`queryStrategy` **不指定**（交给内核默认：A/AAAA 都查）；能否连上由**拨号侧**决定——`direct` 出站的 `streamSettings.sockopt.domainStrategy` 按探测到的协议族设置（纯 IPv4 → `UseIPv4`，纯 IPv6 → `UseIPv6`，双栈 → `UseIP`），WARP 包装出站同理用 `ForceIPv4`/`ForceIPv6`。这样**完全不依赖系统 DNS**，也不会在 v4-only 机器上去拨 AAAA。用域名 DoH + hosts 引导（而不是把 DoH 写成 IP），同一个配置在 v4-only / v6-only / 双栈机器上都能用——hosts 里同时给出两族地址，由拨号器选可达的那个。

`queryStrategy` 跟随探测到的协议族：纯 IPv4 用 `UseIPv4`，纯 IPv6 用 `UseIPv6`，双栈用 `UseIP` —— 避免纯 v4 机器拿到 AAAA 后连不上。

实测（把 `/etc/resolv.conf` 指向不存在的解析器后）：

```
系统解析测试: 解析失败
www.gstatic.com   → 204     api.github.com    → 200
www.wikipedia.org → 200     api.cloudflare.com→ 404（路径不存在，链路正常）
example.com       → 200
对照（DNS_DOH=no，走系统 DNS） → 000
```

`DNS_DOH=no` 可关掉，退回系统解析。

## DNS 不可用时的保障

脚本自身不依赖本地 DNS 的可用性：

| 场景 | 做法 |
|---|---|
| 探测出口 IP / 协议族 | `curl` 直连 `https://www.cloudflare.com/cdn-cgi/trace`；域名解析不了时先用 **DoH**（`1.1.1.1/dns-query`，失败再 `8.8.8.8/resolve`）解析，并写入 `$HOSTS_FILE` 的托管块 |
| `api.trycloudflare.com`（临时隧道创建） | 系统解析不了 → DoH 解析 → 写入 `/etc/hosts` 托管块（`# >>> okxhttp-doh`），`--uninstall` 会移除 |
| `region1/2.v2.argotunnel.com`（固定隧道边缘） | 同上，仅在系统解析失败时写 |
| `argotunnel.com` 的 **SRV** 记录 | **hosts 无法替代**。DoH 查 SRV 也拿不到时直接报错并提示「换 1.1.1.1 修好 DNS 后重试」，不装作成功 |

DoH 服务可用 `DOH_SERVERS` 覆盖（空格分隔），hosts 路径可用 `HOSTS_FILE` 覆盖。

## 已知限制

**临时隧道（`*.trycloudflare.com`）与 XHTTP 不兼容**，这是 Cloudflare 侧行为，服务端无法规避：

1. quick tunnel 会把普通 HTTP 响应体**整体缓冲到响应结束**才转发；XHTTP 的下行是永不结束的流 → 约 11s 后 CF 放弃。实测对照：同一 origin 每 500ms 写一行持续 8s，经 quick tunnel 的 16 行全部在 `t=+7s` 一次性到达，本地直连则逐次到达。
2. `mode=stream-one` 会被 CF 边缘直接 `403`（它发 `Content-Type: application/grpc`）。
3. WebSocket 不受影响（Upgrade 走双向 raw 通道），所以临时隧道默认用 WS；固定隧道（named/token）下 XHTTP 的 h2/h3 均正常。

**自签证书的信任锚是 pinSHA256，不是 `insecure`**。hysteria2 链接里带的是证书 SHA-256 指纹（hex，`openssl x509 -outform der | openssl dgst -sha256`），**不带 `insecure`**：

```
hysteria2://<auth>@<ip>:<port>/?sni=<伪装域名>&pinSHA256=<64 位 hex>#name
```

实测（本地起 hysteria 服务端 + 官方客户端）：

| 链接写法 | 结果 |
|---|---|
| `pinSHA256=…`（无 insecure） | 官方客户端直接失败：`tls: failed to verify certificate: x509: certificate signed by unknown authority` —— Go TLS 的链校验发生在 pin 回调**之前**，自签必然先失败 |
| `insecure=1&pinSHA256=…` | 连通，且 pin 真的在起作用（换成错误指纹立刻报 `no certificate matches the pinned hash`） |
| `insecure=1`（无 pin） | 连通但**完全不校验**，任何中间人都能劫持 |

所以：
- **Xray 内核客户端（v2rayN / mihomo 等）**：`pinSHA256` 会被映射成 `pinnedPeerCertSha256`，内核在设置了 pin 时内部才跳过链校验并用 pin 代替校验 → 本链接可直接用。
- **hysteria 官方 CLI**：需要在链接里额外加 `insecure=1`，否则链校验先失败；加了之后验证仍由 pin 完成（不是盲跳）。要完全避免这一类取舍，用 `HY2_CERT=le` 签真实 IP 证书即可，链接里既无 `insecure` 也无 pin。

## 已验证

| 项目 | 环境 | 结果 |
|---|---|---|
| 临时隧道：WS + REALITY + HY2 | Alpine（OpenRC） | 全部 204 |
| 固定隧道：XHTTP h2 + h3 + REALITY + HY2 | Alpine（OpenRC）+ 异地客户端 | 全部 204，h2/h3 约 0.5s |
| XHTTP h2/h3 | 服务器本机自测 | 204（0.45–0.75s），稳定 |
| REALITY dest `pic.bstarstatic.com` | TLS1.3 + h2 探测 | 通过（LE 证书、SAN 匹配、ALPN h2） |
| HY2 自签 / LE 真实 IP 证书 | Alpine | 204；LE 签发成功并自动续期 |
| BT → WARP 分流 | Alpine | 远端观测到源 IP 为 `104.28.x.x`（Cloudflare），普通流量仍为本机 IP |
| 安装幂等 / `--uninstall` / `--purge` | Alpine + Debian 13 | 通过（凭据不漂移、无重复单元、无监听残留） |
| systemd 托管 | Debian 13 | unit active；Alpine 用 `supervise-daemon`，`kill -9` 后约 5s 自动拉起 |
| 测试 | 10 个测试文件 / 约 190 条断言 + `shellcheck -s sh` | 全绿 / 0 告警 |

## 依赖

安装时自动检查并安装 `curl jq unzip openssl`（Debian `apt-get`、Alpine `apk`；Alpine 上若缺 `supervise-daemon` 会安装/升级 `openrc`）。其余只用 busybox 自带的 `sed/awk/grep/od/timeout/tar`。

下载失败会打印 curl 的真实原因并重试 2 次。
