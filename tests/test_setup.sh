# tests/test_setup.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
prefix="$(mktemp -d)"; agents="$(mktemp -d)"; state="$(mktemp -d)"

env CDT_PREFIX="$prefix" CDT_AGENTS_DIR="$agents" CDT_STATE_DIR="$state" \
    CDT_NO_LAUNCHCTL=1 bash "$ROOT/setup.sh" >/dev/null 2>&1

assert_true "maintain installed"   test -x "$prefix/codex-disk-maintain"
assert_true "check installed"       test -x "$prefix/codex-disk-check"
assert_true "common.sh installed"   test -f "$prefix/lib/common.sh"
assert_true "uninstall installed"   test -x "$prefix/codex-disk-uninstall"
assert_true "maintain plist exists" test -f "$agents/com.user.codex-disk-maintain.plist"
assert_true "check plist exists"    test -f "$agents/com.user.codex-disk-check.plist"
assert_true "plist has rendered prefix" grep -q "$prefix/codex-disk-maintain" "$agents/com.user.codex-disk-maintain.plist"
assert_false "plist has no placeholder" grep -q "__PREFIX__" "$agents/com.user.codex-disk-maintain.plist"

# 安装的脚本能独立找到 lib(source 兼容性)
assert_true "installed check runs" bash -c "CODEX_HOME=$(mktemp -d) CDT_STATE_DIR=$(mktemp -d) '$prefix/codex-disk-check' >/dev/null 2>&1"

# 卸载清干净
env CDT_PREFIX="$prefix" CDT_AGENTS_DIR="$agents" CDT_STATE_DIR="$state" \
    CDT_NO_LAUNCHCTL=1 bash "$prefix/codex-disk-uninstall" >/dev/null 2>&1
assert_false "maintain removed" test -e "$prefix/codex-disk-maintain"
assert_false "check plist removed" test -e "$agents/com.user.codex-disk-check.plist"
