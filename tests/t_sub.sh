#!/bin/sh
# t_sub：订阅推送/同步/重置 key 的逻辑（网络层用桩替换）
. "$(dirname "$0")/lib.sh"
echo "== t_sub =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/sub-$$"
export STACK_DIR
CONFIG="$STACK_DIR/config.json"; export CONFIG
STATE="$STACK_DIR/stack.conf"; export STATE
SUB_URL="https://note.example"
export SUB_URL SUB
rm -rf "$STACK_DIR"; mkdir -p "$STACK_DIR/certs"
. ./okxhttp

# 造一份可用的 config + 证书
export UUID=11111111-1111-4111-8111-111111111111 PUBLIC_IP=203.0.113.9 NODE_NAME=subtest
export XHTTP_PORT=2087 XHTTP_PATH=/p1 REALITY_PORT=443 REALITY_SNI=dm.toutiao.com
export HY2_PORT=443 HY2_PASSWORD=pw HY2_CERT=self
eval "$(gen_x25519)"; export REALITY_PRIV=$PRIVATE_KEY REALITY_PUB=$PUBLIC_KEY REALITY_SHORTID=1a2b3c4d
gen_self_cert t.local "$TLS_DIR" 203.0.113.9 >/dev/null 2>&1
ENABLE_XHTTP=1 ENABLE_WS=0 ENABLE_REALITY=1 ENABLE_HY2=1 ARGO_MODE=off build_config "$CONFIG"

# 公网 IP 探测用桩：默认与状态一致（不触发"IP 变更"）
_probe_all() { PROBE_IP_V4=${FAKE_V4:-203.0.113.9}; PROBE_IP_V6=${FAKE_V6:-}; }

# 抓取推送内容
POSTS="$STACK_DIR/posts.log"
_sub_post() { printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | head -c 40 | tr '\n' ' ')" >>"$POSTS"; }

SUB_KEY=11111111-2222-3333-4444-555555555555
assert_ok "推送成功" sub_push
assert_match "推送内容含链接" 'vless://' "$(cat "$POSTS")"
assert_match "推送 key 正确" '^11111111-2222-3333-4444-555555555555' "$(cat "$POSTS")"
assert_match "记录内容指纹" '^[0-9a-f]{64}$' "${SUB_LAST:-}"

# 内容没变不重复推送
: >"$POSTS"
SUB=yes sub_sync
assert_eq "无变化不推送" "0" "$(wc -l <"$POSTS" | tr -d ' ')"

# 公网 IP 变化也算节点变化
: >"$POSTS"
FAKE_V4=198.51.100.7 SUB=yes sub_sync
assert_eq "IP 变更触发推送" "1" "$(wc -l <"$POSTS" | tr -d ' ')"
assert_match "新 IP 写回状态" '^PUBLIC_IP=198\.51\.100\.7$' "$(grep '^PUBLIC_IP=' "$STATE")"
FAKE_V4=203.0.113.9

# 节点变化（换现实 SNI 即改内容）→ 自动推送
: >"$POSTS"
REALITY_SNI=dm.toutiao.com XHTTP_PATH=/changed build_config "$CONFIG"
SUB=yes sub_sync
assert_eq "内容变化触发推送" "1" "$(wc -l <"$POSTS" | tr -d ' ')"

# 重置：先清空旧 key，再换新 key 推送
: >"$POSTS"
_old=$SUB_KEY
sub_reset >/dev/null 2>&1
assert_match "旧 key 被清空" "^$_old	" "$(cat "$POSTS")"
assert_eq "新 key 已推送" "$(grep '^SUB_KEY=' "$STATE" | cut -d= -f2)" "$(sed -n '2p' "$POSTS" | cut -f1)"
assert_fail "新 key 与旧 key 不同" test "$(sed -n '2p' "$POSTS" | cut -f1)" = "$_old"
assert_match "新 key 记录到状态" "^SUB_KEY=$(sed -n '2p' "$POSTS" | cut -f1)$" "$(grep '^SUB_KEY=' "$STATE")"

# SUB=no 时不同步
: >"$POSTS"
SUB=no sub_sync
assert_eq "SUB=no 不推送" "0" "$(wc -l <"$POSTS" | tr -d ' ')"


# 清空 key 内容（重置与卸载共用）
SUB_KEY=clear-me-9999
: >"$POSTS"
assert_ok "清空成功" sub_clear
assert_match "清空时向旧 key 写空值" '^clear-me-9999	$' "$(cat "$POSTS")"
SUB_KEY=
assert_ok "没有 key 时清空是空操作" sub_clear

[ "${TESTS_FAIL:-0}" -eq 0 ] && echo "全部通过"
rm -rf "$STACK_DIR"
exit "${TESTS_FAIL:-0}"
