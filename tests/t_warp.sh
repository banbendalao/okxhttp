#!/bin/sh
# t_warp：WARP 出站渲染、路由规则、与配置合成的集成
. "$(dirname "$0")/lib.sh"
echo "== t_warp =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/warp-$$"
export STACK_DIR
CONFIG="$STACK_DIR/config.json"; export CONFIG
WARP_FILE="$STACK_DIR/warp.json"; export WARP_FILE
rm -rf "$STACK_DIR"; mkdir -p "$STACK_DIR/certs"
. ./okxhttp

# 路由规则
assert_eq "BT 规则" '[{"type":"field","protocol":["bittorrent"],"outboundTag":"warp"}]' "$(WARP_ROUTE=bittorrent warp_rules)"
assert_eq "all 规则" '[{"type":"field","network":"tcp,udp","outboundTag":"warp"}]' "$(WARP_ROUTE=all warp_rules)"

# 凭据 fixture（假密钥，仅验证渲染结构）
eval "$(gen_x25519)"
jq -n --arg k "$PRIVATE_KEY" '{privateKey:$k,
 peerPublicKey:"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
 endpoint:"162.159.192.1:2408",addresses:["172.16.0.2/32","2606:4700:110::1/128"],
 reserved:[1,2,3],mtu:1280}' >"$WARP_FILE"
out=$(warp_outbounds)
assert_eq "两个出站" "2" "$(printf '%s' "$out" | jq 'length')"
assert_eq "wireguard 出站 tag" "x-warp" "$(printf '%s' "$out" | jq -r '.[0].tag')"
assert_eq "使用内置栈（不依赖 TUN）" "true" "$(printf '%s' "$out" | jq -r '.[0].settings.noKernelTun')"
assert_eq "reserved 透传" "[1,2,3]" "$(printf '%s' "$out" | jq -c '.[0].settings.reserved')"
assert_eq "freedom 走 dialerProxy" "x-warp" "$(printf '%s' "$out" | jq -r '.[1].streamSettings.sockopt.dialerProxy')"
assert_eq "address 含 v4+v6" "2" "$(printf '%s' "$out" | jq '.[0].settings.address|length')"

# 集成：WARP 开启时配置里有多余出站与规则
export UUID=11111111-1111-4111-8111-111111111111 PUBLIC_IP=203.0.113.9 NODE_NAME=w XHTTP_PORT=2087 XHTTP_PATH=/x
export REALITY_PORT=443 REALITY_SNI=dm.toutiao.com HY2_PORT=443 HY2_PASSWORD=pw HY2_CERT=self
eval "$(gen_x25519)"; export REALITY_PRIV=$PRIVATE_KEY REALITY_PUB=$PUBLIC_KEY REALITY_SHORTID=1a2b3c4d
gen_self_cert t.local "$TLS_DIR" 203.0.113.9 >/dev/null 2>&1

ENABLE_XHTTP=0 ENABLE_WS=0 ENABLE_REALITY=0 ENABLE_HY2=1 WARP_ENABLED=1 WARP_ROUTE=bittorrent build_config "$CONFIG"
assert_eq "WARP 开启后出站数" "4" "$(jq '.outbounds|length' "$CONFIG")"
assert_eq "路由规则已注入" "warp" "$(jq -r '.routing.rules[0].outboundTag' "$CONFIG")"
assert_eq "默认出站仍是 direct" "direct" "$(jq -r '.outbounds[0].tag' "$CONFIG")"
assert_ok "含 WARP 的配置通过 xray 校验" test_config "$CONFIG"

ENABLE_HY2=1 WARP_ENABLED=0 build_config "$CONFIG"
assert_eq "WARP 关闭后出站数" "2" "$(jq '.outbounds|length' "$CONFIG")"
assert_eq "WARP 关闭后无规则" "0" "$(jq '.routing.rules|length' "$CONFIG")"

# 凭据复用：ensure_warp 不重新注册、并收紧权限
chmod 644 "$WARP_FILE"
WARP=yes ensure_warp >/dev/null 2>&1
assert_eq "复用后权限 600" "600" "$(stat -c %a "$WARP_FILE")"
assert_ok "WARP=no 时不做任何事" sh -c '. ./okxhttp; WARP=no ensure_warp'
[ "${TESTS_FAIL:-0}" -eq 0 ] && echo "全部通过"
rm -rf "$STACK_DIR"
exit "${TESTS_FAIL:-0}"
