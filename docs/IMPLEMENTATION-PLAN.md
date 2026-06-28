# Codex CLI 频繁写盘缓解工具 Implementation Plan

> 本文件是本项目的逐任务实施计划(TDD),记录了工具从零到完成的完整构建过程,供想了解设计与实现细节的使用者/贡献者参考。每个任务都是"先写测试 → 跑红 → 实现 → 跑绿 → 提交"的小步。

**Goal:** 为本机 codex CLI 交付一套纯用户态、零依赖的写盘治理工具(维护 + 监测 + 一键安装/卸载),并完成"改前基线测速 → 应用缓解 → 改后复测 → SSD 寿命预估"的闭环。

**Architecture:** 在 `~/codex-disk-guard/`(git 仓库)中开发 source,核心逻辑放 `lib/common.sh` 并对纯函数做 bash TDD。两个可执行脚本 `codex-disk-maintain`(checkpoint/vacuum/清旧日志)与 `codex-disk-check`(被动采样监测,核心指标用 `logs` 表 `sqlite_sequence.seq` 增量,无需 sudo;`--measure` 用 `sudo fs_usage` 精确测速)。`setup.sh` 把脚本装到 `~/.local/bin/`、把 launchd plist 装到 `~/Library/LaunchAgents/` 并加载每日 03:00 定时;`uninstall.sh` 精确卸载。报告写到 `~/.local/state/codex-disk/`(刻意避开 `~/.codex`)。

**Tech Stack:** bash、/usr/bin/sqlite3(3.51)、launchd(`launchctl bootstrap`/`bootout`)、`fs_usage`(仅 --measure)。无第三方依赖。

**设计文档(Spec):** [DESIGN.md](DESIGN.md)

**关键本机事实(实施时假定为真,已实测):**
- codex CLI: `@openai/codex` 0.142.2,`CODEX_HOME=~/.codex`,`sqlite3` 在 `/usr/bin/sqlite3`。
- `~/.local/bin` 已存在且在 PATH 中。
- `logs_2.sqlite` 的 `logs` 表结构:`id INTEGER PK AUTOINCREMENT, ts INTEGER(unix秒), ts_nanos, level TEXT, target TEXT, ..., estimated_bytes INTEGER`。库内含 `_sqlx_migrations`、`logs` 两表;AUTOINCREMENT 维护内部 `sqlite_sequence`。
- 当前 `logs_2.sqlite` 可能为 0 字节/无表(被截断过)——所有脚本必须对"文件不存在/表不存在/库为空"安全。
- 系统盘:Apple 内置 SSD(512GB 级)。Apple SSD 无官方 TBW,脚本默认按保守 `150 TBW` 估算,可用环境变量覆盖。
- `RUST_LOG=warn` 当前生效但不在任何标准 shell rc 中(疑由环境注入)——配置任务须防御式处理。

---

## 文件结构

```
~/codex-disk-guard/                      # git 仓库(Task 1 创建)
  lib/common.sh                          # 共享纯函数 + 指标采集(Task 2)
  bin/codex-disk-maintain                # 维护脚本(Task 3)
  bin/codex-disk-check                   # 监测脚本:被动 + --measure(Task 4/5)
  launchd/com.user.codex-disk-maintain.plist.template   # (Task 6)
  launchd/com.user.codex-disk-check.plist.template      # (Task 6)
  setup.sh                               # 一键安装(Task 6)
  uninstall.sh                           # 一键卸载(Task 6)
  cleanup-once.sh                        # 一次性清理(交互确认)(Task 7)
  tests/run_tests.sh                     # 测试入口(Task 1)
  tests/assert.sh                        # 断言helper(Task 1)
  tests/fixtures.sh                      # 造测试库helper(Task 2)
  tests/test_common.sh                   # (Task 2)
  tests/test_maintain.sh                 # (Task 3)
  tests/test_check.sh                    # (Task 4)
  tests/test_measure.sh                  # (Task 5)
  tests/test_setup.sh                    # (Task 6)
  README.md                              # 用法(Task 8 收尾)
docs/.../specs|plans                     # 既有
```

安装后落点(由 setup.sh 部署):
- `~/.local/bin/codex-disk-maintain`、`~/.local/bin/codex-disk-check`、`~/.local/bin/codex-disk-uninstall`
- `~/Library/LaunchAgents/com.user.codex-disk-maintain.plist`、`...codex-disk-check.plist`
- `~/.local/state/codex-disk/`(report.log、last-sample)

**环境变量约定(贯穿所有脚本,便于测试与覆盖):**
- `CODEX_HOME`(默认 `$HOME/.codex`)
- `CDT_STATE_DIR`(默认 `$HOME/.local/state/codex-disk`)
- `CDT_RETENTION_DAYS`(默认 `3`)— 维护保留多少天日志行
- `CDT_WAL_WARN_BYTES`(默认 `8388608` = 8MB)
- `CDT_LOGS_RATE_WARN_MB_DAY`(默认 `50`)— logs 写入速率告警阈值(MB/天当量)
- `CDT_TBW_TB`(默认 `150`)— SSD 标称耐久,用于寿命换算

---

## Task 1: 工具仓库脚手架 + 测试框架

**Files:**
- Create: `~/codex-disk-guard/tests/assert.sh`
- Create: `~/codex-disk-guard/tests/run_tests.sh`
- Create: `~/codex-disk-guard/.gitignore`

- [ ] **Step 1: 创建仓库目录并 git init**

Run:
```bash
mkdir -p ~/codex-disk-guard/{lib,bin,launchd,tests}
cd ~/codex-disk-guard && git init -q && echo "ok"
```
Expected: 打印 `ok`

- [ ] **Step 2: 写断言 helper `tests/assert.sh`**

