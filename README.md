# okxhttp

Debian / Alpine 通用的 Xray 一键部署脚本（单文件、纯 POSIX sh）。一个 Xray 内核跑三种协议，可任意组合，带管理命令与自动续期。

## 特性

| 协议 | 暴露方式 | 说明 |
|---|---|---|
| **VLESS + XHTTP**（源站不加密） | Argo 隧道 | 固定隧道输出 `h2` + `h3` 两个节点；临时隧道用 WS（原因见[已知限制](#已知限制)） |
| **VLESS + TCP + REALITY + Vision** | 直连 | REALITY 目标站点默认 `dm.toutiao.com` |
| **Hysteria2** | 直连（UDP） | 证书可选自签或 Let's Encrypt 真实 IP 证书，自动续期 |
| **WARP 出站**（可选） | Cloudflare WARP | 自动注册免费账号；按嗅探结果把 BT 流量送 WARP |

其它：交互菜单 + 环境变量双模式、systemd/OpenRC/nohup 三分支托管（Alpine 用 `supervise-daemon` 自动拉起）、配置写盘前 `xray run -test` 校验、失败自动回滚、卸载干净。

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

- `okxhttp --version` 查看当前脚本版本；`--status` 同时显示「脚本版本 / 已安装命令版本」。
- **用 curl/wget 一键方式运行时会自动检测**：如果已安装的 `/usr/local/bin/okxhttp` 版本低于正在运行的版本，就地更新命令（无需重装部署），然后继续执行你这次要做的操作。
- 以文件方式或已安装命令方式运行时不联网、不改动命令。

```sh
# 升级只需再跑一次一键命令，旧命令会被自动替换
sh -c "$(curl -fsSL https://raw.githubusercontent.com/banbendalao/okxhttp/main/okxhttp)" okxhttp --status
#   [*] 已安装命令是 v1.0.0，当前 v1.0.1，自动更新
#   [*] 已安装命令: /usr/local/bin/okxhttp（v1.0.1）
```

> 注意：自动更新只替换命令本身，不会重装/重启服务；要应用配置层面的变更仍需跑一次安装。

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

```
okxhttp                      # 菜单：1 安装/重装  2 管理  3 卸载
okxhttp --status             # 协议/端口/服务/监听/证书/WARP 一屏
okxhttp --info               # 打印节点链接（由当前 config.json 实时推导）
okxhttp --restart            # 重启 xray 与 argo
okxhttp --log[=xray|argo]    # 看日志（LOG_LINES 控制行数）
okxhttp --cert-info          # 证书签发者/有效期/SAN/指纹/续期计划
okxhttp --renew              # 立即续期（仅 HY2_CERT=le）
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
| `ARGO_PROTO` | `auto` | 连接器协议：先 quic，60s 内未完成隧道注册则回退 http2；也可强制 `quic` / `http2` |
| （自动）`edge-ip` | 探测 | 安装时探测 IPv6 出站：可用 → `--edge-ip-version auto`；不可用（v4-only 机器）→ 强制 `4`，避免 cloudflared 去连 IPv6 边缘超时 |
| `TEMP_TRANSPORT` | `ws` | 临时隧道暴露方式：`ws`（可用）/ `xhttp`（quick tunnel 下实测不可用） |
| `XHTTP_PORT` / `REALITY_PORT` / `HY2_PORT` | 2087 / 443 / 443 | 端口；temp 模式且该入站不存在时自动取 10000-65535 随机空闲端口 |
| `WS_PORT` | `XHTTP_PORT+1` | WS 入站端口（temp 模式下同样随机） |
| `REALITY_SNI` | `dm.toutiao.com` | REALITY 目标站点（需 TLS1.3 + h2） |
| `HY2_CERT` / `LE_EMAIL` | `self` / `ops@no-reply.dev` | 自签或 LE 证书；LE 会拒绝 `example.com` 这类保留域名 |
| `WARP` / `WARP_ROUTE` | `no` / `bittorrent` | 启用 WARP 出站；承载 `bittorrent` 或 `all` |
| `NODE_NAME` / `PUBLIC_IP` | 主机名 / 自动探测 | 节点名、公网 IP |
| `LOG_LINES` / `FORCE_FETCH` | `50` / 空 | `--log` 行数、强制重新下载内核 |

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
├── renew.sh      # LE 续期脚本（仅 HY2_CERT=le）
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

## 网络环境适配

- **v4-only 机器**：安装时用 `curl -6 http://[2606:4700:4700::1111]/` 探测 IPv6 出站，不通就强制 cloudflared 走 IPv4 边缘（`--edge-ip-version 4`），日志会打印「未检测到 IPv6 出站，Argo 连接器强制走 IPv4 边缘」，`--status` 显示 `连接器协议 : quic（edge-ip 4）`。
- **WARP** 的出站端点固定用 IPv4 字面量（`162.159.192.1:2408`），不受 DNS/双栈影响。

## 已知限制

**临时隧道（`*.trycloudflare.com`）与 XHTTP 不兼容**，这是 Cloudflare 侧行为，服务端无法规避：

1. quick tunnel 会把普通 HTTP 响应体**整体缓冲到响应结束**才转发；XHTTP 的下行是永不结束的流 → 约 11s 后 CF 放弃。实测对照：同一 origin 每 500ms 写一行持续 8s，经 quick tunnel 的 16 行全部在 `t=+7s` 一次性到达，本地直连则逐次到达。
2. `mode=stream-one` 会被 CF 边缘直接 `403`（它发 `Content-Type: application/grpc`）。
3. WebSocket 不受影响（Upgrade 走双向 raw 通道），所以临时隧道默认用 WS；固定隧道（named/token）下 XHTTP 的 h2/h3 均正常。

## 已验证

| 项目 | 环境 | 结果 |
|---|---|---|
| 临时隧道：WS + REALITY + HY2 | Alpine（OpenRC） | 全部 204 |
| 固定隧道：XHTTP h2 + h3 + REALITY + HY2 | Alpine（OpenRC）+ 异地客户端 | 全部 204，h2/h3 约 0.5s |
| XHTTP h2/h3 | 服务器本机自测 | 204（0.45–0.75s），稳定 |
| REALITY dest `dm.toutiao.com` | TLS1.3 + h2 探测 | 通过 |
| HY2 自签 / LE 真实 IP 证书 | Alpine | 204；LE 签发成功并自动续期 |
| BT → WARP 分流 | Alpine | 远端观测到源 IP 为 `104.28.x.x`（Cloudflare），普通流量仍为本机 IP |
| 安装幂等 / `--uninstall` / `--purge` | Alpine + Debian 13 | 通过（凭据不漂移、无重复单元、无监听残留） |
| systemd 托管 | Debian 13 | unit active；Alpine 用 `supervise-daemon`，`kill -9` 后约 5s 自动拉起 |
| 测试 | 10 个测试文件 / 约 190 条断言 + `shellcheck -s sh` | 全绿 / 0 告警 |

## 依赖

安装时自动检查并安装 `curl jq unzip openssl`（Debian `apt-get`、Alpine `apk`；Alpine 上若缺 `supervise-daemon` 会安装/升级 `openrc`）。其余只用 busybox 自带的 `sed/awk/grep/od/timeout/tar`。

下载失败会打印 curl 的真实原因并重试 2 次。
