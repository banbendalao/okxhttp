#!/bin/sh
# t_selftest：死节点探测必须失败（证明探测真的在验证出网）
. "$(dirname "$0")/lib.sh"
echo "== t_selftest =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/st-$$"
export STACK_DIR
mkdir -p "$STACK_DIR"
. ./okxhttp

cat >"$STACK_DIR/dead.json" <<'EOF'
{"log":{"loglevel":"warning"},
 "inbounds":[{"listen":"127.0.0.1","port":18080,"protocol":"socks","settings":{"udp":true}}],
 "outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":1,"users":[{"id":"11111111-1111-4111-8111-111111111111","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"none"}}]}
EOF
assert_ok "probe_node/_wait_port 已定义" sh -c '. ./okxhttp; command -v probe_node >/dev/null && command -v _wait_port >/dev/null'
assert_ok "死节点配置本身合法" test_config "$STACK_DIR/dead.json"
assert_fail "死节点探测失败" probe_node "$STACK_DIR/dead.json" 18080
assert_ok "空闲端口等待超时" sh -c '. ./okxhttp; ! _wait_port tcp 18181 2'
# 自检节点列表按客户端文件驱动（不依赖状态里的开关）
mkdir -p "$STACK_DIR/clients"
: >"$STACK_DIR/clients/client-ws.json"
: >"$STACK_DIR/clients/client-reality.json"
assert_eq "节点列表按文件生成" "ws-h2 reality" "$(selftest_nodes | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')"
rm -f "$STACK_DIR/clients/client-ws.json"
: >"$STACK_DIR/clients/client-xhttp-h2.json"
: >"$STACK_DIR/clients/client-xhttp-h3.json"
assert_eq "固定隧道节点列表" "xhttp-h2 xhttp-h3 reality" "$(selftest_nodes | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')"
rm -rf "$STACK_DIR"
