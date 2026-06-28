# How codex-disk-guard works

**English** | [中文](HOW-IT-WORKS.zh-CN.md)

A guided walk through **why this project exists**, **what approach it takes**, and **how each piece is implemented** — so you can understand not just *what* the code does, but *why* it does it that way.

## 1. Background — the problem

The OpenAI Codex CLI (and the desktop app) continuously writes high-frequency `TRACE` logs into a single SQLite database, `~/.codex/logs_2.sqlite` (see [openai/codex#29532](https://github.com/openai/codex/issues/29532)).

What developers observed in that issue:

- It is an **insert-and-prune churn**: the table's auto-increment id (`max(id)`) climbed by **~1,600+ rows per minute** of active use, even though the *retained* row count barely changed (old rows are deleted as new ones arrive).
- The database was seen at **~288 MB** with a **~13 MB WAL** (write-ahead log) that kept advancing.
- Setting `RUST_LOG=info` did **not** stop the persisted `TRACE` rows — the SQLite log sink has its **own** tracing layer that the environment variable does not control.
- There is currently **no configuration switch** to turn that sink off.

The practical worry: a steady stream of writes to the SSD, 24/7 if the desktop app's background daemon is running.

## 2. Solution — the approach (and why)

By default the tool works **around** Codex without modifying it, doing four things:

1. **Monitor** the write rate (so you know if it's bad / getting worse).
2. **Maintain** the log database (so it never grows without bound).
3. **Measure** precisely on demand (so you have hard numbers).
4. **Clean** one-off junk (so disk space is reclaimed).

Because the high-volume writes have no off-switch, the tool also offers a fifth, **opt-in** capability that *does* stop them — `codex-disk-block` — which modifies Codex's own log DB (a SQLite trigger; backed up first and reversible). It is gated behind `--apply` and is never run automatically.

The design decisions, and the reason behind each:

| Decision | Why |
|---|---|
| Monitor via the `sqlite_sequence` counter delta | The auto-increment counter is **monotonic** and survives pruning. Sampling it twice gives the exact number of inserted rows in between — an accurate rate **without sudo** and **without scanning** the whole DB. |
| Precise mode via `fs_usage` | When you want real byte counts (not an estimate), `fs_usage` measures actual writes to `~/.codex`. It needs sudo, so it's opt-in. |
| Maintain with `DELETE` + `wal_checkpoint(TRUNCATE)` + `VACUUM`, **lock-safe** | Keeps the log DB small without corrupting it. If Codex holds the lock, the job backs off instead of forcing a write. |
| **Never** touch `sessions/` or `memories/`; cleanup is **dry-run by default** | Safety first. The only data the tool may delete is a hardcoded junk list, and only with `--apply`. |
| State/reports kept **outside** `~/.codex` (in `~/.local/state/codex-disk/`) | So the monitor never counts its own writes as Codex's. |
| Scheduling via user-level **launchd** | Automatic daily runs, no root, no system changes. |
| **Zero dependencies**, bash 3.2, macOS-only | Clone and run — nothing to install. Only macOS tools (`launchd`, `fs_usage`, BSD `stat`, `sqlite3`). |

## 3. Implementation logic — component by component

### `lib/common.sh` — shared metric functions
The single source of truth for measurement, sourced by the `bin/` commands.

- **`cdt_insert_counter`** — the heart of monitoring. Runs
  `SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='logs'), (SELECT max(id) FROM logs), 0)`.
  *Why this formula:* `sqlite_sequence.seq` keeps rising even after every row is pruned, so it's a true cumulative insert count; `max(id)` is the fallback; `0` covers a missing/empty DB. Two samples → exact inserts in between.
- **`cdt_sum_fsusage_bytes`** — parses `fs_usage` output and sums the `B=0x…` byte fields of `write`/`pwrite` lines under a target path. *Why the odd split:* macOS's `awk` (BWK) has **no `strtonum`**, so awk only extracts the hex tokens and **bash arithmetic** (`$(( … ))`, which natively understands `0x`) does the addition.
- **`cdt_measure`** — runs `sudo fs_usage` for N seconds, sums the bytes, and converts to MB/day plus an SSD-lifetime estimate. Kills the `fs_usage` child cleanly so no root sampler is left behind.
- Helpers: `cdt_human_bytes` (byte → "1.5M"), `cdt_mb_per_day`, `cdt_tbw_years` (lifetime math), `cdt_detect_residual` (spots a leftover daemon: `app-server` / `remote-control` / `SkyComputerUse` process, launchd job, or autostart agent).

### `bin/codex-disk-check` — the monitor
- **Passive mode (default, no sudo):** reads `cdt_insert_counter`, compares it to the previous value stored in `last-sample`, and computes inserted rows + rows/min. It appends one line to `report.log` and prints it. First run has no previous sample, so it records a `baseline`.
- **Thresholds → PASS/WARN:** WARN if the estimated MB/day exceeds `CDT_LOGS_RATE_WARN_MB_DAY` (50), or the WAL exceeds `CDT_WAL_WARN_BYTES` (8 MB), or a residual writer is detected. *Why a passive default:* you can run it (or schedule it) with zero privileges and near-zero overhead.
- **`--measure [secs]`:** delegates to `cdt_measure` for precise, sudo-based numbers.

### `bin/codex-disk-maintain` — the maintenance
Runs, in one SQLite session: `PRAGMA busy_timeout=2000;` then `DELETE FROM logs WHERE ts < (now − retention·86400);` then `PRAGMA wal_checkpoint(TRUNCATE);` then `VACUUM;`.
- *Why this order:* delete old rows, fold the WAL back and truncate it, then compact the file.
- *Why lock-safe:* the short `busy_timeout` means if Codex is mid-write, the run gives up (exit 0, no corruption) rather than fighting for the lock.
- Retention is validated (`CDT_RETENTION_DAYS`, default 3) so a bad value can't silently turn the scheduled job into a no-op.
- It touches **only** `logs_2.sqlite` — no `rm`, no other paths.

### `bin/codex-disk-bench` — the benchmark
Runs the same `--measure` in four labelled scenarios — *idle baseline*, *CLI active*, *desktop idle*, *desktop active* — and saves each result under `bench/`.
- *Why staged + saved to files:* the four states can't all be captured in one sitting (you must install the desktop app between CLI and desktop stages). Persisting each stage lets the run span sessions, and `report` prints a side-by-side table at the end.
- *Why these four states:* the CLI only writes while active; the **desktop app adds an idle, 24/7 writer** (its daemon) — that idle churn is the real wear concern, so it gets its own measurement.

### `bin/codex-disk-cleanup` — the cleanup
Deletes a **hardcoded** list of obvious junk under `~/.codex` (stale `.bak` files, `.DS_Store`, `.tmp/`, rebuildable caches, the `computer-use/` app).
- *Why dry-run by default:* it previews and only deletes with `--apply`, so an accidental run can't lose anything.
- *Why a hardcoded list (never a glob):* `sessions/` and `memories/` can never be selected — the safety is structural, not conditional. A guard also refuses to run if `HOME`/`CODEX_HOME` is unset.

### `bin/codex-disk-block` / `codex-disk-unblock` — the opt-in "real" stop
The only lever that actually halts the churn, because it intercepts at the SQLite layer instead of the app.
- `codex-disk-block --apply` backs up the DB (sqlite `.backup`), installs `CREATE TRIGGER cdg_block_logs BEFORE INSERT ON logs BEGIN SELECT RAISE(IGNORE); END;`, then truncates the WAL. *Why a trigger:* `RAISE(IGNORE)` turns every insert into a silent no-op, so `sqlite_sequence`/`max(id)` freeze and the WAL stops growing — there is no app or config switch, so the table itself is the only place left to stop it.
- *Why it's gated:* it **modifies Codex's own database**, so it is dry-run unless `--apply`, backs up first, and is reversible with `codex-disk-unblock` (`DROP TRIGGER`).
- *Honest risks:* Codex features that read logs back may break; a Codex update that recreates the log DB drops the trigger. `codex-disk-uninstall` automatically removes this one trigger (lock-safe), so a clean uninstall restores normal Codex logging — it still never touches your sessions, memories, or log rows.

### `setup.sh` / `uninstall.sh` / `launchd/*.plist.template`
- `setup.sh` installs the commands to `~/.local/bin`, renders the two plist templates (substituting the real paths) into `~/Library/LaunchAgents`, and loads them. Preflight refuses non-macOS and missing `sqlite3`, and it warns if `~/.local/bin` isn't on your `PATH`.
- The launchd jobs run **maintain at 03:00** and **check at 03:05** daily, user-level (no root). If the Mac is asleep, launchd catches up on wake.
- `uninstall.sh` removes exactly what setup created (commands, lib, plists, the whole state dir) and lists them. The only thing it touches in `~/.codex` is the optional block trigger — it drops that if present (lock-safe), restoring normal logging — and it never touches your sessions, memories, log rows, or your own config edits.

## 4. The known limitation (stated honestly)
The active-use writes to `logs_2.sqlite` **cannot be eliminated** by configuration today. This tool keeps that database **bounded and observable** and removes the *idle* and *junk* portions — but it is a mitigation, not a cure. If Codex later ships a switch to disable the sink, that becomes the real fix and this tool becomes a monitor.

Lowering the write *rate* is possible only outside the app's control. The opt-in `codex-disk-block` command does it by intercepting at the SQLite layer (a `BEFORE INSERT` trigger) — the one place with no off-switch — at the cost of modifying Codex's own database (see that component above). Two lighter levers help *partially* without touching the DB: raising the log level (`export RUST_LOG=error`) trims the filter-respecting categories but **not** the high-volume `target=log` rows; and fully quitting the desktop app removes its 24/7 idle writer. Measure any of them with `codex-disk-check --measure` / `codex-disk-bench`.
