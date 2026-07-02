# codex-disk-guard

[![tests](https://github.com/RuntianLee/codex-disk-guard/actions/workflows/test.yml/badge.svg)](https://github.com/RuntianLee/codex-disk-guard/actions/workflows/test.yml)

**English** | [中文](README.zh-CN.md)

**Tame the OpenAI Codex CLI's constant disk writing on macOS — monitor it, keep its log database from growing, and clean up junk, without ever touching your sessions or memories.**

> ⚠️ **Disclaimer.** This project was built entirely by an AI agent. It was tested and ran without anomalies on the author's machine (macOS, Apple Silicon; OpenAI Codex CLI **`0.142.2`**), but **no guarantee is made about its safety on other systems or with other data.** Please read the scripts before running them and use at your own risk — start with the dry-run / monitoring commands (`codex-disk-check`, `codex-disk-cleanup` without `--apply`).

> Background: the Codex CLI continuously writes high-frequency `TRACE` logs into `~/.codex/logs_2.sqlite` (see [openai/codex#29532](https://github.com/openai/codex/issues/29532)). The `RUST_LOG` environment variable does **not** stop it, because the SQLite log sink has its own tracing layer. There is currently no config switch to disable that sink. By default this toolkit works *around* Codex without modifying it — monitoring, low-frequency maintenance, and safe cleanup. It also ships one **opt-in** command (`codex-disk-block`) that can actually stop the writes at the database level; that one **does** modify Codex's own log DB (with a backup first and an easy undo).

> 📖 **New here?** Read **[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md)** for the background, the approach, and a component-by-component explanation of *how* and *why* it works.

## What it does

| Command | What it does |
|---|---|
| `codex-disk-check` | **Monitor.** Samples how many log rows Codex inserted since last run and reports a write rate. No `sudo`. Appends one line to a report log. |
| `codex-disk-check --measure 60` | **Precisely measure** real bytes written to `~/.codex` over 60s using `fs_usage` (needs `sudo`). Prints a MB/day figure and an SSD-lifetime estimate. |
| `codex-disk-maintain` | **Maintain.** Deletes log rows older than N days, truncates the WAL, and `VACUUM`s `logs_2.sqlite` so it stays small. Only touches that one database. |
| `codex-disk-cleanup` | **Preview cleanup (dry-run).** Lists the disposable junk it *would* remove (stale backups, caches, temp dirs) and **deletes nothing** — this is expected, not a failure. Never touches `sessions/` or `memories/`. |
| `codex-disk-cleanup --apply` | **Actually deletes** that junk. Only this form removes files. |
| `codex-disk-bench` | **Benchmark.** Stage-by-stage comparison of write rates — idle baseline, CLI active, and (if you install the desktop app) desktop idle / active — then a side-by-side table. |
| `codex-disk-block` / `--apply` | **⚠️ Advanced, opt-in.** Installs a SQLite trigger that **actually stops** Codex's log writes at the database level — the only thing that halts the churn. **Modifies Codex's own database**; dry-run unless `--apply`, and it backs the DB up first. |
| `codex-disk-unblock` | Removes that trigger; Codex resumes logging normally. |
| `codex-disk-uninstall` | **Uninstall** everything this tool installed. |

`setup.sh` installs these commands into `~/.local/bin` and registers two `launchd` jobs that run **maintain at 03:00** and **check at 03:05** every day.

> **Note:** by default this tool *monitors, maintains, and cleans* — it does not change how often Codex writes. One **opt-in, advanced** command (`codex-disk-block`) can actually stop the writes at the database level. See **[Reducing the writes](#reducing-the-writes)** below.

## Why the writes happen (and what this can / can't do)

- The hot file is `~/.codex/logs_2.sqlite`. Developers in [issue #29532](https://github.com/openai/codex/issues/29532) reported it growing to ~288 MB (with a ~13 MB WAL), with the insert counter (`max(id)`) advancing **~1,600+ rows per minute** of active use (≈470 KB of `TRACE log` content in a single 60-second window), and `RUST_LOG` not stopping it. Your own rate depends on your Codex log settings — those are reporters' real measurements, not a number this tool measured for you.
- This **cannot be turned off** by configuration today — so this tool does not claim to eliminate writes during active use. Instead it (a) keeps that database from growing without bound, (b) lets you watch the write rate over time, and (c) removes one-off junk.
- For perspective: even at 1–2 GB/day (~0.5 TB/year), a modern SSD rated at hundreds of TBW lasts centuries. The point of this tool is awareness and hygiene, not panic.

## Reducing the writes

By default this tool only *observes and tidies* — `codex-disk-maintain` bounds the file *size* but does not change how often Codex writes. There is **one opt-in way to actually stop the writes**, plus two lighter config/behaviour levers:

- **`codex-disk-block` — opt-in, advanced, actually stops it.** Installs a SQLite `BEFORE INSERT … RAISE(IGNORE)` trigger on the `logs` table, so Codex's inserts become silent no-ops and the churn halts at the database level — the only place with no off-switch. Because it **modifies Codex's own database**, it is dry-run unless you pass `--apply`, it backs the DB up first, and `codex-disk-unblock` reverses it. **Caveats:** Codex features that read those logs back (e.g. feedback sharing) may break; a Codex update that recreates the log DB will silently drop the trigger; uninstalling this tool **automatically removes the trigger** (lock-safe), restoring normal Codex logging. Verify it worked with `codex-disk-check --measure`.
- **Lower the log level** — `export RUST_LOG=error` in `~/.zshenv`. Trims the categories that respect the filter (much of INFO/DEBUG and some `codex_*` TRACE targets) but **not** the high-volume `target=log` rows. Partial, and varies by setup.
- **Don't keep the desktop app's daemon resident** — the 24/7 idle churn comes from the desktop app-server; fully quitting it removes that source (the CLI alone has no idle writer).

**Measure the real effect on *your* machine:** run `codex-disk-check --measure 60` (or `codex-disk-bench`) before and after.

## Requirements

- **macOS only** (uses `launchd`, `fs_usage`, BSD `stat`). The installer refuses to run elsewhere.
- `sqlite3` — ships with macOS at `/usr/bin/sqlite3`; Homebrew's is auto-detected if present.
- `bash` — works with the system bash 3.2; no bash 4+ features used.
- The OpenAI **Codex CLI** installed (this tool reads/maintains `~/.codex`).

## Running the tests

The full suite is hermetic — it runs against temp `HOME`/`CODEX_HOME` fixtures and never touches your real `~/.codex` or launchd:

```bash
bash tests/run_tests.sh
```

The same suite runs in CI on every push and pull request (macOS runner).

## Install

```bash
git clone https://github.com/RuntianLee/codex-disk-guard.git
cd codex-disk-guard
./setup.sh
```

If `setup.sh` warns that `~/.local/bin` is not on your `PATH`, add it and reopen your terminal:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

## Usage

```bash
codex-disk-check                 # quick status, no sudo; appends to the report log
codex-disk-check --json          # same, machine-readable single line
codex-disk-check --measure 60    # precise active write rate over 60s (sudo); use Codex during the window
codex-disk-maintain              # prune old logs + checkpoint + vacuum now
codex-disk-cleanup               # preview junk to delete (dry-run)
codex-disk-cleanup --apply       # actually delete the junk

# ⚠️  ADVANCED — actually STOPS the writes by modifying Codex's own DB (backs up first; reversible):
codex-disk-block                 # preview (dry-run) — shows what it would do, changes nothing
codex-disk-block --apply         # install the trigger that halts Codex's log writes
codex-disk-unblock               # remove the trigger; Codex resumes logging
```

A typical "is it still writing a lot?" check is just `codex-disk-check`. Run `--measure` when you want hard numbers.

### Benchmark: CLI vs desktop app

The CLI only writes while you actively run it. The **desktop app** additionally runs a background daemon that writes 24/7 even when idle — that idle churn is the real wear concern. `codex-disk-bench` measures both, stage by stage, so you can compare:

```bash
codex-disk-bench guide            # runs: ① idle baseline → ② CLI active → ③ maintain
# ...then install & launch the desktop app, and:
codex-disk-bench desktop-idle 120 # ④ app running, do NOT touch it (measures the daemon's idle writes)
codex-disk-bench desktop-active   # ⑤ actively use the app
codex-disk-bench report           # side-by-side table (no sudo)
```

The measurement command is identical for every stage; only the scenario differs. Stages ④/⑤ are only meaningful once the desktop app (and its daemon) is installed — the CLI has no idle-writing state.

## How it works

- **Passive monitoring** uses the `logs` table's `sqlite_sequence` counter (a monotonic insert count that does not go down even when old rows are pruned). The difference between two samples is exactly how many log rows were inserted in between — so you get an accurate insert rate **without `sudo`** and without scanning the whole database.
- **Precise mode** (`--measure`) runs `sudo fs_usage` for N seconds, sums the bytes written to paths under `~/.codex`, and extrapolates to MB/day plus an SSD-lifetime estimate (using `CDT_TBW_TB`, default 150).
- **Maintenance** runs `DELETE FROM logs WHERE ts < cutoff`, `PRAGMA wal_checkpoint(TRUNCATE)`, and `VACUUM`. If the database is locked (Codex is using it), it backs off safely and exits 0 without touching data.

## Scheduled jobs

`setup.sh` installs two user-level `launchd` agents (no root, no system changes):

- `com.user.codex-disk-maintain` — daily at **03:00**
- `com.user.codex-disk-check` — daily at **03:05**

If your Mac is asleep at that time, `launchd` runs the job at the next wake. Job stdout/stderr go to `~/.local/state/codex-disk/`.

## Configuration

All settings are environment variables with sensible defaults:

| Variable | Default | Meaning |
|---|---|---|
| `CODEX_HOME` | `~/.codex` | Codex data directory |
| `CDT_STATE_DIR` | `~/.local/state/codex-disk` | Where reports are written (kept **outside** `~/.codex`) |
| `CDT_RETENTION_DAYS` | `3` | Maintenance keeps log rows newer than this |
| `CDT_WAL_WARN_BYTES` | `8388608` (8 MB) | Check warns if the WAL grows past this |
| `CDT_LOGS_RATE_WARN_MB_DAY` | `50` | Check warns if the estimated log write rate exceeds this |
| `CDT_TBW_TB` | `150` | SSD endurance used for the lifetime estimate (an estimate; override for your drive) |
| `CDT_SQLITE` | auto / `/usr/bin/sqlite3` | sqlite3 binary to use |
| `CDT_PREFIX` | `~/.local/bin` | Install location for the commands |
| `CDT_AGENTS_DIR` | `~/Library/LaunchAgents` | Install location for the launchd plists |

## Where it writes files (per feature)

Everything this tool writes lives under your home directory, is configurable, and is fully removed by `codex-disk-uninstall`. Exactly which path each feature writes to:

| Command / feature | Writes to |
|---|---|
| `setup.sh` (install) | commands → `~/.local/bin/` (and `~/.local/bin/lib/common.sh`); timers → `~/Library/LaunchAgents/com.user.codex-disk-maintain.plist` and `…codex-disk-check.plist`; creates the report dir `~/.local/state/codex-disk/` |
| `codex-disk-check` (passive) | `~/.local/state/codex-disk/report.log` (one line appended per run) and `~/.local/state/codex-disk/last-sample` (overwritten each run) |
| `codex-disk-check --measure` | **nothing persistent** — a `mktemp` temp file that is deleted immediately; the result is printed to your terminal/stdout |
| `codex-disk-maintain` | modifies `~/.codex/logs_2.sqlite` (its maintenance target — the only file it changes); writes nothing else |
| `codex-disk-bench` | `~/.local/state/codex-disk/bench/<stage>.json` (+ a `.residual` marker) for each stage |
| `codex-disk-cleanup --apply` | **deletes** junk under `~/.codex`; creates no files |
| `codex-disk-block --apply` | backs up to `~/.codex/logs_2.sqlite.block-backup-<timestamp>` and adds a trigger **inside** `~/.codex/logs_2.sqlite` |
| `codex-disk-unblock` | removes that trigger from `~/.codex/logs_2.sqlite` |
| daily `launchd` jobs | their stdout/stderr → `~/.local/state/codex-disk/maintain.out.log`, `maintain.err.log`, `check.out.log`, `check.err.log` |
| `codex-disk-uninstall` | removes all of the above |

Paths are overridable: `CDT_PREFIX` (commands), `CDT_AGENTS_DIR` (timers), `CDT_STATE_DIR` (reports). The report dir is kept **outside** `~/.codex` on purpose, so monitoring never counts its own writes.

**Want zero files?** Skip `setup.sh` and run the on-demand commands directly from the repo (`./bin/codex-disk-check --measure 60`, `./bin/codex-disk-maintain`, `./bin/codex-disk-cleanup`). Those print to the terminal only and persist nothing — at the cost of the daily timers, the no-sudo passive rate, the `report.log` history, and the cross-session bench table.

## Safety

- **Maintenance only ever touches `logs_2.sqlite`.** It never reads or writes `sessions/` or `memories/`.
- **Cleanup is dry-run by default** and only deletes a hardcoded list of junk: `logs_2.sqlite.bak`, `.codex-global-state.json.bak`, `.DS_Store`, `.tmp/`, `cache/remote_plugin_catalog/`, and `computer-use/`. `sessions/` and `memories/` are explicitly protected and can never be selected.
- Everything installs under your home directory; **no `sudo` is needed** except for the optional `--measure` mode.

## Uninstall

```bash
codex-disk-uninstall
```

Removes the commands, the two launchd jobs, and the report directory. If you used `codex-disk-block`, it also drops that trigger from Codex's log DB (lock-safe), restoring normal logging. It does not change any Codex config you may have edited yourself (that's yours to manage).

## Design & how it works

For the full story — the background, the reasoning behind the approach, and a component-by-component walkthrough (what each part does and *why*) — see **[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md)**.

## Related projects

- **[claude-codex-sync](https://github.com/RuntianLee/claude-codex-sync)** — another open-source tool by the same author. A Node.js utility that bridges Claude Code and Codex, safely converting Claude's global instructions, rules, and project memory into Markdown that Codex can read. It never modifies Claude's native state or Codex's memory database, requires an explicit confirmation flag, and backs up before any change. Handy if you use both Codex and Claude Code.

## License

MIT — see [LICENSE](LICENSE).
