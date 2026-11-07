# xray-stack —— Xray 多协议一键部署

Debian / Alpine 通用的单文件部署脚本，一个 Xray 内核跑三种协议，可任意组合：

| 协议 | 说明 |
|---|---|
| **VLESS + XHTTP**（源站不加密） | 经 Argo 隧道暴露。**固定隧道**输出 `h2` + `h3` 两个节点；**临时隧道**默认用 WS（原因见下） |
| **VLESS + TCP + REALITY + Vision** | 直连，REALITY 目标站点默认 `dm.toutiao.com` |
| **Hysteria2** | UDP，证书可选**自签**或 **LE 真实 IP 证书**（6 天期，自动续期） |

## 用法

```sh
# 交互菜单
sh xray-stack.sh

# 非交互（推荐，可复现）
XHTTP=yes REALITY=yes HY2=yes ARGO_MODE=temp YES=1 sh xray-stack.sh

# 固定隧道
ARGO_MODE=token ARGO_AUTH='<token>' ARGO_DOMAIN=example.com YES=1 sh xray-stack.sh

# 其他子命令
sh xray-stack.sh --selftest     # 每个节点端到端自检（本地起客户端 + curl 真实出网）
sh xray-stack.sh --info         # 打印链接与状态，不重装
sh xray-stack.sh --uninstall    # 卸载（保留证书）；--purge 连证书一起删
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
| `LE_EMAIL` | `admin@example.com` | ACME 邮箱 |
| `NODE_NAME` | 主机名 | 节点名 |

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
| Alpine 3.24.3（OpenRC）临时隧道：WS + REALITY + HY2 | 已验证（`--selftest` 全绿） |
| Alpine 3.24.3（OpenRC）固定隧道：XHTTP h2 + h3 + REALITY + HY2 | 已验证（服务器自检 + 异地客户端复验均 `204`） |
| REALITY dest `dm.toutiao.com`（TLS1.3 + h2） | 已验证 |
| HY2 自签证书 + `insecure`&`pinSHA256` 客户端 | 已验证（官方 hysteria 客户端 `204`） |
| `HY2_CERT=le` 真实 IP 证书签发 | 未验证（本机 80 端口被占用 / 未做真实签发） |
| Debian 13 实机 systemd 托管 | 见 `docs/verification/` |
| 上游 Xray 26.10.31 的 hysteria **出站** | 有 bug（server 报 `invalid address length`）；hy2 节点统一用官方 hysteria 客户端 |

## 设计要点

- 配置由 `jq -n -f tpl/<proto>.jq` 生成各入站，再 `jq -s` 合成，最后 `xray run -test` 强校验，不通过不写服务。
- 服务托管按 systemd / OpenRC / nohup 三分支；`INIT_SYS=none` 时用 pidfile。
- 幂等：重复执行 = 重装；密钥与自签证书默认复用；`--uninstall` 会移除本脚本安装过的二进制、unit、cron，且保留证书（除非 `--purge`）。
- 自检对 hy2 使用官方 hysteria 客户端（Xray 26.10.31 的 hysteria 出站不可用），其余节点用 Xray 客户端。
