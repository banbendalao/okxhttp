#!/bin/sh
# t_config：状态文件读取、YES 模式配置归一化、参数解析
. "$(dirname "$0")/lib.sh"
echo "== t_config =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/cfg-$$"
export STACK_DIR
STATE="$STACK_DIR/stack.conf"
export STATE
rm -rf "$STACK_DIR"
mkdir -p "$STACK_DIR"
. ./okxhttp

printf 'ENABLE_XHTTP=1\nENABLE_REALITY=0\n;rm -rf /\nXHTTP_PORT=2087\nUUID=11111111-1111-4111-8111-111111111111\n' >"$STATE"
load_state
assert_eq "读取 ENABLE_XHTTP" "1" "$ENABLE_XHTTP"
assert_eq "读取 ENABLE_REALITY" "0" "$ENABLE_REALITY"
assert_eq "读取端口" "2087" "$XHTTP_PORT"
assert_ok "非法行未被执行" test -d "$STACK_DIR"

# 环境变量优先于状态文件
assert_eq "环境变量不被状态文件覆盖" "9999" "$(STACK_DIR="$STACK_DIR" STATE="$STATE" XHTTP_PORT=9999 sh -c '. ./okxhttp; load_state; printf %s "$XHTTP_PORT"')"

YES=1 XHTTP=yes REALITY=no HY2=yes ARGO_MODE=temp collect_config </dev/null
assert_eq "YES 模式 XHTTP" "1" "$ENABLE_XHTTP"
assert_eq "YES 模式 REALITY" "0" "$ENABLE_REALITY"
assert_eq "YES 模式 HY2" "1" "$ENABLE_HY2"
assert_eq "默认 argo 协议" "auto" "$ARGO_PROTO"
assert_eq "默认 hy2 证书" "self" "$HY2_CERT"
assert_eq "默认临时隧道传输" "ws" "$TEMP_TRANSPORT"
assert_eq "默认 reality sni" "dm.toutiao.com" "$REALITY_SNI"

assert_fail "token 模式缺 ARGO_AUTH 应失败" sh -c '. ./okxhttp; YES=1 XHTTP=yes HY2=no REALITY=no ARGO_MODE=token collect_config </dev/null'
assert_fail "非法 ARGO_MODE 应失败" sh -c '. ./okxhttp; YES=1 XHTTP=yes ARGO_MODE=lol collect_config </dev/null'
assert_fail "环境变量写错协议应失败" sh -c '. ./okxhttp; YES=1 XHTTP=maybe HY2=no REALITY=no collect_config </dev/null'

assert_ok "--help 退出 0" sh -c '. ./okxhttp; parse_args --help'
assert_fail "未知参数应失败" sh -c '. ./okxhttp; parse_args --nope'
parse_args --yes --info
assert_eq "解析 --info" "info" "$MODE"
assert_eq "解析 --yes" "1" "$YES"

save_state
# 临时隧道：未显式指定端口 -> 随机高位（子 shell 避免带上前面的状态）
_pick() { # $1=xhttp端口 $2=ws端口（传空=未指定）
  XHTTP_PORT=$1 WS_PORT=$2 sh -c '. ./okxhttp; YES=1 collect_config >/dev/null 2>&1; printf "%s %s" "$XHTTP_PORT" "$WS_PORT"' </dev/null
}
out=$(XHTTP=yes REALITY=yes HY2=yes ARGO_MODE=temp _pick "" "")
set -- $out
assert_match "临时模式 xhttp 端口为高位随机" '^[1-9][0-9]{4}$' "$1"
assert_match "临时模式 ws 端口为高位随机" '^[1-9][0-9]{4}$' "$2"
assert_ok "两个端口不重复" test "$1" != "$2"

# 显式指定则尊重
out=$(XHTTP=yes REALITY=no HY2=no ARGO_MODE=temp _pick 2087 2088)
assert_eq "显式端口被尊重" "2087 2088" "$out"

# 固定隧道不随机
out=$(XHTTP=yes REALITY=no HY2=no ARGO_MODE=token ARGO_AUTH=t ARGO_DOMAIN=d.example _pick "" "")
assert_eq "token 模式不随机" "2087 2088" "$out"

assert_ok "状态文件已写" test -s "$STATE"
assert_eq "状态文件权限 600" "600" "$(stat -c %a "$STATE")"
assert_match "状态文件含 UUID" '^UUID=' "$(grep '^UUID=' "$STATE")"
rm -rf "$STACK_DIR"
