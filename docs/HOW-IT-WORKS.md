# How codex-disk-guard works / 工作原理

**English** below · [中文见下](#中文)

---

## English

A guided walk through **why this project exists**, **what approach it takes**, and **how each piece is implemented** — so you can understand not just *what* the code does, but *why* it does it that way.

### 1. Background — the problem

The OpenAI Codex CLI (and the desktop app) continuously writes high-frequency `TRACE` logs into a single SQLite database, `~/.codex/logs_2.sqlite` (see [openai/codex#29532](https://github.com/openai/codex/issues/29532)).

What developers observed in that issue:

- It is an **insert-and-prune churn**: the table's auto-increment id (`max(id)`) climbed by **~1,600+ rows per minute** of active use, even though the *retained* row count barely changed (old rows are deleted as new ones arrive).
- The database was seen at **~288 MB** with a **~13 MB WAL** (write-ahead log) that kept advancing.
- Setting `RUST_LOG=info` did **not** stop the persisted `TRACE` rows — the SQLite log sink has its **own** tracing layer that the environment variable does not control.
- There is currently **no configuration switch** to turn that sink off.

The practical worry: a steady stream of writes to the SSD, 24/7 if the desktop app's background daemon is running.

### 2. Solution — the approach (and why)

Because the writes **cannot be turned off** today, the tool deliberately does *not* promise to stop them. Instead it does four things **around** Codex, never modifying Codex itself:

1. **Monitor** the write rate (so you know if it's bad / getting worse).
2. **Maintain** the log database (so it never grows without bound).
3. **Measure** precisely on demand (so you have hard numbers).
4. **Clean** one-off junk (so disk space is reclaimed).

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

### 3. Implementation logic — component by component

#### `lib/common.sh` — shared metric functions
The single source of truth for measurement, sourced by the `bin/` commands.

- **`cdt_insert_counter`** — the heart of monitoring. Runs
  `SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='logs'), (SELECT max(id) FROM logs), 0)`.
  *Why this formula:* `sqlite_sequence.seq` keeps rising even after every row is pruned, so it's a true cumulative insert count; `max(id)` is the fallback; `0` covers a missing/empty DB. Two samples → exact inserts in between.
- **`cdt_sum_fsusage_bytes`** — parses `fs_usage` output and sums the `B=0x…` byte fields of `write`/`pwrite` lines under a target path. *Why the odd split:* macOS's `awk` (BWK) has **no `strtonum`**, so awk only extracts the hex tokens and **bash arithmetic** (`$(( … ))`, which natively understands `0x`) does the addition.
- **`cdt_measure`** — runs `sudo fs_usage` for N seconds, sums the bytes, and converts to MB/day plus an SSD-lifetime estimate. Kills the `fs_usage` child cleanly so no root sampler is left behind.
- Helpers: `cdt_human_bytes` (byte → "1.5M"), `cdt_mb_per_day`, `cdt_tbw_years` (lifetime math), `cdt_detect_residual` (spots a leftover daemon: `app-server` / `remote-control` / `SkyComputerUse` process, launchd job, or autostart agent).

#### `bin/codex-disk-check` — the monitor
- **Passive mode (default, no sudo):** reads `cdt_insert_counter`, compares it to the previous value stored in `last-sample`, and computes inserted rows + rows/min. It appends one line to `report.log` and prints it. First run has no previous sample, so it records a `baseline`.
- **Thresholds → PASS/WARN:** WARN if the estimated MB/day exceeds `CDT_LOGS_RATE_WARN_MB_DAY` (50), or the WAL exceeds `CDT_WAL_WARN_BYTES` (8 MB), or a residual writer is detected. *Why a passive default:* you can run it (or schedule it) with zero privileges and near-zero overhead.
- **`--measure [secs]`:** delegates to `cdt_measure` for precise, sudo-based numbers.

#### `bin/codex-disk-maintain` — the maintenance
Runs, in one SQLite session: `PRAGMA busy_timeout=2000;` then `DELETE FROM logs WHERE ts < (now − retention·86400);` then `PRAGMA wal_checkpoint(TRUNCATE);` then `VACUUM;`.
- *Why this order:* delete old rows, fold the WAL back and truncate it, then compact the file.
- *Why lock-safe:* the short `busy_timeout` means if Codex is mid-write, the run gives up (exit 0, no corruption) rather than fighting for the lock.
- Retention is validated (`CDT_RETENTION_DAYS`, default 3) so a bad value can't silently turn the scheduled job into a no-op.
- It touches **only** `logs_2.sqlite` — no `rm`, no other paths.

#### `bin/codex-disk-bench` — the benchmark
Runs the same `--measure` in four labelled scenarios — *idle baseline*, *CLI active*, *desktop idle*, *desktop active* — and saves each result under `bench/`.
- *Why staged + saved to files:* the four states can't all be captured in one sitting (you must install the desktop app between CLI and desktop stages). Persisting each stage lets the run span sessions, and `report` prints a side-by-side table at the end.
- *Why these four states:* the CLI only writes while active; the **desktop app adds an idle, 24/7 writer** (its daemon) — that idle churn is the real wear concern, so it gets its own measurement.

#### `bin/codex-disk-cleanup` — the cleanup
Deletes a **hardcoded** list of obvious junk under `~/.codex` (stale `.bak` files, `.DS_Store`, `.tmp/`, rebuildable caches, the `computer-use/` app).
- *Why dry-run by default:* it previews and only deletes with `--apply`, so an accidental run can't lose anything.
- *Why a hardcoded list (never a glob):* `sessions/` and `memories/` can never be selected — the safety is structural, not conditional. A guard also refuses to run if `HOME`/`CODEX_HOME` is unset.

#### `setup.sh` / `uninstall.sh` / `launchd/*.plist.template`
- `setup.sh` installs the commands to `~/.local/bin`, renders the two plist templates (substituting the real paths) into `~/Library/LaunchAgents`, and loads them. Preflight refuses non-macOS and missing `sqlite3`, and it warns if `~/.local/bin` isn't on your `PATH`.
- The launchd jobs run **maintain at 03:00** and **check at 03:05** daily, user-level (no root). If the Mac is asleep, launchd catches up on wake.
- `uninstall.sh` removes exactly what setup created (commands, lib, plists, the whole state dir) and lists them; it never touches `~/.codex` or your own config edits.

### 4. The known limitation (stated honestly)
The active-use writes to `logs_2.sqlite` **cannot be eliminated** by configuration today. This tool keeps that database **bounded and observable** and removes the *idle* and *junk* portions — but it is a mitigation, not a cure. If Codex later ships a switch to disable the sink, that becomes the real fix and this tool becomes a monitor.

---

## 中文

带你走一遍**这个项目为什么存在**、**采取了什么方案**、以及**每个部分如何实现**——让你不只看懂代码*做了什么*,更明白*为什么这样做*。

### 1. 背景 —— 问题是什么

OpenAI Codex CLI(以及桌面版)会持续把高频 `TRACE` 日志写进同一个 SQLite 数据库 `~/.codex/logs_2.sqlite`(见 [openai/codex#29532](https://github.com/openai/codex/issues/29532))。

issue 中开发者的实测:

- 这是一种**"插入即删除"的 churn**:表的自增 id(`max(id)`)在活跃使用时**每分钟推进 1,600+ 行**,但*保留*的行数几乎不变(旧行随新行到来被删)。
- 数据库曾被观察到 **~288 MB**,WAL(预写日志)**~13 MB** 且持续增长。
- 设 `RUST_LOG=info` **拦不住**这些持久化的 `TRACE` 行——这个 SQLite 日志 sink 有**自己独立**的 tracing 层,不受该环境变量控制。
- 目前**没有任何配置开关**能关掉它。

现实担忧:对 SSD 持续不断的写入;如果桌面版的后台 daemon 在跑,就是 7×24 小时。

### 2. 解决方案 —— 思路(以及为什么)

既然这些写入**目前无法关闭**,本工具刻意**不**承诺消除它,而是在 Codex **周围**做四件事,绝不改动 Codex 本身:

1. **监测**写入速率(知道严不严重、有没有变差)。
2. **维护**日志库(让它永不无限膨胀)。
3. **按需精确测量**(给你硬数据)。
4. **清理**一次性垃圾(回收磁盘空间)。

每个设计决策及其原因:

| 决策 | 为什么 |
|---|---|
| 用 `sqlite_sequence` 计数差值监测 | 这个自增计数器是**单调**的、行被 prune 后也不回退。两次采样求差,就得到这期间插入了多少行——**无需 sudo**、**不用扫描**整个库的准确速率。 |
| 精确模式用 `fs_usage` | 想要真实字节数(而非估算)时,`fs_usage` 测对 `~/.codex` 的实际写入。它需要 sudo,所以是可选项。 |
| 维护用 `DELETE` + `wal_checkpoint(TRUNCATE)` + `VACUUM`,且**锁安全** | 让日志库保持小体积又不破坏它。Codex 持锁时,任务退避而不是硬抢。 |
| **绝不**碰 `sessions/` 或 `memories/`;清理**默认 dry-run** | 安全第一。唯一可能被删的是一份写死的垃圾清单,且必须加 `--apply`。 |
| 状态/报告放在 `~/.codex` **之外**(`~/.local/state/codex-disk/`) | 这样监测不会把自己写报告也算成 Codex 的写入。 |
| 用用户级 **launchd** 调度 | 每日自动运行,不需要 root,不改系统。 |
| **零依赖**、bash 3.2、仅 macOS | 克隆即用,无需安装任何东西。只用 macOS 自带工具(`launchd`、`fs_usage`、BSD `stat`、`sqlite3`)。 |

### 3. 实现逻辑 —— 逐组件讲(是什么 + 为什么)

#### `lib/common.sh` —— 共享指标函数
测量逻辑的唯一真源,被 `bin/` 各命令 source。

- **`cdt_insert_counter`** —— 监测的核心。执行
  `SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='logs'), (SELECT max(id) FROM logs), 0)`。
  *为什么这么写:* `sqlite_sequence.seq` 即使每行都被 prune 也持续上升,是真正的累计插入数;`max(id)` 作回退;`0` 兜底缺失/空库。两次采样 → 这期间的精确插入数。
- **`cdt_sum_fsusage_bytes`** —— 解析 `fs_usage` 输出,累加目标路径下 `write`/`pwrite` 行的 `B=0x…` 字节。*为什么要拆开:* macOS 的 `awk`(BWK)**没有 `strtonum`**,所以 awk 只负责抽出十六进制 token,由 **bash 算术**(`$(( … ))`,原生识别 `0x`)做求和。
- **`cdt_measure`** —— 跑 `sudo fs_usage` N 秒,累加字节,换算成 MB/天 + SSD 寿命估算。结束时干净地杀掉 `fs_usage` 子进程,不残留 root 采样进程。
- 辅助:`cdt_human_bytes`(字节→"1.5M")、`cdt_mb_per_day`、`cdt_tbw_years`(寿命换算)、`cdt_detect_residual`(发现残留 daemon:`app-server` / `remote-control` / `SkyComputerUse` 进程、launchd 任务或自启项)。

#### `bin/codex-disk-check` —— 监测器
- **被动模式(默认,无需 sudo):** 读 `cdt_insert_counter`,与 `last-sample` 里上次的值比较,算出插入行数 + rows/min。向 `report.log` 追加一行并打印。首次运行没有上次样本,记一条 `baseline`。
- **阈值 → PASS/WARN:** 估算 MB/天 超过 `CDT_LOGS_RATE_WARN_MB_DAY`(50)、或 WAL 超过 `CDT_WAL_WARN_BYTES`(8 MB)、或检测到残留写入者,就 WARN。*为什么默认被动:* 零权限、近零开销,可随手跑或挂定时。
- **`--measure [secs]`:** 委托给 `cdt_measure`,走 sudo 的精确数字。

#### `bin/codex-disk-maintain` —— 维护
在同一个 SQLite 会话里依次执行:`PRAGMA busy_timeout=2000;` → `DELETE FROM logs WHERE ts < (now − 保留天数·86400);` → `PRAGMA wal_checkpoint(TRUNCATE);` → `VACUUM;`。
- *为什么这个顺序:* 先删旧行,再把 WAL 合并回去并截断,最后压实文件。
- *为什么锁安全:* 短 `busy_timeout` 意味着 Codex 正在写时,任务直接放弃(退出码 0、不破坏数据),而不是抢锁。
- 保留天数会校验(`CDT_RETENTION_DAYS`,默认 3),非法值不会让定时任务静默空转。
- 它**只**碰 `logs_2.sqlite`——没有 `rm`,不碰其它任何路径。

#### `bin/codex-disk-bench` —— 对比测试
在四个带标签的场景下跑同一个 `--measure`——*空闲基线*、*CLI 活跃*、*桌面空闲*、*桌面活跃*——每个结果存到 `bench/`。
- *为什么分阶段 + 存文件:* 四个状态没法一次测完(CLI 阶段和桌面阶段之间你得先装桌面版)。把每个阶段存盘,就能跨会话进行,最后 `report` 打一张并排对比表。
- *为什么是这四态:* CLI 只在活跃时写;**桌面版多出一个空闲、7×24 的写入者**(它的 daemon)——那个空闲 churn 才是磨损的真正来源,所以单独测它。

#### `bin/codex-disk-cleanup` —— 清理
删除 `~/.codex` 下一份**写死**的明显垃圾(陈旧 `.bak`、`.DS_Store`、`.tmp/`、可重建缓存、`computer-use/` app)。
- *为什么默认 dry-run:* 先预览,只有加 `--apply` 才删,误跑也丢不了东西。
- *为什么用写死清单(绝不用通配):* `sessions/` 和 `memories/` 永远不可能被选中——安全是结构性的,而非条件判断。另有守卫:`HOME`/`CODEX_HOME` 未设时拒绝运行。

#### `setup.sh` / `uninstall.sh` / `launchd/*.plist.template`
- `setup.sh` 把命令装到 `~/.local/bin`,把两个 plist 模板渲染(替换成真实路径)到 `~/Library/LaunchAgents` 并加载。预检会拒绝非 macOS 和缺少 `sqlite3` 的情况,并在 `~/.local/bin` 不在 `PATH` 时提醒。
- launchd 任务每日 **03:00 维护**、**03:05 检查**,用户级(无 root)。Mac 睡眠时 launchd 唤醒后补跑。
- `uninstall.sh` 精确移除 setup 创建的一切(命令、lib、plist、整个状态目录)并逐项列出;绝不碰 `~/.codex` 或你自己的配置改动。

### 4. 已知限制(诚实说明)
活跃使用时对 `logs_2.sqlite` 的写入,**目前无法用配置消除**。本工具让这个库**可控且可观测**,并清掉其中*空闲*和*垃圾*的部分——但它是缓解,不是根治。若 Codex 日后提供关闭该 sink 的开关,那才是真正的解法,本工具届时退化为一个监测器。
