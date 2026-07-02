# tests/test_check.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/fixtures.sh"
CHECK="$HERE/../bin/codex-disk-check"

h="$(make_fixture_home 10)"
state="$(mktemp -d)"

# 首次运行:无基线,应初始化 last-sample 且报告 baseline,退出0
CODEX_HOME="$h" CDT_STATE_DIR="$state" bash "$CHECK" >/dev/null 2>&1
assert_true "last-sample created" test -f "$state/last-sample"
assert_true "report created" test -f "$state/report.log"
assert_true "first run records baseline" grep -q "baseline" "$state/report.log"

# 再插 6 行后第二次运行:应报告 inserted=6
sqlite3 "$h/logs_2.sqlite" "INSERT INTO logs(ts,ts_nanos,level,target,estimated_bytes) SELECT ts,0,'TRACE','log',100 FROM logs LIMIT 6;"
CODEX_HOME="$h" CDT_STATE_DIR="$state" bash "$CHECK" >/dev/null 2>&1
assert_true "second run records inserted=6" grep -q "inserted=6" "$state/report.log"

# --json 输出含 inserted 字段
out_file="$(mktemp)"
CODEX_HOME="$h" CDT_STATE_DIR="$state" bash "$CHECK" --json >"$out_file" 2>/dev/null
assert_true "json mode emits inserted key" grep -q '"inserted"' "$out_file"

# M1: 间隔太短时，速率不得触发 WARN（JSON 的 reasons 不含 rate）
h2="$(make_fixture_home 10)"
state2="$(mktemp -d)"
CODEX_HOME="$h2" CDT_STATE_DIR="$state2" bash "$CHECK" >/dev/null 2>&1   # baseline
sqlite3 "$h2/logs_2.sqlite" "INSERT INTO logs(ts,ts_nanos,level,target,estimated_bytes) SELECT ts,0,'TRACE','log',100 FROM logs;"
out2="$(CODEX_HOME="$h2" CDT_STATE_DIR="$state2" bash "$CHECK" --json 2>/dev/null)"
assert_false "short interval does not warn on rate" bash -c "printf '%s' '$out2' | grep -q 'rate'"
assert_true  "json has reasons field"  bash -c "printf '%s' '$out2' | grep -q '\"reasons\"'"
assert_true  "json has residual field" bash -c "printf '%s' '$out2' | grep -q '\"residual\"'"

# M1: 把上次采样伪造成 1 小时前，同样的插入量就应该 WARN(rate)
prev_counter="$(awk -F= '/^counter=/{print $2}' "$state2/last-sample")"
printf 'ts=%s\ncounter=%s\n' "$(( $(date +%s) - 3600 ))" "$prev_counter" > "$state2/last-sample"
sqlite3 "$h2/logs_2.sqlite" "INSERT INTO logs(ts,ts_nanos,level,target,estimated_bytes) SELECT ts,0,'TRACE','log',100 FROM logs LIMIT 20;"
# 1 小时插入 20 行不会超过 50MB/day 阈值；把阈值压到 0.0001 逼出 rate WARN
out3="$(CODEX_HOME="$h2" CDT_STATE_DIR="$state2" CDT_LOGS_RATE_WARN_MB_DAY=0.0001 bash "$CHECK" --json 2>/dev/null)"
assert_true "long interval warns on rate" bash -c "printf '%s' '$out3' | grep -q 'rate'"

# L2: 非法阈值环境变量必须回退默认值并在 stderr 提示，而不是静默变 0
err="$(CODEX_HOME="$h2" CDT_STATE_DIR="$(mktemp -d)" CDT_WAL_WARN_BYTES=abc bash "$CHECK" 2>&1 >/dev/null || true)"
assert_true "invalid CDT_WAL_WARN_BYTES falls back with a note" bash -c "printf '%s' '$err' | grep -q 'invalid CDT_WAL_WARN_BYTES'"
