#!/bin/sh
# t_client：分享链接、客户端配置（xray json + 官方 hysteria yaml）、mihomo、sub.txt
. "$(dirname "$0")/lib.sh"
echo "== t_client =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/cli-$$"
export STACK_DIR
rm -rf "$STACK_DIR"
mkdir -p "$STACK_DIR/certs"
. ./okxhttp
write_templates

export UUID=11111111-1111-4111-8111-111111111111
export PUBLIC_IP=203.0.113.9
export NODE_NAME=testnode
export XHTTP_PATH=/p1 XHTTP_PORT=2087
export REALITY_PORT=443 REALITY_SNI=dm.toutiao.com
export HY2_PORT=443 HY2_PASSWORD=pw-test
ARGO_DOMAIN_RESOLVED=abc-def.trycloudflare.com
eval "$(gen_x25519)"
export REALITY_PRIV=$PRIVATE_KEY
export REALITY_PUB=$PUBLIC_KEY
export REALITY_SHORTID=1a2b3c4d
gen_self_cert test.local "$TLS_DIR" 203.0.113.9 >/dev/null 2>&1
HY2_PIN=$(cert_pin_sha256 "$TLS_DIR/cert.pem")

assert_match "h2 链接" '^vless://11111111.*@abc-def\.trycloudflare\.com:443\?.*alpn=h2.*type=xhttp.*path=/p1.*mode=auto' "$(uri_xhttp abc-def.trycloudflare.com h2)"
assert_match "h3 链接" 'alpn=h3' "$(uri_xhttp abc-def.trycloudflare.com h3)"
assert_match "xhttp 链接带 host 参数" 'host=abc-def\.trycloudflare\.com' "$(uri_xhttp abc-def.trycloudflare.com h2)"
assert_match "reality 链接" "flow=xtls-rprx-vision.*pbk=$PUBLIC_KEY.*sid=1a2b3c4d.*type=tcp" "$(uri_reality)"
assert_match "reality 链接指向公网 IP" '@203\.0\.113\.9:443' "$(uri_reality)"
assert_match "hy2 链接" '^hysteria2://pw-test@203\.0\.113\.9:443/\?sni=203\.0\.113\.9&insecure=1' "$(uri_hy2)"
assert_match "节点名带后缀" '#testnode-hy2$' "$(uri_hy2)"

# 预置上一次部署的陈旧节点文件，验证会被清理
mkdir -p "$CLI_DIR"; printf '{}\n' > "$CLI_DIR/client-xhttp-h2.json"

# 临时隧道：实测不支持 XHTTP，输出 ws 节点
WS_PATH=/ws1 ENABLE_WS=1 ENABLE_XHTTP=1 ENABLE_REALITY=1 ENABLE_HY2=1 ARGO_MODE=temp emit_clients
assert_ok "临时模式生成 ws 客户端" test -s "$CLI_DIR/client-ws.json"
assert_ok "临时模式不生成 xhttp 客户端" sh -c "[ ! -e '$CLI_DIR/client-xhttp-h2.json' ]"
assert_ok "陈旧节点文件被清理" sh -c "[ ! -e '$CLI_DIR/client-xhttp-h2.json' ]"
assert_ok "reality 客户端配置生成" test -s "$CLI_DIR/client-reality.json"
assert_ok "hy2 官方客户端配置生成" test -s "$CLI_DIR/hy2-client.yaml"
assert_ok "ws 客户端通过 xray 校验" test_config "$CLI_DIR/client-ws.json"
assert_eq "ws 客户端网络类型" "ws" "$(jq -r '.outbounds[0].streamSettings.network' "$CLI_DIR/client-ws.json")"
assert_eq "reality 客户端 vision" "xtls-rprx-vision" "$(jq -r '.outbounds[0].settings.vnext[0].users[0].flow' "$CLI_DIR/client-reality.json")"
assert_match "hy2 yaml 带 pin" "pinSHA256: $HY2_PIN" "$(cat "$CLI_DIR/hy2-client.yaml")"
assert_match "hy2 yaml 带 insecure" 'insecure: true' "$(cat "$CLI_DIR/hy2-client.yaml")"
assert_match "hy2 yaml 带 auth" 'auth: pw-test' "$(cat "$CLI_DIR/hy2-client.yaml")"
assert_match "mihomo 含 ws 节点" 'name: testnode-ws-h2' "$(cat "$CLI_DIR/mihomo.yaml")"
assert_eq "sub 行数（ws+reality+hy2）" "3" "$(grep -c '://' "$CLI_DIR/sub.txt")"

# 固定隧道：输出 xhttp h2 + h3
rm -rf "$CLI_DIR"
ENABLE_WS=0 ENABLE_XHTTP=1 ENABLE_REALITY=1 ENABLE_HY2=1 ARGO_MODE=token emit_clients
assert_ok "固定模式生成 h2 客户端" test -s "$CLI_DIR/client-xhttp-h2.json"
assert_ok "固定模式生成 h3 客户端" test -s "$CLI_DIR/client-xhttp-h3.json"
assert_ok "h2 客户端通过 xray 校验" test_config "$CLI_DIR/client-xhttp-h2.json"
assert_ok "h3 客户端通过 xray 校验" test_config "$CLI_DIR/client-xhttp-h3.json"
assert_eq "h2 客户端 alpn" "h2" "$(jq -r '.outbounds[0].streamSettings.tlsSettings.alpn[0]' "$CLI_DIR/client-xhttp-h2.json")"
assert_eq "h3 客户端 alpn" "h3" "$(jq -r '.outbounds[0].streamSettings.tlsSettings.alpn[0]' "$CLI_DIR/client-xhttp-h3.json")"
assert_match "mihomo 含 h2/h3 节点" 'name: testnode-xhttp-h2' "$(cat "$CLI_DIR/mihomo.yaml")"
assert_eq "sub 行数（h2+h3+reality+hy2）" "4" "$(grep -c '://' "$CLI_DIR/sub.txt")"
rm -rf "$STACK_DIR"
