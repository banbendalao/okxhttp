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
mkdir -p "$FAKE_INIT_DIR" "$STACK_DIR/certs"
STATE="$STACK_DIR/stack.conf"
export STATE
. ./okxhttp
touch "$FAKE_INIT_DIR/xray.service" "$FAKE_INIT_DIR/argo.service"
printf 'ENABLE_HY2=1\nNODE_NAME=life\n' >"$STATE"

printf 'cert\n' >"$STACK_DIR/certs/cert.pem"
printf 'xray\n' >"$STACK_DIR/.installed_bins"

do_uninstall
assert_fail "xray 服务文件被移除" test -e "$FAKE_INIT_DIR/xray.service"
assert_fail "argo 服务文件被移除" test -e "$FAKE_INIT_DIR/argo.service"
assert_ok "不再产生链接文件" sh -c "[ ! -e '$STACK_DIR/links.txt' ]"
assert_ok "证书默认保留" test -e "$STACK_DIR/certs/cert.pem"
assert_ok "二次卸载幂等" do_uninstall
PURGE=1 do_uninstall
assert_fail "purge 后证书被删除" test -e "$STACK_DIR/certs"

assert_ok "do_info 无部署时也退出 0" do_info

# ---- 每次运行的自我更新检查 ----
REPO=$PWD
BIN_DIR="$STACK_DIR/bin"
export BIN_DIR
mkdir -p "$BIN_DIR"
NEWV=$(printf '%s' "$SCRIPT_VERSION" | awk -F. '{printf "%s.%s.%s", $1, $2, $3 + 1}')
printf '#!/bin/sh\nSCRIPT_VERSION=%s\nmain "$@"\n' "$NEWV" >"$STACK_DIR/remote-new"
printf '#!/bin/sh\nSCRIPT_VERSION=%s\nmain "$@"\n' "$SCRIPT_VERSION" >"$STACK_DIR/remote-same"
printf '#!/bin/sh\nSCRIPT_VERSION=%s\n' "$NEWV" >"$STACK_DIR/remote-broken"
inst() { # 造一个"已安装命令 + 版本号"
  printf '#!/bin/sh\nSCRIPT_VERSION=%s\n' "$1" >"$BIN_DIR/okxhttp"
  chmod 755 "$BIN_DIR/okxhttp"
  printf '%s\n' "$1" >"$STACK_DIR/version"
}
curl() { cat "${FAKE_REMOTE:?}"; }
log_info() { :; }
log_warn() { :; }
SELF_URL=http://remote.invalid/okxhttp
export SELF_URL

# 命令已是最新 → 不动
inst "$SCRIPT_VERSION"
FAKE_REMOTE="$STACK_DIR/remote-same" check_self_update
assert_match "已是最新不覆盖命令" "^SCRIPT_VERSION=$SCRIPT_VERSION$" "$(sed -n 2p "$BIN_DIR/okxhttp")"

# 远端有新版本 → 安装（非交互直接装）
inst 0.0.1
FAKE_REMOTE="$STACK_DIR/remote-new" YES=1 check_self_update
assert_match "远端更新时安装新版本" "^SCRIPT_VERSION=$NEWV$" "$(sed -n 2p "$BIN_DIR/okxhttp")"
assert_eq "version 文件同步" "$NEWV" "$(cat "$STACK_DIR/version")"

# 运行中的比已安装的新（用户跑一键命令的典型场景）→ 同步命令，不提问
inst 0.0.1
FAKE_REMOTE="$STACK_DIR/remote-same" check_self_update
assert_match "一键运行会把命令同步成当前版本" "^SCRIPT_VERSION=$SCRIPT_VERSION$" "$(sed -n 2p "$BIN_DIR/okxhttp")"

# 内容不完整（无 main 入口）→ 不装
inst 0.0.1
FAKE_REMOTE="$STACK_DIR/remote-broken" YES=1 check_self_update
assert_match "残缺内容不覆盖命令" '^SCRIPT_VERSION=0\.0\.1$' "$(sed -n 2p "$BIN_DIR/okxhttp")"

# 回归：cwd 里正好有个同名旧 okxhttp，也必须照样更新
inst 0.0.1
mkdir -p "$STACK_DIR/cwd"
printf '#!/bin/sh\nSCRIPT_VERSION=0.0.1\n' >"$STACK_DIR/cwd/okxhttp"
(
  cd "$STACK_DIR/cwd" || exit 1
  sh -c "STACK_LIB_ONLY=1 . '$REPO/okxhttp' >/dev/null 2>&1
    curl() { cat '$STACK_DIR/remote-new'; }
    log_info() { :; }
    SELF_URL=http://x/; YES=1; check_self_update" okxhttp
)
assert_match "cwd 有同名旧文件也不挡更新" "^SCRIPT_VERSION=$NEWV$" "$(sed -n 2p "$BIN_DIR/okxhttp")"

rm -rf "$STACK_DIR"
