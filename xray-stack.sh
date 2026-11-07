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
