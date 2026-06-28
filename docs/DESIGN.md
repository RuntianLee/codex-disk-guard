# Codex 频繁写日志磨损 SSD —— 缓解方案设计(方案 A)

- 日期:2026-06-28
- 适用机器:macOS(Apple Silicon Mac)
- 适用安装:**仅 `@openai/codex` CLI `0.142.2`**(经 Homebrew/npm)。**不安装 Codex 桌面版**,本方案不涉及桌面版。
- 关联问题:GitHub openai/codex #29532(`logs_2.sqlite` 高频 TRACE 写入)

## 1. 背景与诊断结论

### 1.1 问题
社区反馈 codex 频繁写日志,担心高频磁盘写入磨损 SSD。需排查本机是否存在该问题,并给出比社区教程更彻底、且符合本机使用习惯的缓解方案。

### 1.2 本机实测诊断(确认存在)
- `~/.codex/logs_2.sqlite`(WAL 模式)今天仍在写,`logs_2.sqlite.bak` 1.2MB。`.bak` 内容采样为满屏 `TRACE log`(`macos::current_platform is called`、`list_models{refresh_strategy=online}`、app-server websocket loop 等),与 issue #29532 描述的"高频 TRACE target=log"完全一致。
- 环境变量已设 `RUST_LOG=warn`,但 TRACE 日志照写不误——**根因**:SQLite 日志 sink(`codex_state::telemetry`,二进制内字符串 "process SQLite telemetry sink already installed")有独立 tracing 层,**不受 `RUST_LOG` 约束**。因此社区"改环境变量"的办法治不彻底。
- 通过 `codex features list` 确认:**当前版本没有任何用户可见的功能开关能关闭这个 sqlite 日志 sink**。这与 issue 状态一致(官方 PR #29432 / #29457 试图过滤但未根治)。

### 1.3 其它写放大源(教程未覆盖)
- `sessions/*.jsonl` 回放文件:113 个共 74MB,逐事件追加,单个最大 10MB。**持久数据,需保留。**
- `state_5.sqlite`(1MB)、`memories_1.sqlite`(565K)、`goals_1.sqlite`:周期性重写。**持久数据,需保留。**
- `.codex-global-state.json` + `.bak`:整文件重写。
- `~/.codex` 总计约 651MB,全部位于系统 SSD。

### 1.4 关键推论
- 当前 `~/Library/LaunchAgents` 无 codex 自启项,launchd 无 codex 服务,无后台 daemon 运行。
- 用户已确认**不安装桌面版**,因此不存在"桌面版常驻 daemon 24/7 写心跳日志"这一最大空闲磨损源。
- **因此本机的写盘只发生在主动运行 codex CLI 的活跃期。** 本方案聚焦:压低活跃期写入、让日志库不堆积、并提供长期监测手段确认问题不复发。

### 1.5 量化与定调(诚实评估)
- 活跃使用时 TRACE 写入约 0.5MB/分钟(改前基线,以 §5.2 实测为准)。
- 现代 SSD 耐久约数百 TBW;即便每天 1–2GB 写入(约 0.5TB/年),对 600TBW 的盘仍是数百年寿命。
- **结论**:对寿命的真实威胁较小;由于不装桌面版,已无 24/7 空闲写入。剩余的活跃期写入中 `logs_2.sqlite` 的 TRACE sink 无配置开关可关(已知限制),本方案通过低频截断使其不堆积,并通过定期检查脚本持续确认写盘速率处于可接受区间。

## 2. 目标与非目标

### 2.1 目标
- 确保 codex CLI 不残留后台 daemon、无自启项(空闲期零写入)。
- 将活跃使用时的日志库(`logs_2.sqlite`)控制在"不增长"的稳态。
- 提供**可定期运行的检查脚本**,长期监测 codex CLI 是否仍存在大量写盘,问题复发可及时发现。
- 改动后**实测验证生效**,并**预估改后活跃期写盘速率**(§5)。
- 零维护、重启不丢失、不引入易失存储。
- 不触碰任何持久数据。

### 2.2 非目标(明确排除)
- 不使用 RAM disk / 内存盘(用户偏好排除)。
- 不把 `CODEX_HOME` / `CODEX_SQLITE_HOME` / `CODEX_ROLLOUT_TRACE_ROOT` 迁移到其它磁盘卷(转移非消除,用户排除)。
- 不删除、不迁移 `sessions/`、`memories/`、`history.jsonl`、`state_5.sqlite`、`memories_1.sqlite`、`goals_1.sqlite`。
- **不修改 `history.persistence`**(用户要求保留上箭头跨会话命令历史)。

### 2.3 已知限制(用户已接受)
- `logs_2.sqlite` 的 TRACE sink 没有配置开关可彻底关闭;活跃使用时仍有约 0.5MB/分钟写入。本方案通过低频截断让该文件不堆积,但不消除活跃期写入。

## 3. 方案设计(五个组成部分)

### 组成 1:确保 CLI 无后台残留(空闲零写)
纯 CLI 场景下守住"用完即停":
- 不执行 `codex remote-control start` / `codex app-server` 常驻;若发现已起,`codex remote-control stop`。
- 核对 `~/Library/LaunchAgents` 与 `/Library/LaunchAgents` 始终无 codex/openai 自启项(当前已确认无)。
- 移除 `config.toml` 中的 `notify`(指向 computer-use 的 turn-ended 回调);CLI-only 不需要它,且与组成 4 删除 computer-use 绑定(详见下)。
- **预期效果**:无人使用时零写入。

### 组成 2:配置压制(写入 `~/.codex/config.toml` / 环境变量)
- `RUST_LOG` 由 `warn` 收紧为 `error`(进一步压低 stderr/file tracing;对 sqlite sink 无效但无害,且零风险)。
- 保留 `memories`、`history` 等用户依赖的功能,不动。
- 记录改动前的原值,提供一键回滚说明。

### 组成 3:低频维护任务(一个 launchd 定时任务,建议每天 1 次)
- 对 `logs_2.sqlite` 执行 `PRAGMA wal_checkpoint(TRUNCATE)`、清理超期日志行、`VACUUM`,使日志库稳定在小体积、WAL 不堆积。
- **不触碰** `sessions/` 与 `memories/`(用户要求全保留)。
- 频率低 → 维护本身几乎不增加写入。
- 提供 plist 的一键 `launchctl load` / `unload`。
- 维护脚本需具备幂等性、文件不存在时安全退出、对正在被 codex 占用的库做安全处理(检测锁/失败即跳过,不破坏数据)。

### 组成 4:一次性安全清理(执行前逐项确认)
仅清理明确的临时/缓存/备份,**清单先交用户逐项确认后才执行**:
- `~/.codex/logs_2.sqlite.bak`(1.2M)
- `~/.codex/.codex-global-state.json.bak`
- `~/.codex/.DS_Store`、`~/.codex/.tmp/`
- `~/.codex/cache/remote_plugin_catalog/`(可重建缓存)
- `~/.codex/computer-use/`(53M)—— CLI-only 不使用 GUI 自动化,计划删除。**必须与组成 1 移除 `notify` 行同步执行**(否则每轮 turn-ended 会调一个不存在的程序而报错)。可逆:以后启用 `computer_use` 时 codex 会重新拉取。
- `sessions/` 与 `memories/` **一律不动**。

### 组成 5:定期检查脚本(长期监测,核心新增)
一个可定期运行的脚本,用于持续确认 codex CLI **没有重新出现大量写盘**:
- **采集指标**(低开销、无需 sudo 即可常态运行):
  - `logs_2.sqlite` 体积、其 `-wal` 文件大小、内部行数;`.bak` 是否再生。
  - 自上次采样以来 `~/.codex` 关键路径(`logs_2.sqlite*`、`sessions/*.jsonl`、`*-global-state.json`)的体积增量。
  - 是否存在意外的 codex 常驻进程 / 自启项(复用组成 1 的检查)。
- **判定与告警**:对每项设阈值(如 WAL > 阈值、日志库日增量 > 阈值、出现常驻 daemon),超阈值则在报告中标红;正常则记一行 PASS。
- **可选精确模式**:带 `--measure` 参数时,用 `sudo fs_usage` 在固定窗口实测活跃期字节/分钟(即 §5.2 方法),供深度核查。常态定时任务用被动采样模式,不需要 sudo。
- **自身近零写**:报告以追加少量文本行为主,写到用户指定的小日志文件;采样频率低(随组成 3 每天 1 次,或单独排期)。
- **调度**:提供 launchd plist,可一键 `load`/`unload`;也支持手动随时运行查看当前状态。
- **与组成 3 的区别**:组成 3 做"维护"(checkpoint/vacuum,改变状态);组成 5 只做"监测"(读取/报告,不改状态)。两者独立交付,可共用同一每日触发点。

## 4. 交付物
- 改好的 `config.toml`(移除 `notify` 行;含改动说明与回滚方法,改动前自动备份原文件)。
- 维护脚本(组成 3,幂等、安全)+ 对应 launchd plist(可一键加载/卸载)。
- **定期检查/监测脚本(组成 5)** + 对应 launchd plist;支持手动运行与 `--measure` 精确模式;产出可读报告。
- 一次性清理清单(组成 4,执行前逐项确认,含 computer-use + notify 同步删除)。
- **写盘速率测量脚本**:用同一套方法测改前(基线)与改后的活跃期写盘速率,产出对比报告(见 §5.2 / §5.3)。可与组成 5 的 `--measure` 模式合并实现。

## 4.1 文件布局、调度与运行方式

### 文件布局
- 可执行脚本 → `~/.local/bin/`(已在 PATH 中,可直接按命令名调用):
  - `codex-disk-check` —— 组成 5 监测脚本(被动采样默认,无需 sudo;`--measure` 走精确模式)。
  - `codex-disk-maintain` —— 组成 3 维护脚本(checkpoint/vacuum/清理超期日志行)。
  - `codex-disk-setup.sh` / `codex-disk-uninstall.sh` —— 一键安装/卸载。
- launchd 定时配置 → `~/Library/LaunchAgents/`(用户级,无需 sudo):
  - `com.user.codex-disk-maintain.plist`
  - `com.user.codex-disk-check.plist`
- 报告/状态 → `~/.local/state/codex-disk/`(**刻意放在 `~/.codex` 之外**,避免监测脚本统计到自身写入)。

### 调度触发
- 机制:macOS launchd LaunchAgent + `StartCalendarInterval`,每天固定时刻触发(默认 03:00),用户级、无需 sudo。
- 登录时自动加载;若该时刻 Mac 处于睡眠,launchd 在下次唤醒补跑。
- 启用:`launchctl bootstrap gui/$(id -u) <plist>`(由 setup 脚本完成);停用:`launchctl bootout gui/$(id -u)/<label>`(由 uninstall 脚本完成)。

### 运行方式(一键性)
- **一键安装+排程**:`bash codex-disk-setup.sh`(部署脚本 + 布 plist + 加载定时,一次完成)。
- **随时手动查状态**:`codex-disk-check`(被动采样,**无需 sudo,真正一键**)。
- **手动维护**:`codex-disk-maintain`。
- **例外**:`codex-disk-check --measure` 使用 `sudo fs_usage` 精确测速,需输入密码,非纯一键;日常定时任务跑的是无 sudo 的被动采样模式。

## 5. 验证方法

### 5.1 生效性验证(改动是否真的起作用)
- **空闲零写验证**:不运行任何 codex,观察 `~/.codex` 下文件 mtime 在一段时间内无变化。这是组成 1(无后台残留)的核心验收。
- **配置生效验证**:确认 `RUST_LOG=error` 已在新 shell 生效(`echo $RUST_LOG`);确认 `config.toml` 改动被 codex 加载(`codex doctor` 无报错、无 `strict-config` 拒绝)。
- **daemon 验证**:`launchctl list | grep -i codex` 为空;`ps aux | grep -iE 'codex|app-server|SkyComputerUse'` 无常驻进程;`~/Library/LaunchAgents`、`/Library/LaunchAgents` 无 codex 自启项。
- **日志库稳态验证**:运行维护任务后,确认 `logs_2.sqlite` 体积回落、WAL 文件被截断;持续使用一段时间后文件不无限增长。
- **持久数据完好验证**:确认 `sessions/`、`memories/`、`history.jsonl`、各持久 sqlite 文件数量与内容未被方案改动。
- **回滚验证**:确认 config.toml 备份存在、launchd plist 可干净卸载、RUST_LOG 改动可还原。

### 5.2 活跃期写盘速率测量方法(改前基线 + 改后复测,同方法对比)
在一个**固定、可复现的代表性会话**下测量(例如:`codex exec` 跑一段固定 prompt,或交互模式固定操作约 60–120 秒),改前改后各测一次,确保可对比:
- **主测(syscall 级,最准)**:`sudo fs_usage -w -f filesystem` 过滤 codex 进程与 `~/.codex` 路径,统计窗口内对 `logs_2.sqlite*`、`*.sqlite-wal`、`sessions/*.jsonl`、`*-global-state.json` 等的 `write`/`pwrite` 字节总量,换算为 **字节/分钟**。按文件分类列出贡献占比(预期 `logs_2.sqlite*` 仍为大头)。
- **交叉校验(文件增量级)**:测量窗口前后对上述文件做 `stat` 体积差(含 WAL),作为 fs_usage 结果的旁证。
- **记录环境**:codex CLI 版本、`RUST_LOG` 值、会话内容,确保改前改后变量一致。

### 5.3 改后写盘速率预估与寿命换算(交付报告)
- 用 §5.2 改后实测的 **字节/分钟**,结合典型每日活跃时长,外推 **GB/天**。
- 叠加空闲态(组成 1 生效后预期 ≈ 0)。
- 用本机系统盘标称耐久(TBW)换算 **预计可用年数**,与改前基线对比给出降幅。
- 在报告中明确标注:`logs_2.sqlite` 活跃期写入属已知不可消除项(§2.3),预估值据此而来,而非假设其为零。

## 6. 回滚 / 卸载

### 6.1 清除脚本与定时任务(一键)
`bash codex-disk-uninstall.sh` 自包含完成,精确删除以下全部产物(也可手动逐条核对):
- `launchctl bootout gui/$(id -u)/com.user.codex-disk-maintain` 与 `...codex-disk-check`(卸载两个定时任务)
- 删 `~/Library/LaunchAgents/com.user.codex-disk-maintain.plist`、`...codex-disk-check.plist`
- 删 `~/.local/bin/codex-disk-check`、`codex-disk-maintain`、`codex-disk-setup.sh`
- 删报告目录 `~/.local/state/codex-disk/`
- 最后自删 `~/.local/bin/codex-disk-uninstall.sh`
- 全部位于家目录,无需 sudo,不动系统、不留残留。

### 6.2 还原缓解类改动(独立、可选,删脚本默认不动这些)
- `config.toml`:从安装时自动备份恢复(含还原 `notify` 行)。
- 环境变量:还原 `RUST_LOG`。
- `computer-use/`:重新启用 `computer_use` 功能后由 codex 自动重新拉取。
- 一次性清理为不可逆删除,故执行前必须逐项确认;被删项均为可重建缓存/备份/临时文件。

### 6.3 设计要求
- 安装器须记录其创建/修改的全部路径清单,卸载器据此精确移除,确保"装了什么 → 删什么"一一对应,不误删用户其它文件。

## 7. 风险
- 维护脚本若在 codex 正在写库时操作,可能撞锁——脚本须检测并安全跳过,绝不强写。
- 删除 computer-use 后若未同步移除 `notify`,会导致每轮 turn-ended 报错并增加写入——两者必须同步处理(组成 1 + 组成 4)。
- CLI 升级或未来若改用桌面版,可能引入新的自启/常驻写入;组成 5 的定期检查脚本即用于及时发现此类复发。
- `logs_2.sqlite` sink 的活跃期写入无法消除属已知限制;若未来官方提供开关,可再叠加。
