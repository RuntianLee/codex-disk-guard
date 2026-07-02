# tests/test_maintain.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/fixtures.sh"
MAINTAIN="$HERE/../bin/codex-disk-maintain"

# 造库:5 行新日志 + 2 行"老"日志(ts 设为 10 天前)
h="$(make_fixture_home 5)"
old=$(( $(date +%s) - 10*86400 ))
sqlite3 "$h/logs_2.sqlite" "INSERT INTO logs(ts,ts_nanos,level,target,estimated_bytes) VALUES($old,0,'TRACE','log',100),($old,0,'TRACE','log',100);"
before=$(sqlite3 "$h/logs_2.sqlite" "SELECT count(*) FROM logs;")
assert_eq "7" "$before" "fixture has 7 rows"

# 运行维护(保留 3 天)
CODEX_HOME="$h" CDT_RETENTION_DAYS=3 bash "$MAINTAIN" >/dev/null 2>&1
after=$(sqlite3 "$h/logs_2.sqlite" "SELECT count(*) FROM logs;")
assert_eq "5" "$after" "maintain pruned 2 old rows, kept 5"

# 缺库时安全退出(退出码0,不报错)
assert_true "maintain safe on missing db" bash -c "CODEX_HOME=/nonexistent-xyz bash '$MAINTAIN'"

# non-integer CDT_RETENTION_DAYS must fall back to default (3) and still prune, not silently no-op
h2="$(make_fixture_home 0)"
oldts=$(( $(date +%s) - 10*86400 ))
sqlite3 "$h2/logs_2.sqlite" "INSERT INTO logs(ts,ts_nanos,level,target,estimated_bytes) VALUES($oldts,0,'TRACE','log',100);"
CODEX_HOME="$h2" CDT_RETENTION_DAYS=abc bash "$MAINTAIN" >/dev/null 2>&1
assert_eq "0" "$(sqlite3 "$h2/logs_2.sqlite" 'SELECT count(*) FROM logs;')" "non-integer retention falls back to 3 and still prunes"

# L3: 正常路径输出必须同时确认 prune 与 compact 两个阶段都发生了
h3="$(make_fixture_home 3)"
m_file="$(mktemp)"
CODEX_HOME="$h3" bash "$MAINTAIN" >"$m_file" 2>&1
assert_true "maintain reports prune stage"   grep -q 'pruned' "$m_file"
assert_true "maintain reports compact stage" grep -q 'vacuumed' "$m_file"
