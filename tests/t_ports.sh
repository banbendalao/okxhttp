#!/bin/sh
# t_ports：直连协议端口修改（只改入站端口，校验后原子落盘）
. "$(dirname "$0")/lib.sh"
echo "== t_ports =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/ports-$$"
export STACK_DIR
CONFIG="$STACK_DIR/config.json"; export CONFIG
STATE="$STACK_DIR/stack.conf"; export STATE
rm -rf "$STACK_DIR"; mkdir -p "$STACK_DIR/certs"
. ./okxhttp

export UUID=11111111-1111-4111-8111-111111111111 PUBLIC_IP=203.0.113.9 NODE_NAME=porttest
export XHTTP_PORT=2087 XHTTP_PATH=/p1 REALITY_PORT=443 REALITY_SNI=dm.toutiao.com
export HY2_PORT=443 HY2_PASSWORD=pw HY2_CERT=self
eval "$(gen_x25519)"; export REALITY_PRIV=$PRIVATE_KEY REALITY_PUB=$PUBLIC_KEY REALITY_SHORTID=1a2b3c4d
gen_self_cert t.local "$TLS_DIR" 203.0.113.9 >/dev/null 2>&1
ENABLE_XHTTP=1 ENABLE_WS=0 ENABLE_REALITY=1 ENABLE_HY2=1 ARGO_MODE=off build_config "$CONFIG"

assert_ok "端口 1 合法" _valid_port 1
assert_ok "端口 65535 合法" _valid_port 65535
assert_fail "端口 0 不合法" _valid_port 0
assert_fail "端口 65536 不合法" _valid_port 65536
assert_fail "非数字不合法" _valid_port 80a
assert_fail "空不合法" _valid_port ""

assert_eq "读到 reality 端口" "443" "$(_inbound_port "$TAG_REALITY")"
assert_eq "读到 hy2 端口" "443" "$(_inbound_port "$TAG_HY2")"

assert_ok "改 reality 端口" set_inbound_port "$TAG_REALITY" 8443
assert_eq "reality 已改" "8443" "$(_inbound_port "$TAG_REALITY")"
assert_eq "其它入站未动" "2087" "$(_inbound_port "$TAG_XHTTP")"
assert_eq "hy2 未动" "443" "$(_inbound_port "$TAG_HY2")"
assert_eq "uuid 未动" "11111111-1111-4111-8111-111111111111" "$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG")"
assert_eq "权限 600" "600" "$(stat -c %a "$CONFIG")"
assert_fail "非法端口不落盘" set_inbound_port "$TAG_REALITY" 70000

# 冲突：xhttp 的 2087/tcp 不能给 reality
_port_blocked() { return 1; }   # 让"被占用"检查不干扰冲突判定
printf '%s\n' 2087 >"$STACK_DIR/in1"
_rc=0
_change_port "$TAG_REALITY" tcp REALITY 8443 <"$STACK_DIR/in1" || _rc=$?
assert_eq "冲突时返回非 0" "1" "$_rc"
assert_eq "拒绝后端口没变" "8443" "$(_inbound_port "$TAG_REALITY")"

# 被外部进程占用
_port_blocked() { # tcp|udp port
  [ "$2" = 9000 ]
}
printf '%s\n' 9000 >"$STACK_DIR/in2"
_rc=0
_change_port "$TAG_REALITY" tcp REALITY 8443 <"$STACK_DIR/in2" || _rc=$?
assert_eq "被占用时返回非 0" "1" "$_rc"
assert_eq "占用后端口没变" "8443" "$(_inbound_port "$TAG_REALITY")"

# 正常改动
CHANGED="$STACK_DIR/changed.log"
printf '%s\n' 9443 >"$STACK_DIR/in3"
_rc=0
_change_port "$TAG_REALITY" tcp REALITY 8443 <"$STACK_DIR/in3" || _rc=$?
assert_eq "改到 9443 返回 0" "0" "$_rc"
assert_eq "端口已改" "9443" "$(_inbound_port "$TAG_REALITY")"
assert_eq "只改端口，不动 hysteria 网络类型" "hysteria" "$(jq -r --arg t "$TAG_HY2" '.inbounds[]|select(.tag==$t)|.streamSettings.network' "$CONFIG")"
assert_match "reality 网络仍是 tcp" '^tcp$' "$(jq -r --arg t "$TAG_REALITY" '.inbounds[]|select(.tag==$t)|.streamSettings.network' "$CONFIG")"

# do_ports：菜单驱动（1 = reality），回车保持
save_state
detect_init() { INIT_SYS=none; }
svc_restart() { printf '%s\n' "$1" >>"$CHANGED"; }
wait_serving() { return 0; }
sub_push() { :; }
: >"$CHANGED"
printf '1\n8555\n' | do_ports >/dev/null 2>&1
assert_eq "do_ports 改了端口" "8555" "$(_inbound_port "$TAG_REALITY")"
assert_match "同步写回 stack.conf" '^REALITY_PORT=8555$' "$(grep '^REALITY_PORT=' "$STATE")"
assert_eq "重启过 xray" "xray" "$(cat "$CHANGED")"

# 回车保持
: >"$CHANGED"
printf '1\n\n' | do_ports >/dev/null 2>&1
assert_eq "回车保持端口" "8555" "$(_inbound_port "$TAG_REALITY")"
assert_eq "没变化不重启" "" "$(cat "$CHANGED")"

# 两个都改
printf 'a\n8666\n9555\n' | do_ports >/dev/null 2>&1
assert_eq "全部改（reality）" "8666" "$(_inbound_port "$TAG_REALITY")"
assert_eq "全部改（hy2）" "9555" "$(_inbound_port "$TAG_HY2")"

# 交互安装：直接问端口（XHTTP 关闭 → 跳过 argo 提问）
ENABLE_XHTTP=0 ENABLE_REALITY=1 ENABLE_HY2=1
HY2_CERT=self WARP=no WARP_ROUTE=
REALITY_PORT= HY2_PORT=
printf '\n1\n18443\n28443\n1\n' >"$STACK_DIR/in4"
_menu_toggle <"$STACK_DIR/in4" >/dev/null 2>&1
assert_eq "交互安装问 REALITY 端口" "18443" "${REALITY_PORT:-}"
assert_eq "交互安装问 HY2 端口" "28443" "${HY2_PORT:-}"

# 非法输入保持原值
REALITY_PORT=8443
printf '\n1\nabc\n\n1\n' >"$STACK_DIR/in5"
_menu_toggle <"$STACK_DIR/in5" >/dev/null 2>&1
assert_eq "非法端口不采纳" "8443" "${REALITY_PORT:-}"

# 同号端口（tcp）装不了
_rc=0
(XHTTP=yes REALITY=yes HY2=no ARGO_MODE=off XHTTP_PORT=8443 REALITY_PORT=8443 YES=1; collect_config) >/dev/null 2>&1 || _rc=$?
assert_eq "同号 tcp 端口被拒绝" "1" "$_rc"

[ "${TESTS_FAIL:-0}" -eq 0 ] && echo "全部通过"
rm -rf "$STACK_DIR"
exit "${TESTS_FAIL:-0}"