```bash
# tests/assert.sh — 极简 bash 断言库,无第三方依赖
CDT_TESTS_RUN=0
CDT_TESTS_FAIL=0

assert_eq() { # <expected> <actual> <msg>
  CDT_TESTS_RUN=$((CDT_TESTS_RUN+1))
  if [ "$1" != "$2" ]; then
    CDT_TESTS_FAIL=$((CDT_TESTS_FAIL+1))
    printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$1" "$2" >&2
  else
    printf 'ok: %s\n' "$3"
  fi
}

assert_true() { # <cmd...> ; 命令退出码为0则通过
  CDT_TESTS_RUN=$((CDT_TESTS_RUN+1))
  local msg="$1"; shift
  if "$@"; then printf 'ok: %s\n' "$msg"; else
    CDT_TESTS_FAIL=$((CDT_TESTS_FAIL+1)); printf 'FAIL: %s (cmd: %s)\n' "$msg" "$*" >&2; fi
}

assert_false() { # <msg> <cmd...> ; 命令退出码非0则通过
  CDT_TESTS_RUN=$((CDT_TESTS_RUN+1))
  local msg="$1"; shift
  if "$@"; then CDT_TESTS_FAIL=$((CDT_TESTS_FAIL+1)); printf 'FAIL: %s (cmd unexpectedly succeeded: %s)\n' "$msg" "$*" >&2
  else printf 'ok: %s\n' "$msg"; fi
}

assert_summary() {
  printf '\n--- %d run, %d failed ---\n' "$CDT_TESTS_RUN" "$CDT_TESTS_FAIL"
  [ "$CDT_TESTS_FAIL" -eq 0 ]
}
```

- [ ] **Step 3: 写测试入口 `tests/run_tests.sh`**

```bash
#!/usr/bin/env bash
# 运行 tests/ 下所有 test_*.sh,聚合结果
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
for t in "$HERE"/test_*.sh; do
  [ -e "$t" ] || continue
  printf '\n=== %s ===\n' "$(basename "$t")"
  source "$t"
done
assert_summary
```

Run:
```bash
chmod +x ~/codex-disk-guard/tests/run_tests.sh
```

- [ ] **Step 4: 写 `.gitignore`**

```
tests/.tmp/
*.bak
.DS_Store
```

- [ ] **Step 5: 运行空测试套件,确认框架可跑**

Run: `bash ~/codex-disk-guard/tests/run_tests.sh`
Expected: 输出 `--- 0 run, 0 failed ---`,退出码 0

- [ ] **Step 6: Commit**

```bash
cd ~/codex-disk-guard
git add -A && git commit -q -m "chore: scaffold codex-disk-guard repo and bash test harness" && echo committed
```

---

## Task 2: 核心共享库 `lib/common.sh`(纯函数 TDD)

**Files:**
- Create: `~/codex-disk-guard/lib/common.sh`
- Create: `~/codex-disk-guard/tests/fixtures.sh`
- Test: `~/codex-disk-guard/tests/test_common.sh`

- [ ] **Step 1: 写造测试库 helper `tests/fixtures.sh`**

```bash
# tests/fixtures.sh — 在临时目录造一个与真实结构一致的 logs_2.sqlite
# 用法: fixture_home=$(make_fixture_home <rows>)
make_fixture_home() {
  local rows="${1:-0}"
  local home; home="$(mktemp -d)"
  local db="$home/logs_2.sqlite"
  sqlite3 "$db" "
    CREATE TABLE logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts INTEGER NOT NULL, ts_nanos INTEGER NOT NULL,
      level TEXT NOT NULL, target TEXT NOT NULL,
      feedback_log_body TEXT, module_path TEXT, file TEXT, line INTEGER,
      thread_id TEXT, process_uuid TEXT,
      estimated_bytes INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE _sqlx_migrations (version BIGINT PRIMARY KEY);
  "
  local i now; now="$(date +%s)"
  for ((i=0; i<rows; i++)); do
    sqlite3 "$db" "INSERT INTO logs(ts,ts_nanos,level,target,estimated_bytes) VALUES($now,0,'TRACE','log',100);"
  done
  printf '%s' "$home"
}
```

- [ ] **Step 2: 写失败测试 `tests/test_common.sh`**

```bash
# tests/test_common.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/fixtures.sh"
source "$HERE/../lib/common.sh"

# human_bytes
assert_eq "0B"    "$(cdt_human_bytes 0)"        "human_bytes 0"
assert_eq "1.0K"  "$(cdt_human_bytes 1024)"     "human_bytes 1K"
assert_eq "1.5M"  "$(cdt_human_bytes 1572864)"  "human_bytes 1.5M"

# 目录解析尊重环境变量
( export CODEX_HOME=/tmp/x; assert_eq "/tmp/x" "$(cdt_codex_home)" "codex_home from env" )

# 空库/缺文件安全
emptyhome="$(make_fixture_home 0)"
( export CODEX_HOME="$emptyhome"
  assert_eq "0" "$(cdt_insert_counter)" "insert_counter empty db = 0"
  assert_eq "0" "$(cdt_logs_rowcount)"  "rowcount empty db = 0" )
( export CODEX_HOME=/nonexistent-xyz
  assert_eq "0" "$(cdt_file_size "$(cdt_logs_db)")" "file_size missing = 0"
  assert_eq "0" "$(cdt_insert_counter)" "insert_counter missing db = 0" )

# 有数据:插入计数与行数
h5="$(make_fixture_home 5)"
( export CODEX_HOME="$h5"
  assert_eq "5" "$(cdt_insert_counter)" "insert_counter = seq 5"
  assert_eq "5" "$(cdt_logs_rowcount)"  "rowcount = 5" )

# 阈值比较
assert_true  "over: 10>5"      cdt_over 10 5
assert_false "not over: 5>5"   cdt_over 5 5

# MB/天换算: 100MB 在 3600s -> 2400 MB/day
assert_eq "2400.00" "$(cdt_mb_per_day $((100*1024*1024)) 3600)" "mb_per_day"

# TBW 年数: 1 GB/day, 150 TBW -> 150000 GB / 365 GB/yr ~ 410.96 年
assert_eq "410.96" "$(cdt_tbw_years $((1024*1024*1024)) 150)" "tbw_years"
```

- [ ] **Step 3: 运行测试,确认失败**

Run: `bash ~/codex-disk-guard/tests/run_tests.sh`
Expected: 多条 `FAIL`(`cdt_*: command not found` / 不等),结尾非 0

- [ ] **Step 4: 实现 `lib/common.sh`**

