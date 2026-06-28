# lib/common.sh — shared pure functions and metric collection.
# Reused by codex-disk-{maintain,check,bench}.
# No 'set -e' here: this file is sourced as a library, so each function reports
# failure through its return value / output rather than aborting the caller.
CDT_SQLITE="${CDT_SQLITE:-$(command -v sqlite3 2>/dev/null || echo /usr/bin/sqlite3)}"

cdt_codex_home() { printf '%s' "${CODEX_HOME:-$HOME/.codex}"; }
# Report/state directory (default ~/.local/state/codex-disk). Everything this tool
# persists lives here: report.log + last-sample (codex-disk-check), bench/*.json
# (codex-disk-bench), and the launchd jobs' *.out/err.log. Kept OUTSIDE ~/.codex so
# monitoring never counts its own writes. Removed entirely by codex-disk-uninstall.
cdt_state_dir()  { printf '%s' "${CDT_STATE_DIR:-$HOME/.local/state/codex-disk}"; }
cdt_logs_db()    { printf '%s/logs_2.sqlite' "$(cdt_codex_home)"; }

cdt_human_bytes() { # <int bytes>
  awk -v b="${1:-0}" 'BEGIN{
    split("B K M G T",u," "); i=1; x=b+0;
    while (x>=1024 && i<5){ x/=1024; i++ }
    if (i==1) printf "%dB", x; else printf "%.1f%s", x, u[i];
  }'
}

cdt_file_size() { # <path> -> size in bytes, or 0 if the file is missing
  if [ -f "$1" ]; then stat -f '%z' "$1" 2>/dev/null || echo 0; else echo 0; fi
}

# Monotonic insert counter for the logs table.
# Prefer sqlite_sequence.seq (keeps rising even after old rows are pruned),
# fall back to max(id), then 0 when the db/table is missing or empty.
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

cdt_over() { # <value> <threshold> -> exit 0 when value > threshold (supports decimals)
  awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a+0 > b+0) }'
}

cdt_mb_per_day() { # <bytes> <elapsed_seconds> -> MB/day, 2 decimals
  awk -v by="$1" -v s="$2" 'BEGIN{
    if (s+0<=0){ printf "0.00"; exit }
    printf "%.2f", (by/1048576.0) * (86400.0/s);
  }'
}

cdt_tbw_years() { # <bytes_per_day> <tbw_tb> -> years, 2 decimals
  awk -v bpd="$1" -v tbw="$2" 'BEGIN{
    gb_per_day = bpd/1073741824.0;
    if (gb_per_day<=0){ printf "inf"; exit }
    total_gb = tbw*1000.0;            # 1 TB = 1000 GB (vendor convention)
    printf "%.2f", total_gb/(gb_per_day*365.0);
  }'
}

# Detect a leftover Codex daemon / autostart agent that would keep writing in the
# background. Echo one line per finding; produce no output when nothing is found.
# (SkyComputerUse is the Codex desktop app's "computer use" helper process, one of
# the resident writers the desktop app can leave running.)
cdt_detect_residual() {
  ps aux | grep -iE 'codex .*(app-server|remote-control)|SkyComputerUse' | grep -v grep \
    | awk '{print "proc:", $2, $11, $12, $13}'
  launchctl list 2>/dev/null | grep -i codex | awk '{print "launchd:", $0}'
  ls "$HOME/Library/LaunchAgents" /Library/LaunchAgents 2>/dev/null \
    | grep -iE 'codex|openai' | awk '{print "agent:", $0}'
}

# Read fs_usage text from stdin and sum the B=0x.. byte counts of write/pwrite
# operations whose path contains <target>.
# Note: macOS /usr/bin/awk (BWK) has no strtonum, so awk only extracts the 0x
# values and bash arithmetic does the hex addition.
cdt_sum_fsusage_bytes() { # <target_path_substring>
  local target="$1" total=0 v
  while IFS= read -r v; do
    [ -n "$v" ] && total=$(( total + v ))   # v looks like 0x1000; bash arithmetic reads 0x natively
  done < <(awk -v t="$target" '
    /(^| )(write|pwrite)( |$)/ && index($0,t) {
      for (i=1;i<=NF;i++) if ($i ~ /^B=0x/) { v=$i; sub(/^B=/,"",v); print v }
    }')
  printf '%d' "$total"
}

# Precise measurement: run fs_usage for <secs> seconds, sum the bytes written to
# CODEX_HOME, and convert to a rate. Requires sudo; prints a clear hint if it is
# unavailable or the session is non-interactive.
cdt_measure() { # <secs> <want_json>
  local secs="${1:-60}" want_json="${2:-0}"
  local home; home="$(cdt_codex_home)"
  local tmp; tmp="$(mktemp)"
  echo "Sampling with fs_usage for ${secs}s (needs sudo). Use Codex normally during this window to measure active writes..." >&2
  # -w wide format; -f filesystem limits the trace to filesystem events
  if ! sudo -v 2>/dev/null; then echo "sudo is required to run fs_usage" >&2; rm -f "$tmp"; return 3; fi
  sudo fs_usage -w -f filesystem 2>/dev/null > "$tmp" &
  local fpid=$!
  sleep "$secs"
  # Kill the sudo child first (the real fs_usage), then the sudo wrapper, so no
  # root sampling process is left running.
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
    printf 'Active writes: %s in %ss = %s MB/day equivalent (if sustained)\n' "$(cdt_human_bytes "$bytes")" "$secs" "$mbday"
    printf 'SSD lifetime (assuming %s TBW at this 24/7 rate): ~%s years (relative comparison only; it only writes while active)\n' "${CDT_TBW_TB:-150}" "$years"
  fi
}
