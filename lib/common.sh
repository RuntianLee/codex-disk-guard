# lib/common.sh — 共享纯函数与指标采集(被 maintain/check 复用)
# 不要 set -e:作为库被 source,失败处理交由各函数返回值。
CDT_SQLITE="${CDT_SQLITE:-/usr/bin/sqlite3}"

cdt_codex_home() { printf '%s' "${CODEX_HOME:-$HOME/.codex}"; }
cdt_state_dir()  { printf '%s' "${CDT_STATE_DIR:-$HOME/.local/state/codex-disk}"; }
cdt_logs_db()    { printf '%s/logs_2.sqlite' "$(cdt_codex_home)"; }

cdt_human_bytes() { # <int bytes>
  awk -v b="${1:-0}" 'BEGIN{
    split("B K M G T",u," "); i=1; x=b+0;
    while (x>=1024 && i<5){ x/=1024; i++ }
    if (i==1) printf "%dB", x; else printf "%.1f%s", x, u[i];
  }'
}

cdt_file_size() { # <path> -> bytes 或 0
  if [ -f "$1" ]; then stat -f '%z' "$1" 2>/dev/null || echo 0; else echo 0; fi
}

# 单调插入计数:优先 sqlite_sequence.seq(行被 prune 后仍不回退),回退 max(id),再回退 0。
cdt_insert_counter() {
  local db; db="$(cdt_logs_db)"
  [ -f "$db" ] || { echo 0; return; }
  local v
  v="$("$CDT_SQLITE" "$db" \
    "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='logs'),(SELECT max(id) FROM logs),0);" 2>/dev/null)"
  [ -n "$v" ] && printf '%s' "$v" || echo 0
}

cdt_logs_rowcount() {
  local db; db="$(cdt_logs_db)"
  [ -f "$db" ] || { echo 0; return; }
  local v; v="$("$CDT_SQLITE" "$db" "SELECT count(*) FROM logs;" 2>/dev/null)"
  [ -n "$v" ] && printf '%s' "$v" || echo 0
}

cdt_wal_size() { cdt_file_size "$(cdt_logs_db)-wal"; }

cdt_over() { # <value> <threshold> -> 退出码0 当 value>threshold(支持小数)
  awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a+0 > b+0) }'
}

cdt_mb_per_day() { # <bytes> <elapsed_seconds> -> MB/day, 2位小数
  awk -v by="$1" -v s="$2" 'BEGIN{
    if (s+0<=0){ printf "0.00"; exit }
    printf "%.2f", (by/1048576.0) * (86400.0/s);
  }'
}

cdt_tbw_years() { # <bytes_per_day> <tbw_tb> -> 年, 2位小数
  awk -v bpd="$1" -v tbw="$2" 'BEGIN{
    gb_per_day = bpd/1073741824.0;
    if (gb_per_day<=0){ printf "inf"; exit }
    total_gb = tbw*1000.0;            # 1 TB = 1000 GB(厂商口径)
    printf "%.2f", total_gb/(gb_per_day*365.0);
  }'
}

# 检测残留 daemon / 自启项;有则逐行 echo,无则无输出。
cdt_detect_residual() {
  ps aux | grep -iE 'codex .*(app-server|remote-control)|SkyComputerUse' | grep -v grep \
    | awk '{print "proc:", $2, $11, $12, $13}'
  launchctl list 2>/dev/null | grep -i codex | awk '{print "launchd:", $0}'
  ls "$HOME/Library/LaunchAgents" /Library/LaunchAgents 2>/dev/null \
    | grep -iE 'codex|openai' | awk '{print "agent:", $0}'
}
cdt_measure() { echo "measure mode not yet implemented" >&2; return 3; }
