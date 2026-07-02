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

# L7: 非法十六进制 token 必须被忽略，不能进入算术展开
bad_sample='12:00:00  write  F=5  B=0xZZ  /Users/x/.codex/a  0.01 codex
12:00:01  write  F=5  B=0x10  /Users/x/.codex/a  0.01 codex'
got_bad="$(printf '%s\n' "$bad_sample" | cdt_sum_fsusage_bytes "/Users/x/.codex" 2>/dev/null)"
assert_eq "16" "$got_bad" "malformed hex tokens are ignored"

# M3: --measure 被 INT 中断时，采样子进程必须被杀掉
fake_bin="$(mktemp -d)"
cat > "$fake_bin/fake-sudo" <<'FS'
#!/bin/bash
[ "$1" = "-v" ] && exit 0
exec "$@"
FS
cat > "$fake_bin/fake-fs_usage" <<'FF'
#!/bin/bash
while :; do echo "12:00:00 write F=1 B=0x100 /tmp/x"; sleep 0.2; done
FF
chmod +x "$fake_bin/fake-sudo" "$fake_bin/fake-fs_usage"
( CDT_SUDO="$fake_bin/fake-sudo" CDT_FSUSAGE="$fake_bin/fake-fs_usage" \
  bash -c "source '$HERE/../lib/common.sh'; cdt_measure 30 1" >/dev/null 2>&1 ) &
runner=$!
sleep 1
kill -INT "$runner" 2>/dev/null; wait "$runner" 2>/dev/null
sleep 0.5
leftover="$(pgrep -f fake-fs_usage || true)"
assert_eq "" "$leftover" "interrupted measure leaves no sampler process behind"
pkill -f fake-fs_usage 2>/dev/null || true   # 兜底清理，避免失败时污染后续测试
