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

# 出站协议族探测：4 / 6 / 46 / 空 四种结果，映射到 cloudflared 的 edge-ip-version
assert_match "协议族取值" '^(4|6|46|64|)$' "$(detect_ip_family)"
assert_match "edge-ip-version 取值" '^(auto|4|6|)$' "$(detect_edge_ip_version)"
# 三种环境都要覆盖（用桩替换探测结果，不依赖本机网络）
_fam() { # 用桩替换探测结果，验证三种环境的映射
  _want=$1
  detect_ip_family() { printf '%s' "$_want"; }
  detect_edge_ip_version
}
assert_eq "双栈 => auto" "auto" "$(_fam 46)"
assert_eq "v4-only => 4" "4" "$(_fam 4)"
assert_eq "v6-only => 6" "6" "$(_fam 6)"
assert_eq "都不通 => 空（安装时会报错）" "" "$(_fam '')"
# 探测目标不能是写死的 IP
assert_eq "探测目标用域名" "0" "$(grep -cE 'DEF_PROBE_HOST=(https?://)?[0-9a-f:.]*[0-9]' okxhttp)"
# DoH 端点必须用 IP 字面量（否则解析自身又要 DNS），但除此之外不应出现写死的 IP
assert_eq "IP 字面量只出现在 DoH 端点常量里" "0" "$(grep -nE '2606:4700:4700::1111|1\.1\.1\.1/dns-query' okxhttp | grep -vcE 'DEF_DOH_V[46]|DEF_XRAY_DOH_V[46]')"
assert_eq "cloudflared 命令全部使用探测值" "0" "$(grep -c "edge-ip-version auto" okxhttp)"
