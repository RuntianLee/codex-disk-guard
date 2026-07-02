# tests/test_setup.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
prefix="$(mktemp -d)"; agents="$(mktemp -d)"; state="$(mktemp -d)"

env CDT_PREFIX="$prefix" CDT_AGENTS_DIR="$agents" CDT_STATE_DIR="$state" \
    CDT_NO_LAUNCHCTL=1 bash "$ROOT/setup.sh" >/dev/null 2>&1

assert_true "maintain installed"   test -x "$prefix/codex-disk-maintain"
assert_true "check installed"       test -x "$prefix/codex-disk-check"
assert_true "bench installed"       test -x "$prefix/codex-disk-bench"
assert_true "cleanup installed"     test -x "$prefix/codex-disk-cleanup"
assert_true "block installed"       test -x "$prefix/codex-disk-block"
assert_true "unblock installed"     test -x "$prefix/codex-disk-unblock"
assert_true "common.sh installed"   test -f "$prefix/lib/common.sh"
assert_true "uninstall installed"   test -x "$prefix/codex-disk-uninstall"
assert_true "maintain plist exists" test -f "$agents/com.user.codex-disk-maintain.plist"
assert_true "check plist exists"    test -f "$agents/com.user.codex-disk-check.plist"
assert_true "plist has rendered prefix" grep -q "$prefix/codex-disk-maintain" "$agents/com.user.codex-disk-maintain.plist"
assert_false "plist has no placeholder" grep -q "__PREFIX__" "$agents/com.user.codex-disk-maintain.plist"

# 安装的脚本能独立找到 lib(source 兼容性)
# 注意:退出码可能是 0(PASS)或 1(WARN,例如本机确实有残留的 Codex 进程),
# 这两者都说明脚本正常跑完了逻辑;只用 report.log 是否生成来判断"跑起来了",
# 不对 PASS/WARN 状态做机器相关的断言。
check_state="$(mktemp -d)"
CODEX_HOME="$(mktemp -d)" CDT_STATE_DIR="$check_state" "$prefix/codex-disk-check" >/dev/null 2>&1
assert_true "installed check runs" test -f "$check_state/report.log"

# 卸载清干净
env CDT_PREFIX="$prefix" CDT_AGENTS_DIR="$agents" CDT_STATE_DIR="$state" \
    CODEX_HOME="$(mktemp -d)" CDT_NO_LAUNCHCTL=1 bash "$prefix/codex-disk-uninstall" >/dev/null 2>&1
assert_false "maintain removed" test -e "$prefix/codex-disk-maintain"
assert_false "bench removed" test -e "$prefix/codex-disk-bench"
assert_false "cleanup removed" test -e "$prefix/codex-disk-cleanup"
assert_false "block removed" test -e "$prefix/codex-disk-block"
assert_false "unblock removed" test -e "$prefix/codex-disk-unblock"
assert_false "check plist removed" test -e "$agents/com.user.codex-disk-check.plist"

# M4: 用户把 CDT_STATE_DIR 指到已有目录时，卸载不得吞掉目录里的无关文件
prefix2="$(mktemp -d)"; agents2="$(mktemp -d)"; state_mixed="$(mktemp -d)"
echo precious > "$state_mixed/USER-FILE.txt"
env CDT_PREFIX="$prefix2" CDT_AGENTS_DIR="$agents2" CDT_STATE_DIR="$state_mixed" \
    CDT_NO_LAUNCHCTL=1 bash "$ROOT/setup.sh" >/dev/null 2>&1
CODEX_HOME="$(mktemp -d)" CDT_STATE_DIR="$state_mixed" bash "$prefix2/codex-disk-check" >/dev/null 2>&1
env CDT_PREFIX="$prefix2" CDT_AGENTS_DIR="$agents2" CDT_STATE_DIR="$state_mixed" \
    CODEX_HOME="$(mktemp -d)" CDT_NO_LAUNCHCTL=1 bash "$prefix2/codex-disk-uninstall" >/dev/null 2>&1
assert_true  "foreign file survives uninstall"      test -f "$state_mixed/USER-FILE.txt"
assert_false "our report.log removed by uninstall"  test -e "$state_mixed/report.log"

# 只含本工具文件的 STATE 目录应被整个移除（原行为保持）
prefix3="$(mktemp -d)"; agents3="$(mktemp -d)"; state_clean="$(mktemp -d)"
env CDT_PREFIX="$prefix3" CDT_AGENTS_DIR="$agents3" CDT_STATE_DIR="$state_clean" \
    CDT_NO_LAUNCHCTL=1 bash "$ROOT/setup.sh" >/dev/null 2>&1
CODEX_HOME="$(mktemp -d)" CDT_STATE_DIR="$state_clean" bash "$prefix3/codex-disk-check" >/dev/null 2>&1
env CDT_PREFIX="$prefix3" CDT_AGENTS_DIR="$agents3" CDT_STATE_DIR="$state_clean" \
    CODEX_HOME="$(mktemp -d)" CDT_NO_LAUNCHCTL=1 bash "$prefix3/codex-disk-uninstall" >/dev/null 2>&1
assert_false "clean state dir fully removed" test -d "$state_clean"

# L8: 含 sed 定界符的安装路径必须被拒绝，而不是渲染出损坏的 plist
assert_false "setup refuses CDT_PREFIX containing '#'" \
  bash -c "env CDT_PREFIX='$(mktemp -d)/we#ird' CDT_AGENTS_DIR='$(mktemp -d)' CDT_STATE_DIR='$(mktemp -d)' CDT_NO_LAUNCHCTL=1 bash '$ROOT/setup.sh' >/dev/null 2>&1"
l8_err="$(mktemp)"
env CDT_PREFIX="$(mktemp -d)/we#ird" CDT_AGENTS_DIR="$(mktemp -d)" CDT_STATE_DIR="$(mktemp -d)" \
    CDT_NO_LAUNCHCTL=1 bash "$ROOT/setup.sh" >/dev/null 2>"$l8_err" || true
assert_true "setup explains why the path was refused" grep -q 'must not contain' "$l8_err"
