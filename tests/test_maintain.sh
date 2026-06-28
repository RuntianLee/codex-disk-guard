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
