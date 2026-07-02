# tests/test_cleanup.sh — codex-disk-cleanup（唯一执行 rm -rf 的命令）
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP="$HERE/../bin/codex-disk-cleanup"

h="$(mktemp -d)"
mkdir -p "$h/sessions" "$h/memories" "$h/cache/remote_plugin_catalog" "$h/.tmp" "$h/computer-use"
echo keep > "$h/sessions/s.jsonl"
echo keep > "$h/memories/m.md"
echo junk > "$h/logs_2.sqlite.bak"
echo junk > "$h/.DS_Store"
echo junk > "$h/logs_2.sqlite.block-backup-20260101-000000"

# 预览：什么都不删，且已经给出 computer-use/notify 提示（用户做决定的时刻）
prev_out="$(CODEX_HOME="$h" bash "$CLEANUP" 2>&1)"
assert_true "dry-run keeps junk"                 test -f "$h/logs_2.sqlite.bak"
assert_true "dry-run keeps block backup"          test -f "$h/logs_2.sqlite.block-backup-20260101-000000"
assert_true "preview lists the block backup"      bash -c "printf '%s' '$prev_out' | grep -q 'block-backup'"
assert_true "preview shows computer-use caveat"   bash -c "printf '%s' '$prev_out' | grep -q 'notify'"

# --apply：删干净垃圾（含 block 备份），绝不动 sessions/memories
CODEX_HOME="$h" bash "$CLEANUP" --apply >/dev/null 2>&1
assert_false "bak deleted"           test -e "$h/logs_2.sqlite.bak"
assert_false ".DS_Store deleted"     test -e "$h/.DS_Store"
assert_false ".tmp deleted"          test -e "$h/.tmp"
assert_false "block backup deleted"  test -e "$h/logs_2.sqlite.block-backup-20260101-000000"
assert_true  "sessions intact"       test -f "$h/sessions/s.jsonl"
assert_true  "memories intact"       test -f "$h/memories/m.md"

# 防呆：HOME/CODEX_HOME 都不可用时拒绝运行
assert_false "refuses when HOME and CODEX_HOME unset" \
  bash -c "env -u HOME -u CODEX_HOME bash '$CLEANUP' >/dev/null 2>&1"
