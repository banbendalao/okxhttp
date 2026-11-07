#!/bin/sh
# t_render：三协议 jq 模板、合成、xray 配置校验
. "$(dirname "$0")/lib.sh"
echo "== t_render =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/render-$$"
export STACK_DIR
rm -rf "$STACK_DIR"
. ./xray-stack.sh
mkdir -p "$STACK_DIR/certs"
write_templates

export UUID=11111111-1111-4111-8111-111111111111
eval "$(gen_x25519)"
export REALITY_PRIV=$PRIVATE_KEY REALITY_SHORTID=1a2b3c4d
export XHTTP_PORT=2087 XHTTP_PATH=/abc123
export REALITY_PORT=443 REALITY_SNI=dm.toutiao.com
export HY2_PORT=443 HY2_PASSWORD=pw-test
gen_self_cert test.local "$TLS_DIR" 203.0.113.9 >/dev/null 2>&1

ENABLE_XHTTP=1 ENABLE_REALITY=1 ENABLE_HY2=1 build_config "$STACK_DIR/all.json"
assert_eq "三协议入站数" "3" "$(jq '.inbounds|length' "$STACK_DIR/all.json")"
assert_eq "xhttp 仅本机监听" "127.0.0.1" "$(jq -r '.inbounds[]|select(.tag=="vless-xhttp-in")|.listen' "$STACK_DIR/all.json")"
assert_eq "xhttp 无 tls" "none" "$(jq -r '.inbounds[]|select(.tag=="vless-xhttp-in")|.streamSettings.security' "$STACK_DIR/all.json")"
assert_eq "xhttp 路径" "/abc123" "$(jq -r '.inbounds[]|select(.tag=="vless-xhttp-in")|.streamSettings.xhttpSettings.path' "$STACK_DIR/all.json")"
assert_eq "reality 使用 vision" "xtls-rprx-vision" "$(jq -r '.inbounds[]|select(.tag=="vless-reality-in")|.settings.clients[0].flow' "$STACK_DIR/all.json")"
assert_eq "reality dest" "dm.toutiao.com:443" "$(jq -r '.inbounds[]|select(.tag=="vless-reality-in")|.streamSettings.realitySettings.dest' "$STACK_DIR/all.json")"
assert_eq "reality shortId" "1a2b3c4d" "$(jq -r '.inbounds[]|select(.tag=="vless-reality-in")|.streamSettings.realitySettings.shortIds[0]' "$STACK_DIR/all.json")"
assert_eq "hy2 alpn" "h3" "$(jq -r '.inbounds[]|select(.tag=="hy2-in")|.streamSettings.tlsSettings.alpn[0]' "$STACK_DIR/all.json")"
assert_eq "hy2 版本 2" "2" "$(jq -r '.inbounds[]|select(.tag=="hy2-in")|.settings.version' "$STACK_DIR/all.json")"
assert_eq "出站有 direct" "freedom" "$(jq -r '.outbounds[0].protocol' "$STACK_DIR/all.json")"
assert_ok "三协议配置过 xray 校验" test_config "$STACK_DIR/all.json"

ENABLE_XHTTP=0 ENABLE_REALITY=1 ENABLE_HY2=0 build_config "$STACK_DIR/rel.json"
assert_eq "仅 reality 入站数" "1" "$(jq '.inbounds|length' "$STACK_DIR/rel.json")"
assert_ok "仅 reality 配置过校验" test_config "$STACK_DIR/rel.json"

ENABLE_XHTTP=0 ENABLE_REALITY=0 ENABLE_HY2=1 build_config "$STACK_DIR/hy2.json"
assert_eq "仅 hy2 入站数" "1" "$(jq '.inbounds|length' "$STACK_DIR/hy2.json")"
assert_ok "仅 hy2 配置过校验" test_config "$STACK_DIR/hy2.json"

assert_fail "渲染未知协议应失败" sh -c '. ./xray-stack.sh; render_inbound vmess /dev/null'
assert_fail "一个协议都不开应失败" sh -c '. ./xray-stack.sh; ENABLE_XHTTP=0 ENABLE_REALITY=0 ENABLE_HY2=0 build_config /dev/null'
assert_fail "坏配置无法通过校验" test_config /dev/null
rm -rf "$STACK_DIR"
