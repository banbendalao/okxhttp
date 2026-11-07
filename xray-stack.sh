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

[ "${STACK_LIB_ONLY:-0}" = 1 ] || main "$@"
