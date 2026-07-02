# codex-disk-guard

[English](README.md) | **中文**

**在 macOS 上治理 OpenAI Codex CLI 的频繁写盘 —— 监测写入、控制日志库不再膨胀、清理垃圾文件,且绝不动你的会话记录和记忆数据。**

> ⚠️ **免责声明。** 本项目完全由 AI 智能体完成。已在作者本机(macOS,Apple Silicon;OpenAI Codex CLI **`0.142.2`**)测试通过、运行无异常,但**不保证在其他系统环境或数据下的安全性,请谨慎尝试。** 运行前请先阅读脚本代码、自行承担风险——建议先用 dry-run / 监测类命令(`codex-disk-check`、不带 `--apply` 的 `codex-disk-cleanup`)试探。

> 背景:Codex CLI 会持续把高频 `TRACE` 日志写进 `~/.codex/logs_2.sqlite`(见 [openai/codex#29532](https://github.com/openai/codex/issues/29532))。`RUST_LOG` 环境变量**拦不住**它,因为这个 SQLite 日志 sink 有独立的 tracing 层,而且目前没有配置开关能关掉它。默认情况下本工具在 Codex **周围**工作、不改动它本身——监测、低频维护、安全清理。此外它还提供一个 **opt-in** 命令(`codex-disk-block`),能在数据库层真正止住写入;这一个**会**改动 Codex 自己的日志库(但会先备份、可一键还原)。

> 📖 **想了解原理?** 先看 **[docs/HOW-IT-WORKS.zh-CN.md](docs/HOW-IT-WORKS.zh-CN.md)**:背景、方案、以及逐组件"是什么 + 为什么"的实现讲解。

## 它能做什么

| 命令 | 作用 |
|---|---|
| `codex-disk-check` | **监测。** 采样 Codex 自上次以来插入了多少行日志,算出写入速率。无需 `sudo`,向报告文件追加一行。 |
| `codex-disk-check --measure 60` | **精确测速。** 用 `fs_usage` 实测 60 秒内对 `~/.codex` 的写入字节(需 `sudo`),给出 MB/天当量和 SSD 寿命估算。 |
| `codex-disk-maintain` | **维护。** 删除 N 天前的日志行、截断 WAL、`VACUUM` 压实 `logs_2.sqlite`,让它保持小体积。只动这一个数据库。 |
| `codex-disk-cleanup` | **预览清理(dry-run)。** 列出*将要*清理的垃圾(陈旧备份、缓存、临时目录),但**不删除任何文件**——这是正常的,不是命令没生效。绝不碰 `sessions/` 和 `memories/`。 |
| `codex-disk-cleanup --apply` | **真正删除**上面那些垃圾。只有这个形式会删文件。 |
| `codex-disk-bench` | **对比测试。** 分阶段测写盘速率——空闲基线、CLI 活跃,以及(若安装桌面版)桌面空闲/活跃——最后出一张对照表。 |
| `codex-disk-block` / `--apply` | **⚠️ 进阶、opt-in。** 装一个 SQLite 触发器,在数据库层**真正止住** Codex 的日志写入——唯一能停下 churn 的办法。**会改动 Codex 自己的数据库**;默认 dry-run,`--apply` 才执行,且先备份。 |
| `codex-disk-unblock` | 移除该触发器,Codex 恢复正常写日志。 |
| `codex-disk-uninstall` | **卸载** 本工具安装的一切。 |

`setup.sh` 会把上述命令装进 `~/.local/bin`,并注册两个 `launchd` 定时任务:每天 **03:00 维护**、**03:05 检查**。

> **注意:** 默认情况下本工具是*监测、维护、清理*——不改变 Codex 写入的频率。有一个 **opt-in、进阶**命令(`codex-disk-block`)能在数据库层**真正止住**写入。见下方 **减少写入** 一节。

## 为什么会频繁写(以及本工具能/不能做什么)

- 热点文件是 `~/.codex/logs_2.sqlite`。[issue #29532](https://github.com/openai/codex/issues/29532) 中其他开发者实测:该库曾涨到 ~288MB(WAL ~13MB),插入计数 `max(id)` 在活跃使用时**每分钟推进约 1,600+ 行**(单个 60 秒窗口内 `TRACE log` 约 470KB),且 `RUST_LOG` 拦不住。你自己的实际速率取决于本机的 Codex 日志级别设置——这里引用的是其他开发者的真实实测数据,**不是本工具在你机器上测出的数字**。
- 这个写入**目前无法用配置关闭**——所以本工具不声称能消除活跃使用时的写入。它做的是:(a) 让日志库不再无限膨胀;(b) 让你长期观察写入速率;(c) 清掉一次性垃圾。
- 客观看:即使每天写 1–2 GB(约 0.5 TB/年),一块标称数百 TBW 的现代 SSD 也能用上百年。本工具的意义是"心里有数 + 保持整洁",而不是制造焦虑。

## 减少写入

默认情况下本工具只*观测和整理*——`codex-disk-maintain` 控制文件*体积*,但不改变 Codex 写入的频率。有**一个 opt-in 的办法能真正止住写入**,外加两个更轻的配置/行为杠杆:

- **`codex-disk-block` —— opt-in、进阶、真正止血。** 在 `logs` 表上装一个 SQLite `BEFORE INSERT … RAISE(IGNORE)` 触发器,让 Codex 的插入变成静默空操作,在**数据库层**停住 churn——这是唯一没有开关的那一层。因为它**会改动 Codex 自己的数据库**:默认 dry-run,加 `--apply` 才执行,且**先备份**,`codex-disk-unblock` 可还原。**注意事项:** 依赖回读日志的 Codex 功能(如 feedback 上报)可能失效;Codex 升级若重建日志库会静默丢掉该触发器;卸载本工具会**自动移除该触发器**(锁安全),恢复 Codex 正常日志。用 `codex-disk-check --measure` 验证是否生效。
- **调高日志级别** —— 在 `~/.zshenv` 加 `export RUST_LOG=error`。能砍掉遵守过滤器的那部分(大部分 INFO/DEBUG 和部分 `codex_*` TRACE target),但**拦不住**高频的 `target=log` 行。部分缓解,效果因环境而异。
- **别让桌面版 daemon 常驻** —— 7×24 的空闲 churn 来自桌面版 app-server;彻底退出它就消除了这个来源(纯 CLI 本身没有空闲写入者)。

**在*你自己*的机器上实测效果:** 改动前后各跑一次 `codex-disk-check --measure 60`(或 `codex-disk-bench`)对比。

## 环境要求

- **仅 macOS**(用到 `launchd`、`fs_usage`、BSD `stat`)。安装器在非 macOS 上会直接拒绝运行。
- `sqlite3` —— macOS 自带于 `/usr/bin/sqlite3`;若装了 Homebrew 版会自动识别。
- `bash` —— 兼容系统自带的 bash 3.2,未使用 bash 4+ 特性。
- 已安装 OpenAI **Codex CLI**(本工具读取/维护 `~/.codex`)。

## 安装

```bash
git clone https://github.com/RuntianLee/codex-disk-guard.git
cd codex-disk-guard
./setup.sh
```

如果 `setup.sh` 提示 `~/.local/bin` 不在 `PATH` 中,加入后重开终端:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

## 日常使用

```bash
codex-disk-check                 # 快速查状态,无需 sudo;结果追加到报告文件
codex-disk-check --json          # 同上,机器可读的单行输出
codex-disk-check --measure 60    # 精确测 60 秒活跃写速(需 sudo),这段时间正常用 Codex
codex-disk-maintain              # 立即清旧日志 + checkpoint + vacuum
codex-disk-cleanup               # 预览可删的垃圾(dry-run)
codex-disk-cleanup --apply       # 真正删除垃圾

# ⚠️  进阶 —— 真正“止血”:会改动 Codex 自己的数据库(先备份、可还原)
codex-disk-block                 # 预览(dry-run)——只显示将做什么,不改动
codex-disk-block --apply         # 装上触发器,止住 Codex 的日志写入
codex-disk-unblock               # 移除触发器,Codex 恢复写日志
```

平时想知道"是不是又在大量写盘",敲 `codex-disk-check` 即可;想要硬数据时再用 `--measure`。

### 对比测试:CLI vs 桌面版

CLI 只在你主动运行时写盘;而**桌面版**还会常驻一个后台 daemon,**空闲时也 24/7 持续写**——那才是磨损的真正来源。`codex-disk-bench` 分阶段把两者都测一遍,方便对比:

```bash
codex-disk-bench guide            # 依次:① 空闲基线 → ② CLI 活跃 → ③ 维护
# ……然后安装并启动桌面版,再:
codex-disk-bench desktop-idle 120 # ④ 桌面版开着、完全不操作(测 daemon 的空闲写入)
codex-disk-bench desktop-active   # ⑤ 主动使用桌面版
codex-disk-bench report           # 出对照表(无需 sudo)
```

每个阶段用的测量命令完全一样,只是场景不同。④/⑤ 只有在装了桌面版(及其 daemon)后才有意义——CLI 本身没有"空闲写入"这个状态。

## 工作原理

- **被动监测** 利用 `logs` 表的 `sqlite_sequence` 计数器(单调递增的插入计数,即使旧行被删也不回退)。两次采样的差值,正好等于这期间插入了多少行日志——于是**无需 `sudo`**、也不用扫描整个库,就能得到准确的插入速率。
- **精确模式**(`--measure`)运行 `sudo fs_usage` N 秒,累加写到 `~/.codex` 下各路径的字节,外推成 MB/天,并按 `CDT_TBW_TB`(默认 150)换算 SSD 寿命。
- **维护** 执行 `DELETE FROM logs WHERE ts < 截止时间`、`PRAGMA wal_checkpoint(TRUNCATE)`、`VACUUM`。如果库正被 Codex 占用(锁定),它会安全退避、退出码 0、不碰数据。

## 定时任务

`setup.sh` 安装两个用户级 `launchd` 任务(不需要 root,不改系统):

- `com.user.codex-disk-maintain` —— 每天 **03:00**
- `com.user.codex-disk-check` —— 每天 **03:05**

若到点时 Mac 在睡眠,`launchd` 会在下次唤醒补跑。任务的标准输出/错误写到 `~/.local/state/codex-disk/`。

## 配置

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

## 各功能会写哪些文件(按功能)

本工具写的所有东西都在你的家目录下、可配置、并能被 `codex-disk-uninstall` 完全清除。每个功能具体写到哪个路径:

| 命令 / 功能 | 写入路径 |
|---|---|
| `setup.sh`(安装) | 命令 → `~/.local/bin/`(及 `~/.local/bin/lib/common.sh`);定时任务 → `~/Library/LaunchAgents/com.user.codex-disk-maintain.plist`、`…codex-disk-check.plist`;创建报告目录 `~/.local/state/codex-disk/` |
| `codex-disk-check`(被动模式) | `~/.local/state/codex-disk/report.log`(每次运行追加一行)和 `~/.local/state/codex-disk/last-sample`(每次覆盖) |
| `codex-disk-check --measure` | **不留持久文件** —— 仅用一个 `mktemp` 临时文件且立即删除;结果打印到终端/stdout |
| `codex-disk-maintain` | 修改 `~/.codex/logs_2.sqlite`(它要维护的目标,也是唯一改动的文件);不写其它任何文件 |
| `codex-disk-bench` | 每个阶段写 `~/.local/state/codex-disk/bench/<阶段>.json`(及 `.residual` 标记) |
| `codex-disk-cleanup --apply` | **删除** `~/.codex` 下的垃圾;不创建任何文件 |
| `codex-disk-block --apply` | 先备份到 `~/.codex/logs_2.sqlite.block-backup-<时间戳>`,并在 `~/.codex/logs_2.sqlite` **内部**加一个触发器 |
| `codex-disk-unblock` | 从 `~/.codex/logs_2.sqlite` 移除该触发器 |
| 每日 `launchd` 定时任务 | 标准输出/错误 → `~/.local/state/codex-disk/maintain.out.log`、`maintain.err.log`、`check.out.log`、`check.err.log` |
| `codex-disk-uninstall` | 移除以上全部 |

路径可覆盖:`CDT_PREFIX`(命令)、`CDT_AGENTS_DIR`(定时任务)、`CDT_STATE_DIR`(报告)。报告目录**刻意放在 `~/.codex` 之外**,这样监测不会把自己写报告也算进 codex 的写入量。

**想要零文件?** 不跑 `setup.sh`,直接从仓库目录按需运行命令(`./bin/codex-disk-check --measure 60`、`./bin/codex-disk-maintain`、`./bin/codex-disk-cleanup`)。这些只打印到终端、不留任何文件——代价是失去每日定时、免 sudo 的被动速率、`report.log` 历史、以及跨会话的 bench 对比表。

## 安全性

- **维护只会操作 `logs_2.sqlite`**,永不读写 `sessions/` 或 `memories/`。
- **清理默认只预览**,且只删一份写死的垃圾清单:`logs_2.sqlite.bak`、`.codex-global-state.json.bak`、`.DS_Store`、`.tmp/`、`cache/remote_plugin_catalog/`、`computer-use/`。`sessions/` 和 `memories/` 被显式保护,永远不会被选中。
- 一切都装在你的家目录下;**除了可选的 `--measure` 模式外不需要 `sudo`**。

## 卸载

```bash
codex-disk-uninstall
```

删除命令、两个 launchd 任务、报告目录。如果你用过 `codex-disk-block`,它还会(锁安全地)从 Codex 日志库移除那个触发器,恢复正常日志。它不会改动你自己手动编辑过的任何 Codex 配置(那部分由你自行管理)。

## 设计与实现

完整的来龙去脉——背景、方案取舍的原因、以及逐组件的实现讲解(每部分是什么、*为什么*这样做)——见 **[docs/HOW-IT-WORKS.zh-CN.md](docs/HOW-IT-WORKS.zh-CN.md)**。

## 相关项目

- **[claude-codex-sync](https://github.com/RuntianLee/claude-codex-sync)** —— 作者的另一个开源项目。一个打通 Claude Code 与 Codex 的 Node.js 工具:把 Claude 的全局指令、规则和项目记忆安全地转换成 Codex 能读取的 Markdown。它绝不改动 Claude 的原生状态,也不碰 Codex 的记忆数据库,需显式确认参数、改动前自动备份。如果你 Codex 和 Claude Code 都用,会很方便。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
