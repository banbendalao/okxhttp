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
SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC2034 # 测试用来断言 sourcing 不执行 main
MAIN_RAN=''

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

cert_pin_sha256() { # 输出 64 位 hex（Xray 26 的 pinnedPeerCertSha256 / hysteria pinSHA256 都吃 hex）
  openssl x509 -in "$1" -outform DER | openssl dgst -sha256 -hex | sed 's/.*= *//'
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
  # lego v5：--accept-tos/--email/--path/--http/--profile 都是 run 的子命令参数
  "$LEGO_BIN" run --accept-tos --email "$_email" --path "$_dir/lego" --http \
    --profile shortlived -d "$_ip" >"$_dir/lego.log" 2>&1 || return 1
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
EMAIL=${LE_EMAIL:-ops@no-reply.dev}
DIR=$TLS_DIR
LOG=$STACK_DIR/renew.log
exec >>"\$LOG" 2>&1
echo "[\$(date -u +%FT%TZ)] renew \$IP"
"\$LEGO" run --accept-tos --email "\$EMAIL" --path "\$DIR/lego" --http --profile shortlived -d "\$IP" --renew-days 4 \\
  || "\$LEGO" run --accept-tos --email "\$EMAIL" --path "\$DIR/lego" --http --profile shortlived -d "\$IP"
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
  else
    # Alpine/busybox：crond 读 /etc/crontabs/root（该目录可能不存在，需要自建）
    mkdir -p /etc/crontabs
    _tmp="$STACK_DIR/crontab.tmp"
    [ -f /etc/crontabs/root ] && grep -v 'xray-stack' /etc/crontabs/root >"$_tmp" || : >"$_tmp"
    printf '0 3 */3 * * %s\n' "$STACK_DIR/renew.sh" >>"$_tmp"
    cat "$_tmp" >/etc/crontabs/root
    chmod 600 /etc/crontabs/root
    rm -f "$_tmp"
    if command_exists crond; then
      rc-update add crond default >/dev/null 2>&1 || true
      rc-service crond restart >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
    elif ! command_exists cron; then
      log_warn "未找到 cron/crond，自动续期未启用（证书约 6 天过期，请手动执行 $STACK_DIR/renew.sh）"
    fi
  fi
}

# ---------- 配置模板与合成 ----------
write_templates() {
  mkdir -p "$TPL_DIR"
  cat >"$TPL_DIR/xhttp.jq" <<'JQ'
{
  tag: "vless-xhttp-in",
  listen: $listen,
  port: $port,
  protocol: "vless",
  settings: {clients: [{id: $uuid}], decryption: "none"},
  streamSettings: {
    network: "xhttp",
    security: "none",
    xhttpSettings: {path: $path, mode: "auto"}
  },
  sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]}
}
JQ
  cat >"$TPL_DIR/reality.jq" <<'JQ'
{
  tag: "vless-reality-in",
  listen: "0.0.0.0",
  port: $port,
  protocol: "vless",
  settings: {clients: [{id: $uuid, flow: "xtls-rprx-vision"}], decryption: "none"},
  streamSettings: {
    network: "tcp",
    security: "reality",
    realitySettings: {
      show: false,
      dest: $dest,
      xver: 0,
      serverNames: [$sni],
      privateKey: $priv,
      shortIds: [$sid]
    }
  },
  sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]}
}
JQ
  cat >"$TPL_DIR/hy2.jq" <<'JQ'
{
  tag: "hy2-in",
  listen: "0.0.0.0",
  port: $port,
  protocol: "hysteria",
  settings: {version: 2, clients: [{auth: $auth}]},
  streamSettings: {
    network: "hysteria",
    security: "tls",
    tlsSettings: {
      alpn: ["h3"],
      certificates: [{certificateFile: $cert, keyFile: $key}]
    }
  },
  sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]}
}
JQ
  cat >"$TPL_DIR/ws.jq" <<'JQ'
{
  tag: "vless-ws-in",
  listen: "127.0.0.1",
  port: $port,
  protocol: "vless",
  settings: {clients: [{id: $uuid}], decryption: "none"},
  streamSettings: {
    network: "ws",
    security: "none",
    wsSettings: {path: $path}
  },
  sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]}
}
JQ
  cat >"$TPL_DIR/merge.jq" <<'JQ'
{
  log: {loglevel: "warning"},
  inbounds: .,
  outbounds: [
    {tag: "direct", protocol: "freedom"},
    {tag: "block", protocol: "blackhole"}
  ]
}
JQ
}

render_inbound() { # proto outfile
  _p=$1
  _dst=$2
  case "$_p" in
    xhttp)
      jq -n -f "$TPL_DIR/xhttp.jq" \
        --arg uuid "${UUID:?UUID 未设置}" \
        --argjson port "${XHTTP_PORT:-2087}" \
        --arg path "${XHTTP_PATH:-/xhttp}" \
        --arg listen "$([ "${ARGO_MODE:-temp}" = off ] && echo 0.0.0.0 || echo 127.0.0.1)" >"$_dst"
      ;;
    reality)
      jq -n -f "$TPL_DIR/reality.jq" \
        --arg uuid "${UUID:?UUID 未设置}" \
        --argjson port "${REALITY_PORT:-443}" \
        --arg dest "${REALITY_SNI:-dm.toutiao.com}:443" \
        --arg sni "${REALITY_SNI:-dm.toutiao.com}" \
        --arg priv "${REALITY_PRIV:?REALITY 私钥未设置}" \
        --arg sid "${REALITY_SHORTID:?shortId 未设置}" >"$_dst"
      ;;
    ws)
      jq -n -f "$TPL_DIR/ws.jq" \
        --arg uuid "${UUID:?UUID 未设置}" \
        --argjson port "${WS_PORT:-2088}" \
        --arg path "${WS_PATH:-/ws}" >"$_dst"
      ;;
    hy2)
      jq -n -f "$TPL_DIR/hy2.jq" \
        --arg auth "${HY2_PASSWORD:?hy2 密码未设置}" \
        --argjson port "${HY2_PORT:-443}" \
        --arg cert "${TLS_DIR:-$STACK_DIR/certs}/cert.pem" \
        --arg key "${TLS_DIR:-$STACK_DIR/certs}/key.pem" >"$_dst"
      ;;
    *) die "未知协议: $_p" ;;
  esac
}

test_config() { # file
  [ -s "$1" ] || return 1
  if _err=$("$(_xray)" run -test -c "$1" 2>&1); then
    return 0
  fi
  log_err "配置校验失败: $1"
  printf '%s\n' "$_err" | tail -30 >&2
  return 1
}

