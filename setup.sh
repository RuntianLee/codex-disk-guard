#!/usr/bin/env bash
# setup.sh — 一键安装 codex 写盘工具:部署脚本/lib、渲染并加载 launchd 定时。
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

# 0. 预检:仅支持 macOS,且依赖 sqlite3(macOS 自带 /usr/bin/sqlite3)
if [ "$(uname)" != "Darwin" ]; then
  echo "错误: codex-disk-tools 仅支持 macOS(依赖 launchd / fs_usage)。" >&2
  exit 1
fi
if ! command -v sqlite3 >/dev/null 2>&1 && [ ! -x /usr/bin/sqlite3 ]; then
  echo "错误: 未找到 sqlite3。macOS 应自带;或运行 'brew install sqlite'。" >&2
  exit 1
fi

PREFIX="${CDT_PREFIX:-$HOME/.local/bin}"
AGENTS="${CDT_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
STATE="${CDT_STATE_DIR:-$HOME/.local/state/codex-disk}"
mkdir -p "$PREFIX/lib" "$AGENTS" "$STATE"

# 1. 部署可执行 + lib
install -m 0755 "$HERE/bin/codex-disk-maintain" "$PREFIX/codex-disk-maintain"
install -m 0755 "$HERE/bin/codex-disk-check"    "$PREFIX/codex-disk-check"
install -m 0755 "$HERE/cleanup-once.sh"         "$PREFIX/codex-disk-cleanup"
install -m 0644 "$HERE/lib/common.sh"           "$PREFIX/lib/common.sh"
install -m 0755 "$HERE/uninstall.sh"            "$PREFIX/codex-disk-uninstall"

# 2. 渲染 plist(替换 __PREFIX__ / __STATE__)
render() { sed -e "s#__PREFIX__#$PREFIX#g" -e "s#__STATE__#$STATE#g" "$1" > "$2"; }
render "$HERE/launchd/com.user.codex-disk-maintain.plist.template" "$AGENTS/com.user.codex-disk-maintain.plist"
render "$HERE/launchd/com.user.codex-disk-check.plist.template"    "$AGENTS/com.user.codex-disk-check.plist"

# 3. 加载定时(测试可用 CDT_NO_LAUNCHCTL=1 跳过)
if [ "${CDT_NO_LAUNCHCTL:-0}" != "1" ]; then
  for lbl in codex-disk-maintain codex-disk-check; do
    launchctl bootout "gui/$(id -u)/com.user.$lbl" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENTS/com.user.$lbl.plist"
  done
fi

echo "已安装:"
echo "  $PREFIX/codex-disk-maintain"
echo "  $PREFIX/codex-disk-check"
echo "  $PREFIX/codex-disk-cleanup"
echo "  $PREFIX/codex-disk-uninstall"
echo "  $AGENTS/com.user.codex-disk-maintain.plist (每天 03:00)"
echo "  $AGENTS/com.user.codex-disk-check.plist (每天 03:05)"
echo "随时手动查状态: codex-disk-check   |   精确测速: codex-disk-check --measure 60"
echo "卸载: codex-disk-uninstall"

# 4. PATH 提醒:~/.local/bin 在很多 Mac 上默认不在 PATH
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo
     echo "⚠ 注意: $PREFIX 不在 PATH 中,命令名暂时无法直接调用。请加入后重开终端:"
     echo "    echo 'export PATH=\"$PREFIX:\$PATH\"' >> ~/.zshrc" ;;
esac
