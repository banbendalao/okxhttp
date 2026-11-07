#!/bin/sh
# xray-stack.sh —— Xray 多协议一键部署（VLESS-XHTTP+Argo / VLESS-TCP-REALITY-Vision / Hysteria2）
# 支持 Debian / Alpine，纯 POSIX sh（busybox ash 兼容）
set -eu

# ---------- 常量 ----------
STACK_DIR=${STACK_DIR:-/usr/local/etc/xray-stack}
BIN_DIR=${BIN_DIR:-/usr/local/bin}
XRAY_BIN=${XRAY_BIN:-$BIN_DIR/xray}
CLOUDFLARED_BIN=${CLOUDFLARED_BIN:-$BIN_DIR/cloudflared}
LEGO_BIN=${LEGO_BIN:-$BIN_DIR/lego}
TLS_DIR=${TLS_DIR:-$STACK_DIR/certs}
TPL_DIR=${TPL_DIR:-$STACK_DIR/tpl}
CLI_DIR=${CLI_DIR:-$STACK_DIR/clients}
STATE=${STATE:-$STACK_DIR/stack.conf}
CONFIG=${CONFIG:-$STACK_DIR/config.json}
ARGO_LOG=${ARGO_LOG:-$STACK_DIR/argo.log}
ARGO_PID=${ARGO_PID:-$STACK_DIR/argo.pid}
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MAIN_RAN=

# ---------- 日志 ----------
log_info() { printf '\033[32m[*]\033[0m %s\n' "$*"; }
log_warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
log_err() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; }
die() {
  log_err "$*"
  exit 1
}

# ---------- 工具 ----------
rand_hex() { od -An -tx1 -N "${1:-8}" /dev/urandom | tr -d ' \n'; }
rand_str() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | dd bs=1 count="${1:-16}" 2>/dev/null; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "需要 root 运行"; }

# ---------- 密钥与证书 ----------
_xray() {
  if [ -x "$XRAY_BIN" ]; then printf '%s\n' "$XRAY_BIN"; else command -v xray || die "未找到 xray"; fi
}

gen_uuid() { "$(_xray)" uuid; }

gen_x25519() {
  _out=$("$(_xray)" x25519) || return 1
  _priv=$(printf '%s\n' "$_out" | sed -n 's/^PrivateKey: //p')
  _pub=$(printf '%s\n' "$_out" | sed -n 's/^Password (PublicKey): //p')
  [ -n "$_priv" ] && [ -n "$_pub" ] || return 1
  printf 'PRIVATE_KEY=%s\nPUBLIC_KEY=%s\n' "$_priv" "$_pub"
}

gen_shortid() { rand_hex 4; }
gen_password() { rand_str 24; }

gen_self_cert() { # cn dir san_ip
  _cn=$1
  _dir=$2
  _ip=${3:-}
  mkdir -p "$_dir"
  _san="DNS:$_cn"
  [ -n "$_ip" ] && _san="$_san,IP:$_ip"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$_dir/key.pem" -out "$_dir/cert.pem" -days 365 \
    -subj "/CN=$_cn" -addext "subjectAltName=$_san" >/dev/null 2>&1 || die "自签证书生成失败"
  chmod 600 "$_dir/key.pem"
}

cert_pin_sha256() {
  openssl x509 -in "$1" -outform DER | openssl dgst -sha256 -binary | openssl base64 -A
}

check_reality_dest() { # sni
  _out=$(timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 </dev/null 2>/dev/null || true)
  printf '%s' "$_out" | grep -q 'TLSv1.3' || return 1
  printf '%s' "$_out" | grep -qi 'ALPN protocol: h2' || return 1
  return 0
}

fetch_lego() {
  command_exists lego && {
    LEGO_BIN=$(command -v lego)
    return 0
  }
  [ -x "$LEGO_BIN" ] && return 0
  case "$(uname -m)" in
    x86_64 | amd64) _a=amd64 ;;
    aarch64 | arm64) _a=arm64 ;;
    *) die "lego 不支持该架构: $(uname -m)" ;;
  esac
  _url=$(curl -fsSL --max-time 15 https://api.github.com/repos/go-acme/lego/releases/latest 2>/dev/null \
    | jq -r '.assets[] | select(.name | test("linux_" + $a + "[.]tar[.]gz$")) | .browser_download_url' --arg a "$_a" 2>/dev/null | head -1)
  [ -n "$_url" ] || die "无法解析 lego 下载地址"
  mkdir -p "$BIN_DIR"
  _tgz="$BIN_DIR/.lego.tgz"
  fetch_dl "$_url" "$_tgz" || die "lego 下载失败"
  tar xzf "$_tgz" -C "$BIN_DIR" lego || die "lego 解压失败"
  rm -f "$_tgz"
  chmod +x "$BIN_DIR/lego"
  LEGO_BIN="$BIN_DIR/lego"
}

