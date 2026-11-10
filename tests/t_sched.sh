#!/bin/sh
# t_sched：调度服务（不依赖系统 cron）—— 单元生成、订阅轮询、证书日检、TERM 退出
. "$(dirname "$0")/lib.sh"
echo "== t_sched =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/sched-$$"
export STACK_DIR
CONFIG="$STACK_DIR/config.json"; export CONFIG
STATE="$STACK_DIR/stack.conf"; export STATE
BIN_DIR="$STACK_DIR/bin"; export BIN_DIR
rm -rf "$STACK_DIR"; mkdir -p "$STACK_DIR/bin" "$STACK_DIR/init"
printf '#!/bin/sh\n' >"$BIN_DIR/okxhttp"; chmod 755 "$BIN_DIR/okxhttp"
. ./okxhttp

# 1) 服务单元：只有订阅或 LE 证书时才装
FAKE_INIT_DIR="$STACK_DIR/init" INIT_SYS=fake
export FAKE_INIT_DIR
SUB=yes HY2_CERT=self install_sched_service
assert_ok "SUB=yes 生成调度单元" test -f "$FAKE_INIT_DIR/okxhttp.service"
assert_match "单元跑 --daemon" 'ExecStart=.*okxhttp --daemon' "$(cat "$FAKE_INIT_DIR/okxhttp.service")"
assert_match "单元常驻重启" '^Restart=always' "$(cat "$FAKE_INIT_DIR/okxhttp.service")"
rm -f "$FAKE_INIT_DIR/okxhttp.service"
SUB=no HY2_CERT=self install_sched_service
assert_fail "SUB=no 且自签不装调度服务" test -f "$FAKE_INIT_DIR/okxhttp.service"
SUB=no HY2_CERT=le install_sched_service
assert_ok "LE 证书需要调度服务" test -f "$FAKE_INIT_DIR/okxhttp.service"

# 2) 证书日检：一天只跑一次，且只在 LE 证书时跑
RN="$STACK_DIR/renew.calls"
_is_le_cert() { [ "${FAKE_LE:-no}" = yes ]; }
do_renew() { echo run >>"$RN"; }
FAKE_LE=no _cert_tick
assert_fail "自签不做证书检查" test -f "$RN"
FAKE_LE=yes _cert_tick
FAKE_LE=yes _cert_tick
assert_eq "一天内只检查一次" "1" "$(wc -l <"$RN" | tr -d ' ')"
# 标记文件过期 → 再跑一次
touch -d '2 days ago' "$STACK_DIR/.renew_checked" 2>/dev/null || touch -t 202001010000 "$STACK_DIR/.renew_checked"
FAKE_LE=yes _cert_tick
assert_eq "过期后再检查" "2" "$(wc -l <"$RN" | tr -d ' ')"

# 3) 主循环：周期性同步订阅，TERM 立即退出
SYNCED="$STACK_DIR/sync.calls"
sub_sync() { echo x >>"$SYNCED"; }
_cert_tick() { :; }
SCHED_TICK=1
export SCHED_TICK
( do_daemon >"$STACK_DIR/daemon.log" 2>&1 & echo $! >"$STACK_DIR/d.pid" )
sleep 3
kill -TERM "$(cat "$STACK_DIR/d.pid")" 2>/dev/null
sleep 1
_n=$(wc -l <"$SYNCED" 2>/dev/null | tr -d ' ')
assert_ok "循环里反复同步订阅（>=2 次，实际 $_n）" test "${_n:-0}" -ge 2
assert_ok "TERM 能让进程退出" eval '! kill -0 "$(cat "$STACK_DIR/d.pid")" 2>/dev/null'

[ "${TESTS_FAIL:-0}" -eq 0 ] && echo "全部通过"
rm -rf "$STACK_DIR"
exit "${TESTS_FAIL:-0}"