```bash
# lib/common.sh — 共享纯函数与指标采集(被 maintain/check 复用)
# 不要 set -e:作为库被 source,失败处理交由各函数返回值。
CDT_SQLITE="${CDT_SQLITE:-/usr/bin/sqlite3}"

cdt_codex_home() { printf '%s' "${CODEX_HOME:-$HOME/.codex}"; }
cdt_state_dir()  { printf '%s' "${CDT_STATE_DIR:-$HOME/.local/state/codex-disk}"; }
cdt_logs_db()    { printf '%s/logs_2.sqlite' "$(cdt_codex_home)"; }

cdt_human_bytes() { # <int bytes>
  awk -v b="${1:-0}" 'BEGIN{
    split("B K M G T",u," "); i=1; x=b+0;
    while (x>=1024 && i<5){ x/=1024; i++ }
    if (i==1) printf "%dB", x; else printf "%.1f%s", x, u[i];
  }'
}

cdt_file_size() { # <path> -> bytes 或 0
  if [ -f "$1" ]; then stat -f '%z' "$1" 2>/dev/null || echo 0; else echo 0; fi
}

# 单调插入计数:优先 sqlite_sequence.seq(行被 prune 后仍不回退),回退 max(id),再回退 0。
cdt_insert_counter() {
  local db; db="$(cdt_logs_db)"
  [ -f "$db" ] || { echo 0; return; }
  local v
  v="$("$CDT_SQLITE" "$db" \
    "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='logs'),(SELECT max(id) FROM logs),0);" 2>/dev/null)"
  [ -n "$v" ] && printf '%s' "$v" || echo 0
}

cdt_logs_rowcount() {
  local db; db="$(cdt_logs_db)"
  [ -f "$db" ] || { echo 0; return; }
  local v; v="$("$CDT_SQLITE" "$db" "SELECT count(*) FROM logs;" 2>/dev/null)"
  [ -n "$v" ] && printf '%s' "$v" || echo 0
}

cdt_wal_size() { cdt_file_size "$(cdt_logs_db)-wal"; }

cdt_over() { # <value> <threshold> -> 退出码0 当 value>threshold(支持小数)
  awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a+0 > b+0) }'
}

cdt_mb_per_day() { # <bytes> <elapsed_seconds> -> MB/day, 2位小数
  awk -v by="$1" -v s="$2" 'BEGIN{
    if (s+0<=0){ printf "0.00"; exit }
    printf "%.2f", (by/1048576.0) * (86400.0/s);
  }'
}

cdt_tbw_years() { # <bytes_per_day> <tbw_tb> -> 年, 2位小数
  awk -v bpd="$1" -v tbw="$2" 'BEGIN{
    gb_per_day = bpd/1073741824.0;
    if (gb_per_day<=0){ printf "inf"; exit }
    total_gb = tbw*1000.0;            # 1 TB = 1000 GB(厂商口径)
    printf "%.2f", total_gb/(gb_per_day*365.0);
  }'
}

# 检测残留 daemon / 自启项;有则逐行 echo,无则无输出。
cdt_detect_residual() {
  ps aux | grep -iE 'codex .*(app-server|remote-control)|SkyComputerUse' | grep -v grep \
    | awk '{print "proc:", $2, $11, $12, $13}'
  launchctl list 2>/dev/null | grep -i codex | awk '{print "launchd:", $0}'
  ls "$HOME/Library/LaunchAgents" /Library/LaunchAgents 2>/dev/null \
    | grep -iE 'codex|openai' | awk '{print "agent:", $0}'
}
```

- [ ] **Step 5: 运行测试,确认通过**

Run: `bash ~/codex-disk-guard/tests/run_tests.sh`
Expected: 全部 `ok`,结尾 `0 failed`,退出码 0

- [ ] **Step 6: Commit**

```bash
cd ~/codex-disk-guard
git add -A && git commit -q -m "feat: add common.sh metrics lib with passing unit tests" && echo committed
```

---

## Task 3: 维护脚本 `bin/codex-disk-maintain`

**Files:**
- Create: `~/codex-disk-guard/bin/codex-disk-maintain`
- Test: `~/codex-disk-guard/tests/test_maintain.sh`

- [ ] **Step 1: 写失败测试 `tests/test_maintain.sh`**

```bash
# tests/test_maintain.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/fixtures.sh"
MAINTAIN="$HERE/../bin/codex-disk-maintain"

# 造库:5 行新日志 + 2 行"老"日志(ts 设为 10 天前)
h="$(make_fixture_home 5)"
old=$(( $(date +%s) - 10*86400 ))
sqlite3 "$h/logs_2.sqlite" "INSERT INTO logs(ts,ts_nanos,level,target,estimated_bytes) VALUES($old,0,'TRACE','log',100),($old,0,'TRACE','log',100);"
before=$(sqlite3 "$h/logs_2.sqlite" "SELECT count(*) FROM logs;")
assert_eq "7" "$before" "fixture has 7 rows"

# 运行维护(保留 3 天)
CODEX_HOME="$h" CDT_RETENTION_DAYS=3 bash "$MAINTAIN" >/dev/null 2>&1
after=$(sqlite3 "$h/logs_2.sqlite" "SELECT count(*) FROM logs;")
assert_eq "5" "$after" "maintain pruned 2 old rows, kept 5"

# 缺库时安全退出(退出码0,不报错)
assert_true "maintain safe on missing db" bash -c "CODEX_HOME=/nonexistent-xyz bash '$MAINTAIN'"
```

- [ ] **Step 2: 运行测试,确认失败**

Run: `bash ~/codex-disk-guard/tests/run_tests.sh`
Expected: `test_maintain.sh` 段 `FAIL`(脚本不存在 / 行数不符)

- [ ] **Step 3: 实现 `bin/codex-disk-maintain`**

```bash
#!/usr/bin/env bash
# codex-disk-maintain — 截断 WAL、清理超期日志行、压实 logs_2.sqlite。
# 只动 logs_2.sqlite,绝不碰 sessions/ 与 memories/。库被占用/锁定时安全跳过。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# 安装后 lib 与 bin 同级目录结构:优先仓库相对路径,回退安装路径。
if [ -f "$HERE/../lib/common.sh" ]; then source "$HERE/../lib/common.sh";
elif [ -f "$HERE/lib/common.sh" ]; then source "$HERE/lib/common.sh";
else echo "common.sh not found" >&2; exit 1; fi

db="$(cdt_logs_db)"
retention="${CDT_RETENTION_DAYS:-3}"
log() { printf '[maintain %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

[ -f "$db" ] || { log "no logs db at $db, nothing to do"; exit 0; }

# 锁检测:busy_timeout 短,撞锁即放弃本轮(不破坏数据)
cutoff="$(( $(date +%s) - retention*86400 ))"
out="$("$CDT_SQLITE" "$db" 2>&1 <<SQL
PRAGMA busy_timeout=2000;
DELETE FROM logs WHERE ts < $cutoff;
PRAGMA wal_checkpoint(TRUNCATE);
VACUUM;
SQL
)"
rc=$?
if [ $rc -ne 0 ]; then
  log "skipped (db busy/locked or error): ${out}"
  exit 0   # 安全跳过,不视为失败
fi
log "ok: pruned rows older than ${retention}d, checkpointed + vacuumed; size now $(cdt_human_bytes "$(cdt_file_size "$db")")"
exit 0
```

