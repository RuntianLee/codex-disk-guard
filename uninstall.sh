#!/usr/bin/env bash
# uninstall.sh — precise uninstall: stop the timers and remove the scripts/lib/plists/report dir.
# Removes only what this tool created. If codex-disk-block left an insert-blocking trigger in
# Codex's log DB, this also drops that ONE trigger (restoring normal Codex logging); it never
# touches Codex's sessions, memories, or log rows.
set -u
PREFIX="${CDT_PREFIX:-$HOME/.local/bin}"
AGENTS="${CDT_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
STATE="${CDT_STATE_DIR:-$HOME/.local/state/codex-disk}"

# Detect a leftover codex-disk-block trigger so we can drop it (see end of script).
logsdb="${CODEX_HOME:-$HOME/.codex}/logs_2.sqlite"
sqlite_bin="$(command -v sqlite3 2>/dev/null || echo /usr/bin/sqlite3)"
block_present=0
if [ -f "$logsdb" ]; then
  n="$("$sqlite_bin" "$logsdb" "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name='cdg_block_logs';" 2>/dev/null)"
  [ "${n:-0}" = "1" ] && block_present=1
fi

if [ "${CDT_NO_LAUNCHCTL:-0}" != "1" ]; then
  for lbl in codex-disk-maintain codex-disk-check; do
    launchctl bootout "gui/$(id -u)/com.user.$lbl" 2>/dev/null || true
  done
fi

rm -f "$AGENTS/com.user.codex-disk-maintain.plist" "$AGENTS/com.user.codex-disk-check.plist"
rm -f "$PREFIX/codex-disk-maintain" "$PREFIX/codex-disk-check" "$PREFIX/codex-disk-bench" "$PREFIX/codex-disk-cleanup" "$PREFIX/codex-disk-block" "$PREFIX/codex-disk-unblock" "$PREFIX/lib/common.sh"
rmdir "$PREFIX/lib" 2>/dev/null || true
[ -n "$STATE" ] && rm -rf "$STATE"
echo "Removed everything this tool wrote:"
echo "  commands:  $PREFIX/codex-disk-{maintain,check,bench,cleanup,block,unblock,uninstall}  (+ $PREFIX/lib/common.sh)"
echo "  timers:    $AGENTS/com.user.codex-disk-maintain.plist, $AGENTS/com.user.codex-disk-check.plist"
echo "  reports:   $STATE/  (report.log, last-sample, bench/, *.out/err.log)"
echo "Left intact: your Codex sessions, memories, and log rows in ~/.codex."
echo "Note: any changes you made yourself to Codex config.toml / RUST_LOG / computer-use are NOT reverted; handle those manually."

# If codex-disk-block installed a trigger, drop that one trigger (lock-safe) to restore
# normal Codex logging. If the DB is busy, fall back to telling the user how to do it.
if [ "$block_present" = "1" ]; then
  echo
  drop_out="$("$sqlite_bin" "$logsdb" 2>&1 <<SQL
PRAGMA busy_timeout=3000;
DROP TRIGGER IF EXISTS cdg_block_logs;
PRAGMA wal_checkpoint(TRUNCATE);
SQL
)"
  if [ $? -eq 0 ]; then
    echo "Also removed the codex-disk-block trigger from $logsdb — Codex logging is back to normal."
  else
    echo "WARNING: could not remove the codex-disk-block trigger (DB busy?): $drop_out"
    echo "  It is still installed in $logsdb; Codex log inserts remain blocked. Remove it later with:"
    echo "    sqlite3 \"$logsdb\" \"DROP TRIGGER IF EXISTS cdg_block_logs;\""
  fi
fi
# List (but never delete) codex-disk-block DB backups: they are copies of the
# user's Codex log DB, so removal stays a user decision.
for b in "${CODEX_HOME:-$HOME/.codex}"/logs_2.sqlite.block-backup-*; do
  [ -e "$b" ] || continue
  echo "Note: a codex-disk-block DB backup remains (left in place, it's your data):"
  echo "  $b"
  echo "  Remove it when no longer needed: rm \"$b\""
done
# Finally remove this uninstaller itself.
rm -f "$PREFIX/codex-disk-uninstall"
