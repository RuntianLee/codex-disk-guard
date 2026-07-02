#!/usr/bin/env bash
# 运行 tests/ 下所有 test_*.sh,聚合结果
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
for t in "$HERE"/test_*.sh; do
  [ -e "$t" ] || continue
  printf '\n=== %s ===\n' "$(basename "$t")"
  source "$t"
done
assert_summary
