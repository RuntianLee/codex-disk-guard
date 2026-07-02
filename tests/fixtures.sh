# tests/fixtures.sh — 在临时目录造一个与真实结构一致的 logs_2.sqlite
# 用法: fixture_home=$(make_fixture_home <rows>)
make_fixture_home() {
  local rows="${1:-0}"
  local home; home="$(mktemp -d)"
  local db="$home/logs_2.sqlite"
  sqlite3 "$db" "
    CREATE TABLE logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts INTEGER NOT NULL, ts_nanos INTEGER NOT NULL,
      level TEXT NOT NULL, target TEXT NOT NULL,
      feedback_log_body TEXT, module_path TEXT, file TEXT, line INTEGER,
      thread_id TEXT, process_uuid TEXT,
      estimated_bytes INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE _sqlx_migrations (version BIGINT PRIMARY KEY);
  "
  local i now; now="$(date +%s)"
  for ((i=0; i<rows; i++)); do
    sqlite3 "$db" "INSERT INTO logs(ts,ts_nanos,level,target,estimated_bytes) VALUES($now,0,'TRACE','log',100);"
  done
  printf '%s' "$home"
}
