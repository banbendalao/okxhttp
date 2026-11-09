#!/bin/sh
# t_env：架构映射、发行版识别、公网 IP、UDP 探测、内核下载
. "$(dirname "$0")/lib.sh"
echo "== t_env =="
export STACK_LIB_ONLY=1
. ./okxhttp

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
assert_match "公网 IP 形状" '^[0-9a-fA-F:.]+$' "$(public_ip)"
assert_match "协议族探测结果" '^(4|6|46|64|)$' "$(detect_ip_family)"
assert_eq "trace 探测的 IP 与协议族判定一致" "same" "$(sh -c '. ./okxhttp; _probe_all; case "$(detect_ip_family)" in *4*) _f=yes ;; *) _f=no ;; esac; [ -n "$PROBE_IP_V4" ] && _i=yes || _i=no; [ "$_f" = "$_i" ] && echo same || echo "differ($_f/$_i)"')"
assert_eq "IPv6 链接加方括号" "[2001:db8::1]" "$(. ./okxhttp >/dev/null 2>&1; _bracket 2001:db8::1)"
assert_eq "IPv4 不加括号" "203.0.113.9" "$(. ./okxhttp >/dev/null 2>&1; _bracket 203.0.113.9)"
assert_ok "UDP 探测可执行" sh -c 'STACK_LIB_ONLY=1 . ./okxhttp; udp_egress_ok || true'
assert_eq "本机依赖齐全" "" "$(missing_deps)"

# 依赖阶段：缺 supervise-daemon 时用候选包安装（独立包 -> openrc）
_fb="$PWD/.tmp/fakebin2"
rm -rf "$_fb"; mkdir -p "$_fb"
cat >"$_fb/apk" <<'APK'
#!/bin/sh
# 模拟：supervise-daemon 独立包不存在，openrc 包能装上并带来 supervise-daemon
case "$*" in
  *"add"*"supervise-daemon"*) exit 1 ;;
  *"add"*"openrc"*) printf '#!/bin/sh\n' >"$(dirname "$0")/supervise-daemon"; chmod +x "$(dirname "$0")/supervise-daemon"; exit 0 ;;
esac
exit 0
APK
chmod +x "$_fb/apk"
assert_ok "依赖阶段装好 supervise-daemon" sh -c "PATH='$_fb:/usr/bin:/bin' INIT_SYS=openrc STACK_LIB_ONLY=1 . ./okxhttp; detect_os() { OS_ID=alpine; OS_PKG=apk; }; command_exists() { command -v \"\$1\" >/dev/null 2>&1; }; install_deps"
assert_ok "装完命令可用" test -x "$_fb/supervise-daemon"

# 下载失败要把原因透出（而不是只吞成一句"失败"）
assert_fail "坏地址下载失败" sh -c 'STACK_LIB_ONLY=1 . ./okxhttp; fetch_dl https://127.0.0.1:1/nope /tmp/dl-bad.bin'
assert_match "失败原因可见" 'curl:' "$(sh -c 'STACK_LIB_ONLY=1 . ./okxhttp; fetch_dl https://127.0.0.1:1/nope /tmp/dl-bad.bin' 2>&1)"

# 内核下载：缓存目录 .tmp/bin，首次真下载，之后复用
BIN_DIR="$PWD/.tmp/bin"
export BIN_DIR
mkdir -p "$BIN_DIR"
fetch_core >/dev/null
assert_ok "xray 可执行" test -x "$BIN_DIR/xray"
assert_match "xray 主版本 26" "^26$" "$("$BIN_DIR/xray" version | head -1 | awk '{print $2}' | cut -d. -f1)"
assert_ok "cloudflared 可执行" test -x "$BIN_DIR/cloudflared"
assert_match "cloudflared 版本输出" 'cloudflared version' "$("$BIN_DIR/cloudflared" --version 2>&1 | head -1)"
