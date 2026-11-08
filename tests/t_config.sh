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

# 已部署过的端口要复用（重装不能漂移）
mkdir -p "$STACK_DIR"
printf '{"inbounds":[{"tag":"vless-xhttp-in","listen":"127.0.0.1","port":39999,"protocol":"vless","settings":{"clients":[{"id":"x"}]},"streamSettings":{"network":"xhttp","xhttpSettings":{"path":"/x"}}},{"tag":"vless-ws-in","listen":"127.0.0.1","port":40000,"protocol":"vless","settings":{"clients":[{"id":"x"}]},"streamSettings":{"network":"ws","wsSettings":{"path":"/w"}}}]}\n' >"$CONFIG"
out=$(XHTTP=yes REALITY=no HY2=no ARGO_MODE=temp _pick "" "")
assert_eq "重装复用已部署的端口" "39999 40000" "$out"
rm -f "$CONFIG"

# 显式指定则尊重
out=$(XHTTP=yes REALITY=no HY2=no ARGO_MODE=temp _pick 2087 2088)
assert_eq "显式端口被尊重" "2087 2088" "$out"

# 固定隧道不随机
out=$(XHTTP=yes REALITY=no HY2=no ARGO_MODE=token ARGO_AUTH=t ARGO_DOMAIN=d.example _pick "" "")
assert_eq "token 模式不随机" "2087 2088" "$out"

# 交互菜单：WARP 选项（a 全选 / 回车确认 / 回车默认 argo / 回车默认证书 / WARP 选择）
menu_warp() { printf "a\n\n\n\n$1\n" | sh -c 'unset WARP WARP_ROUTE; . ./okxhttp; _menu_toggle >/dev/null 2>&1; printf "%s %s" "$WARP" "${WARP_ROUTE:-none}"'; }
assert_eq "菜单 1=不启用 WARP" "no none" "$(menu_warp 1)"
assert_eq "菜单 2=仅 BT 走 WARP" "yes bittorrent" "$(menu_warp 2)"
assert_eq "菜单 3=全部走 WARP" "yes all" "$(menu_warp 3)"

# 固定隧道的 token/域名要能记住并在重装时复用
ARGO_MODE=token ARGO_AUTH='tok-abc' ARGO_DOMAIN='t.example.com'
YES=1 XHTTP=yes REALITY=no HY2=no collect_config </dev/null
save_state
assert_match "token 写入状态" '^ARGO_AUTH=tok-abc$' "$(grep '^ARGO_AUTH=' "$STATE")"
assert_match "域名写入状态" '^ARGO_DOMAIN=t.example.com$' "$(grep '^ARGO_DOMAIN=' "$STATE")"
assert_eq "状态文件仍为 600" "600" "$(stat -c %a "$STATE")"
# 模拟重装：只从状态恢复（不带任何 env），不应报缺 token
out=$(unset ARGO_AUTH ARGO_DOMAIN ARGO_MODE; sh -c '. ./okxhttp; load_state; YES=1 collect_config </dev/null 2>&1; printf "%s|%s|%s" "$ARGO_MODE" "$ARGO_DOMAIN" "$ARGO_AUTH"')
assert_eq "重装复用 token/域名" "token|t.example.com|tok-abc" "$out"

assert_ok "状态文件已写" test -s "$STATE"
assert_eq "状态文件权限 600" "600" "$(stat -c %a "$STATE")"
assert_match "状态文件含 UUID" '^UUID=' "$(grep '^UUID=' "$STATE")"
# 协议选择记忆：没给 env 时沿用状态里的选择；给了 env 则覆盖
printf 'ENABLE_XHTTP=1\nENABLE_REALITY=0\nENABLE_HY2=0\n' >"$STATE"
out=$(sh -c 'unset XHTTP REALITY HY2 ENABLE_XHTTP ENABLE_REALITY ENABLE_HY2 ARGO_MODE ARGO_AUTH ARGO_DOMAIN WARP WARP_ROUTE; . ./okxhttp; load_state; YES=1 collect_config >/dev/null </dev/null; printf "%s%s%s" "$ENABLE_XHTTP" "$ENABLE_REALITY" "$ENABLE_HY2"')
assert_eq "重装沿用协议选择" "100" "$out"
assert_eq "env 覆盖记忆" "010" "$(XHTTP=no REALITY=yes HY2=no sh -c '. ./okxhttp; load_state; YES=1 collect_config >/dev/null </dev/null; printf "%s%s%s" "$ENABLE_XHTTP" "$ENABLE_REALITY" "$ENABLE_HY2"')"
if XHTTP=maybe sh -c 'unset ENABLE_XHTTP; . ./okxhttp; load_state; YES=1 collect_config </dev/null' >/dev/null 2>&1; then
  _bad=0
else
  _bad=1
fi
assert_eq "非法 env 仍报错" "1" "$_bad"

# 菜单勾选起点也来自记忆值：直接回车确认，选择应保持
out=$(printf '\n\n\n\n\n' | sh -c 'unset XHTTP REALITY HY2 ENABLE_XHTTP ENABLE_REALITY ENABLE_HY2 ARGO_MODE ARGO_AUTH ARGO_DOMAIN WARP WARP_ROUTE; . ./okxhttp; load_state; _menu_toggle >/dev/null 2>&1; printf "%s%s%s" "${ENABLE_XHTTP:-?}" "${ENABLE_REALITY:-?}" "${ENABLE_HY2:-?}"')
assert_eq "菜单起点沿用记忆" "100" "$out"

# 固定隧道：菜单里填写可覆盖，回车则复用
printf 'ARGO_AUTH=old-token\nARGO_DOMAIN=old.example.com\n' >>"$STATE"
out=$(printf 'a\n\n2\nnew.com\nauth-new\n' | sh -c '. ./okxhttp; load_state; _menu_toggle >/dev/null 2>&1; printf "%s|%s" "$ARGO_DOMAIN" "$ARGO_AUTH"' 2>/dev/null)
assert_eq "菜单可覆盖 token/域名" "new.com|auth-new" "$out"
out=$(printf 'a\n\n2\n\n\n' | sh -c '. ./okxhttp; load_state; _menu_toggle >/dev/null 2>&1; printf "%s|%s" "$ARGO_DOMAIN" "$ARGO_AUTH"' 2>/dev/null)
assert_eq "回车复用 token/域名" "old.example.com|old-token" "$out"

rm -rf "$STACK_DIR"
