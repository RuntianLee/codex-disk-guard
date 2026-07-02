#!/usr/bin/env bash
# setup.sh — installer for codex-disk-guard: deploy the commands + lib, then render
# and load the launchd timers. (codex-disk-guard guards against the Codex CLI's
# excessive disk writing; it does not itself write logs.)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

# 0. Preflight: macOS only, and sqlite3 must be present (macOS ships /usr/bin/sqlite3).
if [ "$(uname)" != "Darwin" ]; then
  echo "error: codex-disk-guard supports macOS only (it relies on launchd / fs_usage)." >&2
  exit 1
fi
if ! command -v sqlite3 >/dev/null 2>&1 && [ ! -x /usr/bin/sqlite3 ]; then
  echo "error: sqlite3 not found. It ships with macOS, or run 'brew install sqlite'." >&2
  exit 1
fi

PREFIX="${CDT_PREFIX:-$HOME/.local/bin}"
AGENTS="${CDT_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
STATE="${CDT_STATE_DIR:-$HOME/.local/state/codex-disk}"

# The plist render below uses sed with '#' as the delimiter; a path containing
# '#', '&', '\' or a newline would produce a silently-broken plist. Refuse instead.
nl='
'
case "${PREFIX}${AGENTS}${STATE}" in
  *'#'*|*'&'*|*'\'*|*"$nl"*)
    echo "error: CDT_PREFIX / CDT_AGENTS_DIR / CDT_STATE_DIR must not contain '#', '&', '\\' or newlines." >&2
    exit 1 ;;
esac

mkdir -p "$PREFIX/lib" "$AGENTS" "$STATE"

# 1. Deploy the executables + shared lib.
install -m 0755 "$HERE/bin/codex-disk-maintain" "$PREFIX/codex-disk-maintain"
install -m 0755 "$HERE/bin/codex-disk-check"    "$PREFIX/codex-disk-check"
install -m 0755 "$HERE/bin/codex-disk-bench"    "$PREFIX/codex-disk-bench"
install -m 0755 "$HERE/bin/codex-disk-cleanup"  "$PREFIX/codex-disk-cleanup"
install -m 0755 "$HERE/bin/codex-disk-block"    "$PREFIX/codex-disk-block"
install -m 0755 "$HERE/bin/codex-disk-unblock"  "$PREFIX/codex-disk-unblock"
install -m 0644 "$HERE/lib/common.sh"           "$PREFIX/lib/common.sh"
install -m 0755 "$HERE/uninstall.sh"            "$PREFIX/codex-disk-uninstall"

# 2. Render the plists (substitute __PREFIX__ / __STATE__).
render() { sed -e "s#__PREFIX__#$PREFIX#g" -e "s#__STATE__#$STATE#g" "$1" > "$2"; }
render "$HERE/launchd/maintain.plist.template" "$AGENTS/com.user.codex-disk-maintain.plist"
render "$HERE/launchd/check.plist.template"    "$AGENTS/com.user.codex-disk-check.plist"

# 3. Load the timers (tests can skip the real launchctl with CDT_NO_LAUNCHCTL=1).
if [ "${CDT_NO_LAUNCHCTL:-0}" != "1" ]; then
  for lbl in codex-disk-maintain codex-disk-check; do
    launchctl bootout "gui/$(id -u)/com.user.$lbl" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENTS/com.user.$lbl.plist"
  done
fi

echo "Installed:"
echo "  $PREFIX/codex-disk-maintain"
echo "  $PREFIX/codex-disk-check"
echo "  $PREFIX/codex-disk-bench"
echo "  $PREFIX/codex-disk-cleanup"
echo "  $PREFIX/codex-disk-block, $PREFIX/codex-disk-unblock  (advanced, opt-in)"
echo "  $PREFIX/codex-disk-uninstall"
echo "  $AGENTS/com.user.codex-disk-maintain.plist (daily 03:00)"
echo "  $AGENTS/com.user.codex-disk-check.plist (daily 03:05)"
echo "Check status anytime: codex-disk-check   |   Precise measure: codex-disk-check --measure 60"
echo "Uninstall: codex-disk-uninstall"

# 4. PATH reminder: ~/.local/bin is not on PATH by default on many Macs.
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo
     echo "Note: $PREFIX is not on your PATH, so the command names won't resolve yet. Add it and reopen the terminal:"
     echo "    echo 'export PATH=\"$PREFIX:\$PATH\"' >> ~/.zshrc" ;;
esac
