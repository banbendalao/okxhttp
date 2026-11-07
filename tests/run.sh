#!/bin/sh
# 测试入口：逐个运行 tests/t_*.sh，任一失败即整体失败
cd "$(dirname "$0")/.." || exit 1

# 本地测试环境：把 .tmp/xray 放进 PATH（真实环境由脚本自己下载到 /usr/local/bin）
[ -x .tmp/xray ] && PATH="$PWD/.tmp:$PATH" && export PATH

command -v jq >/dev/null 2>&1 || { echo "缺少 jq，无法运行测试"; exit 1; }
command -v xray >/dev/null 2>&1 || { echo "缺少 .tmp/xray（先放入 Xray 二进制）"; exit 1; }

total_fail=0
for t in tests/t_*.sh; do
  sh "$t" || total_fail=1
done
echo "---------------------------------------"
[ "$total_fail" -eq 0 ] && echo "全部通过" || echo "存在失败"
exit "$total_fail"
