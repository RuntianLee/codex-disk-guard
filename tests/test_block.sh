# tests/test_block.sh — codex-disk-block / codex-disk-unblock (no sudo; against a fixture DB)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/fixtures.sh"
BLOCK="$HERE/../bin/codex-disk-block"
UNBLOCK="$HERE/../bin/codex-disk-unblock"

h="$(make_fixture_home 2)"        # 2 rows, sqlite_sequence.seq = 2
db="$h/logs_2.sqlite"
trg() { sqlite3 "$db" "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name='cdg_block_logs';"; }
cnt() { sqlite3 "$db" "SELECT count(*) FROM logs;"; }

# dry-run must NOT install the trigger
CODEX_HOME="$h" bash "$BLOCK" >/dev/null 2>&1
assert_eq "0" "$(trg)" "dry-run does not install the trigger"

# --apply installs the trigger and creates a backup
CODEX_HOME="$h" bash "$BLOCK" --apply >/dev/null 2>&1
assert_eq "1" "$(trg)" "--apply installs the block trigger"
assert_true "backup file created" bash -c "ls '$db'.block-backup-* >/dev/null 2>&1"

# while blocked, inserts are silently ignored
sqlite3 "$db" "INSERT INTO logs(ts,ts_nanos,level,target,estimated_bytes) VALUES(1,0,'T','log',1);" 2>/dev/null
assert_eq "2" "$(cnt)" "inserts are ignored while blocked (row count stays 2)"

# running block again is a safe no-op (already installed)
assert_true "block is idempotent when already installed" bash -c "CODEX_HOME='$h' bash '$BLOCK' >/dev/null 2>&1"

# unblock drops the trigger and inserts resume
CODEX_HOME="$h" bash "$UNBLOCK" >/dev/null 2>&1
assert_eq "0" "$(trg)" "unblock drops the trigger"
sqlite3 "$db" "INSERT INTO logs(ts,ts_nanos,level,target,estimated_bytes) VALUES(1,0,'T','log',1);" 2>/dev/null
assert_eq "3" "$(cnt)" "inserts resume after unblock (row count = 3)"

# unblock again is a safe no-op
assert_true "unblock is a safe no-op when not installed" bash -c "CODEX_HOME='$h' bash '$UNBLOCK' >/dev/null 2>&1"

# block refuses gracefully when there is no logs table
empty="$(mktemp -d)"; sqlite3 "$empty/logs_2.sqlite" "CREATE TABLE _sqlx_migrations(version BIGINT PRIMARY KEY);"
assert_true "block safe when no logs table" bash -c "CODEX_HOME='$empty' bash '$BLOCK' --apply >/dev/null 2>&1"

# uninstall auto-removes a leftover block trigger from the (sandboxed) Codex DB
h3="$(make_fixture_home 1)"
sqlite3 "$h3/logs_2.sqlite" "CREATE TRIGGER cdg_block_logs BEFORE INSERT ON logs BEGIN SELECT RAISE(IGNORE); END;"
P3="$(mktemp -d)"; A3="$(mktemp -d)"; S3="$(mktemp -d)"
env CDT_PREFIX="$P3" CDT_AGENTS_DIR="$A3" CDT_STATE_DIR="$S3" CODEX_HOME="$h3" CDT_NO_LAUNCHCTL=1 \
  bash "$HERE/../uninstall.sh" >/dev/null 2>&1
assert_eq "0" "$(sqlite3 "$h3/logs_2.sqlite" "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name='cdg_block_logs';")" "uninstall auto-removes the block trigger from Codex DB"

# M2: unblock 成功后要提醒遗留的备份文件
# （输出写入临时文件再 grep：输出里含单引号，内嵌进 bash -c 字符串会碎）
h4="$(make_fixture_home 1)"
CODEX_HOME="$h4" bash "$BLOCK" --apply >/dev/null 2>&1
ub_file="$(mktemp)"
CODEX_HOME="$h4" bash "$UNBLOCK" >"$ub_file" 2>&1
assert_true "unblock mentions leftover backup" grep -q 'block-backup' "$ub_file"

# M2: uninstall 列出遗留备份但不删除（那是用户数据的副本）
h5="$(make_fixture_home 1)"
touch "$h5/logs_2.sqlite.block-backup-20260101-000000"
P5="$(mktemp -d)"; A5="$(mktemp -d)"; S5="$(mktemp -d)"
un_file="$(mktemp)"
env CDT_PREFIX="$P5" CDT_AGENTS_DIR="$A5" CDT_STATE_DIR="$S5" CODEX_HOME="$h5" CDT_NO_LAUNCHCTL=1 \
  bash "$HERE/../uninstall.sh" >"$un_file" 2>&1
assert_true "uninstall lists leftover backup"      grep -q 'block-backup' "$un_file"
assert_true "uninstall does not delete the backup" test -f "$h5/logs_2.sqlite.block-backup-20260101-000000"

# L6: 装完触发器的验证指引应指向普通 check（看 counter），--measure 是字节级复核
h6="$(make_fixture_home 1)"
b_file="$(mktemp)"
CODEX_HOME="$h6" bash "$BLOCK" --apply >"$b_file" 2>&1
assert_true "block verify hint mentions plain check" grep -q "run 'codex-disk-check' twice" "$b_file"
