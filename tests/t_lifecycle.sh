#!/bin/sh
# t_lifecycle：卸载、证书保留/清除、幂等、--info
. "$(dirname "$0")/lib.sh"
echo "== t_lifecycle =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/life-$$"
export STACK_DIR
FAKE_INIT_DIR="$STACK_DIR/fake-init"
export FAKE_INIT_DIR INIT_SYS=fake
rm -rf "$STACK_DIR"
mkdir -p "$FAKE_INIT_DIR" "$STACK_DIR/clients" "$STACK_DIR/certs"
STATE="$STACK_DIR/stack.conf"
export STATE
. ./okxhttp
touch "$FAKE_INIT_DIR/xray.service" "$FAKE_INIT_DIR/argo.service"
printf 'ENABLE_HY2=1\nNODE_NAME=life\n' >"$STATE"
printf 'vless://x\n' >"$STACK_DIR/clients/sub.txt"
printf 'cert\n' >"$STACK_DIR/certs/cert.pem"
printf 'xray\n' >"$STACK_DIR/.installed_bins"

do_uninstall
assert_fail "xray 服务文件被移除" test -e "$FAKE_INIT_DIR/xray.service"
assert_fail "argo 服务文件被移除" test -e "$FAKE_INIT_DIR/argo.service"
assert_fail "配置目录被清理" test -e "$STACK_DIR/clients"
assert_ok "证书默认保留" test -e "$STACK_DIR/certs/cert.pem"
assert_ok "二次卸载幂等" do_uninstall
PURGE=1 do_uninstall
assert_fail "purge 后证书被删除" test -e "$STACK_DIR/certs"

assert_ok "do_info 无部署时也退出 0" do_info
rm -rf "$STACK_DIR"