Run: `chmod +x ~/codex-disk-guard/bin/codex-disk-maintain`

- [ ] **Step 4: 运行测试,确认通过**

Run: `bash ~/codex-disk-guard/tests/run_tests.sh`
Expected: 全 `ok`,`0 failed`

- [ ] **Step 5: Commit**

```bash
cd ~/codex-disk-guard
git add -A && git commit -q -m "feat: add codex-disk-maintain (prune/checkpoint/vacuum, lock-safe)" && echo committed
```

---

## Task 4: 监测脚本被动模式 `bin/codex-disk-check`

**Files:**
- Create: `~/codex-disk-guard/bin/codex-disk-check`
- Test: `~/codex-disk-guard/tests/test_check.sh`

被动模式逻辑:读取当前 `insert_counter`,与 `state_dir/last-sample` 中上次值比较,算出"两次采样间新增插入行数"和"rows/min";把 WAL 大小、残留检测、PASS/WARN 写入 `state_dir/report.log`;更新 last-sample。无需 sudo。

- [ ] **Step 1: 写失败测试 `tests/test_check.sh`**

```bash
# tests/test_check.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/fixtures.sh"
CHECK="$HERE/../bin/codex-disk-check"

h="$(make_fixture_home 10)"
state="$(mktemp -d)"

# 首次运行:无基线,应初始化 last-sample 且报告 baseline,退出0
CODEX_HOME="$h" CDT_STATE_DIR="$state" bash "$CHECK" >/dev/null 2>&1
assert_true "last-sample created" test -f "$state/last-sample"
assert_true "report created" test -f "$state/report.log"
assert_true "first run records baseline" grep -q "baseline" "$state/report.log"

# 再插 6 行后第二次运行:应报告 inserted=6
sqlite3 "$h/logs_2.sqlite" "INSERT INTO logs(ts,ts_nanos,level,target,estimated_bytes) SELECT ts,0,'TRACE','log',100 FROM logs LIMIT 6;"
CODEX_HOME="$h" CDT_STATE_DIR="$state" bash "$CHECK" >/dev/null 2>&1
assert_true "second run records inserted=6" grep -q "inserted=6" "$state/report.log"

# --json 输出含 inserted 字段
out_file="$(mktemp)"
CODEX_HOME="$h" CDT_STATE_DIR="$state" bash "$CHECK" --json >"$out_file" 2>/dev/null
assert_true "json mode emits inserted key" grep -q '"inserted"' "$out_file"
```

- [ ] **Step 2: 运行测试,确认失败**

Run: `bash ~/codex-disk-guard/tests/run_tests.sh`
Expected: `test_check.sh` 段 `FAIL`(脚本不存在)

- [ ] **Step 3: 实现 `bin/codex-disk-check`(被动模式;`--measure` 占位在 Task 5 补全)**

```bash
#!/usr/bin/env bash
# codex-disk-check — 监测 codex CLI 写盘是否复发。
#   默认: 被动采样(无需 sudo),写报告并按阈值判定 PASS/WARN。
#   --json: 机器可读单行输出。
#   --measure [secs]: 精确测速模式(sudo fs_usage),见 Task 5。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/../lib/common.sh" ]; then source "$HERE/../lib/common.sh";
elif [ -f "$HERE/lib/common.sh" ]; then source "$HERE/lib/common.sh";
else echo "common.sh not found" >&2; exit 1; fi

mode="passive"; want_json=0; measure_secs=60
while [ $# -gt 0 ]; do
  case "$1" in
    --json) want_json=1 ;;
    --measure) mode="measure"; [ -n "${2:-}" ] && case "$2" in ''|*[!0-9]*) ;; *) measure_secs="$2"; shift;; esac ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

state="$(cdt_state_dir)"; mkdir -p "$state"
report="$state/report.log"; last="$state/last-sample"
now="$(date +%s)"
wal="$(cdt_wal_size)"
wal_warn="${CDT_WAL_WARN_BYTES:-8388608}"
rate_warn="${CDT_LOGS_RATE_WARN_MB_DAY:-50}"

if [ "$mode" = "measure" ]; then cdt_measure "$measure_secs" "$want_json"; exit $?; fi

counter="$(cdt_insert_counter)"
residual="$(cdt_detect_residual)"

# 读取上次采样
prev_counter=""; prev_ts=""
if [ -f "$last" ]; then
  prev_counter="$(awk -F= '/^counter=/{print $2}' "$last")"
  prev_ts="$(awk -F= '/^ts=/{print $2}' "$last")"
fi

# 写新采样
printf 'ts=%s\ncounter=%s\n' "$now" "$counter" > "$last"

status="PASS"; line=""
if [ -z "$prev_counter" ] || [ -z "$prev_ts" ]; then
  line="$(date '+%F %T') baseline counter=${counter} wal=$(cdt_human_bytes "$wal")"
else
  inserted=$(( counter - prev_counter )); [ "$inserted" -lt 0 ] && inserted=0
  elapsed=$(( now - prev_ts )); [ "$elapsed" -le 0 ] && elapsed=1
  rpm="$(awk -v i="$inserted" -v e="$elapsed" 'BEGIN{printf "%.2f", i*60.0/e}')"
  # 用平均每行 estimated_bytes≈150 估算字节速率(粗略,仅用于阈值与趋势)
  bytes=$(( inserted * 150 ))
  mbday="$(cdt_mb_per_day "$bytes" "$elapsed")"
  cdt_over "$mbday" "$rate_warn" && status="WARN"
  cdt_over "$wal" "$wal_warn" && status="WARN"
  [ -n "$residual" ] && status="WARN"
  line="$(date '+%F %T') ${status} inserted=${inserted} rows_per_min=${rpm} est_mb_per_day=${mbday} wal=$(cdt_human_bytes "$wal")"
  [ -n "$residual" ] && line="${line} residual=YES"
fi

printf '%s\n' "$line" >> "$report"

if [ "$want_json" -eq 1 ]; then
  ins="${inserted:-0}"
  printf '{"status":"%s","inserted":%s,"counter":%s,"wal_bytes":%s}\n' \
    "${status}" "${ins}" "${counter}" "${wal}"
else
  printf '%s\n' "$line"
  [ -n "$residual" ] && { echo "  ⚠ 检测到残留:"; printf '%s\n' "$residual" | sed 's/^/    /'; }
fi
[ "$status" = "WARN" ] && exit 1 || exit 0
```