build_config() { # outfile
  _cfgout=$1
  write_templates
  _n=0
  _tmpd=$STACK_DIR/.render
  rm -rf "$_tmpd"
  mkdir -p "$_tmpd"
  if [ "${ENABLE_XHTTP:-0}" = 1 ]; then render_inbound xhttp "$_tmpd/10-xhttp.json"; _n=$((_n + 1)); fi
  if [ "${ENABLE_WS:-0}" = 1 ]; then render_inbound ws "$_tmpd/15-ws.json"; _n=$((_n + 1)); fi
  if [ "${ENABLE_REALITY:-0}" = 1 ]; then render_inbound reality "$_tmpd/20-reality.json"; _n=$((_n + 1)); fi
  if [ "${ENABLE_HY2:-0}" = 1 ]; then render_inbound hy2 "$_tmpd/30-hy2.json"; _n=$((_n + 1)); fi
  [ "$_n" -gt 0 ] || die "至少需要启用一个协议"
  # shellcheck disable=SC2086
  jq -s -f "$TPL_DIR/merge.jq" "$_tmpd"/*.json >"$_cfgout" || die "配置合成失败"
  rm -rf "$_tmpd"
  test_config "$_cfgout" || die "生成的配置未通过 xray 校验"
}

# ---------- Argo 隧道 ----------
argo_domain_from_log() {
  [ -f "$1" ] || return 0
  grep -aoE 'https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com' "$1" 2>/dev/null | head -1 | sed 's#^https://##'
}

argo_ingress_port() {
  [ -f "$1" ] || return 0
  grep -ao 'localhost:[0-9][0-9]*' "$1" 2>/dev/null | head -1 | cut -d: -f2
}

argo_log_connected() {
  [ -f "$1" ] || return 1
  grep -aq 'Registered tunnel connection' "$1"
}

argo_pick_proto() {
  case "${ARGO_PROTO:-auto}" in
    http2) printf 'http2\n' ;;
    quic) printf 'quic\n' ;;
    *)
      if [ "${UDP_EGRESS_OK:-1}" = 0 ]; then printf 'http2\n'; else printf 'quic\n'; fi
      ;;
  esac
}

_argo_launch() { # proto
  _mp=$1
  if [ "${ARGO_MODE:-temp}" = token ]; then
    _acmd="$CLOUDFLARED_BIN tunnel --no-autoupdate --edge-ip-version auto --protocol $_mp run --token ${ARGO_AUTH:-}"
  else
    _tport=${XHTTP_PORT:-2087}
    [ "${ENABLE_WS:-0}" = 1 ] && _tport=${WS_PORT:-$((XHTTP_PORT + 1))}
    _acmd="$CLOUDFLARED_BIN tunnel --url http://127.0.0.1:$_tport --no-autoupdate --edge-ip-version auto --protocol $_mp"
  fi
  if [ "${INIT_SYS:-none}" = none ]; then
    $_acmd >>"$ARGO_LOG" 2>&1 &
    _argonpid=$!
    printf '%s\n' "$_argonpid" >>"$ARGO_PID"
  else
    SVC_LOG=$ARGO_LOG svc_install argo "$_acmd"
  fi
}

_argo_wait_connected() { # log timeout
  _i=0
  while [ "$_i" -lt "${2:-15}" ]; do
    argo_log_connected "$1" && return 0
    sleep 1
    _i=$((_i + 1))
  done
  return 1
}

argo_stop() {
  if [ "${INIT_SYS:-none}" != none ] && { [ -f /etc/init.d/argo ] || [ -f /etc/systemd/system/argo.service ]; }; then
    svc_stop argo
  fi
  [ -f "$ARGO_PID" ] || return 0
  while read -r _p; do
    [ -n "$_p" ] || continue
    kill "$_p" 2>/dev/null || true
  done <"$ARGO_PID"
  rm -f "$ARGO_PID"
}

# token 模式：先短跑一次连接器，从日志读出面板下发的 ingress 端口并对齐 XHTTP_PORT
argo_probe_ingress() {
  [ "${ARGO_MODE:-temp}" = token ] || return 0
  [ -n "${ARGO_AUTH:-}" ] || die "token 模式需要 ARGO_AUTH"
  log_info "探测面板 ingress 配置（最长 20s）…"
  : >"$ARGO_LOG"
  "$CLOUDFLARED_BIN" tunnel --no-autoupdate --edge-ip-version auto --protocol "$(argo_pick_proto)" \
    run --token "$ARGO_AUTH" >"$ARGO_LOG" 2>&1 &
  _probe=$!
  _ins=
  _i=0
  while [ "$_i" -lt 20 ]; do
    _ins=$(argo_ingress_port "$ARGO_LOG")
    [ -n "$_ins" ] && break
    sleep 1
    _i=$((_i + 1))
  done
  kill "$_probe" 2>/dev/null || true
  wait "$_probe" 2>/dev/null || true
  if [ -z "$_ins" ]; then
    log_warn "未能从日志读到面板 ingress；请确认面板中 $ARGO_DOMAIN 指向 http://localhost:${XHTTP_PORT:-2087}"
    return 1
  fi
  if [ "$_ins" != "${XHTTP_PORT:-2087}" ]; then
    log_warn "面板 ingress 指向 localhost:$_ins，XHTTP_PORT 由 ${XHTTP_PORT:-2087} 自动对齐为 $_ins"
    XHTTP_PORT=$_ins
  fi
  return 0
}

argo_start() {
  [ "${ARGO_MODE:-temp}" = off ] && {
    log_info "ARGO_MODE=off：跳过隧道，XHTTP 将直接监听公网"
    return 0
  }
  mkdir -p "$STACK_DIR"
  argo_stop
  : >"$ARGO_LOG"
  : >"$ARGO_PID"
  _proto=$(argo_pick_proto)
  log_info "启动 Argo 连接器（prot=${_proto}，mode=${ARGO_MODE:-temp}）…"
  _argo_launch "$_proto"
  if ! _argo_wait_connected "$ARGO_LOG" 15; then
    if [ "$_proto" = quic ] && [ "${ARGO_PROTO:-auto}" = auto ]; then
      log_warn "quic 未在 15s 内完成隧道注册，回退 http2"
      argo_stop
      : >"$ARGO_PID"
      _proto=http2
      _argo_launch http2
      _argo_wait_connected "$ARGO_LOG" 20 || {
        tail -20 "$ARGO_LOG" >&2
        die "Argo 隧道注册失败（quic 与 http2 均未成功）"
      }
    else
      tail -20 "$ARGO_LOG" >&2
      die "Argo 隧道注册失败（prot=${_proto}）"
    fi
  fi
  ARGO_PROTO_USED=$_proto
  if [ "${ARGO_MODE:-temp}" = token ]; then
    ARGO_DOMAIN_RESOLVED=${ARGO_DOMAIN:-}
    [ -n "$ARGO_DOMAIN_RESOLVED" ] || die "token 模式需要 ARGO_DOMAIN"
  else
    ARGO_DOMAIN_RESOLVED=$(argo_domain_from_log "$ARGO_LOG")
    [ -n "$ARGO_DOMAIN_RESOLVED" ] || die "未从 cloudflared 日志取到临时隧道域名（见 $ARGO_LOG）"
  fi
  log_info "Argo 就绪：domain=$ARGO_DOMAIN_RESOLVED prot=$ARGO_PROTO_USED"
}

# ---------- 客户端配置与分享链接 ----------
uri_xhttp() { # host alpn
  _h=$1
  _alpn=$2
  if [ "${ARGO_MODE:-temp}" = off ]; then
    printf 'vless://%s@%s:%s?encryption=none&type=xhttp&security=none&path=%s&mode=auto#%s-xhttp-%s\n' \
      "$UUID" "${PUBLIC_IP}" "${XHTTP_PORT:-2087}" "${XHTTP_PATH:-/xhttp}" "${NODE_NAME:-node}" "$_alpn"
  else
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&alpn=%s&fp=chrome&type=xhttp&path=%s&mode=auto&host=%s#%s-xhttp-%s\n' \
      "$UUID" "$_h" "$_h" "$_alpn" "${XHTTP_PATH:-/xhttp}" "$_h" "${NODE_NAME:-node}" "$_alpn"
  fi
}

uri_ws() { # host
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&path=%s&host=%s#%s-ws-h2\n' \
    "$UUID" "$1" "$1" "${WS_PATH:-/ws}" "$1" "${NODE_NAME:-node}"
}

uri_reality() {
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s-reality\n' \
    "$UUID" "${PUBLIC_IP}" "${REALITY_PORT:-443}" "${REALITY_SNI:-dm.toutiao.com}" \
    "${REALITY_PUB}" "${REALITY_SHORTID}" "${NODE_NAME:-node}"
}

uri_hy2() {
  printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=1#%s-hy2\n' \
    "${HY2_PASSWORD}" "${PUBLIC_IP}" "${HY2_PORT:-443}" "${PUBLIC_IP}" "${NODE_NAME:-node}"
}

_emit_xhttp_json() { # alpn socks_port outfile
  _alpn=$1
  _sport=$2
  _dst=$3
  if [ "${ARGO_MODE:-temp}" = off ]; then
    jq -n --arg uuid "$UUID" --arg ip "$PUBLIC_IP" --argjson rport "${XHTTP_PORT:-2087}" \
      --arg path "${XHTTP_PATH:-/xhttp}" --argjson sport "$_sport" '
      {log:{loglevel:"warning"},
       inbounds:[{listen:"127.0.0.1",port:$sport,protocol:"socks",settings:{udp:true}}],
       outbounds:[{protocol:"vless",
         settings:{vnext:[{address:$ip,port:$rport,users:[{id:$uuid,encryption:"none"}]}]},
         streamSettings:{network:"xhttp",security:"none",
           xhttpSettings:{path:$path,mode:"auto"}}}]}' >"$_dst"
  else
    jq -n --arg uuid "$UUID" --arg host "${ARGO_DOMAIN_RESOLVED}" --arg alpn "$_alpn" \
      --arg path "${XHTTP_PATH:-/xhttp}" --argjson sport "$_sport" '
      {log:{loglevel:"warning"},
       inbounds:[{listen:"127.0.0.1",port:$sport,protocol:"socks",settings:{udp:true}}],
       outbounds:[{protocol:"vless",
         settings:{vnext:[{address:$host,port:443,users:[{id:$uuid,encryption:"none"}]}]},
         streamSettings:{network:"xhttp",security:"tls",
           tlsSettings:{serverName:$host,alpn:[$alpn],fingerprint:"chrome"},
           xhttpSettings:{path:$path,mode:"auto",host:$host}}}]}' >"$_dst"
  fi
}

_emit_ws_json() { # socks_port outfile
  jq -n --arg uuid "$UUID" --arg host "${ARGO_DOMAIN_RESOLVED}" --arg path "${WS_PATH:-/ws}" --argjson sport "$1" '
    {log:{loglevel:"warning"},
     inbounds:[{listen:"127.0.0.1",port:$sport,protocol:"socks",settings:{udp:true}}],
     outbounds:[{protocol:"vless",
       settings:{vnext:[{address:$host,port:443,users:[{id:$uuid,encryption:"none"}]}]},
       streamSettings:{network:"ws",security:"tls",
         tlsSettings:{serverName:$host,alpn:["h2"],fingerprint:"chrome"},
         wsSettings:{path:$path,headers:{Host:$host}}}}]}' >"$2"
}

_emit_reality_json() { # socks_port outfile
  jq -n --arg uuid "$UUID" --arg ip "$PUBLIC_IP" --argjson rport "${REALITY_PORT:-443}" \
    --arg sni "${REALITY_SNI:-dm.toutiao.com}" --arg pbk "$REALITY_PUB" --arg sid "$REALITY_SHORTID" \
    --argjson sport "$1" '
    {log:{loglevel:"warning"},
     inbounds:[{listen:"127.0.0.1",port:$sport,protocol:"socks",settings:{udp:true}}],
     outbounds:[{protocol:"vless",
       settings:{vnext:[{address:$ip,port:$rport,
         users:[{id:$uuid,encryption:"none",flow:"xtls-rprx-vision"}]}]},
       streamSettings:{network:"tcp",security:"reality",
         realitySettings:{serverName:$sni,fingerprint:"chrome",publicKey:$pbk,shortId:$sid,
           spiderX:"/"}}}]}' >"$2"
}

_emit_hy2_yaml() { # outfile
  _pin=$(cert_pin_sha256 "$TLS_DIR/cert.pem" 2>/dev/null || true)
  {
    printf 'server: %s:%s\n' "$PUBLIC_IP" "${HY2_PORT:-443}"
    printf 'auth: %s\n' "$HY2_PASSWORD"
    printf 'tls:\n  sni: %s\n' "$PUBLIC_IP"
    if [ -n "$_pin" ] && [ "${HY2_CERT_EFFECTIVE:-self}" = self ]; then
      # 官方 hysteria 客户端：insecure 关闭 CA 校验 + pinSHA256 钉指纹（实测必须两者同时给）
      printf '  insecure: true\n  pinSHA256: %s\n' "$_pin"
    else
      printf '  insecure: false\n'
    fi
    printf 'socks5:\n  listen: 127.0.0.1:%s\n' "${SELFTEST_HY2_SOCKS:-10811}"
    printf 'fastOpen: true\n'
  } >"$1"
}

_emit_mihomo() { # outfile
  {
    printf 'proxies:\n'
    if [ "${ENABLE_XHTTP:-0}" = 1 ] && [ "${ARGO_MODE:-temp}" = temp ]; then
      printf '  - name: %s-ws-h2\n' "${NODE_NAME:-node}"
      printf '    type: vless\n    server: %s\n    port: 443\n    uuid: %s\n' "$ARGO_DOMAIN_RESOLVED" "$UUID"
      printf '    network: ws\n    tls: true\n    servername: %s\n' "$ARGO_DOMAIN_RESOLVED"
      printf '    client-fingerprint: chrome\n    alpn: [h2]\n'
      printf '    ws-opts:\n      path: %s\n      headers:\n        Host: %s\n' "${WS_PATH:-/ws}" "$ARGO_DOMAIN_RESOLVED"
    fi
    if [ "${ENABLE_XHTTP:-0}" = 1 ] && [ "${ARGO_MODE:-temp}" = token ]; then
      for _a in h2 h3; do
        printf '  - name: %s-xhttp-%s\n' "${NODE_NAME:-node}" "$_a"
        printf '    type: vless\n    server: %s\n    port: 443\n    uuid: %s\n' "$ARGO_DOMAIN_RESOLVED" "$UUID"
        printf '    network: xhttp\n    tls: true\n    servername: %s\n' "$ARGO_DOMAIN_RESOLVED"
        printf '    client-fingerprint: chrome\n    alpn: [%s]\n' "$_a"
        printf '    xhttp-opts:\n      path: %s\n      host: %s\n      mode: auto\n' "${XHTTP_PATH:-/xhttp}" "$ARGO_DOMAIN_RESOLVED"
      done
    fi
    if [ "${ENABLE_XHTTP:-0}" = 1 ] && [ "${ARGO_MODE:-temp}" = off ]; then
      printf '  - name: %s-xhttp\n' "${NODE_NAME:-node}"
      printf '    type: vless\n    server: %s\n    port: %s\n    uuid: %s\n' "$PUBLIC_IP" "${XHTTP_PORT:-2087}" "$UUID"
      printf '    network: xhttp\n    tls: false\n'
      printf '    xhttp-opts:\n      path: %s\n      mode: auto\n' "${XHTTP_PATH:-/xhttp}"
    fi
    if [ "${ENABLE_REALITY:-0}" = 1 ]; then
      printf '  - name: %s-reality\n' "${NODE_NAME:-node}"
      printf '    type: vless\n    server: %s\n    port: %s\n    uuid: %s\n' "$PUBLIC_IP" "${REALITY_PORT:-443}" "$UUID"
      printf '    network: tcp\n    udp: true\n    tls: true\n    flow: xtls-rprx-vision\n'
      printf '    servername: %s\n    client-fingerprint: chrome\n' "${REALITY_SNI:-dm.toutiao.com}"
      printf '    reality-opts:\n      public-key: %s\n      short-id: %s\n' "$REALITY_PUB" "$REALITY_SHORTID"
    fi
    if [ "${ENABLE_HY2:-0}" = 1 ]; then
      printf '  - name: %s-hy2\n' "${NODE_NAME:-node}"
      printf '    type: hysteria2\n    server: %s\n    port: %s\n    password: %s\n' "$PUBLIC_IP" "${HY2_PORT:-443}" "$HY2_PASSWORD"
      printf '    sni: %s\n    skip-cert-verify: true\n' "$PUBLIC_IP"
    fi
    printf 'proxy-groups:\n  - name: auto\n    type: url-test\n    url: https://www.gstatic.com/generate_204\n    interval: 300\n    proxies:\n'
    _names=
    [ "${ENABLE_XHTTP:-0}" = 1 ] && [ "${ARGO_MODE:-temp}" = token ] && _names="$_names, ${NODE_NAME}-xhttp-h2, ${NODE_NAME}-xhttp-h3"
    [ "${ENABLE_XHTTP:-0}" = 1 ] && [ "${ARGO_MODE:-temp}" = temp ] && _names="$_names, ${NODE_NAME}-ws-h2"
    [ "${ENABLE_XHTTP:-0}" = 1 ] && [ "${ARGO_MODE:-temp}" = off ] && _names="$_names, ${NODE_NAME}-xhttp"
    [ "${ENABLE_REALITY:-0}" = 1 ] && _names="$_names, ${NODE_NAME}-reality"
    [ "${ENABLE_HY2:-0}" = 1 ] && _names="$_names, ${NODE_NAME}-hy2"
    printf '%s\n' "$_names" | tr ',' '\n' | sed 's/^ *//' | grep -v '^$' | sed 's/^/      - /'
    printf 'rules:\n  - GEOIP,CN,DIRECT\n  - MATCH,auto\n'
  } >"$1"
}

