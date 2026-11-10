#!/bin/sh
# t_links：分享链接必须由当前部署配置现场生成（不依赖任何预制文件）
. "$(dirname "$0")/lib.sh"
echo "== t_links =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/ln-$$"
export STACK_DIR
CONFIG="$STACK_DIR/config.json"
export CONFIG
ARGO_LOG="$STACK_DIR/argo.log"
export ARGO_LOG
rm -rf "$STACK_DIR"
mkdir -p "$STACK_DIR/certs"
. ./okxhttp

export UUID=11111111-1111-4111-8111-111111111111
export PUBLIC_IP=203.0.113.9
export NODE_NAME=testnode
export XHTTP_PORT=2087 XHTTP_PATH=/from-config
export REALITY_PORT=443 REALITY_SNI=dm.toutiao.com
export HY2_PORT=443 HY2_PASSWORD=pw-test HY2_CERT=self
eval "$(gen_x25519)"
export REALITY_PRIV=$PRIVATE_KEY REALITY_PUB=$PUBLIC_KEY REALITY_SHORTID=1a2b3c4d
gen_self_cert test.local "$TLS_DIR" 203.0.113.9 >/dev/null 2>&1

# 固定隧道：面板 hostname 写在 argo 日志里
printf 'INF Updated to new configuration config="{\\"ingress\\":[{\\"hostname\\":\\"op.example.cc.cd\\",\\"service\\":\\"http://localhost:2087\\"}]}"\n' >"$ARGO_LOG"
ENABLE_XHTTP=1 ENABLE_WS=0 ENABLE_REALITY=1 ENABLE_HY2=1 ARGO_MODE=token build_config "$CONFIG"
out=$(gen_links)
assert_eq "固定隧道 4 条链接" "4" "$(printf '%s\n' "$out" | grep -c '://')"
assert_match "域名来自 argo 日志" 'op\.example\.cc\.cd:443' "$out"
assert_match "h2 链接" 'alpn=h2.*type=xhttp' "$out"
assert_match "h3 链接" 'alpn=h3.*type=xhttp' "$out"
assert_match "路径来自 config" 'path=/from-config' "$out"
assert_match "reality 公钥由私钥推导" "pbk=$PUBLIC_KEY" "$out"
assert_match "reality sid 来自 config" 'sid=1a2b3c4d' "$out"
assert_match "hy2 自签带 pinSHA256（hex 指纹）" 'pinSHA256=[0-9a-f]{64}' "$out"
assert_match "hy2 链接 SNI 用伪装域名（与 REALITY 同一个）" '\?sni=dm\.toutiao\.com&pinSHA256=' "$out"
assert_fail "hy2 自签不跳过证书验证" sh -c "ENABLE_HY2=1 STACK_LIB_ONLY=1 . ./okxhttp; gen_links | grep -q 'insecure=1'"
assert_eq "pin 等于当前证书指纹" "$(cert_pin_sha256 "$TLS_DIR/cert.pem")" \
  "$(printf '%s\n' "$out" | sed -n 's/.*pinSHA256=\([0-9a-f]*\).*/\1/p')"
assert_fail "链接文件不应存在" test -e "$STACK_DIR/links.txt"

# 改配置后链接必须跟着变（证明不是预制）
sed -i 's|/from-config|/changed-path|' "$CONFIG"
assert_match "改 config 后链接跟着变" 'path=/changed-path' "$(gen_links)"

# 临时隧道：有 ws 入站则只出 ws 节点，域名取临时域名
ENABLE_XHTTP=1 ENABLE_WS=1 ENABLE_REALITY=0 ENABLE_HY2=0 ARGO_MODE=temp build_config "$CONFIG"
printf 'INF |  https://abc-def.trycloudflare.com  |\n' >"$ARGO_LOG"
ENABLE_WS=1 ARGO_MODE=temp
out2=$(ENABLE_XHTTP=1 ENABLE_REALITY=0 ENABLE_HY2=0 ENABLE_WS=1 ARGO_MODE=temp gen_links)
assert_eq "临时隧道 1 条链接" "1" "$(printf '%s\n' "$out2" | grep -c '://')"
assert_match "临时隧道走 ws" 'type=ws' "$out2"
assert_match "临时隧道域名来自日志" '@abc-def\.trycloudflare\.com' "$out2"

# ARGO_MODE=off：xhttp 听 0.0.0.0，链接走明文
ENABLE_XHTTP=1 ENABLE_WS=0 ENABLE_REALITY=0 ENABLE_HY2=0 ARGO_MODE=off build_config "$CONFIG"
out3=$(ENABLE_XHTTP=1 ENABLE_WS=0 ENABLE_REALITY=0 ENABLE_HY2=0 ARGO_MODE=off gen_links)
assert_match "off 模式明文" 'security=none' "$out3"
assert_match "off 模式用公网 IP" '@203\.0\.113\.9:2087' "$out3"

# 公信证书（LE）时 hy2 既不带 insecure 也不带 pin（走系统信任链）
cp "$TLS_DIR/cert.pem" /tmp/selfsigned.$$.pem
printf -- '-----BEGIN CERTIFICATE-----\n' >/dev/null
_cert_is_public() { return 0; }
ENABLE_XHTTP=0 ENABLE_WS=0 ENABLE_REALITY=0 ENABLE_HY2=1 ARGO_MODE=off build_config "$CONFIG"
assert_fail "公信证书不带 insecure" sh -c "ENABLE_HY2=1 STACK_LIB_ONLY=1 . ./okxhttp; _cert_is_public() { return 0; }; gen_links | grep -q 'insecure=1'"
assert_fail "公信证书不带 pin" sh -c "ENABLE_HY2=1 STACK_LIB_ONLY=1 . ./okxhttp; _cert_is_public() { return 0; }; gen_links | grep -q 'pinSHA256'"

[ "${TESTS_FAIL:-0}" -eq 0 ] && echo "全部通过"
exit "$TESTS_FAIL"