注:`cdt_measure` 函数在 Task 5 加入 `lib/common.sh`;本任务测试只覆盖被动路径,不触发 `--measure`。

Run: `chmod +x ~/codex-disk-guard/bin/codex-disk-check`

- [ ] **Step 4: 临时桩,让被动测试可独立通过**

在 `lib/common.sh` 末尾追加占位(Task 5 会替换为真实现):

```bash
cdt_measure() { echo "measure mode not yet implemented" >&2; return 3; }
```

- [ ] **Step 5: 运行测试,确认通过**

Run: `bash ~/codex-disk-guard/tests/run_tests.sh`
Expected: 全 `ok`,`0 failed`

- [ ] **Step 6: Commit**

```bash
cd ~/codex-disk-guard
git add -A && git commit -q -m "feat: add codex-disk-check passive monitoring with report + thresholds" && echo committed
```

---

## Task 5: 精确测速模式 `--measure`(fs_usage)

**Files:**
- Modify: `~/codex-disk-guard/lib/common.sh`(替换 `cdt_measure` 桩)
- Test: `~/codex-disk-guard/tests/test_measure.sh`

`cdt_measure` 解析 `fs_usage` 输出,统计窗口内对 `~/.codex` 下文件的 write 字节。live 抓取需 sudo+真实 codex 活动,无法在 CI 单测;因此**把"解析聚合"逻辑抽成可单测的纯函数 `cdt_sum_fsusage_bytes`**,用一段固定 fs_usage 样本测试它;`cdt_measure` 负责采集+调用解析。

- [ ] **Step 1: 写失败测试 `tests/test_measure.sh`**

```bash
# tests/test_measure.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/common.sh"

# 模拟 fs_usage 三行写操作(字段:... 字节数 ... 路径),分别 4096/8192/100 字节写到 .codex
sample="$(cat <<'EOF'
12:00:00  write    F=5  B=0x1000  /Users/x/.codex/logs_2.sqlite-wal  0.01 codex
12:00:01  pwrite   F=5  B=0x2000  /Users/x/.codex/logs_2.sqlite      0.01 codex
12:00:02  write    F=9  B=0x64    /Users/x/.codex/sessions/a.jsonl   0.01 codex
12:00:03  read     F=5  B=0x1000  /Users/x/.codex/logs_2.sqlite      0.01 codex
EOF
)"
# 期望:只统计 write/pwrite 的 B= 字节:0x1000+0x2000+0x64 = 4096+8192+100 = 12388
got="$(printf '%s\n' "$sample" | cdt_sum_fsusage_bytes "/Users/x/.codex")"
assert_eq "12388" "$got" "sum_fsusage_bytes counts only writes under target"
```

- [ ] **Step 2: 运行测试,确认失败**

Run: `bash ~/codex-disk-guard/tests/run_tests.sh`
Expected: `test_measure.sh` `FAIL`(`cdt_sum_fsusage_bytes: command not found`)

- [ ] **Step 3: 实现解析函数 + 替换 `cdt_measure` 桩**

把 `lib/common.sh` 末尾的桩:
```bash
cdt_measure() { echo "measure mode not yet implemented" >&2; return 3; }
```
替换为:
```bash
# 从 stdin 读 fs_usage 文本,累加 write/pwrite 操作中 B=0x.. 字节(仅限路径含 <target>)。
# 注意: macOS /usr/bin/awk(BWK)无 strtonum,故用 awk 仅抽取 0x 值、由 bash 算术求和。
cdt_sum_fsusage_bytes() { # <target_path_substring>
  local target="$1" total=0 v
  while IFS= read -r v; do
    [ -n "$v" ] && total=$(( total + v ))   # v 形如 0x1000,bash 算术原生识别 0x
  done < <(awk -v t="$target" '
    /(^| )(write|pwrite)( |$)/ && index($0,t) {
      for (i=1;i<=NF;i++) if ($i ~ /^B=0x/) { v=$i; sub(/^B=/,"",v); print v }
    }')
  printf '%d' "$total"
}

# 精确测速:用 fs_usage 抓 <secs> 秒,统计对 CODEX_HOME 的写字节,换算速率。
# 需要 sudo;无 sudo 或非交互时给出清晰提示。
cdt_measure() { # <secs> <want_json>
  local secs="${1:-60}" want_json="${2:-0}"
  local home; home="$(cdt_codex_home)"
  local tmp; tmp="$(mktemp)"
  echo "正在用 fs_usage 采样 ${secs}s(需 sudo)。请在此期间正常使用 codex 以测活跃写入…" >&2
  # -w 宽格式; -f filesystem 只看文件系统事件
  if ! sudo -v 2>/dev/null; then echo "需要 sudo 来运行 fs_usage" >&2; rm -f "$tmp"; return 3; fi
  sudo fs_usage -w -f filesystem 2>/dev/null > "$tmp" &
  local fpid=$!
  sleep "$secs"
  sudo kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
  local bytes; bytes="$(cdt_sum_fsusage_bytes "$home" < "$tmp")"
  rm -f "$tmp"
  local mbday; mbday="$(cdt_mb_per_day "$bytes" "$secs")"
  local bpd; bpd="$(awk -v by="$bytes" -v s="$secs" 'BEGIN{printf "%d", by*(86400.0/s)}')"
  local years; years="$(cdt_tbw_years "$bpd" "${CDT_TBW_TB:-150}")"
  if [ "$want_json" -eq 1 ]; then
    printf '{"window_s":%s,"write_bytes":%s,"mb_per_day_active":%s,"tbw_years_if_24x7":"%s"}\n' \
      "$secs" "$bytes" "$mbday" "$years"
  else
    printf '活跃期写入: %s / %ss = %s MB/天当量(若全天持续)\n' "$(cdt_human_bytes "$bytes")" "$secs" "$mbday"
    printf 'SSD 寿命(假设 %s TBW、该速率 24x7): 约 %s 年(仅供相对对比,实际只在活跃时写)\n' "${CDT_TBW_TB:-150}" "$years"
  fi
}
```

