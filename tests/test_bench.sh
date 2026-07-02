# tests/test_bench.sh — 验证 codex-disk-bench report 的解析/出表(无需 sudo)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$HERE/../bin/codex-disk-bench"
state="$(mktemp -d)"
mkdir -p "$state/bench"

# 造两份阶段结果:idle(0 字节)、desktop-idle(2MB, residual YES);cli-active 故意缺失
printf '{"window_s":60,"write_bytes":0,"mb_per_day_active":0.00,"tbw_years_if_24x7":"inf"}\n'        > "$state/bench/idle.json"
echo NO  > "$state/bench/idle.residual"
printf '{"window_s":120,"write_bytes":2097152,"mb_per_day_active":1234.50,"tbw_years_if_24x7":"33.3"}\n' > "$state/bench/desktop-idle.json"
echo YES > "$state/bench/desktop-idle.residual"

out_file="$(mktemp)"
CDT_STATE_DIR="$state" bash "$BENCH" report > "$out_file" 2>/dev/null

assert_true "report runs without sudo, exit 0" bash -c "CDT_STATE_DIR='$state' bash '$BENCH' report >/dev/null 2>&1"
assert_true "idle row shows 0B"                 grep -Eq "idle[^0-9]+60[^0-9]+0B" "$out_file"
assert_true "desktop-idle row shows 2.0M"       grep -q "desktop-idle.*2.0M" "$out_file"
assert_true "desktop-idle residual = YES"       grep -Eq "desktop-idle.*YES" "$out_file"
assert_true "missing stage marked not measured" grep -q "cli-active.*not measured" "$out_file"

# 未知子命令应退出码 2
assert_false "unknown subcommand fails" bash -c "CDT_STATE_DIR='$state' bash '$BENCH' bogus >/dev/null 2>&1"
