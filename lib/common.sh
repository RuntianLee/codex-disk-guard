# lib/common.sh — shared pure functions and metric collection.
# Reused by codex-disk-{maintain,check,bench}.
# No 'set -e' here: this file is sourced as a library, so each function reports
# failure through its return value / output rather than aborting the caller.
CDT_SQLITE="${CDT_SQLITE:-$(command -v sqlite3 2>/dev/null || echo /usr/bin/sqlite3)}"

# Single source of truth for the launchd label prefix. setup.sh renders it into
# the plists and job names, uninstall.sh derives the labels from it (with a
# same-literal fallback the tests keep in sync), and cdt_detect_residual
# excludes it so the tool never flags its own agents as residual writers.
CDT_LAUNCHD_LABEL_PREFIX='com.user.codex-disk-'

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

# True (exit 0) if our insert-blocking trigger (installed by codex-disk-block) is present.
cdt_block_trigger_installed() {
  local db; db="$(cdt_logs_db)"
  [ -f "$db" ] || return 1
  local n; n="$("$CDT_SQLITE" "$db" "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name='cdg_block_logs';" 2>/dev/null)"
  [ "${n:-0}" = "1" ]
}

# Validate numeric env knobs: echo the env var's value when well-formed,
# otherwise echo the default and note the fallback on stderr — a typo'd value
# must fail loudly, not silently coerce to 0 in awk and produce phantom WARNs.
cdt_validate_int() { # <env_name> <default> -> plain non-negative integer
  local v; v="${!1:-$2}"
  case "$v" in ''|*[!0-9]*) echo "warn: invalid $1='$v', using $2" >&2; v="$2" ;; esac
  printf '%s' "$v"
}

cdt_validate_num() { # <env_name> <default> -> integer or decimal (one dot max)
  local v; v="${!1:-$2}"
  case "$v" in ''|.|*[!0-9.]*|*.*.*) echo "warn: invalid $1='$v', using $2" >&2; v="$2" ;; esac
  printf '%s' "$v"
}

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
# This tool's own launchd agents (com.user.codex-disk-*) also contain "codex" and
# must be excluded, or every scheduled check would WARN on itself forever.
# (SkyComputerUse is the Codex desktop app's "computer use" helper process, one of
# the resident writers the desktop app can leave running.)
CDT_SELF_AGENT_RE="${CDT_LAUNCHD_LABEL_PREFIX//./\\.}"
cdt_detect_residual() {
  ps aux | grep -iE 'codex .*(app-server|remote-control)|SkyComputerUse' | grep -v grep \
    | awk '{print "proc:", $2, $11, $12, $13}'
  launchctl list 2>/dev/null | grep -i codex | grep -vE "$CDT_SELF_AGENT_RE" \
    | awk '{print "launchd:", $0}'
  local d
  for d in "$HOME/Library/LaunchAgents" /Library/LaunchAgents; do
    ls "$d" 2>/dev/null | grep -iE 'codex|openai' | grep -vE "$CDT_SELF_AGENT_RE" \
      | awk '{print "agent:", $0}'
  done
}

# Read fs_usage text from stdin and sum the B=0x.. byte counts of write/pwrite
# operations whose path contains <target>.
# Note: macOS /usr/bin/awk (BWK) has no strtonum, so awk only extracts the 0x
# values and bash arithmetic does the hex addition.
cdt_sum_fsusage_bytes() { # <target_path_substring>
  local target="$1" total=0 v
  while IFS= read -r v; do
    # Only well-formed hex may reach arithmetic expansion.
    case "$v" in
      0x*[!0-9a-fA-F]*|0x|"") continue ;;
    esac
    total=$(( total + v ))   # v looks like 0x1000; bash arithmetic reads 0x natively
  done < <(awk -v t="$target" '
    /(^| )(write|pwrite)( |$)/ && index($0,t) {
      for (i=1;i<=NF;i++) if ($i ~ /^B=0x/) { v=$i; sub(/^B=/,"",v); print v }
    }')
  printf '%d' "$total"
}

# Interrupted-measure cleanup: killing the shell mid-window must not leave a
# root fs_usage writing to a temp file forever (this tool must never become
# the resident disk writer it hunts).
_cdt_measure_pid=""; _cdt_measure_tmp=""; _cdt_measure_sudo="sudo"
_cdt_measure_abort() {
  [ -n "$_cdt_measure_pid" ] && {
    "$_cdt_measure_sudo" pkill -P "$_cdt_measure_pid" 2>/dev/null
    "$_cdt_measure_sudo" kill "$_cdt_measure_pid" 2>/dev/null
  }
  rm -f "$_cdt_measure_tmp"
  exit 130
}

# Precise measurement: run fs_usage for <secs> seconds, sum the bytes written to
# CODEX_HOME, and convert to a rate. Requires sudo; prints a clear hint if it is
# unavailable or the session is non-interactive.
# CDT_SUDO / CDT_FSUSAGE exist only as test seams (defaults: sudo / fs_usage).
cdt_measure() { # <secs> <want_json>
  local secs="${1:-60}" want_json="${2:-0}"
  local home; home="$(cdt_codex_home)"
  local tmp; tmp="$(mktemp)"
  local sudo_cmd="${CDT_SUDO:-sudo}" fsusage_cmd="${CDT_FSUSAGE:-fs_usage}"
  echo "Sampling with fs_usage for ${secs}s (needs sudo). Use Codex normally during this window to measure active writes..." >&2
  # -w wide format; -f filesystem limits the trace to filesystem events
  if ! "$sudo_cmd" -v 2>/dev/null; then echo "sudo is required to run fs_usage" >&2; rm -f "$tmp"; return 3; fi
  "$sudo_cmd" "$fsusage_cmd" -w -f filesystem 2>/dev/null > "$tmp" &
  local fpid=$!
  _cdt_measure_pid="$fpid"; _cdt_measure_tmp="$tmp"; _cdt_measure_sudo="$sudo_cmd"
  trap _cdt_measure_abort INT TERM
  sleep "$secs"
  trap - INT TERM
  # Kill the sudo child first (the real fs_usage), then the sudo wrapper, so no
  # root sampling process is left running.
  "$sudo_cmd" pkill -P "$fpid" 2>/dev/null; "$sudo_cmd" kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
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
