# codex-disk-guard 工作原理

[English](HOW-IT-WORKS.md) | **中文**

带你走一遍**这个项目为什么存在**、**采取了什么方案**、以及**每个部分如何实现**——让你不只看懂代码*做了什么*,更明白*为什么*这样做。

## 1. 背景 —— 问题是什么

OpenAI Codex CLI(以及桌面版)会持续把高频 `TRACE` 日志写进同一个 SQLite 数据库 `~/.codex/logs_2.sqlite`(见 [openai/codex#29532](https://github.com/openai/codex/issues/29532))。

issue 中开发者的实测:

- 这是一种**"插入即删除"的 churn**:表的自增 id(`max(id)`)在活跃使用时**每分钟推进 1,600+ 行**,但*保留*的行数几乎不变(旧行随新行到来被删)。
- 数据库曾被观察到 **~288 MB**,WAL(预写日志)**~13 MB** 且持续增长。
- 设 `RUST_LOG=info` **拦不住**这些持久化的 `TRACE` 行——这个 SQLite 日志 sink 有**自己独立**的 tracing 层,不受该环境变量控制。
- 目前**没有任何配置开关**能关掉它。

现实担忧:对 SSD 持续不断的写入;如果桌面版的后台 daemon 在跑,就是 7×24 小时。

## 2. 解决方案 —— 思路(以及为什么)

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

## 3. 实现逻辑 —— 逐组件讲(是什么 + 为什么)

### `lib/common.sh` —— 共享指标函数
测量逻辑的唯一真源,被 `bin/` 各命令 source。

- **`cdt_insert_counter`** —— 监测的核心。执行
  `SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='logs'), (SELECT max(id) FROM logs), 0)`。
  *为什么这么写:* `sqlite_sequence.seq` 即使每行都被 prune 也持续上升,是真正的累计插入数;`max(id)` 作回退;`0` 兜底缺失/空库。两次采样 → 这期间的精确插入数。
- **`cdt_sum_fsusage_bytes`** —— 解析 `fs_usage` 输出,累加目标路径下 `write`/`pwrite` 行的 `B=0x…` 字节。*为什么要拆开:* macOS 的 `awk`(BWK)**没有 `strtonum`**,所以 awk 只负责抽出十六进制 token,由 **bash 算术**(`$(( … ))`,原生识别 `0x`)做求和。
- **`cdt_measure`** —— 跑 `sudo fs_usage` N 秒,累加字节,换算成 MB/天 + SSD 寿命估算。结束时干净地杀掉 `fs_usage` 子进程,不残留 root 采样进程。
- 辅助:`cdt_human_bytes`(字节→"1.5M")、`cdt_mb_per_day`、`cdt_tbw_years`(寿命换算)、`cdt_detect_residual`(发现残留 daemon:`app-server` / `remote-control` / `SkyComputerUse` 进程、launchd 任务或自启项)。

### `bin/codex-disk-check` —— 监测器
- **被动模式(默认,无需 sudo):** 读 `cdt_insert_counter`,与 `last-sample` 里上次的值比较,算出插入行数 + rows/min。向 `report.log` 追加一行并打印。首次运行没有上次样本,记一条 `baseline`。
- **阈值 → PASS/WARN:** 估算 MB/天 超过 `CDT_LOGS_RATE_WARN_MB_DAY`(50)、或 WAL 超过 `CDT_WAL_WARN_BYTES`(8 MB)、或检测到残留写入者,就 WARN。*为什么默认被动:* 零权限、近零开销,可随手跑或挂定时。
- **`--measure [secs]`:** 委托给 `cdt_measure`,走 sudo 的精确数字。

### `bin/codex-disk-maintain` —— 维护
在同一个 SQLite 会话里依次执行:`PRAGMA busy_timeout=2000;` → `DELETE FROM logs WHERE ts < (now − 保留天数·86400);` → `PRAGMA wal_checkpoint(TRUNCATE);` → `VACUUM;`。
- *为什么这个顺序:* 先删旧行,再把 WAL 合并回去并截断,最后压实文件。
- *为什么锁安全:* 短 `busy_timeout` 意味着 Codex 正在写时,任务直接放弃(退出码 0、不破坏数据),而不是抢锁。
- 保留天数会校验(`CDT_RETENTION_DAYS`,默认 3),非法值不会让定时任务静默空转。
- 它**只**碰 `logs_2.sqlite`——没有 `rm`,不碰其它任何路径。

### `bin/codex-disk-bench` —— 对比测试
在四个带标签的场景下跑同一个 `--measure`——*空闲基线*、*CLI 活跃*、*桌面空闲*、*桌面活跃*——每个结果存到 `bench/`。
- *为什么分阶段 + 存文件:* 四个状态没法一次测完(CLI 阶段和桌面阶段之间你得先装桌面版)。把每个阶段存盘,就能跨会话进行,最后 `report` 打一张并排对比表。
- *为什么是这四态:* CLI 只在活跃时写;**桌面版多出一个空闲、7×24 的写入者**(它的 daemon)——那个空闲 churn 才是磨损的真正来源,所以单独测它。

### `bin/codex-disk-cleanup` —— 清理
删除 `~/.codex` 下一份**写死**的明显垃圾(陈旧 `.bak`、`.DS_Store`、`.tmp/`、可重建缓存、`computer-use/` app)。
- *为什么默认 dry-run:* 先预览,只有加 `--apply` 才删,误跑也丢不了东西。
- *为什么用写死清单(绝不用通配):* `sessions/` 和 `memories/` 永远不可能被选中——安全是结构性的,而非条件判断。另有守卫:`HOME`/`CODEX_HOME` 未设时拒绝运行。

### `bin/codex-disk-block` / `codex-disk-unblock` —— opt-in 的"真止血"
唯一能真正停下 churn 的杠杆,因为它拦在 SQLite 层、而不是 App 层。
- `codex-disk-block --apply` 先备份(sqlite `.backup`),装上 `CREATE TRIGGER cdg_block_logs BEFORE INSERT ON logs BEGIN SELECT RAISE(IGNORE); END;`,再截断 WAL。*为什么用触发器:* `RAISE(IGNORE)` 让每条插入变成静默空操作,于是 `sqlite_sequence`/`max(id)` 冻结、WAL 不再增长——既然 App 和配置都没有开关,表本身就是唯一能拦的地方。
- *为什么要 gate:* 它**会改动 Codex 自己的数据库**,所以默认 dry-run、加 `--apply` 才执行、且先备份,并可用 `codex-disk-unblock`(`DROP TRIGGER`)还原。
- *诚实的风险:* 依赖回读日志的 Codex 功能可能失效;Codex 升级若重建日志库会丢掉触发器。`codex-disk-uninstall` 会自动移除这一个触发器(锁安全),所以干净卸载会恢复 Codex 正常日志——它仍然绝不碰你的 sessions、memories 或日志行。

### `setup.sh` / `uninstall.sh` / `launchd/*.plist.template`
- `setup.sh` 把命令装到 `~/.local/bin`,把两个 plist 模板渲染(替换成真实路径)到 `~/Library/LaunchAgents` 并加载。预检会拒绝非 macOS 和缺少 `sqlite3` 的情况,并在 `~/.local/bin` 不在 `PATH` 时提醒。
- launchd 任务每日 **03:00 维护**、**03:05 检查**,用户级(无 root)。Mac 睡眠时 launchd 唤醒后补跑。
- `uninstall.sh` 精确移除 setup 创建的一切(命令、lib、plist、整个状态目录)并逐项列出;绝不碰 `~/.codex` 或你自己的配置改动。

## 4. 已知限制(诚实说明)
活跃使用时对 `logs_2.sqlite` 的写入,**目前无法用配置消除**。本工具让这个库**可控且可观测**,并清掉其中*空闲*和*垃圾*的部分——但它是缓解,不是根治。若 Codex 日后提供关闭该 sink 的开关,那才是真正的解法,本工具届时退化为一个监测器。

降低写入*速率*只能在 App 控制之外做到。opt-in 的 `codex-disk-block` 命令通过拦在 SQLite 层(一个 `BEFORE INSERT` 触发器)实现——那是唯一没有开关的地方——代价是改动 Codex 自己的数据库(见上面那个组件)。另有两个更轻、不碰 DB 的杠杆能*部分*减少:调高日志级别(`export RUST_LOG=error`)砍掉遵守过滤器的那部分,但**拦不住**高频 `target=log` 行;彻底退出桌面版可消除它 7×24 的空闲写入者。用 `codex-disk-check --measure` / `codex-disk-bench` 实测各能帮多少。
