# tests/test_common.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/fixtures.sh"
source "$HERE/../lib/common.sh"

# human_bytes
assert_eq "0B"    "$(cdt_human_bytes 0)"        "human_bytes 0"
assert_eq "1.0K"  "$(cdt_human_bytes 1024)"     "human_bytes 1K"
assert_eq "1.5M"  "$(cdt_human_bytes 1572864)"  "human_bytes 1.5M"

# 目录解析尊重环境变量
( export CODEX_HOME=/tmp/x; assert_eq "/tmp/x" "$(cdt_codex_home)" "codex_home from env" )

# 空库/缺文件安全
emptyhome="$(make_fixture_home 0)"
( export CODEX_HOME="$emptyhome"
  assert_eq "0" "$(cdt_insert_counter)" "insert_counter empty db = 0"
  assert_eq "0" "$(cdt_logs_rowcount)"  "rowcount empty db = 0" )
( export CODEX_HOME=/nonexistent-xyz
  assert_eq "0" "$(cdt_file_size "$(cdt_logs_db)")" "file_size missing = 0"
  assert_eq "0" "$(cdt_insert_counter)" "insert_counter missing db = 0" )

# 有数据:插入计数与行数
h5="$(make_fixture_home 5)"
( export CODEX_HOME="$h5"
  assert_eq "5" "$(cdt_insert_counter)" "insert_counter = seq 5"
  assert_eq "5" "$(cdt_logs_rowcount)"  "rowcount = 5" )

# 阈值比较
assert_true  "over: 10>5"      cdt_over 10 5
assert_false "not over: 5>5"   cdt_over 5 5

# MB/天换算: 100MB 在 3600s -> 2400 MB/day
assert_eq "2400.00" "$(cdt_mb_per_day $((100*1024*1024)) 3600)" "mb_per_day"

# TBW 年数: 1 GB/day, 150 TBW -> 150000 GB / 365 GB/yr ~ 410.96 年
assert_eq "410.96" "$(cdt_tbw_years $((1024*1024*1024)) 150)" "tbw_years"
