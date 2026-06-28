# codex-disk-guard

**English** | [中文](README.zh-CN.md)

**Tame the OpenAI Codex CLI's constant disk writing on macOS — monitor it, keep its log database from growing, and clean up junk, without ever touching your sessions or memories.**

> Background: the Codex CLI continuously writes high-frequency `TRACE` logs into `~/.codex/logs_2.sqlite` (see [openai/codex#29532](https://github.com/openai/codex/issues/29532)). The `RUST_LOG` environment variable does **not** stop it, because the SQLite log sink has its own tracing layer. There is currently no config switch to disable that sink. This toolkit does not try to patch Codex; it gives you monitoring, low-frequency maintenance, and safe cleanup around it.

## What it does

| Command | What it does |
|---|---|
| `codex-disk-check` | **Monitor.** Samples how many log rows Codex inserted since last run and reports a write rate. No `sudo`. Appends one line to a report log. |
| `codex-disk-check --measure 60` | **Precisely measure** real bytes written to `~/.codex` over 60s using `fs_usage` (needs `sudo`). Prints a MB/day figure and an SSD-lifetime estimate. |
| `codex-disk-maintain` | **Maintain.** Deletes log rows older than N days, truncates the WAL, and `VACUUM`s `logs_2.sqlite` so it stays small. Only touches that one database. |
| `codex-disk-cleanup` | **Clean up** obvious junk (stale backups, caches, temp dirs). Dry-run by default; `--apply` to actually delete. Never touches `sessions/` or `memories/`. |
| `codex-disk-bench` | **Benchmark.** Stage-by-stage comparison of write rates — idle baseline, CLI active, and (if you install the desktop app) desktop idle / active — then a side-by-side table. |
| `codex-disk-uninstall` | **Uninstall** everything this tool installed. |

`setup.sh` installs these commands into `~/.local/bin` and registers two `launchd` jobs that run **maintain at 03:00** and **check at 03:05** every day.

## Why the writes happen (and what this can / can't do)

- The hot file is `~/.codex/logs_2.sqlite`. While you actively use Codex it receives ~0.5 MB/min of `TRACE` log inserts.
- This **cannot be turned off** by configuration today — so this tool does not claim to eliminate writes during active use. Instead it (a) keeps that database from growing without bound, (b) lets you watch the write rate over time, and (c) removes one-off junk.
- For perspective: even at 1–2 GB/day (~0.5 TB/year), a modern SSD rated at hundreds of TBW lasts centuries. The point of this tool is awareness and hygiene, not panic.

## Requirements

- **macOS only** (uses `launchd`, `fs_usage`, BSD `stat`). The installer refuses to run elsewhere.
- `sqlite3` — ships with macOS at `/usr/bin/sqlite3`; Homebrew's is auto-detected if present.
- `bash` — works with the system bash 3.2; no bash 4+ features used.
- The OpenAI **Codex CLI** installed (this tool reads/maintains `~/.codex`).

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

## Safety

- **Maintenance only ever touches `logs_2.sqlite`.** It never reads or writes `sessions/` or `memories/`.
- **Cleanup is dry-run by default** and only deletes a hardcoded list of junk: `logs_2.sqlite.bak`, `.codex-global-state.json.bak`, `.DS_Store`, `.tmp/`, `cache/remote_plugin_catalog/`, and `computer-use/`. `sessions/` and `memories/` are explicitly protected and can never be selected.
- Everything installs under your home directory; **no `sudo` is needed** except for the optional `--measure` mode.

## Uninstall

```bash
codex-disk-uninstall
```

Removes the commands, the two launchd jobs, and the report directory. It does not change any Codex config you may have edited yourself (that's yours to manage).

## License

MIT — see [LICENSE](LICENSE).
