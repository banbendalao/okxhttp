#!/bin/sh
# t_argo：cloudflared 日志解析与连接协议选择
. "$(dirname "$0")/lib.sh"
echo "== t_argo =="
STACK_LIB_ONLY=1 . ./xray-stack.sh

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
