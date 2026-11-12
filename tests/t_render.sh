#!/bin/sh
# t_render：三协议 jq 模板、合成、xray 配置校验
. "$(dirname "$0")/lib.sh"
echo "== t_render =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/render-$$"
export STACK_DIR
rm -rf "$STACK_DIR"
. ./okxhttp
mkdir -p "$STACK_DIR/certs"

export UUID=11111111-1111-4111-8111-111111111111
eval "$(gen_x25519)"
export REALITY_PRIV=$PRIVATE_KEY REALITY_SHORTID=1a2b3c4d
export XHTTP_PORT=2087 XHTTP_PATH=/abc123
export REALITY_PORT=443 REALITY_SNI=dm.toutiao.com
export HY2_PORT=443 HY2_PASSWORD=pw-test
gen_self_cert test.local "$TLS_DIR" 203.0.113.9 >/dev/null 2>&1

ENABLE_XHTTP=1 ENABLE_REALITY=1 ENABLE_HY2=1 build_config "$STACK_DIR/all.json"
assert_eq "三协议入站数" "3" "$(jq '.inbounds|length' "$STACK_DIR/all.json")"
assert_eq "xhttp 仅本机监听" "::1" "$(jq -r '.inbounds[]|select(.tag=="vless-xhttp-in")|.listen' "$STACK_DIR/all.json")"
assert_eq "xhttp 无 tls" "none" "$(jq -r '.inbounds[]|select(.tag=="vless-xhttp-in")|.streamSettings.security' "$STACK_DIR/all.json")"
assert_eq "xhttp 路径" "/abc123" "$(jq -r '.inbounds[]|select(.tag=="vless-xhttp-in")|.streamSettings.xhttpSettings.path' "$STACK_DIR/all.json")"
assert_eq "reality 使用 vision" "xtls-rprx-vision" "$(jq -r '.inbounds[]|select(.tag=="vless-reality-in")|.settings.clients[0].flow' "$STACK_DIR/all.json")"
assert_eq "reality dest" "dm.toutiao.com:443" "$(jq -r '.inbounds[]|select(.tag=="vless-reality-in")|.streamSettings.realitySettings.dest' "$STACK_DIR/all.json")"
assert_eq "reality shortId" "1a2b3c4d" "$(jq -r '.inbounds[]|select(.tag=="vless-reality-in")|.streamSettings.realitySettings.shortIds[0]' "$STACK_DIR/all.json")"
assert_eq "hy2 alpn" "h3" "$(jq -r '.inbounds[]|select(.tag=="hy2-in")|.streamSettings.tlsSettings.alpn[0]' "$STACK_DIR/all.json")"
assert_eq "hy2 版本 2" "2" "$(jq -r '.inbounds[]|select(.tag=="hy2-in")|.settings.version' "$STACK_DIR/all.json")"
assert_eq "出站有 direct" "freedom" "$(jq -r '.outbounds[0].protocol' "$STACK_DIR/all.json")"
assert_ok "三协议配置过 xray 校验" test_config "$STACK_DIR/all.json"
assert_eq "默认启用 Xray 内置 DoH" "https://cloudflare-dns.com/dns-query" "$(jq -r '.dns.servers[0]' "$STACK_DIR/all.json")"
# queryStrategy 交给内核默认；拨号策略按协议族
detect_ip_family() { printf '4'; }
ENABLE_XHTTP=0 ENABLE_REALITY=0 ENABLE_HY2=1 build_config "$STACK_DIR/qs4.json"
assert_eq "不指定 queryStrategy" "null" "$(jq -c '.dns.queryStrategy // null' "$STACK_DIR/qs4.json")"
assert_eq "v4-only => 拨号 UseIPv4" "UseIPv4" "$(jq -r '.outbounds[]|select(.tag=="direct")|.streamSettings.sockopt.domainStrategy' "$STACK_DIR/qs4.json")"
detect_ip_family() { printf '6'; }
ENABLE_XHTTP=0 ENABLE_REALITY=0 ENABLE_HY2=1 build_config "$STACK_DIR/qs6.json"
assert_eq "v6-only => 拨号 UseIPv6" "UseIPv6" "$(jq -r '.outbounds[]|select(.tag=="direct")|.streamSettings.sockopt.domainStrategy' "$STACK_DIR/qs6.json")"
detect_ip_family() { printf '46'; }
ENABLE_XHTTP=0 ENABLE_REALITY=0 ENABLE_HY2=1 build_config "$STACK_DIR/qs46.json"
assert_eq "双栈 => 拨号 UseIP" "UseIP" "$(jq -r '.outbounds[]|select(.tag=="direct")|.streamSettings.sockopt.domainStrategy' "$STACK_DIR/qs46.json")"
assert_eq "DoH 上游用域名" "cloudflare-dns.com" "$(jq -r '.dns.servers[0]' "$STACK_DIR/qs4.json" | sed 's#https://##; s#/.*##')"
assert_eq "hosts 提供 v4+v6 引导" "2" "$(jq '.dns.hosts["cloudflare-dns.com"]|length' "$STACK_DIR/qs4.json")"
assert_eq "DoH 上游数量" "2" "$(jq '.dns.servers|length' "$STACK_DIR/qs4.json")"
assert_eq "DoH 上游用域名" "dns.google" "$(jq -r '.dns.servers[1]' "$STACK_DIR/qs4.json" | sed 's#https://##; s#/.*##')"
assert_eq "direct 出站用 UseIP（走内置 DNS）" "UseIP" "$(jq -r '.outbounds[]|select(.tag=="direct")|.streamSettings.sockopt.domainStrategy' "$STACK_DIR/all.json")"

