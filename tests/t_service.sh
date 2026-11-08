#!/bin/sh
# t_service：端口占用检测、服务文件生成、预检
. "$(dirname "$0")/lib.sh"
echo "== t_service =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/svc-$$"
export STACK_DIR
FAKE_INIT_DIR="$STACK_DIR/fake-init"
export FAKE_INIT_DIR INIT_SYS=fake
rm -rf "$STACK_DIR"
mkdir -p "$FAKE_INIT_DIR"
. ./okxhttp

assert_ok "22 端口被识别为已监听" port_in_use tcp 22
assert_fail "54321 未监听" port_in_use tcp 54321
assert_fail "高位 udp 端口未监听" port_in_use udp 54321

# UDP 监听检测：/proc/net/udp 里状态是 07，不是 0A
if command_exists nc; then
  nc -ul -p 18999 >/dev/null 2>&1 &
  _ncpid=$!
  sleep 1
  assert_ok "udp 监听被识别" port_in_use udp 18999
  kill "$_ncpid" 2>/dev/null
fi

svc_install demo "/usr/local/bin/xray run -c /x.json"
assert_ok "生成服务文件" test -s "$FAKE_INIT_DIR/demo.service"
assert_match "服务文件含 ExecStart" 'ExecStart=/usr/local/bin/xray run -c /x.json' "$(cat "$FAKE_INIT_DIR/demo.service")"

svc_install demo "/usr/local/bin/xray run -c /y.json"
assert_eq "重复安装不重复条目" "1" "$(grep -c '^ExecStart=' "$FAKE_INIT_DIR/demo.service")"
assert_match "重复安装更新命令" 'ExecStart=/usr/local/bin/xray run -c /y.json' "$(cat "$FAKE_INIT_DIR/demo.service")"

svc_remove demo
assert_fail "服务文件已删除" test -e "$FAKE_INIT_DIR/demo.service"
assert_ok "重复删除幂等" svc_remove demo

# Alpine：有 supervise-daemon 时必须生成守护配置（进程退出自动拉起）
_openrc_body() {
  command_exists() { [ "$1" = supervise-daemon ]; }
  INIT_SYS=openrc
  _svc_body_openrc demo "/usr/local/bin/xray run -c /x.json"
}
assert_match "openrc 用 supervise-daemon" 'supervisor="supervise-daemon"' "$(_openrc_body)"
assert_match "openrc 拉起延迟" 'respawn_delay=5' "$(_openrc_body)"
assert_match "openrc 不限重启次数" 'respawn_max=0' "$(_openrc_body)"
assert_match "openrc 命令正确" 'command="/usr/local/bin/xray"' "$(_openrc_body)"
assert_match "openrc 参数正确" 'command_args="run -c /x.json"' "$(_openrc_body)"
command_exists() { command -v "$1" >/dev/null 2>&1; }
_missing_openrc() {
  command_exists() { [ "$1" != supervise-daemon ]; }
  INIT_SYS=openrc
  # 本机若真有 /sbin/supervise-daemon 则视为已满足；测试机上通常没有
  [ -x /sbin/supervise-daemon ] && { printf ''; return 0; }
  missing_deps
}
_missing_systemd() {
  command_exists() { return 0; }
  INIT_SYS=systemd
  missing_deps
}
assert_eq "依赖阶段会列出 supervise-daemon" "supervise-daemon" "$(_missing_openrc)"
assert_eq "systemd 下不要求 supervise-daemon" "" "$(_missing_systemd)"
assert_eq "包名候选：独立包优先、老版退回 openrc" "supervise-daemon openrc" "$(_dep_pkgs supervise-daemon)"
command_exists() { command -v "$1" >/dev/null 2>&1; }

# 端口预检：给一个明显被占用的端口，期望中止
assert_fail "端口冲突时预检失败" sh -c '. ./okxhttp; ENABLE_XHTTP=0 ENABLE_REALITY=1 ENABLE_HY2=0 REALITY_PORT=22 preflight'
rm -rf "$STACK_DIR"
