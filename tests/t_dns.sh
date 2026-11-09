#!/bin/sh
# t_dns：DoH 解析与 hosts 托管块（不依赖本机 DNS 质量）
. "$(dirname "$0")/lib.sh"
echo "== t_dns =="
export STACK_LIB_ONLY=1
STACK_DIR="$PWD/.tmp/dns-$$"
export STACK_DIR
HOSTS_FILE="$STACK_DIR/hosts"
export HOSTS_FILE
rm -rf "$STACK_DIR"; mkdir -p "$STACK_DIR"
. ./okxhttp

# DoH 查询（真实网络；失败则跳过断言而不是误判）
if ips=$(doh_query api.trycloudflare.com A 1); then
  assert_match "DoH 解析 A 记录" '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' "$(printf '%s\n' "$ips" | head -1)"
else
  echo "  skip  DoH 不可用，跳过网络断言"
fi
if srv=$(doh_query _v2-origintunneld._tcp.argotunnel.com SRV 33); then
  assert_match "DoH 能查 SRV" 'region[12]\.v2\.argotunnel\.com' "$srv"
else
  echo "  skip  DoH SRV 不可用，跳过"
fi
assert_fail "不存在的域名查不到" doh_query no-such-host-okxhttp.invalid A 1

# hosts 托管块：可写、幂等、可移除
printf '127.0.0.1 localhost\n' >"$HOSTS_FILE"
sys_resolve() { return 1; }   # 模拟系统 DNS 解析不了
ensure_hosts_entry www.cloudflare.com >/dev/null 2>&1 || true
ensure_hosts_entry www.cloudflare.com >/dev/null 2>&1 || true
assert_eq "托管块只有一个" "1" "$(grep -c '^# >>> okxhttp-doh' "$HOSTS_FILE")"
assert_eq "原有内容保留" "1" "$(grep -c '^127.0.0.1 localhost' "$HOSTS_FILE")"
_remove_hosts_block
assert_eq "移除后无托管块" "0" "$(grep -c 'okxhttp-doh' "$HOSTS_FILE")"
assert_eq "移除后保留原内容" "1" "$(grep -c '^127.0.0.1 localhost' "$HOSTS_FILE")"

# 系统能解析时不写 hosts
printf '127.0.0.1 localhost\n' >"$HOSTS_FILE"
sys_resolve() { return 0; }
ensure_hosts_entry anything.example >/dev/null 2>&1
assert_eq "系统能解析则不写 hosts" "0" "$(grep -c 'okxhttp-doh' "$HOSTS_FILE")"

[ "${TESTS_FAIL:-0}" -eq 0 ] && echo "全部通过"
rm -rf "$STACK_DIR"
exit "${TESTS_FAIL:-0}"
