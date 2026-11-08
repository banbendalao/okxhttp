# okxhttp —— Xray 多协议一键部署

Debian / Alpine 通用的单文件部署脚本，一个 Xray 内核跑三种协议，可任意组合：

| 协议 | 说明 |
|---|---|
| **VLESS + XHTTP**（源站不加密） | 经 Argo 隧道暴露。**固定隧道**输出 `h2` + `h3` 两个节点；**临时隧道**默认用 WS（原因见下） |
| **VLESS + TCP + REALITY + Vision** | 直连，REALITY 目标站点默认 `dm.toutiao.com` |
| **Hysteria2** | UDP，证书可选**自签**或 **LE 真实 IP 证书**（6 天期，自动续期） |

## 用法

```sh
# 首次：用脚本自身跑一次安装（安装完成后会自动装为命令 /usr/local/bin/okxhttp）
sh okxhttp            # 或 ./okxhttp

# 之后直接用命令管理
okxhttp               # 交互菜单：安装 / 重装 · 管理 · 卸载
okxhttp --status
```

> 安装会把脚本自身复制到 `/usr/local/bin/okxhttp`（内容相同则跳过），`--uninstall` 会把该命令一并移除。

菜单结构：

```
======== okxhttp ========
 1) 安装 / 重装      → 协议勾选 → Argo 模式 → 证书模式 → 端口
 2) 管理             → 状态 / 日志 / 重启 / 证书信息·续期 / 节点链接
 3) 卸载             → 二次确认；证书保留
 0) 退出
```

# 非交互（推荐，可复现）
XHTTP=yes REALITY=yes HY2=yes ARGO_MODE=temp YES=1 okxhttp

# 固定隧道
ARGO_MODE=token ARGO_AUTH='<token>' ARGO_DOMAIN=example.com YES=1 okxhttp

# 管理命令
okxhttp --status        # 协议/端口/服务/证书一屏概览
okxhttp --info          # 打印节点链接，不重装
okxhttp --restart       # 重启 xray 与 argo
okxhttp --log=xray      # 看日志（--log 两个都看，--log=argo 看隧道）
okxhttp --cert-info     # 证书签发者/有效期/SAN/指纹/续期计划
okxhttp --renew         # 立即执行 LE 续期（仅 HY2_CERT=le）

# 卸载
okxhttp --uninstall     # 保留证书目录
okxhttp --purge         # 连证书一起删
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `XHTTP` / `REALITY` / `HY2` | `yes` | 协议开关（`yes`/`no`） |
| `ARGO_MODE` | `temp` | `temp` 临时隧道 / `token` 固定隧道 / `off` 不走隧道 |
| `ARGO_AUTH` / `ARGO_DOMAIN` | 空 | 固定隧道 token / 域名（token 模式的 ingress 由 CF 面板决定，脚本会读取日志并自动对齐端口） |
| `ARGO_PROTO` | `auto` | 连接器协议：`auto`（先 quic，15s 不通回退 http2）/ `quic` / `http2`；始终只跑一个连接器 |
| `TEMP_TRANSPORT` | `ws` | 临时隧道暴露方式：`ws`（可用）/ `xhttp`（quick tunnel 下实测不可用，见下） |
| `REALITY_SNI` | `dm.toutiao.com` | REALITY 目标站点 |
| `XHTTP_PORT` / `REALITY_PORT` / `HY2_PORT` | 2087 / 443 / 443 | 端口 |
| `HY2_CERT` | `self` | `self` 自签 / `le` LE 真实 IP 证书 |
| `LE_EMAIL` | `ops@no-reply.dev` | ACME 邮箱（LE 会拒绝 `example.com` 这类保留域名） |
| `NODE_NAME` | 主机名 | 节点名 |

## 依赖与下载

安装时自动检查并安装缺失依赖：`curl jq unzip openssl`（Alpine 上若缺 `supervise-daemon`，还会自动装/升级 `openrc`）（Debian 用 `apt-get`，Alpine 用 `apk`；装完复查，仍缺则中止并给出提示）。其余只用 busybox 自带的 `sed/awk/grep/od/timeout/tar` 等。

下载失败时脚本会打印 curl 的真实原因并重试 2 次。

## 输出物

脚本只产出服务端资产与**四行分享链接**，不生成任何客户端配置文件：

```
/usr/local/etc/xray-stack/
├── config.json   # 服务端配置（xray run -test 校验通过才启用）
├── certs/        # 证书（cert.pem / key.pem）
├── tpl/          # jq 模板
├── links.txt     # vless:// / hysteria2:// 链接文本，--info 或安装结束时打印
├── stack.conf    # 部署状态（600）
├── renew.sh      # LE 续期脚本（仅 HY2_CERT=le）
└── xray.log / argo.log / renew.log
```

