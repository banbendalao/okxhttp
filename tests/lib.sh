# tests/lib.sh —— 被 t_*.sh source 的断言库（POSIX sh）
TESTS_PASS=0
PATH="$PWD/.tmp:$PATH"; export PATH
TESTS_FAIL=0

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then
    TESTS_PASS=$((TESTS_PASS + 1))
    printf '  ok   %s\n' "$1"
  else
    TESTS_FAIL=$((TESTS_FAIL + 1))
    printf '  FAIL %s\n       期望: %s\n       实际: %s\n' "$1" "$2" "$3"
  fi
}

assert_match() { # name pattern actual
  if printf '%s' "$3" | grep -Eq "$2"; then
    TESTS_PASS=$((TESTS_PASS + 1))
    printf '  ok   %s\n' "$1"
  else
    TESTS_FAIL=$((TESTS_FAIL + 1))
    printf '  FAIL %s\n       正则: %s\n       实际: %s\n' "$1" "$2" "$3"
  fi
}

assert_ok() { # name cmd...
  _n=$1
  shift
  if "$@" >/dev/null 2>&1; then
    TESTS_PASS=$((TESTS_PASS + 1))
    printf '  ok   %s\n' "$_n"
  else
    TESTS_FAIL=$((TESTS_FAIL + 1))
    printf '  FAIL %s\n       命令失败: %s\n' "$_n" "$*"
  fi
}

assert_fail() { # name cmd...
  _n=$1
  shift
  if "$@" >/dev/null 2>&1; then
    TESTS_FAIL=$((TESTS_FAIL + 1))
    printf '  FAIL %s（期望失败但成功）\n' "$_n"
  else
    TESTS_PASS=$((TESTS_PASS + 1))
    printf '  ok   %s\n' "$_n"
  fi
}
