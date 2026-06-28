# codex-disk-tools

治理本机 codex CLI 频繁写盘(GitHub openai/codex #29532)。详见 spec:
docs/superpowers/specs/2026-06-28-codex-disk-write-mitigation-design.md

## 安装
    bash ~/codex-disk-tools/setup.sh        # 部署脚本 + 每日定时(maintain 03:00 / check 03:05)

## 日常使用
    codex-disk-check              # 一键查写盘状态(无需 sudo),结果追加到 ~/.local/state/codex-disk/report.log
    codex-disk-check --measure 60 # 精确测活跃写速(需 sudo,跑 60s,期间正常用 codex)
    codex-disk-maintain           # 手动维护(checkpoint/vacuum/清 3 天前日志)

## 一次性清理(可选)
    bash ~/codex-disk-tools/cleanup-once.sh           # 预览
    bash ~/codex-disk-tools/cleanup-once.sh --apply   # 执行

## 卸载
    codex-disk-uninstall          # 删脚本/定时/报告(config/RUST_LOG 改动需手动还原,见 spec §6.2)
    cp ~/.codex/config.toml.cdt-backup ~/.codex/config.toml   # 还原 config(恢复 notify)

## 阈值(环境变量覆盖)
    CDT_RETENTION_DAYS=3  CDT_WAL_WARN_BYTES=8388608
    CDT_LOGS_RATE_WARN_MB_DAY=50  CDT_TBW_TB=150
