# codex-disk-guard

[![tests](https://github.com/RuntianLee/codex-disk-guard/actions/workflows/test.yml/badge.svg)](https://github.com/RuntianLee/codex-disk-guard/actions/workflows/test.yml)

[English](README.md) | **中文**

**在 macOS 上治理 OpenAI Codex CLI 的频繁写盘 —— 监测写入、控制日志库不再膨胀、清理垃圾文件,且绝不动你的会话记录和记忆数据。**

> 背景:Codex CLI 会持续把高频 `TRACE` 日志写进 `~/.codex/logs_2.sqlite`(见 [openai/codex#29532](https://github.com/openai/codex/issues/29532))。`RUST_LOG` 环境变量**拦不住**它,因为这个 SQLite 日志 sink 有独立的 tracing 层,而且目前没有配置开关能关掉它。本工具不修改 Codex 本身,而是在它周围提供监测、低频维护和安全清理。

## 它能做什么

| 命令 | 作用 |
|---|---|
| `codex-disk-check` | **监测。** 采样 Codex 自上次以来插入了多少行日志,算出写入速率。无需 `sudo`,向报告文件追加一行。 |
| `codex-disk-check --measure 60` | **精确测速。** 用 `fs_usage` 实测 60 秒内对 `~/.codex` 的写入字节(需 `sudo`),给出 MB/天当量和 SSD 寿命估算。 |
| `codex-disk-maintain` | **维护。** 删除 N 天前的日志行、截断 WAL、`VACUUM` 压实 `logs_2.sqlite`,让它保持小体积。只动这一个数据库。 |
| `codex-disk-cleanup` | **清理** 明确的垃圾(陈旧备份、缓存、临时目录)。默认只预览,加 `--apply` 才真删。绝不碰 `sessions/` 和 `memories/`。 |
| `codex-disk-bench` | **对比测试。** 分阶段测写盘速率——空闲基线、CLI 活跃,以及(若安装桌面版)桌面空闲/活跃——最后出一张对照表。 |
| `codex-disk-uninstall` | **卸载** 本工具安装的一切。 |

`setup.sh` 会把前四个命令装进 `~/.local/bin`,并注册两个 `launchd` 定时任务:每天 **03:00 维护**、**03:05 检查**。

## 为什么会频繁写(以及本工具能/不能做什么)

- 热点文件是 `~/.codex/logs_2.sqlite`。活跃使用 Codex 时,它会以约 0.5 MB/分钟 的速度被写入 `TRACE` 日志。
- 这个写入**目前无法用配置关闭**——所以本工具不声称能消除活跃使用时的写入。它做的是:(a) 让日志库不再无限膨胀;(b) 让你长期观察写入速率;(c) 清掉一次性垃圾。
- 客观看:即使每天写 1–2 GB(约 0.5 TB/年),一块标称数百 TBW 的现代 SSD 也能用上百年。本工具的意义是"心里有数 + 保持整洁",而不是制造焦虑。

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

## 安全性

- **维护只会操作 `logs_2.sqlite`**,永不读写 `sessions/` 或 `memories/`。
- **清理默认只预览**,且只删一份写死的垃圾清单:`logs_2.sqlite.bak`、`.codex-global-state.json.bak`、`.DS_Store`、`.tmp/`、`cache/remote_plugin_catalog/`、`computer-use/`。`sessions/` 和 `memories/` 被显式保护,永远不会被选中。
- 一切都装在你的家目录下;**除了可选的 `--measure` 模式外不需要 `sudo`**。

## 卸载

```bash
codex-disk-uninstall
```

删除命令、两个 launchd 任务、报告目录。它不会改动你自己手动编辑过的任何 Codex 配置(那部分由你自行管理)。

## 开发

```bash
./tests/run_tests.sh      # 运行完整的 bash 测试套件(零依赖)
```

测试是纯 bash + 一个极小的断言 helper,不需要 `bats` 之类的工具。全部针对临时 fixture 目录运行,绝不触碰你真实的 `~/.codex`、`~/.local/bin`、`~/Library/LaunchAgents`。

## 设计与开发

想了解它*为什么*这样设计、*如何*一步步建起来?下面两份文档记录了完整的设计与实现过程:

- **[docs/DESIGN.md](docs/DESIGN.md)** —— 设计文档:问题如何被诊断、考虑过哪些方案、取舍是什么、以及验证方法。
- **[docs/IMPLEMENTATION-PLAN.md](docs/IMPLEMENTATION-PLAN.md)** —— 逐任务、测试驱动(TDD)的实施计划(一次一个任务,红 → 绿 → 提交)。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
