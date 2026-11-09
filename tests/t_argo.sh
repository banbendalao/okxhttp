#!/bin/sh
# t_argo：cloudflared 日志解析与连接协议选择
. "$(dirname "$0")/lib.sh"
echo "== t_argo =="
STACK_LIB_ONLY=1 . ./okxhttp

assert_eq "临时隧道域名" "random-words-1234.trycloudflare.com" "$(argo_domain_from_log tests/fixtures/argo-temp.log)"
assert_eq "固定隧道 ingress 端口" "8080" "$(argo_ingress_port tests/fixtures/argo-token.log)"
assert_eq "无域名返回空" "" "$(argo_domain_from_log /dev/null)"
assert_eq "文件不存在返回空" "" "$(argo_domain_from_log /nonexistent.log)"
assert_eq "无 ingress 返回空" "" "$(argo_ingress_port /dev/null)"
assert_ok "固定隧道已注册识别" argo_log_connected tests/fixtures/argo-token.log
assert_fail "未注册不被识别" argo_log_connected /dev/null

# 协议族探测（用于拨号策略）：取值只能是 4/6/46/空
assert_match "协议族取值" '^(4|6|46|64|)$' "$(detect_ip_family)"

# DoH 端点必须用 IP 字面量（否则解析自身又要 DNS），但除此之外不应出现写死的 IP
assert_eq "IP 字面量只出现在 DNS 常量里" "0" "$(grep -nE '2606:4700:4700::1111|1\.1\.1\.1/dns-query|8\.8\.8\.8/resolve' okxhttp | grep -vcE '^[0-9]+:DEF_DOH_V[46]=|^[0-9]+:DEF_XRAY_DOH_HOSTS=')"
# 内核自选：cloudflared 一律用 auto（协议与 IP 族都不由脚本干预）
assert_eq "cloudflared 命令都用 --edge-ip-version auto" "3" "$(grep -cE '^[^#]*CLOUDFLARED_BIN.*edge-ip-version auto' okxhttp)"
assert_eq "没有脚本侧的 edge-ip 探测残留" "0" "$(grep -c "detect_edge_ip_version\|ARGO_EDGE_IP" okxhttp)"
