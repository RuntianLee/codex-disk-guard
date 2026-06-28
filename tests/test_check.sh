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