- [ ] **Step 4: 运行测试,确认通过**

Run: `bash ~/codex-disk-guard/tests/run_tests.sh`
Expected: 全 `ok`,`0 failed`

- [ ] **Step 5: 冒烟(手动,非自动):确认 --measure 参数被接受**

Run: `CODEX_HOME=$(mktemp -d) ~/codex-disk-guard/bin/codex-disk-check --measure 1` 然后立即 Ctrl-C 跳过 sudo(或输入密码采样 1s)
Expected: 打印"正在用 fs_usage 采样 1s…",不报参数错误

- [ ] **Step 6: Commit**

```bash
cd ~/codex-disk-guard
git add -A && git commit -q -m "feat: add --measure mode (fs_usage) with unit-tested parser" && echo committed
```

---

## Task 6: launchd 模板 + 一键安装/卸载

**Files:**
- Create: `~/codex-disk-guard/launchd/com.user.codex-disk-maintain.plist.template`
- Create: `~/codex-disk-guard/launchd/com.user.codex-disk-check.plist.template`
- Create: `~/codex-disk-guard/setup.sh`
- Create: `~/codex-disk-guard/uninstall.sh`
- Test: `~/codex-disk-guard/tests/test_setup.sh`

setup 把 `bin/*` + `lib/common.sh` 复制到 `~/.local/bin/`(脚本内 source 路径已兼容 `$HERE/lib/common.sh`),渲染 plist 到 `~/Library/LaunchAgents/` 并 `launchctl bootstrap`。为可测试,setup/uninstall 支持 `CDT_PREFIX`(默认 `~/.local/bin`)、`CDT_AGENTS_DIR`(默认 `~/Library/LaunchAgents`)、`CDT_NO_LAUNCHCTL=1`(测试时跳过真实 launchctl)。

- [ ] **Step 1: 写 maintain plist 模板**

`launchd/com.user.codex-disk-maintain.plist.template`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.user.codex-disk-maintain</string>
  <key>ProgramArguments</key>
  <array>
    <string>__PREFIX__/codex-disk-maintain</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>__STATE__/maintain.out.log</string>
  <key>StandardErrorPath</key><string>__STATE__/maintain.err.log</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
```

- [ ] **Step 2: 写 check plist 模板**

`launchd/com.user.codex-disk-check.plist.template`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.user.codex-disk-check</string>
  <key>ProgramArguments</key>
  <array>
    <string>__PREFIX__/codex-disk-check</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>5</integer></dict>
  <key>StandardOutPath</key><string>__STATE__/check.out.log</string>
  <key>StandardErrorPath</key><string>__STATE__/check.err.log</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
```

- [ ] **Step 3: 写失败测试 `tests/test_setup.sh`**

```bash
# tests/test_setup.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
prefix="$(mktemp -d)"; agents="$(mktemp -d)"; state="$(mktemp -d)"

env CDT_PREFIX="$prefix" CDT_AGENTS_DIR="$agents" CDT_STATE_DIR="$state" \
    CDT_NO_LAUNCHCTL=1 bash "$ROOT/setup.sh" >/dev/null 2>&1

assert_true "maintain installed"   test -x "$prefix/codex-disk-maintain"
assert_true "check installed"       test -x "$prefix/codex-disk-check"
assert_true "common.sh installed"   test -f "$prefix/lib/common.sh"
assert_true "uninstall installed"   test -x "$prefix/codex-disk-uninstall"
assert_true "maintain plist exists" test -f "$agents/com.user.codex-disk-maintain.plist"
assert_true "check plist exists"    test -f "$agents/com.user.codex-disk-check.plist"
assert_true "plist has rendered prefix" grep -q "$prefix/codex-disk-maintain" "$agents/com.user.codex-disk-maintain.plist"
assert_false "plist has no placeholder" grep -q "__PREFIX__" "$agents/com.user.codex-disk-maintain.plist"

# 安装的脚本能独立找到 lib(source 兼容性)
assert_true "installed check runs" bash -c "CODEX_HOME=$(mktemp -d) CDT_STATE_DIR=$(mktemp -d) '$prefix/codex-disk-check' >/dev/null 2>&1"

# 卸载清干净
env CDT_PREFIX="$prefix" CDT_AGENTS_DIR="$agents" CDT_STATE_DIR="$state" \
    CDT_NO_LAUNCHCTL=1 bash "$prefix/codex-disk-uninstall" >/dev/null 2>&1
assert_false "maintain removed" test -e "$prefix/codex-disk-maintain"
assert_false "check plist removed" test -e "$agents/com.user.codex-disk-check.plist"
```

- [ ] **Step 4: 运行测试,确认失败**

Run: `bash ~/codex-disk-guard/tests/run_tests.sh`
Expected: `test_setup.sh` `FAIL`(setup.sh 不存在)

- [ ] **Step 5: 实现 `setup.sh`**