gen_le_cert() { # ip dir email —— 失败返回 1，不动已有证书
  _ip=$1
  _dir=$2
  _email=$3
  fetch_lego || return 1
  mkdir -p "$_dir/lego"
  "$LEGO_BIN" --accept-tos --email "$_email" --path "$_dir/lego" --http \
    -d "$_ip" --profile shortlived run >"$_dir/lego.log" 2>&1 || return 1
  [ -s "$_dir/lego/certificates/$_ip.crt" ] || return 1
  cp "$_dir/lego/certificates/$_ip.crt" "$_dir/cert.new.pem" || return 1
  cp "$_dir/lego/certificates/$_ip.key" "$_dir/key.new.pem" || return 1
  chmod 600 "$_dir/key.new.pem"
  mv "$_dir/cert.new.pem" "$_dir/cert.pem"
  mv "$_dir/key.new.pem" "$_dir/key.pem"
}

renew_script_body() { # ip —— 只打印脚本文本，供测试断言
  _ip=${1:-203.0.113.9}
  cat <<EOF
#!/bin/sh
# 自动续期：LE shortlived IP 证书（约 6 天），每 3 天执行
set -eu
IP=$_ip
LEGO=$LEGO_BIN
EMAIL=${LE_EMAIL:-admin@example.com}
DIR=$TLS_DIR
LOG=$STACK_DIR/renew.log
exec >>"\$LOG" 2>&1
echo "[\$(date -u +%FT%TZ)] renew \$IP"
"\$LEGO" --accept-tos --email "\$EMAIL" --path "\$DIR/lego" --http -d "\$IP" --profile shortlived renew --days 4 \\
  || "\$LEGO" --accept-tos --email "\$EMAIL" --path "\$DIR/lego" --http -d "\$IP" --profile shortlived run
cp "\$DIR/lego/certificates/\$IP.crt" "\$DIR/cert.pem"
cp "\$DIR/lego/certificates/\$IP.key" "\$DIR/key.pem"
if command -v systemctl >/dev/null 2>&1; then systemctl restart xray; elif command -v rc-service >/dev/null 2>&1; then rc-service xray restart; fi
EOF
}

install_renew_cron() { # ip
  _ip=$1
  mkdir -p "$STACK_DIR"
  renew_script_body "$_ip" >"$STACK_DIR/renew.sh"
  chmod 700 "$STACK_DIR/renew.sh"
  if [ -d /etc/cron.d ]; then
    printf '0 3 */3 * * root %s\n' "$STACK_DIR/renew.sh" >/etc/cron.d/xray-stack-renew
    chmod 644 /etc/cron.d/xray-stack-renew
  elif [ -d /etc/crontabs ]; then
    _tmp="$STACK_DIR/crontab.tmp"
    [ -f /etc/crontabs/root ] && grep -v 'xray-stack' /etc/crontabs/root >"$_tmp" || : >"$_tmp"
    printf '0 3 */3 * * %s\n' "$STACK_DIR/renew.sh" >>"$_tmp"
    cat "$_tmp" >/etc/crontabs/root
    rm -f "$_tmp"
    command_exists crond && rc-service crond start >/dev/null 2>&1 || true
  else
    log_warn "未找到 cron，跳过自动续期（证书约 6 天过期，请手执行 $STACK_DIR/renew.sh）"
  fi
}

main() {
  MAIN_RAN=1
  log_info "xray-stack 启动"
}

# ---------- 环境探测 ----------
pick_xray_asset() {
  case "$1" in
    x86_64 | amd64) echo Xray-linux-64.zip ;;
    aarch64 | arm64) echo Xray-linux-arm64-v8a.zip ;;
    armv7l | armv7) echo Xray-linux-arm32-v7a.zip ;;
    i386 | i686 | x86) echo Xray-linux-32.zip ;;
    *) echo '' ;;
  esac
}