emit_clients() {
  mkdir -p "$CLI_DIR"
  # 先清掉上一次部署留下的节点文件，避免切换模式后自检/订阅里混入失效节点
  rm -f "$CLI_DIR"/client-*.json "$CLI_DIR"/hy2-client.yaml "$CLI_DIR"/mihomo.yaml
  : >"$CLI_DIR/sub.txt"
  if [ "${ENABLE_XHTTP:-0}" = 1 ]; then
    case "${ARGO_MODE:-temp}" in
      off)
        _emit_xhttp_json h2 "${SELFTEST_H2_SOCKS:-10808}" "$CLI_DIR/client-xhttp-h2.json"
        uri_xhttp "" h2 >>"$CLI_DIR/sub.txt"
        ;;
      token)
        _emit_xhttp_json h2 "${SELFTEST_H2_SOCKS:-10808}" "$CLI_DIR/client-xhttp-h2.json"
        _emit_xhttp_json h3 "${SELFTEST_H3_SOCKS:-10809}" "$CLI_DIR/client-xhttp-h3.json"
        uri_xhttp "$ARGO_DOMAIN_RESOLVED" h2 >>"$CLI_DIR/sub.txt"
        uri_xhttp "$ARGO_DOMAIN_RESOLVED" h3 >>"$CLI_DIR/sub.txt"
        ;;
      *)
        if [ "${ENABLE_WS:-0}" = 1 ]; then
          _emit_ws_json "${SELFTEST_H2_SOCKS:-10808}" "$CLI_DIR/client-ws.json"
          uri_ws "$ARGO_DOMAIN_RESOLVED" >>"$CLI_DIR/sub.txt"
        else
          _emit_xhttp_json h2 "${SELFTEST_H2_SOCKS:-10808}" "$CLI_DIR/client-xhttp-h2.json"
          _emit_xhttp_json h3 "${SELFTEST_H3_SOCKS:-10809}" "$CLI_DIR/client-xhttp-h3.json"
          uri_xhttp "$ARGO_DOMAIN_RESOLVED" h2 >>"$CLI_DIR/sub.txt"
          uri_xhttp "$ARGO_DOMAIN_RESOLVED" h3 >>"$CLI_DIR/sub.txt"
        fi
        ;;
    esac
  fi
  [ "${ENABLE_REALITY:-0}" = 1 ] && {
    _emit_reality_json "${SELFTEST_REALITY_SOCKS:-10810}" "$CLI_DIR/client-reality.json"
    uri_reality >>"$CLI_DIR/sub.txt"
  }
  [ "${ENABLE_HY2:-0}" = 1 ] && {
    _emit_hy2_yaml "$CLI_DIR/hy2-client.yaml"
    uri_hy2 >>"$CLI_DIR/sub.txt"
  }
  _emit_mihomo "$CLI_DIR/mihomo.yaml"
  chmod 600 "$CLI_DIR"/*.json "$CLI_DIR"/*.yaml "$CLI_DIR"/sub.txt 2>/dev/null || true
  for _f in "$CLI_DIR"/client-*.json; do
    [ -f "$_f" ] || continue
    test_config "$_f" || die "客户端配置未通过校验: $_f"
  done
}

# ---------- 服务托管 ----------
detect_init() {
  INIT_SYS=${INIT_SYS_OVERRIDE:-}
  if [ -n "$INIT_SYS" ]; then return 0; fi
  if [ -d /run/systemd/system ] && command_exists systemctl; then
    INIT_SYS=systemd
  elif command_exists rc-service; then
    INIT_SYS=openrc
  else
    INIT_SYS=none
  fi
}

port_in_use() { # tcp|udp port
  _pu=$1
  _pp=$2
  _hex=$(printf '%04X' "$_pp" 2>/dev/null) || return 1
  case "$_pu" in
    tcp) _files="/proc/net/tcp /proc/net/tcp6" ;;
    udp) _files="/proc/net/udp /proc/net/udp6" ;;
    *) return 1 ;;
  esac
  for _pf in $_files; do
    [ -r "$_pf" ] || continue
    if awk -v want=":$_hex" 'NR>1 { split($2, a, ":"); if (":" a[2] == want && $4 == "0A") f = 1 } END { exit f ? 0 : 1 }' "$_pf"; then
      return 0
    fi
  done
  return 1
}

_svc_body_systemd() { # name cmd
  {
    printf '[Unit]\nDescription=xray-stack %s\nAfter=network-online.target\nWants=network-online.target\n\n' "$1"
    printf '[Service]\nType=simple\nExecStart=%s\nRestart=always\nRestartSec=5\nLimitNOFILE=1048576\n' "$2"
    [ -n "${SVC_LOG:-}" ] && printf 'StandardOutput=append:%s\nStandardError=append:%s\n' "$SVC_LOG" "$SVC_LOG"
    printf '\n[Install]\nWantedBy=multi-user.target\n'
  }
}

svc_install() { # name cmdline（cmdline 内不能含空格参数，token/path 均满足）
  _sname=$1
  shift
  _cmd=$*
  [ -n "$_cmd" ] || die "svc_install 需要可执行命令"
  case "${INIT_SYS:-none}" in
    systemd)
      _svc_body_systemd "$_sname" "$_cmd" >"/etc/systemd/system/$_sname.service"
      chmod 600 "/etc/systemd/system/$_sname.service" # 固定隧道 token 在 ExecStart 里
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable "$_sname" >/dev/null 2>&1 || true
      systemctl restart "$_sname" >/dev/null 2>&1 || log_warn "$_sname 启动失败（journalctl -u $_sname 查看）"
      ;;
    openrc)
      set -- $_cmd
      _bin=$1
      shift
      {
        printf '#!/sbin/openrc-run\n'
        printf 'description="xray-stack %s"\n' "$_sname"
        printf 'command="%s"\n' "$_bin"
        _args=
        for _a in "$@"; do _args="$_args $_a"; done
        printf 'command_args="%s"\n' "${_args# }"
        printf 'command_background="yes"\npidfile="/run/%s.pid"\n' "$_sname"
        [ -n "${SVC_LOG:-}" ] && printf 'output_log="%s"\nerror_log="%s"\n' "$SVC_LOG" "$SVC_LOG"
        printf 'depend() {\n\tneed net\n\tafter firewall\n}\n'
      } >"/etc/init.d/$_sname"
      chmod 700 "/etc/init.d/$_sname" # 可能含 token，仅 root
      rc-update add "$_sname" default >/dev/null 2>&1 || true
      rc-service "$_sname" restart >/dev/null 2>&1 || rc-service "$_sname" start >/dev/null 2>&1 || log_warn "$_sname 启动失败（rc-service $_sname status 查看）"
      ;;
    fake)
      mkdir -p "${FAKE_INIT_DIR:?FAKE_INIT_DIR 未设置}"
      _svc_body_systemd "$_sname" "$_cmd" >"$FAKE_INIT_DIR/$_sname.service"
      ;;
    none)
      mkdir -p "$STACK_DIR"
      nohup $_cmd >>"${SVC_LOG:-/dev/null}" 2>&1 &
      printf '%s\n' "$!" >"$STACK_DIR/$_sname.pid"
      ;;
  esac
}

svc_stop() {
  case "${INIT_SYS:-none}" in
    systemd) systemctl stop "$1" >/dev/null 2>&1 || true ;;
    openrc) rc-service "$1" stop >/dev/null 2>&1 || true ;;
    fake | none)
      if [ -f "$STACK_DIR/$1.pid" ]; then
        kill "$(cat "$STACK_DIR/$1.pid")" 2>/dev/null || true
        rm -f "$STACK_DIR/$1.pid"
      fi
      ;;
  esac
}

svc_running() {
  case "${INIT_SYS:-none}" in
    systemd) systemctl is-active --quiet "$1" 2>/dev/null ;;
    openrc) rc-service "$1" status >/dev/null 2>&1 ;;
    fake | none)
      [ -f "$STACK_DIR/$1.pid" ] || return 1
      kill -0 "$(cat "$STACK_DIR/$1.pid")" 2>/dev/null
      ;;
  esac
}

svc_remove() {
  svc_stop "$1"
  case "${INIT_SYS:-none}" in
    systemd)
      systemctl disable "$1" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/$1.service"
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-update del "$1" default >/dev/null 2>&1 || true
      rm -f "/etc/init.d/$1"
      ;;
    fake) rm -f "${FAKE_INIT_DIR:?}/$1.service" ;;
    none) rm -f "$STACK_DIR/$1.pid" ;;
  esac
}

preflight() {
  detect_init
  if svc_running xray; then
    log_info "检测到已部署的 xray 服务，先停止以便重装"
    svc_stop xray
  fi
  if [ "${ENABLE_XHTTP:-0}" = 1 ] && [ "${ARGO_MODE:-temp}" = off ]; then
    port_in_use tcp "${XHTTP_PORT:-2087}" && die "端口 ${XHTTP_PORT}/tcp 已被占用（用 XHTTP_PORT 换一个）"
  fi
  if [ "${ENABLE_REALITY:-0}" = 1 ]; then
    port_in_use tcp "${REALITY_PORT:-443}" && die "端口 ${REALITY_PORT}/tcp 已被占用（用 REALITY_PORT 换一个）"
  fi
  if [ "${ENABLE_HY2:-0}" = 1 ]; then
    port_in_use udp "${HY2_PORT:-443}" && die "端口 ${HY2_PORT}/udp 已被占用（用 HY2_PORT 换一个）"
  fi
  if [ "${ENABLE_REALITY:-0}" = 1 ] && ! check_reality_dest "${REALITY_SNI:-dm.toutiao.com}"; then
    log_warn "REALITY 目标 ${REALITY_SNI} 未通过 TLS1.3+h2 探测，可能握手失败（可换 REALITY_SNI）"
  fi
}

# ---------- 配置采集与状态 ----------
usage() {
  cat <<'EOF'
xray-stack —— Xray 多协议一键部署（VLESS-XHTTP+Argo / VLESS-TCP-REALITY-Vision / Hysteria2）

用法: xray-stack.sh [选项]
  (无选项)        交互菜单
  --yes, -y       不交互，全部用环境变量/默认值
  --info          打印当前节点链接（不重装）
  --selftest      端到端自检每个已启用节点
  --uninstall     卸载（保留证书目录）
  --purge         卸载并删除证书
  --help, -h      显示本帮助

环境变量:
  XHTTP=yes|no            启用 VLESS-XHTTP（默认 yes）
  REALITY=yes|no          启用 VLESS-TCP-REALITY-Vision（默认 yes）
  HY2=yes|no              启用 Hysteria2（默认 yes）
  ARGO_MODE=temp|token|off  隧道模式（默认 temp）
  ARGO_AUTH=<token>       固定隧道 token
  ARGO_DOMAIN=<host>      固定隧道域名
  ARGO_PROTO=auto|quic|http2  连接器协议（默认 auto：quic 优先，15s 不通回退 http2）
  REALITY_SNI=<host>      REALITY 目标站点（默认 dm.toutiao.com）
  XHTTP_PORT=2087         XHTTP 本机端口（token 模式会按面板 ingress 自动对齐）
  REALITY_PORT=443        REALITY 端口
  HY2_PORT=443            Hysteria2 端口
  HY2_CERT=self|le        证书模式（默认 self 自签）
  TEMP_TRANSPORT=ws|xhttp 临时隧道暴露方式（默认 ws；quick tunnel 下 xhttp 实测不可用）
  LE_EMAIL=<mail>         ACME 邮箱（默认 ops@no-reply.dev；LE 禁用 example.com）
  NODE_NAME=<name>        节点名（默认主机名）
EOF
}

MODE=install
parse_args() {
  for _arg in "$@"; do
    case "$_arg" in
      --yes | -y) YES=1 ;;
      --info) MODE=info ;;
      --selftest) MODE=selftest ;;
      --uninstall) MODE=uninstall ;;
      --purge) MODE=uninstall; PURGE=1 ;;
      --help | -h) usage; exit 0 ;;
      *) die "未知参数: $_arg（--help 查看用法）" ;;
    esac
  done
}

load_state() {
  [ -f "$STATE" ] || return 0
  _tmp="$STATE.parsed"
  grep -E '^[A-Z0-9_]+=' "$STATE" >"$_tmp" 2>/dev/null || : >"$_tmp"
  while IFS='=' read -r _k _v; do
    case "$_k" in
      '' | *[!A-Z0-9_]*) continue ;;
    esac
    eval "_cur=\${$_k:-}"
    [ -n "$_cur" ] || eval "export $_k=\$_v"
  done <"$_tmp"
  rm -f "$_tmp"
}

save_state() {
  mkdir -p "$STACK_DIR"
  {
    for _k in ENABLE_XHTTP ENABLE_REALITY ENABLE_HY2 ARGO_MODE ARGO_DOMAIN ARGO_PROTO ARGO_PROTO_USED \
      XHTTP_PORT XHTTP_PATH REALITY_PORT REALITY_SNI REALITY_PUB REALITY_SHORTID \
      HY2_PORT HY2_CERT HY2_CERT_EFFECTIVE LE_EMAIL NODE_NAME PUBLIC_IP UUID \
      WS_PORT WS_PATH ENABLE_WS TEMP_TRANSPORT; do
      eval "_v=\${$_k:-}"
      [ -n "$_v" ] && printf '%s=%s\n' "$_k" "$_v"
    done
  } >"$STATE.tmp"
  chmod 600 "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

_yesno() { # 值 → 1/0，非法值返回 2
  case "$1" in
    yes | y | 1 | true) echo 1 ;;
    no | n | 0 | false) echo 0 ;;
    *) return 2 ;;
  esac
}

collect_config() {
  detect_os
  detect_init
  NODE_NAME=${NODE_NAME:-$(hostname 2>/dev/null || echo node)}
  if [ "${YES:-0}" = 1 ]; then
    ENABLE_XHTTP=$(_yesno "${XHTTP:-yes}") || die "XHTTP 只能是 yes/no"
    ENABLE_REALITY=$(_yesno "${REALITY:-yes}") || die "REALITY 只能是 yes/no"
    ENABLE_HY2=$(_yesno "${HY2:-yes}") || die "HY2 只能是 yes/no"
  else
    [ -t 0 ] || die "当前不是交互终端：请加 --yes 并用环境变量指定协议"
    _menu_toggle
  fi
  [ "$((ENABLE_XHTTP + ENABLE_REALITY + ENABLE_HY2))" -gt 0 ] || die "至少要启用一个协议"

  ARGO_MODE=${ARGO_MODE:-temp}
  case "$ARGO_MODE" in temp | token | off) ;; *) die "ARGO_MODE 只能是 temp/token/off" ;; esac
  ARGO_PROTO=${ARGO_PROTO:-auto}
  case "$ARGO_PROTO" in auto | quic | http2) ;; *) die "ARGO_PROTO 只能是 auto/quic/http2" ;; esac
  if [ "$ENABLE_XHTTP" = 1 ] && [ "$ARGO_MODE" = token ]; then
    [ -n "${ARGO_AUTH:-}" ] || die "ARGO_MODE=token 需要 ARGO_AUTH"
    [ -n "${ARGO_DOMAIN:-}" ] || die "ARGO_MODE=token 需要 ARGO_DOMAIN"
  fi

  HY2_CERT=${HY2_CERT:-self}
  case "$HY2_CERT" in self | le) ;; *) die "HY2_CERT 只能是 self/le" ;; esac
  LE_EMAIL=${LE_EMAIL:-ops@no-reply.dev}

  REALITY_SNI=${REALITY_SNI:-dm.toutiao.com}
  XHTTP_PORT=${XHTTP_PORT:-2087}
  REALITY_PORT=${REALITY_PORT:-443}
  HY2_PORT=${HY2_PORT:-443}
  XHTTP_PATH=${XHTTP_PATH:-/$(rand_hex 6)}
  WS_PATH=${WS_PATH:-/$(rand_hex 6)}
  WS_PORT=${WS_PORT:-$((XHTTP_PORT + 1))}
  TEMP_TRANSPORT=${TEMP_TRANSPORT:-ws}
  case "$TEMP_TRANSPORT" in xhttp | ws) ;; *) die "TEMP_TRANSPORT 只能是 xhttp/ws" ;; esac
  if [ "${ENABLE_XHTTP:-0}" = 1 ] && [ "$ARGO_MODE" = temp ] && [ "$TEMP_TRANSPORT" = ws ]; then
    ENABLE_WS=1
    log_info "临时隧道用 WS 暴露（实测 quick tunnel 会把 XHTTP 下行整段缓冲到响应结束，见 docs/verification/）"
  else
    ENABLE_WS=0
  fi
  export ENABLE_XHTTP ENABLE_REALITY ENABLE_HY2 ARGO_MODE ARGO_PROTO HY2_CERT LE_EMAIL
  export REALITY_SNI XHTTP_PORT REALITY_PORT HY2_PORT XHTTP_PATH NODE_NAME WS_PORT WS_PATH ENABLE_WS TEMP_TRANSPORT
}

_menu_toggle() {
  ENABLE_XHTTP=1
  ENABLE_REALITY=1
  ENABLE_HY2=1
  while :; do
    printf '\n当前选择：\n'
    printf '  1) VLESS-XHTTP（Argo 隧道，输出 h2/h3 两组节点）: %s\n' "$([ "$ENABLE_XHTTP" = 1 ] && echo 启用 || echo 关闭)"
    printf '  2) VLESS-TCP-REALITY-Vision（%s）        : %s\n' "${REALITY_SNI:-dm.toutiao.com}" "$([ "$ENABLE_REALITY" = 1 ] && echo 启用 || echo 关闭)"
    printf '  3) Hysteria2（%s 证书）                   : %s\n' "${HY2_CERT:-self}" "$([ "$ENABLE_HY2" = 1 ] && echo 启用 || echo 关闭)"
    printf '输入 1/2/3 切换，a 全选，n 全不选，回车确认：'
    read -r _ans || _ans=
    case "$_ans" in
      1) [ "$ENABLE_XHTTP" = 1 ] && ENABLE_XHTTP=0 || ENABLE_XHTTP=1 ;;
      2) [ "$ENABLE_REALITY" = 1 ] && ENABLE_REALITY=0 || ENABLE_REALITY=1 ;;
      3) [ "$ENABLE_HY2" = 1 ] && ENABLE_HY2=0 || ENABLE_HY2=1 ;;
      a | A) ENABLE_XHTTP=1; ENABLE_REALITY=1; ENABLE_HY2=1 ;;
      n | N) ENABLE_XHTTP=0; ENABLE_REALITY=0; ENABLE_HY2=0 ;;
      '') break ;;
      *) log_warn "不认识的输入: $_ans" ;;
    esac
  done
  if [ "$ENABLE_XHTTP" = 1 ]; then
    printf 'Argo 模式：1=临时隧道 2=固定隧道(token) 3=不用隧道[1]：'
    read -r _ans || _ans=
    case "$_ans" in
      2)
        ARGO_MODE=token
        [ -n "${ARGO_AUTH:-}" ] || {
          printf 'ARGO_AUTH(token)：'
          read -r ARGO_AUTH || ARGO_AUTH=
        }
        [ -n "${ARGO_DOMAIN:-}" ] || {
          printf 'ARGO_DOMAIN：'
          read -r ARGO_DOMAIN || ARGO_DOMAIN=
        }
        ;;
      3) ARGO_MODE=off ;;
      *) ARGO_MODE=temp ;;
    esac
  fi
  if [ "$ENABLE_HY2" = 1 ]; then
    printf 'Hysteria2 证书：1=自签 2=真实 IP 证书(LE)[1]：'
    read -r _ans || _ans=
    case "$_ans" in 2) HY2_CERT=le ;; *) HY2_CERT=self ;; esac
  fi
}

# ---------- 自检 ----------
_wait_port() { # tcp|udp port timeout_s
  _i=0
  while [ "$_i" -lt "${3:-10}" ]; do
    port_in_use "$1" "$2" && return 0
    sleep 1
    _i=$((_i + 1))
  done
  return 1
}

fetch_hysteria() {
  if [ -n "${HYSTERIA_BIN:-}" ] && [ -x "$HYSTERIA_BIN" ]; then return 0; fi
  if command_exists hysteria; then
    HYSTERIA_BIN=$(command -v hysteria)
    return 0
  fi
  case "$(uname -m)" in
    x86_64 | amd64) _ha=amd64 ;;
    aarch64 | arm64) _ha=arm64 ;;
    *) die "官方 hysteria 客户端不支持该架构: $(uname -m)" ;;
  esac
  mkdir -p "$BIN_DIR"
  log_info "下载官方 hysteria 客户端（自检用，约 24MB）"
  fetch_dl "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$_ha" "$BIN_DIR/hysteria" >/dev/null \
    || die "hysteria 客户端下载失败"
  chmod +x "$BIN_DIR/hysteria"
  HYSTERIA_BIN="$BIN_DIR/hysteria"
  "$HYSTERIA_BIN" version >/dev/null 2>&1 || die "hysteria 客户端无法执行"
}

_probe_curl() { # socks_port
  _code=$(curl -s -x "socks5h://127.0.0.1:$1" -m 20 -o /dev/null -w '%{http_code}' \
    https://www.gstatic.com/generate_204 2>/dev/null || true)
  printf '%s' "${_code:-000}"
}

probe_node() { # client.json socks_port
  _pcf=$1
  _psp=$2
  _ptmp="$STACK_DIR/.probe-$$.json"
  _plog="$STACK_DIR/.probe-$$.log"
  jq --argjson p "$_psp" '(.inbounds[0].port) = $p' "$_pcf" >"$_ptmp" || return 1
  "$(_xray)" run -c "$_ptmp" >"$_plog" 2>&1 &
  _ppid=$!
  if ! _wait_port tcp "$_psp" 10; then
    kill "$_ppid" 2>/dev/null || true
    wait "$_ppid" 2>/dev/null || true
    rm -f "$_ptmp"
    printf '000 0 -\n'
    return 1
  fi
  _pst=$(date +%s)
  _pcode=$(_probe_curl "$_psp")
  _pcost=$(($(date +%s) - _pst))
  _pip=$(curl -s -x "socks5h://127.0.0.1:$_psp" -m 15 https://api.ipify.org 2>/dev/null || true)
  kill "$_ppid" 2>/dev/null || true
  wait "$_ppid" 2>/dev/null || true
  rm -f "$_ptmp"
  printf '%s %s %s\n' "$_pcode" "$_pcost" "${_pip:-?}"
  [ "$_pcode" = 204 ]
}

probe_hy2() { # socks_port
  _hsp=$1
  fetch_hysteria || return 1
  _hyaml="$STACK_DIR/.hy2-probe-$$.yaml"
  _hlog="$STACK_DIR/.hy2-probe-$$.log"
  sed "s|^  listen: 127.0.0.1:[0-9]*|  listen: 127.0.0.1:$_hsp|" "$CLI_DIR/hy2-client.yaml" >"$_hyaml" || return 1
  "$HYSTERIA_BIN" client -c "$_hyaml" >"$_hlog" 2>&1 &
  _hpid=$!
  if ! _wait_port tcp "$_hsp" 10; then
    kill "$_hpid" 2>/dev/null || true
    wait "$_hpid" 2>/dev/null || true
    printf '000 0 -\n'
    return 1
  fi
  _hst=$(date +%s)
  _hcode=$(_probe_curl "$_hsp")
  _hcost=$(($(date +%s) - _hst))
  _hip=$(curl -s -x "socks5h://127.0.0.1:$_hsp" -m 15 https://api.ipify.org 2>/dev/null || true)
  kill "$_hpid" 2>/dev/null || true
  wait "$_hpid" 2>/dev/null || true
  rm -f "$_hyaml"
  printf '%s %s %s\n' "$_hcode" "$_hcost" "${_hip:-?}"
  [ "$_hcode" = 204 ]
}

_selftest_row() { # name result cost ip
  printf '  %-24s %-6s %-6s %s\n' "$1" "$2" "$3"s "$4"
}

selftest_nodes() { # 输出 "name client_json socks_port"
  [ -f "$CLI_DIR/client-ws.json" ] && echo "ws-h2 $CLI_DIR/client-ws.json 10808"
  [ -f "$CLI_DIR/client-xhttp-h2.json" ] && echo "xhttp-h2 $CLI_DIR/client-xhttp-h2.json 10808"
  [ -f "$CLI_DIR/client-xhttp-h3.json" ] && echo "xhttp-h3 $CLI_DIR/client-xhttp-h3.json 10809"
  [ -f "$CLI_DIR/client-reality.json" ] && echo "reality $CLI_DIR/client-reality.json 10810"
  return 0
}

selftest() {
  load_state
  detect_init
  [ -d "$CLI_DIR" ] || die "尚未部署（$CLI_DIR 不存在）"
  _fail=0
  printf '\n节点                        结果    耗时   出口 IP\n'
  printf '%s\n' '------------------------------------------------------------'
  selftest_nodes >"$STACK_DIR/.selftest.nodes"
  while read -r _nname _nj _nport; do
    [ -n "$_nname" ] || continue
    _ln=$(probe_node "$_nj" "$_nport" || true)
    set -- $_ln
    _selftest_row "$_nname" "$([ "$1" = 204 ] && echo OK || echo FAIL)" "$2" "$3"
    [ "$1" = 204 ] || _fail=$((_fail + 1))
  done <"$STACK_DIR/.selftest.nodes"
  rm -f "$STACK_DIR/.selftest.nodes"
  if [ -f "$CLI_DIR/hy2-client.yaml" ]; then
    _ln=$(probe_hy2 10811 || true)
    set -- $_ln
    _selftest_row "hy2" "$([ "$1" = 204 ] && echo OK || echo FAIL)" "$2" "$3"
    [ "$1" = 204 ] || _fail=$((_fail + 1))
  fi
  printf '%s\n' '------------------------------------------------------------'
  if [ "$_fail" -gt 0 ]; then
    log_err "自检失败 $_fail 项"
    [ -f "$STACK_DIR/.probe-$$.log" ] && tail -15 "$STACK_DIR/.probe-$$.log" >&2
    return 1
  fi
  log_info "自检全部通过"
}

# ---------- 卸载 / 信息 / 安装主流程 ----------
do_uninstall() {
  detect_init
  svc_stop xray 2>/dev/null || true
  svc_stop argo 2>/dev/null || true
  svc_remove xray 2>/dev/null || true
  svc_remove argo 2>/dev/null || true
  argo_stop 2>/dev/null || true
  rm -f /etc/cron.d/xray-stack-renew
  if [ -f /etc/crontabs/root ]; then
    grep -v 'xray-stack' /etc/crontabs/root >"$STACK_DIR/.crontab.tmp" 2>/dev/null || : >"$STACK_DIR/.crontab.tmp"
    cat "$STACK_DIR/.crontab.tmp" >/etc/crontabs/root
    rm -f "$STACK_DIR/.crontab.tmp"
  fi
  if [ -f "$STACK_DIR/.installed_bins" ]; then
    while read -r _b; do
      [ -n "$_b" ] && rm -f "$_b"
    done <"$STACK_DIR/.installed_bins"
  fi
  if [ "${PURGE:-0}" = 1 ]; then
    rm -rf "$STACK_DIR"
    log_info "已卸载（含证书）"
  else
    if [ -d "$TLS_DIR" ]; then
      _keep="$(dirname "$STACK_DIR")/.xray-stack-keep-certs.$$"
      rm -rf "$_keep"
      mv "$TLS_DIR" "$_keep"
      rm -rf "$STACK_DIR"
      mkdir -p "$STACK_DIR"
      mv "$_keep" "$TLS_DIR"
      log_info "已卸载（证书保留在 $TLS_DIR）"
    else
      rm -rf "$STACK_DIR"
      mkdir -p "$STACK_DIR"
      log_info "已卸载"
    fi
  fi
}

do_info() {
  load_state
  if [ -s "${CLI_DIR:-/nonexistent}/sub.txt" ]; then
    printf '\n===== 节点链接 =====\n'
    cat "$CLI_DIR/sub.txt"
    printf '\n客户端配置: %s\nMihomo: %s\n' "$CLI_DIR" "$CLI_DIR/mihomo.yaml"
  else
    log_warn "未找到已部署的节点信息（$CLI_DIR/sub.txt）"
  fi
  detect_init
  [ -n "${ARGO_PROTO_USED:-}" ] && printf 'Argo 连接器（上次安装实测）: %s\n' "$ARGO_PROTO_USED"
  printf '\n服务状态: xray=%s argo=%s\n' \
    "$(svc_running xray && echo running || echo stopped)" \
    "$(svc_running argo && echo running || echo stopped)"
}

_record_bin() {
  mkdir -p "$STACK_DIR"
  printf '%s\n' "$1" >>"$STACK_DIR/.installed_bins"
}

_ensure_keys() {
  if [ -z "${UUID:-}" ]; then UUID=$(gen_uuid); fi
  if [ "${ENABLE_REALITY:-0}" = 1 ] && { [ -z "${REALITY_PRIV:-}" ] || [ -z "${REALITY_PUB:-}" ]; }; then
    eval "$(gen_x25519)" || die "REALITY 密钥生成失败"
    REALITY_PRIV=$PRIVATE_KEY
    REALITY_PUB=$PUBLIC_KEY
  fi
  [ -n "${REALITY_SHORTID:-}" ] || REALITY_SHORTID=$(gen_shortid)
  if [ "${ENABLE_HY2:-0}" = 1 ] && [ -z "${HY2_PASSWORD:-}" ]; then HY2_PASSWORD=$(gen_password); fi
  export UUID REALITY_PRIV REALITY_PUB REALITY_SHORTID HY2_PASSWORD
}

_ensure_cert() {
  [ "${ENABLE_HY2:-0}" = 1 ] || return 0
  mkdir -p "$TLS_DIR"
  if [ "${HY2_CERT:-self}" = le ]; then
    log_info "用 lego 申请 LE shortlived IP 证书（HTTP-01，需要 80 端口可达）…"
    if gen_le_cert "$PUBLIC_IP" "$TLS_DIR" "${LE_EMAIL:-ops@no-reply.dev}"; then
      HY2_CERT_EFFECTIVE=le
      install_renew_cron "$PUBLIC_IP"
      log_info "LE 证书签发成功（有效期约 6 天，已加每 3 天续期）"
      return 0
    fi
    log_err "LE 证书签发失败，回退为自签证书（hy2 仍可用，客户端需 pin 或跳过校验）"
    HY2_CERT_EFFECTIVE=self
  else
    HY2_CERT_EFFECTIVE=self
  fi
  if [ ! -s "$TLS_DIR/cert.pem" ] || [ ! -s "$TLS_DIR/key.pem" ]; then
    gen_self_cert "$PUBLIC_IP" "$TLS_DIR" "$PUBLIC_IP"
    log_info "已生成自签证书（SAN=IP:$PUBLIC_IP）"
  fi
}

_print_summary() {
  printf '\n================ 部署完成 ================\n'
  printf '节点名      : %s\n' "${NODE_NAME:-node}"
  printf '公网 IP     : %s\n' "$PUBLIC_IP"
  printf 'Xray 配置   : %s\n' "$CONFIG"
  [ -s "$CLI_DIR/sub.txt" ] && {
    printf '\n----- 分享链接 -----\n'
    cat "$CLI_DIR/sub.txt"
  }
  [ -s "$CLI_DIR/mihomo.yaml" ] && printf '\nMihomo 配置: %s\n' "$CLI_DIR/mihomo.yaml"
  [ -s "$CLI_DIR/hy2-client.yaml" ] && printf 'Hysteria2 客户端: %s\n' "$CLI_DIR/hy2-client.yaml"
  printf '\n自检: %s --selftest\n' "$SELF_DIR/$(basename "$0")"
  printf '==========================================\n\n'
}

install_all() {
  need_root
  install_deps
  detect_arch >/dev/null
  detect_init
  log_info "环境: OS=${OS_ID} arch=${ARCH_RAW} init=${INIT_SYS}"
  fetch_core
  _record_bin "$XRAY_BIN"
  _record_bin "$CLOUDFLARED_BIN"

  PUBLIC_IP=${PUBLIC_IP:-$(public_ipv4)}
  [ -n "$PUBLIC_IP" ] || die "无法获取公网 IPv4（可用 PUBLIC_IP 指定）"
  if udp_egress_ok; then UDP_EGRESS_OK=1; else
    UDP_EGRESS_OK=0
    log_warn "UDP 出站探测失败：Argo 将直接用 http2，Hysteria2 可能不可用"
  fi
  export UDP_EGRESS_OK PUBLIC_IP

  if [ "${ENABLE_XHTTP:-0}" = 1 ] && [ "${ARGO_MODE:-temp}" = token ]; then
    argo_probe_ingress || log_warn "继续使用 XHTTP_PORT=${XHTTP_PORT}"
  fi
  preflight

  _ensure_keys
  _ensure_cert
  build_config "$CONFIG"
  log_info "配置已通过 xray 校验: $CONFIG"

  SVC_LOG='' svc_install xray "$XRAY_BIN run -c $CONFIG"
  svc_running xray || die "xray 服务未启动（查日志: journalctl -u xray / rc-service xray status）"
  log_info "xray 服务已启动"

  if [ "${ENABLE_XHTTP:-0}" = 1 ] && [ "${ARGO_MODE:-temp}" != off ]; then
    argo_start
    svc_running argo || [ "${INIT_SYS:-none}" = none ] || die "argo 连接器未运行"
  fi

  emit_clients
  save_state
  _print_summary
}

main() {
  # shellcheck disable=SC2034
  MAIN_RAN=1
  parse_args "$@"
  case "$MODE" in
    info)
      do_info
      return 0
      ;;
    uninstall)
      need_root
      do_uninstall
      return 0
      ;;
    selftest)
      need_root
      selftest
      return $?
      ;;
  esac
  need_root
  load_state
  collect_config
  install_all
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
  # shellcheck disable=SC2034
  ARCH=$(pick_xray_asset "$ARCH_RAW") # 供调用方读取
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
