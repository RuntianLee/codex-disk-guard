#!/usr/bin/env bash
# uninstall.sh — precise uninstall: stop the timers and remove the scripts/lib/plists/report dir.
# Removes only what setup.sh installed.
set -u
PREFIX="${CDT_PREFIX:-$HOME/.local/bin}"
AGENTS="${CDT_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
STATE="${CDT_STATE_DIR:-$HOME/.local/state/codex-disk}"

# Detect (do NOT remove) a leftover codex-disk-block trigger in Codex's own DB, so we
# can warn the user — this uninstaller never modifies ~/.codex.
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
echo "Not touched: ~/.codex (Codex's own data: logs_2.sqlite, sessions, memories)."
echo "Note: any changes you made yourself to Codex config.toml / RUST_LOG / computer-use are NOT reverted; handle those manually."
if [ "$block_present" = "1" ]; then
  echo
  echo "IMPORTANT: a codex-disk-block trigger is STILL installed in $logsdb."
  echo "  This uninstaller does not modify Codex's data, so it left the trigger in place."
  echo "  Codex log inserts remain blocked. To restore normal Codex logging, run:"
  echo "    sqlite3 \"$logsdb\" \"DROP TRIGGER IF EXISTS cdg_block_logs;\""
fi
# Finally remove this uninstaller itself.
rm -f "$PREFIX/codex-disk-uninstall"