```bash
#!/usr/bin/env bash
# setup.sh — 一键安装 codex 写盘工具:部署脚本/lib、渲染并加载 launchd 定时。
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${CDT_PREFIX:-$HOME/.local/bin}"
AGENTS="${CDT_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
STATE="${CDT_STATE_DIR:-$HOME/.local/state/codex-disk}"
mkdir -p "$PREFIX/lib" "$AGENTS" "$STATE"

# 1. 部署可执行 + lib
install -m 0755 "$HERE/bin/codex-disk-maintain" "$PREFIX/codex-disk-maintain"
install -m 0755 "$HERE/bin/codex-disk-check"    "$PREFIX/codex-disk-check"
install -m 0644 "$HERE/lib/common.sh"           "$PREFIX/lib/common.sh"
install -m 0755 "$HERE/uninstall.sh"            "$PREFIX/codex-disk-uninstall"

# 2. 渲染 plist(替换 __PREFIX__ / __STATE__)
render() { sed -e "s#__PREFIX__#$PREFIX#g" -e "s#__STATE__#$STATE#g" "$1" > "$2"; }
render "$HERE/launchd/com.user.codex-disk-maintain.plist.template" "$AGENTS/com.user.codex-disk-maintain.plist"
render "$HERE/launchd/com.user.codex-disk-check.plist.template"    "$AGENTS/com.user.codex-disk-check.plist"

# 3. 加载定时(测试可用 CDT_NO_LAUNCHCTL=1 跳过)
if [ "${CDT_NO_LAUNCHCTL:-0}" != "1" ]; then
  for lbl in codex-disk-maintain codex-disk-check; do
    launchctl bootout "gui/$(id -u)/com.user.$lbl" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENTS/com.user.$lbl.plist"
  done
fi

echo "已安装:"
echo "  $PREFIX/codex-disk-maintain"
echo "  $PREFIX/codex-disk-check"
echo "  $PREFIX/codex-disk-uninstall"
echo "  $AGENTS/com.user.codex-disk-maintain.plist (每天 03:00)"
echo "  $AGENTS/com.user.codex-disk-check.plist (每天 03:05)"
echo "随时手动查状态: codex-disk-check   |   精确测速: codex-disk-check --measure 60"
echo "卸载: codex-disk-uninstall"
```

Run: `chmod +x ~/codex-disk-guard/setup.sh`

- [ ] **Step 6: 实现 `uninstall.sh`**

```bash
#!/usr/bin/env bash
# uninstall.sh — 精确卸载:停定时、删脚本/lib/plist/报告目录。仅删自己装的东西。
set -u
PREFIX="${CDT_PREFIX:-$HOME/.local/bin}"
AGENTS="${CDT_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
STATE="${CDT_STATE_DIR:-$HOME/.local/state/codex-disk}"

if [ "${CDT_NO_LAUNCHCTL:-0}" != "1" ]; then
  for lbl in codex-disk-maintain codex-disk-check; do
    launchctl bootout "gui/$(id -u)/com.user.$lbl" 2>/dev/null || true
  done
fi

rm -f "$AGENTS/com.user.codex-disk-maintain.plist" "$AGENTS/com.user.codex-disk-check.plist"
rm -f "$PREFIX/codex-disk-maintain" "$PREFIX/codex-disk-check" "$PREFIX/lib/common.sh"
rmdir "$PREFIX/lib" 2>/dev/null || true
rm -rf "$STATE"
echo "已卸载脚本、定时与报告目录。"
echo "注意: config.toml / RUST_LOG / computer-use 等缓解类改动未还原(见 spec §6.2)。"
# 最后自删
rm -f "$PREFIX/codex-disk-uninstall"
```

Run: `chmod +x ~/codex-disk-guard/uninstall.sh`

- [ ] **Step 7: 运行测试,确认通过**

Run: `bash ~/codex-disk-guard/tests/run_tests.sh`
Expected: 全 `ok`,`0 failed`

- [ ] **Step 8: Commit**

```bash
cd ~/codex-disk-guard
git add -A && git commit -q -m "feat: add launchd templates + one-shot setup/uninstall (tested)" && echo committed
```

---

## Task 7: 一次性安全清理脚本 `cleanup-once.sh`

**Files:**
- Create: `~/codex-disk-guard/cleanup-once.sh`

逐项列出可删项、显示体积、**默认 dry-run**,加 `--apply` 才真删;每项前打印,绝不碰 `sessions/`、`memories/`。`computer-use/` 删除时联动提醒移除 `config.toml` 的 `notify`(实际改 config 在 Task 8)。

- [ ] **Step 1: 实现 `cleanup-once.sh`**

```bash
#!/usr/bin/env bash
# cleanup-once.sh — 一次性清理明确的临时/缓存/备份。默认 dry-run,--apply 才执行。
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
  echo "这是预览。确认无误后执行: bash cleanup-once.sh --apply"
else
  echo "⚠ 若已删除 computer-use,请接着执行 Task 8 移除 config.toml 的 notify 行,避免每轮 turn-ended 报错。"
fi
```

Run: `chmod +x ~/codex-disk-guard/cleanup-once.sh`

- [ ] **Step 2: 冒烟:dry-run 列出清单**

Run: `bash ~/codex-disk-guard/cleanup-once.sh`
Expected: 列出各项体积与"保护"行;末尾提示 `--apply`;**不删除任何文件**

- [ ] **Step 3: Commit**

```bash
cd ~/codex-disk-guard
git add -A && git commit -q -m "feat: add cleanup-once.sh (dry-run default, protects sessions/memories)" && echo committed
```

---

## Task 8: config.toml 缓解 + RUST_LOG + README

**Files:**
- Modify: `~/.codex/config.toml`(备份后移除 `notify` 行)
- Modify: `~/.zshenv`(设 `RUST_LOG=error`)
- Create: `~/codex-disk-guard/README.md`

- [ ] **Step 1: 备份 config.toml**

Run:
```bash
cp -p ~/.codex/config.toml ~/.codex/config.toml.cdt-backup && echo "backed up"
```
Expected: `backed up`;`~/.codex/config.toml.cdt-backup` 存在

- [ ] **Step 2: 移除 `notify` 行(与 Task 7 删 computer-use 配套)**

用编辑器删除 `~/.codex/config.toml` 中以 `notify = [` 开头的整行(指向 `SkyComputerUseClient` 的那行)。

- [ ] **Step 3: 验证 config 仍可被 codex 解析**

Run: `codex doctor 2>&1 | tail -20`
Expected: 无 `strict-config` 类报错;若报错,从 `config.toml.cdt-backup` 恢复并停下排查

- [ ] **Step 4: 设 RUST_LOG=error(防御式)**

向 `~/.zshenv` 追加(不存在则创建):
```bash
# codex 写盘治理: 压低 stderr/file tracing(对 sqlite sink 无效但无害)
export RUST_LOG="${RUST_LOG:-error}"
```
说明:用 `${RUST_LOG:-error}` 避免覆盖其它来源已设的值;若希望强制为 error,改成 `export RUST_LOG=error`。

- [ ] **Step 5: 验证新 shell 生效**

Run: `zsh -c 'source ~/.zshenv; echo RUST_LOG=$RUST_LOG'`
Expected: 打印 `RUST_LOG=error`(或既有来源的值)

- [ ] **Step 6: 写 `README.md`(用法 + 回滚速查)**

