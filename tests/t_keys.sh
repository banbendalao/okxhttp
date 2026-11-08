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

assert_ok "dm.toutiao.com 可作 dest" check_reality_dest dm.toutiao.com
assert_fail "不可达站点不通过" check_reality_dest 127.0.0.1

assert_match "续期脚本含 lego shortlived" 'lego.*run --accept-tos.*--profile shortlived' "$(renew_script_body 203.0.113.9 | tr '\n' ' ')"
assert_match "续期脚本用 --renew-days" '--renew-days 4' "$(renew_script_body 203.0.113.9 | tr '\n' ' ')"
assert_match "续期脚本禁用随机 sleep" '--no-random-sleep' "$(renew_script_body 203.0.113.9 | tr '\n' ' ')"
assert_match "续期脚本有超时保护" 'timeout 180' "$(renew_script_body 203.0.113.9 | tr '\n' ' ')"
assert_match "续期失败保留旧证书" '旧证书继续生效' "$(renew_script_body 203.0.113.9)"
assert_match "证书未变不重启" '证书未变化，不重启服务' "$(renew_script_body 203.0.113.9)"
assert_match "续期脚本含服务重启" 'restart|sv restart' "$(renew_script_body 203.0.113.9 | tr '\n' ' ')"
