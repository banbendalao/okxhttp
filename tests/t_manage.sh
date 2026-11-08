#!/bin/sh
# t_manage：管理面子命令（status/log/cert-info/renew）与参数解析
. "$(dirname "$0")/lib.sh"
echo "== t_manage =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/mg-$$"
export STACK_DIR
STATE="$STACK_DIR/stack.conf"
export STATE
ARGO_LOG="$STACK_DIR/argo.log"
export ARGO_LOG
rm -rf "$STACK_DIR"
mkdir -p "$STACK_DIR/certs"
. ./okxhttp

# 参数解析
parse_args --status; assert_eq "--status" "status" "$MODE"
parse_args --restart; assert_eq "--restart" "restart" "$MODE"
parse_args --renew; assert_eq "--renew" "renew" "$MODE"
parse_args --cert-info; assert_eq "--cert-info" "certinfo" "$MODE"
parse_args --log; assert_eq "--log" "log" "$MODE"
parse_args --log=argo; assert_eq "--log=argo 目标" "argo" "$LOG_TARGET"

# 未部署时的状态
assert_ok "未部署 status 仍成功" do_status
assert_match "未部署提示" '尚未部署' "$(do_status 2>&1)"

# 伪造部署状态
cat >"$STATE" <<EOF
ENABLE_XHTTP=1
ENABLE_REALITY=1
ENABLE_HY2=1
ENABLE_WS=0
ARGO_MODE=token
ARGO_DOMAIN=op.example.cc.cd
ARGO_PROTO_USED=quic
XHTTP_PORT=18080
WS_PORT=18081
REALITY_PORT=443
HY2_PORT=443
HY2_CERT=le
HY2_CERT_EFFECTIVE=self
NODE_NAME=mgtest
PUBLIC_IP=203.0.113.9
UUID=11111111-1111-4111-8111-111111111111
EOF
gen_self_cert cert.local "$TLS_DIR" 203.0.113.9 >/dev/null 2>&1
out=$(do_status 2>&1)
assert_match "状态含协议" '协议 *: xhttp reality hy2' "$out"
assert_match "状态含 argo 域名" 'op\.example\.cc\.cd' "$out"
assert_match "状态含连接器" 'quic' "$out"
assert_match "状态含端口" 'reality=443/tcp' "$out"
assert_match "状态含证书签发者" 'CN=cert.local' "$out"
assert_match "固定隧道显示 xhttp" 'xhttp（h2/h3）' "$out"

# 证书信息
certout=$(do_certinfo 2>&1)
assert_match "证书信息含 notAfter" 'notAfter=' "$certout"
assert_match "证书信息含指纹" 'SHA256 *: [0-9a-f]{64}' "$certout"
assert_match "自签时提示 pin" 'pinSHA256' "$certout"

# LE 证书时客户端校验方式应显示 false
sed -i 's/^HY2_CERT_EFFECTIVE=self$/HY2_CERT_EFFECTIVE=le/' "$STATE"
assert_match "LE 时显示 insecure false" 'insecure: false' "$(do_certinfo 2>&1)"

# 证书类型识别（用于重装时复用 LE 证书）
assert_fail "_is_le_cert 对自签返回假" _is_le_cert "$TLS_DIR/cert.pem"
assert_ok "_cert_covers_ip 命中当前 IP" _cert_covers_ip "$TLS_DIR/cert.pem" 203.0.113.9
assert_fail "_cert_covers_ip 对别的 IP 返回假" _cert_covers_ip "$TLS_DIR/cert.pem" 198.51.100.7

# 日志
printf 'argo line1\nargo line2\n' >"$ARGO_LOG"
printf 'xray line1\n' >"$STACK_DIR/xray.log"
assert_match "argo 日志" 'argo line2' "$(do_log argo)"
assert_match "xray 日志" 'xray line1' "$(do_log xray)"
assert_match "两个日志都看" 'argo line1' "$(do_log all)"
assert_fail "非法日志目标" sh -c '. ./okxhttp; do_log nope'

# 续期：非 LE 时明确拒绝
assert_fail "非 LE 时 renew 返回失败" do_renew
assert_match "非 LE 提示" '不是 LE 证书' "$(do_renew 2>&1)"
printf '#!/bin/sh\necho renewed\n' >"$STACK_DIR/renew.sh"
chmod +x "$STACK_DIR/renew.sh"
assert_ok "有 renew.sh 时执行成功" do_renew
rm -rf "$STACK_DIR"

# 命令自安装：首次复制、内容相同不重写、内容变化则覆盖、路径登记到 .installed_bins
BIN_DIR="$STACK_DIR/bin"
INSTALL_SELF_SRC="$STACK_DIR/okxhttp-src"
export BIN_DIR INSTALL_SELF_SRC
mkdir -p "$BIN_DIR"
printf 'v1\n' >"$INSTALL_SELF_SRC"
assert_match "首次安装有提示" '已安装命令' "$(install_self 2>&1)"
assert_ok "命令已安装" test -x "$BIN_DIR/okxhttp"
assert_match "命令内容正确" '^v1$' "$(cat "$BIN_DIR/okxhttp")"
assert_match "登记到 installed_bins" "$BIN_DIR/okxhttp" "$(cat "$STACK_DIR/.installed_bins")"
assert_match "内容相同不重写" '命令已是最新' "$(install_self 2>&1)"
printf 'v2\n' >"$INSTALL_SELF_SRC"
install_self >/dev/null 2>&1
assert_match "内容变化会覆盖" '^v2$' "$(cat "$BIN_DIR/okxhttp")"
rm -rf "$STACK_DIR"

# hydrate：config.json 是事实源，能覆盖状态文件里的陈旧值
mkdir -p "$STACK_DIR"
cat >"$CONFIG" <<'J'
{"inbounds":[
 {"tag":"vless-xhttp-in","listen":"127.0.0.1","port":9999,"protocol":"vless",
  "settings":{"clients":[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}]},
  "streamSettings":{"network":"xhttp","xhttpSettings":{"path":"/real-path"}}}
]}
J
printf 'ENABLE_XHTTP=1\nXHTTP_PORT=1111\nXHTTP_PATH=/stale-path\n' >"$STATE"
assert_eq "config 覆盖陈旧的 state" "9999 /real-path" "$(unset XHTTP_PORT XHTTP_PATH; load_state; printf '%s %s' "$XHTTP_PORT" "$XHTTP_PATH")"
assert_eq "环境变量优先于 config" "7777" "$(XHTTP_PORT=7777 sh -c '. ./okxhttp; load_state; printf %s "$XHTTP_PORT"')"
assert_eq "UUID 从 config 补齐" "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" "$(unset UUID; load_state; printf '%s' "$UUID")"
