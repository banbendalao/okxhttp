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

assert_eq "UDP 通选 quic" "quic" "$(ARGO_PROTO=auto UDP_EGRESS_OK=1 argo_pick_proto)"
assert_eq "UDP 不通选 http2" "http2" "$(ARGO_PROTO=auto UDP_EGRESS_OK=0 argo_pick_proto)"
assert_eq "强制 http2" "http2" "$(ARGO_PROTO=http2 UDP_EGRESS_OK=1 argo_pick_proto)"
assert_eq "强制 quic" "quic" "$(ARGO_PROTO=quic UDP_EGRESS_OK=0 argo_pick_proto)"

# 边缘 IP 版本探测：只会给 auto 或 4，且本机结果与实际 IPv6 出站能力一致
assert_match "edge-ip-version 取值" '^(auto|4)$' "$(detect_edge_ip_version)"
if curl -6 -fsS -m 5 -o /dev/null "http://[2606:4700:4700::1111]/" 2>/dev/null; then
  assert_eq "有 IPv6 出站 => auto" "auto" "$(detect_edge_ip_version)"
else
  assert_eq "无 IPv6 出站 => 4" "4" "$(detect_edge_ip_version)"
fi

# 三处 cloudflared 调用都必须带上探测结果，而不是硬编码 auto
assert_eq "cloudflared 命令全部使用探测值" "0" "$(grep -c "edge-ip-version auto" okxhttp)"
