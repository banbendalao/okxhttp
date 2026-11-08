#!/bin/sh
# t_links：节点链接生成（不再产出客户端配置文件）
. "$(dirname "$0")/lib.sh"
echo "== t_links =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/ln-$$"
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

assert_match "h2 链接" '^vless://11111111.*@abc-def\.trycloudflare\.com:443\?.*alpn=h2.*type=xhttp.*path=/p1.*mode=auto' "$(uri_xhttp abc-def.trycloudflare.com h2)"
assert_match "h3 链接" 'alpn=h3' "$(uri_xhttp abc-def.trycloudflare.com h3)"
assert_match "xhttp 链接带 host 参数" 'host=abc-def\.trycloudflare\.com' "$(uri_xhttp abc-def.trycloudflare.com h2)"
assert_match "reality 链接" "flow=xtls-rprx-vision.*pbk=$PUBLIC_KEY.*sid=1a2b3c4d.*type=tcp" "$(uri_reality)"
assert_match "reality 链接指向公网 IP" '@203\.0\.113\.9:443' "$(uri_reality)"
assert_match "hy2 链接" '^hysteria2://pw-test@203\.0\.113\.9:443/\?sni=203\.0\.113\.9&insecure=1' "$(uri_hy2)"
assert_match "节点名带后缀" '#testnode-hy2$' "$(uri_hy2)"

# 固定隧道：h2 + h3；临时隧道：ws；off：明文
ENABLE_XHTTP=1 ENABLE_REALITY=1 ENABLE_HY2=1 ENABLE_WS=0 ARGO_MODE=token write_links
assert_eq "固定隧道链接数" "4" "$(wc -l <"$LINK_FILE" | tr -d ' ')"
assert_match "固定隧道含 h3" 'alpn=h3' "$(cat "$LINK_FILE")"
assert_ok "链接文件权限 600" test "$(stat -c %a "$LINK_FILE")" = 600
assert_ok "不再生成客户端配置文件" sh -c "[ ! -d '$STACK_DIR/clients' ]"

ENABLE_XHTTP=1 ENABLE_REALITY=1 ENABLE_HY2=1 ENABLE_WS=1 ARGO_MODE=temp write_links
assert_eq "临时隧道链接数" "3" "$(wc -l <"$LINK_FILE" | tr -d ' ')"
assert_match "临时隧道走 ws" 'type=ws' "$(cat "$LINK_FILE")"

ENABLE_XHTTP=1 ENABLE_REALITY=1 ENABLE_HY2=1 ENABLE_WS=0 ARGO_MODE=off write_links
assert_match "off 模式为明文 xhttp" 'security=none' "$(cat "$LINK_FILE")"

[ "${TESTS_FAIL:-0}" -eq 0 ] && echo "全部通过"
exit "$TESTS_FAIL"
rm -rf "$STACK_DIR"
