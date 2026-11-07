#!/bin/sh
# t_env：架构映射、发行版识别、公网 IP、UDP 探测、内核下载
. "$(dirname "$0")/lib.sh"
echo "== t_env =="
STACK_LIB_ONLY=1 . ./xray-stack.sh

assert_eq "x86_64 资源名" "Xray-linux-64.zip" "$(pick_xray_asset x86_64)"
assert_eq "aarch64 资源名" "Xray-linux-arm64-v8a.zip" "$(pick_xray_asset aarch64)"
assert_eq "armv7l 资源名" "Xray-linux-arm32-v7a.zip" "$(pick_xray_asset armv7l)"
assert_eq "i686 资源名" "Xray-linux-32.zip" "$(pick_xray_asset i686)"
assert_eq "未知架构返回空" "" "$(pick_xray_asset sparc64)"
assert_eq "cloudflared amd64" "cloudflared-linux-amd64" "$(pick_cloudflared_asset x86_64)"
assert_eq "cloudflared arm64" "cloudflared-linux-arm64" "$(pick_cloudflared_asset aarch64)"

detect_os >/dev/null
assert_match "发行版识别" '^(debian|alpine|other)$' "$OS_ID"
assert_match "包管理器识别" '^(apt|apk|)$' "$OS_PKG"
assert_match "公网 IP 形状" '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' "$(public_ipv4)"
assert_ok "UDP 探测可执行" sh -c '. ./xray-stack.sh; udp_egress_ok || true'
assert_eq "本机依赖齐全" "" "$(missing_deps)"

# 内核下载：缓存目录 .tmp/bin，首次真下载，之后复用
BIN_DIR="$PWD/.tmp/bin"
export BIN_DIR
mkdir -p "$BIN_DIR"
fetch_core >/dev/null
assert_ok "xray 可执行" test -x "$BIN_DIR/xray"
assert_match "xray 主版本 26" "^26$" "$("$BIN_DIR/xray" version | head -1 | awk '{print $2}' | cut -d. -f1)"
assert_ok "cloudflared 可执行" test -x "$BIN_DIR/cloudflared"
assert_match "cloudflared 版本输出" 'cloudflared version' "$("$BIN_DIR/cloudflared" --version 2>&1 | head -1)"
