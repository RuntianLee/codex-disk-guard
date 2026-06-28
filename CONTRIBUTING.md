# Contributing / 贡献指南

Thanks for your interest! / 感谢你的关注!

## English

### Ground rules

- **macOS only.** This tool depends on `launchd`, `fs_usage`, and BSD `stat`. Keep it that way unless you're adding a clearly-isolated cross-platform path.
- **Zero dependencies.** Plain `bash` (compatible with macOS's system bash 3.2), `sqlite3`, and standard macOS utilities. No `bats`, no package managers, no language runtimes.
- **Safety first.** Maintenance must only ever touch `logs_2.sqlite`. Nothing may read or write `sessions/` or `memories/`. Cleanup stays dry-run by default.
- **Test-driven.** Every behavior change comes with a test. See [docs/IMPLEMENTATION-PLAN.md](docs/IMPLEMENTATION-PLAN.md) for the style.

### Workflow

1. Fork and create a branch.
2. Add or update a test in `tests/test_*.sh` first (red).
3. Implement the change (green).
4. Run the full suite — it must pass with zero failures:
   ```bash
   ./tests/run_tests.sh
   ```
5. Tests must use temporary fixture dirs (`mktemp -d`) and never touch your real `~/.codex`, `~/.local/bin`, or `~/Library/LaunchAgents`.
6. Open a PR. CI runs the same suite on a macOS runner.

### Project layout

- `bin/` — the user-facing commands
- `lib/common.sh` — shared metric/helper functions
- `setup.sh` / `uninstall.sh` / `cleanup-once.sh` — install, uninstall, one-time cleanup
- `launchd/` — plist templates rendered at install time
- `tests/` — plain-bash test suite
- `docs/` — design rationale and the implementation plan

## 中文

### 基本原则

- **仅 macOS。** 工具依赖 `launchd`、`fs_usage`、BSD `stat`。除非你新增的是清晰隔离的跨平台分支,否则请保持 macOS-only。
- **零依赖。** 纯 `bash`(兼容 macOS 系统自带的 bash 3.2)、`sqlite3` 和 macOS 标准工具。不引入 `bats`、包管理器或任何语言运行时。
- **安全第一。** 维护只能操作 `logs_2.sqlite`;任何代码都不得读写 `sessions/` 或 `memories/`;清理默认保持 dry-run。
- **测试驱动。** 任何行为改动都要配套测试。风格见 [docs/IMPLEMENTATION-PLAN.md](docs/IMPLEMENTATION-PLAN.md)。

### 流程

1. Fork 并新建分支。
2. 先在 `tests/test_*.sh` 加/改测试(红)。
3. 实现改动(绿)。
4. 跑完整测试套件,必须零失败:
   ```bash
   ./tests/run_tests.sh
   ```
5. 测试必须使用临时 fixture 目录(`mktemp -d`),绝不触碰你真实的 `~/.codex`、`~/.local/bin`、`~/Library/LaunchAgents`。
6. 提交 PR。CI 会在 macOS runner 上跑同一套测试。

### 项目结构

- `bin/` —— 面向用户的命令
- `lib/common.sh` —— 共享的指标/工具函数
- `setup.sh` / `uninstall.sh` / `cleanup-once.sh` —— 安装、卸载、一次性清理
- `launchd/` —— 安装时渲染的 plist 模板
- `tests/` —— 纯 bash 测试套件
- `docs/` —— 设计文档与实施计划
