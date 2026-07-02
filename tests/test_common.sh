# tests/test_common.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/fixtures.sh"
source "$HERE/../lib/common.sh"

# human_bytes
assert_eq "0B"    "$(cdt_human_bytes 0)"        "human_bytes 0"
assert_eq "1.0K"  "$(cdt_human_bytes 1024)"     "human_bytes 1K"
assert_eq "1.5M"  "$(cdt_human_bytes 1572864)"  "human_bytes 1.5M"

# 目录解析尊重环境变量
assert_eq "/tmp/x" "$(CODEX_HOME=/tmp/x cdt_codex_home)" "codex_home from env"

# 空库/缺文件安全
emptyhome="$(make_fixture_home 0)"
assert_eq "0" "$(CODEX_HOME="$emptyhome" cdt_insert_counter)" "insert_counter empty db = 0"
assert_eq "0" "$(CODEX_HOME="$emptyhome" cdt_logs_rowcount)"  "rowcount empty db = 0"
assert_eq "0" "$(CODEX_HOME=/nonexistent-xyz cdt_file_size "$(CODEX_HOME=/nonexistent-xyz cdt_logs_db)")" "file_size missing = 0"
assert_eq "0" "$(CODEX_HOME=/nonexistent-xyz cdt_insert_counter)" "insert_counter missing db = 0"

# 有数据:插入计数与行数
h5="$(make_fixture_home 5)"
assert_eq "5" "$(CODEX_HOME="$h5" cdt_insert_counter)" "insert_counter = seq 5"
assert_eq "5" "$(CODEX_HOME="$h5" cdt_logs_rowcount)"  "rowcount = 5"

# 阈值比较
assert_true  "over: 10>5"      cdt_over 10 5
assert_false "not over: 5>5"   cdt_over 5 5

# MB/天换算: 100MB 在 3600s -> 2400 MB/day
assert_eq "2400.00" "$(cdt_mb_per_day $((100*1024*1024)) 3600)" "mb_per_day"

# TBW 年数: 1 GB/day, 150 TBW -> 150000 GB / 365 GB/yr ~ 410.96 年
assert_eq "410.96" "$(cdt_tbw_years $((1024*1024*1024)) 150)" "tbw_years"

# H1: 工具自装的 launchd 代理不得被当成残留写入者
fakehome="$(mktemp -d)"; mkdir -p "$fakehome/Library/LaunchAgents"
touch "$fakehome/Library/LaunchAgents/com.user.codex-disk-check.plist" \
      "$fakehome/Library/LaunchAgents/com.user.codex-disk-maintain.plist"
own_agents="$(HOME="$fakehome" cdt_detect_residual | grep 'codex-disk' || true)"
assert_eq "" "$own_agents" "own codex-disk agents are not reported as residual"

# 真正的 Codex 自启动代理仍然要被发现
touch "$fakehome/Library/LaunchAgents/com.openai.codex.helper.plist"
real_agent="$(HOME="$fakehome" cdt_detect_residual | grep -c 'com.openai.codex.helper' || true)"
assert_eq "1" "$real_agent" "genuine codex agent is still detected"

# L5: 多目录 ls 不得混入目录头行(形如 "agent: /path:")
headers="$(HOME="$fakehome" cdt_detect_residual | grep -E '^agent: /' || true)"
assert_eq "" "$headers" "no ls directory-header noise in agent lines"

# 重构: 数字环境变量校验的公共函数
assert_eq "42"  "$(CDT_X=42 cdt_validate_int CDT_X 7 2>/dev/null)"    "validate_int passes a good value"
assert_eq "7"   "$(CDT_X=abc cdt_validate_int CDT_X 7 2>/dev/null)"   "validate_int falls back on garbage"
assert_eq "7"   "$(cdt_validate_int CDT_UNSET_X 7 2>/dev/null)"       "validate_int uses default when unset"
v_err="$(mktemp)"
CDT_X=abc cdt_validate_int CDT_X 7 >/dev/null 2>"$v_err"
assert_true "validate_int notes the fallback on stderr" grep -q "invalid CDT_X" "$v_err"
assert_eq "0.5" "$(CDT_X=0.5 cdt_validate_num CDT_X 50 2>/dev/null)"  "validate_num accepts decimals"
assert_eq "50"  "$(CDT_X=1.2.3 cdt_validate_num CDT_X 50 2>/dev/null)" "validate_num rejects double dots"

# 重构: launchd label 前缀单一真源
assert_eq "com.user.codex-disk-" "$CDT_LAUNCHD_LABEL_PREFIX" "label prefix defined in common.sh"
