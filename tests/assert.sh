# tests/assert.sh — 极简 bash 断言库,无第三方依赖
CDT_TESTS_RUN=0
CDT_TESTS_FAIL=0

assert_eq() { # <expected> <actual> <msg>
  CDT_TESTS_RUN=$((CDT_TESTS_RUN+1))
  if [ "$1" != "$2" ]; then
    CDT_TESTS_FAIL=$((CDT_TESTS_FAIL+1))
    printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$1" "$2" >&2
  else
    printf 'ok: %s\n' "$3"
  fi
}

assert_true() { # <cmd...> ; 命令退出码为0则通过
  CDT_TESTS_RUN=$((CDT_TESTS_RUN+1))
  local msg="$1"; shift
  if "$@"; then printf 'ok: %s\n' "$msg"; else
    CDT_TESTS_FAIL=$((CDT_TESTS_FAIL+1)); printf 'FAIL: %s (cmd: %s)\n' "$msg" "$*" >&2; fi
}

assert_false() { # <msg> <cmd...> ; 命令退出码非0则通过
  CDT_TESTS_RUN=$((CDT_TESTS_RUN+1))
  local msg="$1"; shift
  if "$@"; then CDT_TESTS_FAIL=$((CDT_TESTS_FAIL+1)); printf 'FAIL: %s (cmd unexpectedly succeeded: %s)\n' "$msg" "$*" >&2
  else printf 'ok: %s\n' "$msg"; fi
}

assert_summary() {
  printf '\n--- %d run, %d failed ---\n' "$CDT_TESTS_RUN" "$CDT_TESTS_FAIL"
  [ "$CDT_TESTS_FAIL" -eq 0 ]
}
