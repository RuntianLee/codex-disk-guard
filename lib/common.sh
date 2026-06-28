# lib/common.sh — 共享纯函数与指标采集(被 maintain/check 复用)
# 不要 set -e:作为库被 source,失败处理交由各函数返回值。
CDT_SQLITE="${CDT_SQLITE:-$(command -v sqlite3 2>/dev/null || echo /usr/bin/sqlite3)}"

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
# 从 stdin 读 fs_usage 文本,累加 write/pwrite 操作中 B=0x.. 字节(仅限路径含 <target>)。
# 注意: macOS /usr/bin/awk(BWK)无 strtonum,故用 awk 仅抽取 0x 值、由 bash 算术求和。
cdt_sum_fsusage_bytes() { # <target_path_substring>
  local target="$1" total=0 v
  while IFS= read -r v; do
    [ -n "$v" ] && total=$(( total + v ))   # v 形如 0x1000,bash 算术原生识别 0x
  done < <(awk -v t="$target" '
    /(^| )(write|pwrite)( |$)/ && index($0,t) {
      for (i=1;i<=NF;i++) if ($i ~ /^B=0x/) { v=$i; sub(/^B=/,"",v); print v }
    }')
  printf '%d' "$total"
}

# 精确测速:用 fs_usage 抓 <secs> 秒,统计对 CODEX_HOME 的写字节,换算速率。
# 需要 sudo;无 sudo 或非交互时给出清晰提示。
cdt_measure() { # <secs> <want_json>
  local secs="${1:-60}" want_json="${2:-0}"
  local home; home="$(cdt_codex_home)"
  local tmp; tmp="$(mktemp)"
  echo "正在用 fs_usage 采样 ${secs}s(需 sudo)。请在此期间正常使用 codex 以测活跃写入…" >&2
  # -w 宽格式; -f filesystem 只看文件系统事件
  if ! sudo -v 2>/dev/null; then echo "需要 sudo 来运行 fs_usage" >&2; rm -f "$tmp"; return 3; fi
  sudo fs_usage -w -f filesystem 2>/dev/null > "$tmp" &
  local fpid=$!
  sleep "$secs"
  # 先杀 sudo 的子进程(真正的 fs_usage),再杀 sudo 包装进程,确保 root 采样进程不残留
  sudo pkill -P "$fpid" 2>/dev/null; sudo kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
  local bytes; bytes="$(cdt_sum_fsusage_bytes "$home" < "$tmp")"
  rm -f "$tmp"
  local mbday; mbday="$(cdt_mb_per_day "$bytes" "$secs")"
  local bpd; bpd="$(awk -v by="$bytes" -v s="$secs" 'BEGIN{printf "%d", by*(86400.0/s)}')"
  local years; years="$(cdt_tbw_years "$bpd" "${CDT_TBW_TB:-150}")"
  if [ "$want_json" -eq 1 ]; then
    printf '{"window_s":%s,"write_bytes":%s,"mb_per_day_active":%s,"tbw_years_if_24x7":"%s"}\n' \
      "$secs" "$bytes" "$mbday" "$years"
  else
    printf '活跃期写入: %s / %ss = %s MB/天当量(若全天持续)\n' "$(cdt_human_bytes "$bytes")" "$secs" "$mbday"
    printf 'SSD 寿命(假设 %s TBW、该速率 24x7): 约 %s 年(仅供相对对比,实际只在活跃时写)\n' "${CDT_TBW_TB:-150}" "$years"
  fi
}