## 证书与自动续期

| 模式 | 有效期 | 续期 |
|---|---|---|
| `HY2_CERT=self`（默认，自签） | 365 天 | **不自动续期**（自签换证会改变指纹，需要自行更新） |
| `HY2_CERT=le`（Let's Encrypt 真实 IP 证书） | 约 6.5 天（shortlived profile） | **自动续期** |

LE 模式的续期机制：

- 安装时写 `$STACK_DIR/renew.sh` + cron：`30 3 * * *`（Debian `/etc/cron.d/xray-stack-renew`，Alpine `/etc/crontabs/root` 并启用 crond）。
- 每天检查一次，`--renew-days 4`（剩 <4 天才真正签发）；**证书没变就不重启服务**。
- 续期成功后换证书并 `restart xray`；失败保留旧证书、非 0 退出、下个周期再试。
- `timeout 180` 兜底：lego 遇到 `429 rateLimited` 会无限退避重试，没有这个超时 cron/`--renew` 会挂住。
- 手动：`okxhttp --renew`；证书信息：`okxhttp --cert-info`。
- **重装会复用现有 LE 证书**（剩余 >2 天且 SAN 包含当前公网 IP 时不再签发），LE 对同一 IP 有 `5 张 / 168 小时` 的额度。
- 续期日志：`$STACK_DIR/renew.log`。

## 已知限制：quick tunnel（trycloudflare）与 XHTTP

实测结论（完整证据见 `docs/verification/2026-11-08-quicktunnel-xhttp-rootcause.md`）：

1. **quick tunnel 会把普通 HTTP 响应体整体缓冲到响应结束才转发**。XHTTP 的下行是永不结束的流 → 永远不放行 → 约 11s 后 CF 放弃，客户端报错。
   - 对照组：同一 origin 每 500ms 写一行、持续 8 秒，quick tunnel 下 16 行全部在 `t=+7s` 一次性到达；本地直连逐次到达。
   - 因此「让 origin 更频繁写心跳/padding 以提前 flush」不可行（写入只会进同一个缓冲区）。
2. **`mode=stream-one` 会被 CF 边缘直接 403**：它发 `Content-Type: application/grpc`；换成普通 Content-Type 的同一请求则 200。
3. **WebSocket 不受影响**（Upgrade 走双向 raw 通道），所以临时隧道默认用 WS。
4. **固定隧道（named/token）无此问题**：XHTTP `h2` 与 `h3` 均实测 `204`。

## 已验证 / 未验证

| 项 | 状态 |
|---|---|
| Alpine 3.24.3（OpenRC）临时隧道：WS + REALITY + HY2 | 已验证（实测 `204`） |
| Alpine 3.24.3（OpenRC）固定隧道：XHTTP h2 + h3 + REALITY + HY2 | 已验证（异地客户端复验均 `204`） |
| REALITY dest `dm.toutiao.com`（TLS1.3 + h2） | 已验证 |
| HY2 自签证书（`insecure` + `pinSHA256`） | 已验证（`204`） |
| `HY2_CERT=le` 真实 IP 证书签发（Let's Encrypt shortlived，6.5 天）+ 自动续期 cron | 已验证（签发成功，hy2 `204`） |
| Debian 13 实机 systemd 托管 | 已验证（unit active；reality/hy2 回环 `204`；公网入站受沙箱限制） |
| 幂等重装 / `--uninstall` / `--purge` | 已验证 |
| 上游 Xray 26.10.31 的 hysteria **出站** | 有 bug（server 报 `invalid address length`），与服务端部署无关 |

## 设计要点

- 配置由 `jq -n -f tpl/<proto>.jq` 生成各入站，再 `jq -s` 合成，最后 `xray run -test` 强校验，不通过不写服务。
- 服务托管按 systemd / OpenRC / nohup 三分支：
  - systemd：`Restart=always` + `RestartSec=5`
  - **OpenRC（Alpine）：用 `supervise-daemon`，`respawn_delay=5`、`respawn_max=0`，进程被杀/崩溃后自动拉起**；`supervise-daemon` 由 `openrc` 包提供，缺失时脚本自动 `apk add --no-cache openrc`（老版本会顺带升级），装完复查；只有装不上才退回 `command_background`
  - 都没有时（容器）：`nohup` + pidfile，无守护
- 幂等：重复执行 = 重装；密钥与自签证书默认复用；`--uninstall` 会移除本脚本安装过的二进制、unit、cron，且保留证书（除非 `--purge`）。