DNS_DOH=no ENABLE_XHTTP=0 ENABLE_REALITY=1 ENABLE_HY2=0 build_config "$STACK_DIR/rel.json"
assert_eq "DNS_DOH=no 时不注入 dns 段" "null" "$(jq -c '.dns // null' "$STACK_DIR/rel.json")"
assert_eq "DNS_DOH=no 时 direct 用 AsIs（系统 DNS）" "AsIs" "$(jq -r '.outbounds[]|select(.tag=="direct")|.streamSettings.sockopt.domainStrategy' "$STACK_DIR/rel.json")"
assert_eq "仅 reality 入站数" "1" "$(jq '.inbounds|length' "$STACK_DIR/rel.json")"
assert_ok "仅 reality 配置过校验" test_config "$STACK_DIR/rel.json"

ENABLE_XHTTP=0 ENABLE_REALITY=0 ENABLE_HY2=1 build_config "$STACK_DIR/hy2.json"
assert_eq "仅 hy2 入站数" "1" "$(jq '.inbounds|length' "$STACK_DIR/hy2.json")"
assert_ok "仅 hy2 配置过校验" test_config "$STACK_DIR/hy2.json"

ENABLE_XHTTP=1 ENABLE_WS=1 ENABLE_REALITY=0 ENABLE_HY2=0 build_config "$STACK_DIR/ws.json"
assert_eq "临时隧道 ws 入站数" "2" "$(jq '.inbounds|length' "$STACK_DIR/ws.json")"
assert_eq "ws 仅本机监听" "::1" "$(jq -r '.inbounds[]|select(.tag=="vless-ws-in")|.listen' "$STACK_DIR/ws.json")"
assert_eq "ws 网络类型" "ws" "$(jq -r '.inbounds[]|select(.tag=="vless-ws-in")|.streamSettings.network' "$STACK_DIR/ws.json")"
assert_ok "ws 配置过校验" test_config "$STACK_DIR/ws.json"

assert_fail "渲染未知协议应失败" sh -c '. ./okxhttp; render_inbound vmess /dev/null'
assert_fail "一个协议都不开应失败" sh -c '. ./okxhttp; ENABLE_XHTTP=0 ENABLE_REALITY=0 ENABLE_HY2=0 build_config /dev/null'
assert_fail "坏配置无法通过校验" test_config /dev/null
rm -rf "$STACK_DIR"

# 监听地址统一：公网入站 ::、隧道入站 ::1（与有没有 v6 无关）
PUBLIC_IP6=
ENABLE_REALITY=1 ENABLE_HY2=0 ENABLE_XHTTP=0 ENABLE_WS=0 ARGO_MODE=off build_config "$STACK_DIR/v4.json" >/dev/null
assert_eq "无 v6 时 reality 也听 ::" "::" "$(jq -r '.inbounds[]|select(.tag=="vless-reality-in")|.listen' "$STACK_DIR/v4.json")"
PUBLIC_IP6=2001:db8::5
ENABLE_REALITY=1 build_config "$STACK_DIR/v6.json" >/dev/null
assert_eq "有 v6 时 reality 听 ::" "::" "$(jq -r '.inbounds[]|select(.tag=="vless-reality-in")|.listen' "$STACK_DIR/v6.json")"
assert_eq "双栈配置仍能通过 xray 校验" "ok" "$(test_config "$STACK_DIR/v6.json" && echo ok)"
assert_ok "回环判定认 ::1" _is_loopback ::1
assert_ok "回环判定认 127.x" _is_loopback 127.0.0.1
assert_fail "通配不算回环" _is_loopback ::
assert_match "hy2 模板用 listen 参数" 'listen: \$listen' "$(_tpl_hy2)"
assert_match "reality 模板用 listen 参数" 'listen: \$listen' "$(_tpl_reality)"
rm -f "$STACK_DIR/v4.json" "$STACK_DIR/v6.json"

# hy2 Brutal 带宽：只在配置了才写 quicParams（congestion=brutal + 上下行）
HY2_BRUTAL_UP='' HY2_BRUTAL_DOWN=''
render_inbound hy2 "$STACK_DIR/hy2-none.json"
assert_fail "不配带宽时没有 quicParams" sh -c "grep -q quicParams '$STACK_DIR/hy2-none.json'"
HY2_BRUTAL_UP=200 HY2_BRUTAL_DOWN=500
render_inbound hy2 "$STACK_DIR/hy2-bw.json"
assert_eq "congestion 写成 brutal" "brutal" "$(jq -r '.streamSettings.quicParams.congestion' "$STACK_DIR/hy2-bw.json")"
assert_eq "上行带 mbps 单位" "200 mbps" "$(jq -r '.streamSettings.quicParams.brutalUp' "$STACK_DIR/hy2-bw.json")"
assert_eq "下行带 mbps 单位" "500 mbps" "$(jq -r '.streamSettings.quicParams.brutalDown' "$STACK_DIR/hy2-bw.json")"
HY2_BRUTAL_UP=0 HY2_BRUTAL_DOWN=0
render_inbound hy2 "$STACK_DIR/hy2-zero.json"
assert_eq "0 带宽照常写入" "0 mbps" "$(jq -r '.streamSettings.quicParams.brutalUp' "$STACK_DIR/hy2-zero.json")"
assert_eq "0 带宽下行照常写入" "0 mbps" "$(jq -r '.streamSettings.quicParams.brutalDown' "$STACK_DIR/hy2-zero.json")"
HY2_BRUTAL_UP='' HY2_BRUTAL_DOWN=''
rm -f "$STACK_DIR/hy2-none.json" "$STACK_DIR/hy2-bw.json" "$STACK_DIR/hy2-zero.json"
