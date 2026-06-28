#!/usr/bin/env bash
# cleanup.sh — 一次性清理明确的临时/缓存/备份。默认 dry-run,--apply 才执行。
# 绝不触碰 sessions/ 与 memories/。
set -u
HOME_C="${CODEX_HOME:-$HOME/.codex}"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

targets=(
  "$HOME_C/logs_2.sqlite.bak"
  "$HOME_C/.codex-global-state.json.bak"
  "$HOME_C/.DS_Store"
  "$HOME_C/.tmp"
  "$HOME_C/cache/remote_plugin_catalog"
  "$HOME_C/computer-use"
)

echo "== codex 一次性清理 (apply=$APPLY) =="
echo "保护(永不删): $HOME_C/sessions, $HOME_C/memories"
echo
total=0
for t in "${targets[@]}"; do
  if [ -e "$t" ]; then
    sz=$(du -sk "$t" 2>/dev/null | awk '{print $1}'); total=$((total+sz))
    printf '  [%s] %s\n' "$(du -sh "$t" 2>/dev/null | awk '{print $1}')" "$t"
    if [ "$APPLY" -eq 1 ]; then rm -rf "$t" && echo "      -> 已删除"; fi
  else
    printf '  [skip 不存在] %s\n' "$t"
  fi
done
printf '\n合计可回收: ~%s MB\n' "$((total/1024))"
if [ "$APPLY" -eq 0 ]; then
  echo "这是预览(dry-run),未删除任何文件。确认无误后加 --apply 执行。"
  echo "  codex-disk-cleanup --apply   # 已安装时"
  echo "  ./cleanup.sh --apply         # 在仓库内直接运行时"
else
  echo "⚠ 若删除了 computer-use,且你的 config.toml 里有指向它的 notify = [...] 行,"
  echo "  请一并移除那行,否则 Codex 每轮结束都会去调一个不存在的程序而报错。"
fi