```markdown
# codex-disk-guard

治理 codex CLI 频繁写盘(GitHub openai/codex #29532)。详见设计文档:
docs/DESIGN.md

## 安装
    bash ~/codex-disk-guard/setup.sh        # 部署脚本 + 每日定时(maintain 03:00 / check 03:05)

## 日常使用
    codex-disk-check              # 一键查写盘状态(无需 sudo),结果追加到 ~/.local/state/codex-disk/report.log
    codex-disk-check --measure 60 # 精确测活跃写速(需 sudo,跑 60s,期间正常用 codex)
    codex-disk-maintain           # 手动维护(checkpoint/vacuum/清 3 天前日志)

## 一次性清理(可选)
    bash ~/codex-disk-guard/cleanup-once.sh           # 预览
    bash ~/codex-disk-guard/cleanup-once.sh --apply   # 执行

## 卸载
    codex-disk-uninstall          # 删脚本/定时/报告(config/RUST_LOG 改动需手动还原,见 spec §6.2)
    cp ~/.codex/config.toml.cdt-backup ~/.codex/config.toml   # 还原 config(恢复 notify)

## 阈值(环境变量覆盖)
    CDT_RETENTION_DAYS=3  CDT_WAL_WARN_BYTES=8388608
    CDT_LOGS_RATE_WARN_MB_DAY=50  CDT_TBW_TB=150
```

- [ ] **Step 7: Commit**

```bash
cd ~/codex-disk-guard
git add -A && git commit -q -m "docs: add README; record config/RUST_LOG mitigation steps" && echo committed
```

---

## Task 9: 端到端 Runbook —— 基线测速 → 应用 → 复测 → 寿命报告

本任务把全部交付物串成 spec §5 的验收闭环。**按顺序手动执行并记录**;产出一份对比报告。

**Files:**
- Create: `~/.local/state/codex-disk/before-after-report.md`(执行产物)

- [ ] **Step 1: 安装工具**

Run: `bash ~/codex-disk-guard/setup.sh`
Expected: 打印已安装清单;`launchctl list | grep codex` 显示两个 `com.user.codex-disk-*`(若未跳过 launchctl)

- [ ] **Step 2: 改前基线测速(应用缓解之前的真实写速)**

> 注意:此步要在 **Task 7/8 的清理与 config 改动之前** 跑,才是"改前"。若已改,从 git/备份回退后再测,或接受"改后值 + issue 基线"对比。
Run(开另一个终端,运行 60s,期间用 codex 做一次典型任务):
```bash
codex-disk-check --measure 60 --json | tee /tmp/cdt-before.json
```
记录 `write_bytes`、`mb_per_day_active`、`tbw_years_if_24x7`。

- [ ] **Step 3: 应用缓解**

依次执行(若尚未执行):
```bash
bash ~/codex-disk-guard/cleanup-once.sh          # 预览
bash ~/codex-disk-guard/cleanup-once.sh --apply  # 确认后执行(删 computer-use 等)
# 然后按 Task 8 移除 notify、设 RUST_LOG、codex doctor 验证
codex-disk-maintain                              # 立即压实日志库
```

- [ ] **Step 4: 改后复测(同样 60s、同样的典型任务)**

Run:
```bash
codex-disk-check --measure 60 --json | tee /tmp/cdt-after.json
```

- [ ] **Step 5: 生效性验证(spec §5.1)**

Run:
```bash
echo "RUST_LOG=$RUST_LOG"
launchctl list | grep -i codex || echo "(无定时? 检查 setup)"
ps aux | grep -iE 'codex|app-server|SkyComputerUse' | grep -v grep || echo "无常驻进程 ✓"
ls -lh ~/.codex/logs_2.sqlite ~/.codex/logs_2.sqlite-wal 2>/dev/null
test -f ~/.codex/config.toml.cdt-backup && echo "config 备份存在 ✓"
ls ~/.codex/sessions >/dev/null && echo "sessions 完好 ✓"
```
Expected:无常驻进程;config 备份在;sessions 目录完好;WAL 不超过阈值。

- [ ] **Step 6: 生成对比报告 `before-after-report.md`**

把 before/after 两个 json 与寿命换算写入报告,例如:
```bash
{
  echo "# Codex CLI 写盘 改前/改后对比 ($(date '+%F'))"
  echo; echo "## 改前"; cat /tmp/cdt-before.json
  echo; echo "## 改后"; cat /tmp/cdt-after.json
  echo; echo "## 结论"
  echo "- 空闲态: 不装桌面版、无常驻 daemon -> 0 写入"
  echo "- 活跃态: 见上 mb_per_day_active 字段对比"
  echo "- SSD(默认 ${CDT_TBW_TB:-150} TBW)寿命换算见 tbw_years_if_24x7(保守上界,实际仅活跃时写)"
  echo "- 已知限制: logs_2.sqlite TRACE sink 活跃期写入不可经配置消除(spec §2.3)"
} > ~/.local/state/codex-disk/before-after-report.md
cat ~/.local/state/codex-disk/before-after-report.md
```
Expected:报告生成,含改前/改后数值与结论。

- [ ] **Step 7: 最终确认 check 报告管线工作**

Run: `codex-disk-check && echo "exit=$?"; tail -3 ~/.local/state/codex-disk/report.log`
Expected:打印一行 PASS/WARN 采样,`report.log` 有记录。

---

## 完成标准(对照 spec)
- [ ] 组成 1:`cdt_detect_residual` 集成在 check;§5.1 验证无常驻进程/自启。
- [ ] 组成 2:`config.toml` 移除 notify(已备份)、`RUST_LOG=error` 生效、`codex doctor` 通过。
- [ ] 组成 3:`codex-disk-maintain` + launchd 每日 03:00,prune/checkpoint/vacuum,锁安全,测试通过。
- [ ] 组成 4:`cleanup-once.sh` dry-run 默认、保护 sessions/memories、computer-use 与 notify 联动。
- [ ] 组成 5:`codex-disk-check` 被动采样(sqlite_sequence 增量)+ 阈值告警 + 每日 03:05,测试通过。
- [ ] 测速:`--measure`(fs_usage,解析逻辑单测)+ §5.2/§5.3 改前/改后报告与 TBW 寿命换算。
- [ ] 一键:`setup.sh` 安装+排程;`codex-disk-check` 一键查;`codex-disk-uninstall` 一键卸载(测试覆盖)。
```
