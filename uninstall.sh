#!/usr/bin/env bash
# uninstall.sh — 精确卸载:停定时、删脚本/lib/plist/报告目录。仅删自己装的东西。
set -u
PREFIX="${CDT_PREFIX:-$HOME/.local/bin}"
AGENTS="${CDT_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
STATE="${CDT_STATE_DIR:-$HOME/.local/state/codex-disk}"

if [ "${CDT_NO_LAUNCHCTL:-0}" != "1" ]; then
  for lbl in codex-disk-maintain codex-disk-check; do
    launchctl bootout "gui/$(id -u)/com.user.$lbl" 2>/dev/null || true
  done
fi

rm -f "$AGENTS/com.user.codex-disk-maintain.plist" "$AGENTS/com.user.codex-disk-check.plist"
rm -f "$PREFIX/codex-disk-maintain" "$PREFIX/codex-disk-check" "$PREFIX/lib/common.sh"
rmdir "$PREFIX/lib" 2>/dev/null || true
[ -n "$STATE" ] && rm -rf "$STATE"
echo "已卸载脚本、定时与报告目录。"
echo "注意: config.toml / RUST_LOG / computer-use 等缓解类改动未还原(见 spec §6.2)。"
# 最后自删
rm -f "$PREFIX/codex-disk-uninstall"
