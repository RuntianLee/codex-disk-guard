# tests/test_measure.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/common.sh"

# 模拟 fs_usage 三行写操作(字段:... 字节数 ... 路径),分别 4096/8192/100 字节写到 .codex
sample="$(cat <<'EOF'
12:00:00  write    F=5  B=0x1000  /Users/x/.codex/logs_2.sqlite-wal  0.01 codex
12:00:01  pwrite   F=5  B=0x2000  /Users/x/.codex/logs_2.sqlite      0.01 codex
12:00:02  write    F=9  B=0x64    /Users/x/.codex/sessions/a.jsonl   0.01 codex
12:00:03  read     F=5  B=0x1000  /Users/x/.codex/logs_2.sqlite      0.01 codex
EOF
)"
# 期望:只统计 write/pwrite 的 B= 字节:0x1000+0x2000+0x64 = 4096+8192+100 = 12388
got="$(printf '%s\n' "$sample" | cdt_sum_fsusage_bytes "/Users/x/.codex")"
assert_eq "12388" "$got" "sum_fsusage_bytes counts only writes under target"
