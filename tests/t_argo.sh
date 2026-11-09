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

# --edge：用 DoH 解析边缘地址，跳过 SRV（三种协议族）
_edges() { # family
  _fam=$1
  detect_ip_family() { printf '%s' "$_fam"; }
  doh_query() { # name type code
    case "$2" in
      A) printf '198.41.192.7\n198.41.192.8\n' ;;
      AAAA) printf '2606:4700:d0::a29f:c001\n' ;;
    esac
  }
  argo_edge_args
}
assert_eq "v4-only 只用 A 记录" "--edge 198.41.192.7:7844 --edge 198.41.192.8:7844 --edge 198.41.192.7:7844 --edge 198.41.192.8:7844" "$(_edges 4)"
assert_match "v6-only 用 [v6]:7844" '^--edge \[2606:4700:d0::a29f:c001\]:7844' "$(_edges 6)"
assert_eq "双栈同时给 A 和 AAAA" "6" "$(set -- $(_edges 46); echo $(( $# / 2 )))"
assert_match "双栈含 v6 地址" '\[2606:4700:d0::a29f:c001\]:7844' "$(_edges 46)"
# 解析不到时返回空（回退 SRV）
assert_eq "解析不到返回空" "" "$(detect_ip_family() { printf '4'; }; doh_query() { return 1; }; argo_edge_args)"
