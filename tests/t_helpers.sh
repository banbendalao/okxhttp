#!/bin/sh
# t_helpers：加载脚本不执行 main；随机串形状；die 非 0
. "$(dirname "$0")/lib.sh"
echo "== t_helpers =="
STACK_LIB_ONLY=1 STACK_DIR=/tmp/stack-test . ./xray-stack.sh
assert_eq "sourcing 不执行 main" "" "${MAIN_RAN:-}"
assert_match "rand_hex 8 → 16 位 hex" '^[0-9a-f]{16}$' "$(rand_hex 8)"
assert_match "rand_hex 两次不同" '^1$' "$([ "$(rand_hex 8)" != "$(rand_hex 8)" ] && echo 1 || echo 0)"
assert_match "rand_str 16 位字母数字" '^[A-Za-z0-9]{16}$' "$(rand_str 16)"
assert_fail "die 非 0 退出" sh -c '. ./xray-stack.sh; die "boom"'
assert_match "log_info 带前缀" '^.*\[\*\].*' "$(log_info hello 2>&1)"
