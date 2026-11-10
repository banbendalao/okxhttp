#!/bin/sh
# t_keys：UUID、REALITY 密钥、证书、证书钉、dest 校验、续期脚本
. "$(dirname "$0")/lib.sh"
echo "== t_keys =="
STACK_LIB_ONLY=1 . ./okxhttp

assert_match "uuid v4 形状" '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' "$(gen_uuid)"

eval "$(gen_x25519)"
assert_match "reality 私钥 43 位" '^[A-Za-z0-9_-]{43}$' "$PRIVATE_KEY"
assert_match "reality 公钥 43 位" '^[A-Za-z0-9_-]{43}$' "$PUBLIC_KEY"
assert_eq "公钥可由私钥复算" "$PUBLIC_KEY" "$(xray x25519 -i "$PRIVATE_KEY" | awk -F': *' '/Public/{print $2}')"

assert_match "shortid 8 位 hex" '^[0-9a-f]{8}$' "$(gen_shortid)"
assert_match "密码 24 位" '^[A-Za-z0-9]{24}$' "$(gen_password)"

d=.tmp/cert-test
rm -rf "$d"
mkdir -p "$d"
gen_self_cert test.local "$d" 203.0.113.9
assert_ok "证书文件存在" test -s "$d/cert.pem"
assert_ok "私钥文件存在" test -s "$d/key.pem"
assert_match "证书含 IP SAN" 'IP Address:203\.0\.113\.9' "$(openssl x509 -in "$d/cert.pem" -noout -text)"
assert_match "证书含 DNS SAN" 'DNS:test\.local' "$(openssl x509 -in "$d/cert.pem" -noout -text)"
assert_match "pin 为 64 位 hex" "^[0-9a-f]{64}$" "$(cert_pin_sha256 "$d/cert.pem")"

# hy2 自签证书用伪装域名（与 REALITY 同一个），不带 IP SAN
export STACK_DIR="$PWD/.tmp/keys-$$" TLS_DIR="$PWD/.tmp/keys-$$/certs" PUBLIC_IP=203.0.113.9
rm -rf "$STACK_DIR"; mkdir -p "$TLS_DIR"
assert_eq "hy2 自签域名跟随 REALITY_SNI" "pic.bstarstatic.com" "$(hy2_domain)"
ENABLE_HY2=1 HY2_CERT=self _ensure_cert >/dev/null 2>&1
assert_match "自签 SAN 是伪装域名" 'DN''S:pic\.bstarstatic\.com' "$(openssl x509 -in "$TLS_DIR/cert.pem" -noout -text)"
assert_fail "自签不再塞 IP SAN" sh -c "openssl x509 -in '$TLS_DIR/cert.pem' -noout -text | grep -q 'IP Address:203.0.113.9'"
assert_match "自签 CN 是伪装域名" 'CN *= *pic\.bstarstatic\.com' "$(openssl x509 -in "$TLS_DIR/cert.pem" -noout -subject)"
REALITY_SNI=example.org
assert_eq "REALITY_SNI 变了 hy2 跟着变" "example.org" "$(hy2_domain)"
rm -rf "$STACK_DIR"
unset REALITY_SNI

assert_ok "dm.toutiao.com 可作 dest" check_reality_dest dm.toutiao.com
assert_fail "不可达站点不通过" check_reality_dest 127.0.0.1

assert_match "续期脚本含 lego shortlived" 'lego.*run --accept-tos.*--profile shortlived' "$(renew_script_body 203.0.113.9 | tr '\n' ' ')"
assert_match "续期脚本用 --renew-days" '--renew-days 4' "$(renew_script_body 203.0.113.9 | tr '\n' ' ')"
assert_match "续期脚本禁用随机 sleep" '--no-random-sleep' "$(renew_script_body 203.0.113.9 | tr '\n' ' ')"
assert_match "续期脚本有超时保护" 'timeout 180' "$(renew_script_body 203.0.113.9 | tr '\n' ' ')"
assert_match "续期失败保留旧证书" '旧证书继续生效' "$(renew_script_body 203.0.113.9)"
assert_match "证书未变不重启" '证书未变化，不重启服务' "$(renew_script_body 203.0.113.9)"
assert_match "续期脚本含服务重启" 'restart|sv restart' "$(renew_script_body 203.0.113.9 | tr '\n' ' ')"