pick_cloudflared_asset() {
  case "$1" in
    x86_64 | amd64) echo cloudflared-linux-amd64 ;;
    aarch64 | arm64) echo cloudflared-linux-arm64 ;;
    armv7l | armv7) echo cloudflared-linux-arm ;;
    i386 | i686 | x86) echo cloudflared-linux-386 ;;
    *) echo '' ;;
  esac
}

detect_arch() {
  ARCH_RAW=$(uname -m)
  ARCH=$(pick_xray_asset "$ARCH_RAW")
  printf '%s\n' "$ARCH_RAW"
}

detect_os() {
  OS_ID=other
  OS_PKG=
  if [ -r /etc/os-release ]; then
    _id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | head -1)
    case "$_id" in
      debian | ubuntu) OS_ID=debian ;;
      alpine) OS_ID=alpine ;;
    esac
  fi
  case "$OS_ID" in
    debian) OS_PKG=apt ;;
    alpine) OS_PKG=apk ;;
  esac
}

public_ipv4() {
  _ip=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
  case "$_ip" in
    '' | *[!0-9.]*) _ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1) ;;
  esac
  printf '%s\n' "${_ip:-}"
}

udp_egress_ok() {
  # 无 nc 时不阻塞流程，交给 argo 的 quic→http2 回退判定
  command_exists nc || return 0
  nc -u -w 2 -z 1.1.1.1 443 >/dev/null 2>&1 && return 0
  nc -uz -w 2 1.1.1.1 443 >/dev/null 2>&1 && return 0
  return 1
}

missing_deps() {
  _out=
  for _c in curl jq unzip openssl; do
    command_exists "$_c" || _out="$_out $_c"
  done
  printf '%s\n' "${_out# }"
}

install_deps() {
  detect_os
  _miss=$(missing_deps)
  [ -z "$_miss" ] && return 0
  log_info "安装依赖: $_miss"
  case "$OS_PKG" in
    apt)
      apt-get update -qq >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl jq unzip openssl >/dev/null
      ;;
    apk) apk add --no-cache ca-certificates curl jq unzip openssl >/dev/null ;;
    *) die "无法识别包管理器，请手动安装: $_miss" ;;
  esac
  _miss=$(missing_deps)
  [ -z "$_miss" ] || die "依赖安装失败: $_miss"
}

# ---------- 内核下载 ----------
fetch_dl() { # url out
  curl -fsSL --retry 3 --connect-timeout 10 -o "$2" "$1" 2>/dev/null && [ -s "$2" ]
}

fetch_core() {
  mkdir -p "$BIN_DIR"
  _arch=$(detect_arch)
  if [ "${FORCE_FETCH:-0}" = 1 ] || [ ! -x "$BIN_DIR/xray" ]; then
    _asset=$(pick_xray_asset "$_arch")
    [ -n "$_asset" ] || die "不支持的架构: $_arch"
    log_info "下载 Xray 内核 ($_asset)"
    _tmp="$BIN_DIR/.xray.zip"
    fetch_dl "https://github.com/XTLS/Xray-core/releases/latest/download/$_asset" "$_tmp" || die "Xray 下载失败"
    (cd "$BIN_DIR" && unzip -oq .xray.zip xray) || die "Xray 解压失败"
    rm -f "$_tmp"
    chmod +x "$BIN_DIR/xray"
  fi
  XRAY_BIN="$BIN_DIR/xray"
  "$XRAY_BIN" version >/dev/null 2>&1 || die "xray 无法执行: $XRAY_BIN"

  if [ "${FORCE_FETCH:-0}" = 1 ] || [ ! -x "$BIN_DIR/cloudflared" ]; then
    _casset=$(pick_cloudflared_asset "$_arch")
    [ -n "$_casset" ] || die "cloudflared 不支持该架构: $_arch"
    log_info "下载 cloudflared ($_casset)"
    fetch_dl "https://github.com/cloudflare/cloudflared/releases/latest/download/$_casset" "$BIN_DIR/cloudflared" || die "cloudflared 下载失败"
    chmod +x "$BIN_DIR/cloudflared"
  fi
  CLOUDFLARED_BIN="$BIN_DIR/cloudflared"
  "$CLOUDFLARED_BIN" --version >/dev/null 2>&1 || die "cloudflared 无法执行: $CLOUDFLARED_BIN"
}

[ "${STACK_LIB_ONLY:-0}" = 1 ] || main "$@"
