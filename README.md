# codex-disk-tools

**Tame the OpenAI Codex CLI's constant disk writing on macOS — monitor it, keep its log database from growing, and clean up junk, without ever touching your sessions or memories.**

**在 macOS 上治理 OpenAI Codex CLI 的频繁写盘 —— 监测写入、控制日志库不再膨胀、清理垃圾文件,且绝不动你的会话记录和记忆数据。**

> Background: the Codex CLI continuously writes high-frequency `TRACE` logs into `~/.codex/logs_2.sqlite` (see [openai/codex#29532](https://github.com/openai/codex/issues/29532)). The `RUST_LOG` environment variable does **not** stop it, because the SQLite log sink has its own tracing layer. There is currently no config switch to disable that sink. This toolkit does not try to patch Codex; it gives you monitoring, low-frequency maintenance, and safe cleanup around it.
>
> 背景:Codex CLI 会持续把高频 `TRACE` 日志写进 `~/.codex/logs_2.sqlite`(见 [openai/codex#29532](https://github.com/openai/codex/issues/29532))。`RUST_LOG` 环境变量**拦不住**它,因为这个 SQLite 日志 sink 有独立的 tracing 层,而且目前没有配置开关能关掉它。本工具不修改 Codex 本身,而是在它周围提供监测、低频维护和安全清理。

---

## English

### What it does

| Command | What it does |
|---|---|
| `codex-disk-check` | **Monitor.** Samples how many log rows Codex inserted since last run and reports a write rate. No `sudo`. Appends one line to a report log. |
| `codex-disk-check --measure 60` | **Precisely measure** real bytes written to `~/.codex` over 60s using `fs_usage` (needs `sudo`). Prints a MB/day figure and an SSD-lifetime estimate. |
| `codex-disk-maintain` | **Maintain.** Deletes log rows older than N days, truncates the WAL, and `VACUUM`s `logs_2.sqlite` so it stays small. Only touches that one database. |
| `codex-disk-cleanup` | **Clean up** obvious junk (stale backups, caches, temp dirs). Dry-run by default; `--apply` to actually delete. Never touches `sessions/` or `memories/`. |
| `codex-disk-uninstall` | **Uninstall** everything this tool installed. |

`setup.sh` installs the first four as commands in `~/.local/bin` and registers two `launchd` jobs that run **maintain at 03:00** and **check at 03:05** every day.

### Why the writes happen (and what this can / can't do)

- The hot file is `~/.codex/logs_2.sqlite`. While you actively use Codex it receives ~0.5 MB/min of `TRACE` log inserts.
- This **cannot be turned off** by configuration today — so this tool does not claim to eliminate writes during active use. Instead it (a) keeps that database from growing without bound, (b) lets you watch the write rate over time, and (c) removes one-off junk.
- For perspective: even at 1–2 GB/day (~0.5 TB/year), a modern SSD rated at hundreds of TBW lasts centuries. The point of this tool is awareness and hygiene, not panic.

### Requirements

- **macOS only** (uses `launchd`, `fs_usage`, BSD `stat`). The installer refuses to run elsewhere.
- `sqlite3` — ships with macOS at `/usr/bin/sqlite3`; Homebrew's is auto-detected if present.
- `bash` — works with the system bash 3.2; no bash 4+ features used.
- The OpenAI **Codex CLI** installed (this tool reads/maintains `~/.codex`).

### Install

```bash
git clone https://github.com/<you>/codex-disk-tools.git
cd codex-disk-tools
./setup.sh
```

If `setup.sh` warns that `~/.local/bin` is not on your `PATH`, add it and reopen your terminal:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

### Usage

```bash
codex-disk-check                 # quick status, no sudo; appends to the report log
codex-disk-check --json          # same, machine-readable single line
codex-disk-check --measure 60    # precise active write rate over 60s (sudo); use Codex during the window
codex-disk-maintain              # prune old logs + checkpoint + vacuum now
codex-disk-cleanup               # preview junk to delete (dry-run)
codex-disk-cleanup --apply       # actually delete the junk
```

A typical "is it still writing a lot?" check is just `codex-disk-check`. Run `--measure` when you want hard numbers.

### How it works

- **Passive monitoring** uses the `logs` table's `sqlite_sequence` counter (a monotonic insert count that does not go down even when old rows are pruned). The difference between two samples is exactly how many log rows were inserted in between — so you get an accurate insert rate **without `sudo`** and without scanning the whole database.
- **Precise mode** (`--measure`) runs `sudo fs_usage` for N seconds, sums the bytes written to paths under `~/.codex`, and extrapolates to MB/day plus an SSD-lifetime estimate (using `CDT_TBW_TB`, default 150).
- **Maintenance** runs `DELETE FROM logs WHERE ts < cutoff`, `PRAGMA wal_checkpoint(TRUNCATE)`, and `VACUUM`. If the database is locked (Codex is using it), it backs off safely and exits 0 without touching data.

### Scheduled jobs

`setup.sh` installs two user-level `launchd` agents (no root, no system changes):

- `com.user.codex-disk-maintain` — daily at **03:00**
- `com.user.codex-disk-check` — daily at **03:05**

If your Mac is asleep at that time, `launchd` runs the job at the next wake. Job stdout/stderr go to `~/.local/state/codex-disk/`.

### Configuration

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

### Safety

- **Maintenance only ever touches `logs_2.sqlite`.** It never reads or writes `sessions/` or `memories/`.
- **Cleanup is dry-run by default** and only deletes a hardcoded list of junk: `logs_2.sqlite.bak`, `.codex-global-state.json.bak`, `.DS_Store`, `.tmp/`, `cache/remote_plugin_catalog/`, and `computer-use/`. `sessions/` and `memories/` are explicitly protected and can never be selected.
- Everything installs under your home directory; **no `sudo` is needed** except for the optional `--measure` mode.

### Uninstall

```bash
codex-disk-uninstall
```

Removes the commands, the two launchd jobs, and the report directory. It does not change any Codex config you may have edited yourself (that's yours to manage).

### Development

```bash
./tests/run_tests.sh      # runs the full bash test suite (no dependencies)
```

Tests are plain bash with a tiny assertion helper — no `bats` or other tooling required. They run everything against temporary fixture directories and never touch your real `~/.codex`, `~/.local/bin`, or `~/Library/LaunchAgents`.

### License

Choose a license for your fork (MIT is a good default for small tools) and add a `LICENSE` file.

---

## 中文

### 它能做什么

| 命令 | 作用 |
|---|---|
| `codex-disk-check` | **监测。** 采样 Codex 自上次以来插入了多少行日志,算出写入速率。无需 `sudo`,向报告文件追加一行。 |
| `codex-disk-check --measure 60` | **精确测速。** 用 `fs_usage` 实测 60 秒内对 `~/.codex` 的写入字节(需 `sudo`),给出 MB/天当量和 SSD 寿命估算。 |
| `codex-disk-maintain` | **维护。** 删除 N 天前的日志行、截断 WAL、`VACUUM` 压实 `logs_2.sqlite`,让它保持小体积。只动这一个数据库。 |
| `codex-disk-cleanup` | **清理** 明确的垃圾(陈旧备份、缓存、临时目录)。默认只预览,加 `--apply` 才真删。绝不碰 `sessions/` 和 `memories/`。 |
| `codex-disk-uninstall` | **卸载** 本工具安装的一切。 |

`setup.sh` 会把前四个命令装进 `~/.local/bin`,并注册两个 `launchd` 定时任务:每天 **03:00 维护**、**03:05 检查**。

### 为什么会频繁写(以及本工具能/不能做什么)

- 热点文件是 `~/.codex/logs_2.sqlite`。活跃使用 Codex 时,它会以约 0.5 MB/分钟 的速度被写入 `TRACE` 日志。
- 这个写入**目前无法用配置关闭**——所以本工具不声称能消除活跃使用时的写入。它做的是:(a) 让日志库不再无限膨胀;(b) 让你长期观察写入速率;(c) 清掉一次性垃圾。
- 客观看:即使每天写 1–2 GB(约 0.5 TB/年),一块标称数百 TBW 的现代 SSD 也能用上百年。本工具的意义是"心里有数 + 保持整洁",而不是制造焦虑。

### 环境要求

- **仅 macOS**(用到 `launchd`、`fs_usage`、BSD `stat`)。安装器在非 macOS 上会直接拒绝运行。
- `sqlite3` —— macOS 自带于 `/usr/bin/sqlite3`;若装了 Homebrew 版会自动识别。
- `bash` —— 兼容系统自带的 bash 3.2,未使用 bash 4+ 特性。
- 已安装 OpenAI **Codex CLI**(本工具读取/维护 `~/.codex`)。

### 安装

```bash
git clone https://github.com/<你>/codex-disk-tools.git
cd codex-disk-tools
./setup.sh
```

如果 `setup.sh` 提示 `~/.local/bin` 不在 `PATH` 中,加入后重开终端:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

### 日常使用

```bash
codex-disk-check                 # 快速查状态,无需 sudo;结果追加到报告文件
codex-disk-check --json          # 同上,机器可读的单行输出
codex-disk-check --measure 60    # 精确测 60 秒活跃写速(需 sudo),这段时间正常用 Codex
codex-disk-maintain              # 立即清旧日志 + checkpoint + vacuum
codex-disk-cleanup               # 预览可删的垃圾(dry-run)
codex-disk-cleanup --apply       # 真正删除垃圾
```

平时想知道"是不是又在大量写盘",敲 `codex-disk-check` 即可;想要硬数据时再用 `--measure`。

### 工作原理

- **被动监测** 利用 `logs` 表的 `sqlite_sequence` 计数器(单调递增的插入计数,即使旧行被删也不回退)。两次采样的差值,正好等于这期间插入了多少行日志——于是**无需 `sudo`**、也不用扫描整个库,就能得到准确的插入速率。
- **精确模式**(`--measure`)运行 `sudo fs_usage` N 秒,累加写到 `~/.codex` 下各路径的字节,外推成 MB/天,并按 `CDT_TBW_TB`(默认 150)换算 SSD 寿命。
- **维护** 执行 `DELETE FROM logs WHERE ts < 截止时间`、`PRAGMA wal_checkpoint(TRUNCATE)`、`VACUUM`。如果库正被 Codex 占用(锁定),它会安全退避、退出码 0、不碰数据。

### 定时任务

`setup.sh` 安装两个用户级 `launchd` 任务(不需要 root,不改系统):

- `com.user.codex-disk-maintain` —— 每天 **03:00**
- `com.user.codex-disk-check` —— 每天 **03:05**

若到点时 Mac 在睡眠,`launchd` 会在下次唤醒补跑。任务的标准输出/错误写到 `~/.local/state/codex-disk/`。

### 配置

所有设置都是带默认值的环境变量:

| 变量 | 默认值 | 含义 |
|---|---|---|
| `CODEX_HOME` | `~/.codex` | Codex 数据目录 |
| `CDT_STATE_DIR` | `~/.local/state/codex-disk` | 报告写入位置(**刻意放在 `~/.codex` 之外**) |
| `CDT_RETENTION_DAYS` | `3` | 维护时保留多少天内的日志行 |
| `CDT_WAL_WARN_BYTES` | `8388608`(8 MB) | WAL 超过此值时检查告警 |
| `CDT_LOGS_RATE_WARN_MB_DAY` | `50` | 估算日志写速超过此值时检查告警 |
| `CDT_TBW_TB` | `150` | 用于寿命估算的 SSD 耐久值(估计值,可按你的盘覆盖) |
| `CDT_SQLITE` | 自动 / `/usr/bin/sqlite3` | 使用的 sqlite3 程序 |
| `CDT_PREFIX` | `~/.local/bin` | 命令安装位置 |
| `CDT_AGENTS_DIR` | `~/Library/LaunchAgents` | launchd plist 安装位置 |

### 安全性

- **维护只会操作 `logs_2.sqlite`**,永不读写 `sessions/` 或 `memories/`。
- **清理默认只预览**,且只删一份写死的垃圾清单:`logs_2.sqlite.bak`、`.codex-global-state.json.bak`、`.DS_Store`、`.tmp/`、`cache/remote_plugin_catalog/`、`computer-use/`。`sessions/` 和 `memories/` 被显式保护,永远不会被选中。
- 一切都装在你的家目录下;**除了可选的 `--measure` 模式外不需要 `sudo`**。

### 卸载

```bash
codex-disk-uninstall
```

删除命令、两个 launchd 任务、报告目录。它不会改动你自己手动编辑过的任何 Codex 配置(那部分由你自行管理)。

### 开发

```bash
./tests/run_tests.sh      # 运行完整的 bash 测试套件(零依赖)
```

测试是纯 bash + 一个极小的断言 helper,不需要 `bats` 之类的工具。全部针对临时 fixture 目录运行,绝不触碰你真实的 `~/.codex`、`~/.local/bin`、`~/Library/LaunchAgents`。

### 许可证

为你的 fork 选择一个许可证(小工具用 MIT 即可),并添加 `LICENSE` 文件。
