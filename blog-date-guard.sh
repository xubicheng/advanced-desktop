#!/usr/bin/env bash
# ============================================================================
# blog-date-guard.sh — 旷野新诗博客「>80字改动自动刷新日期」守卫
# 原理: 不侵入原代码。通过 inotifywait 监控博客存储文件变更, 每次保存
#       与上一次缓存做 diff, 净增(新增+修改)>80 字就把该篇的日期字段
#       更新为当前时间。并发写入时自动排队。
#
# 支持的存储后端 (按参数 --backend 指定):
#   mysql      → 直接 SQL UPDATE wp_posts / contents (按你表名)
#   sqlite     → UPDATE posts SET date=...
#   json       → watch 存储 JSON 文件, 原地改 date 字段
#   markdown   → watch Markdown front-matter, 改 date: 行
#
# 用法:
#   # 1. 先 dry-run 看效果 (不会真改):
#   sudo bash blog-date-guard.sh --backend json --path /path/to/posts.json --dry-run
#
#   # 2. 实际跑 (日志写 /var/log/blog-date-guard/):
#   sudo bash blog-date-guard.sh --backend json --path /path/to/posts.json
#
#   # 3. 装成 systemd 开机自启:
#   sudo bash blog-date-guard.sh --install --backend json --path /path/to/posts.json
#
# 输出只做: 修改日期字段, 其它内容一律不动
# ============================================================================
set -euo pipefail

THRESHOLD=80                    # 净新增+修改 字数阈值
STATE_DIR="/var/lib/blog-date-guard"
LOG_DIR="/var/log/blog-date-guard"
mkdir -p "$STATE_DIR" "$LOG_DIR"

log()  { echo "[$(date '+%F %T')] [+] $*"; }
warn() { echo "[$(date '+%F %T')] [!] $*" >&2; }
err()  { echo "[$(date '+%F %T')] [x] $*" >&2; }

# ---------- 参数解析 ----------
BACKEND=""
WATCH_PATH=""
DRY_RUN=0
INSTALL=0
case "${1:-}" in
  --backend)  BACKEND="$2"; shift 2 ;;
  --path)     WATCH_PATH="$2"; shift 2 ;;
  --threshold) THRESHOLD="$2"; shift 2 ;;
  --dry-run)  DRY_RUN=1; shift ;;
  --install)  INSTALL=1; shift ;;
  -h|--help)
    sed -n '2,20p' "$0"; exit 0 ;;
esac
[ -z "$BACKEND" ]  && { err "请指定 --backend (mysql|sqlite|json|markdown)"; exit 1; }
[ -z "$WATCH_PATH" ] && { err "请指定 --path (博客数据文件或目录)"; exit 1; }

# ---------- 工具 ----------
need_cmd() { command -v "$1" >/dev/null 2>&1 || { warn "missing: $1, 尝试安装..."; silent_install "$1"; } }
silent_install() {
  local p="$1"
  if command -v apt-get >/dev/null; then apt-get install -y "$p" >/dev/null 2>&1 || true
  elif command -v yum >/dev/null;   then yum   install -y "$p" >/dev/null 2>&1 || true
  fi
}

# 计算两个文本之间的净新增+修改字数 (中文算1字符, 英文按单词算1)
# 用 diff --unified=0 统计 + 行数 (新增 + 修改都算 +)
compute_delta_chars() {
  local old="$1" new="$2"
  [ -z "$old" ] && old=""
  [ -z "$new" ] && new=""
  local added=0
  # 只算 + 行 (新增+修改的新版本), 忽略 --- 分隔符
  while IFS= read -r line; do
    # + 开头, 但不是 +++ header
    if [[ "$line" == +* && "$line" != "+++"* ]]; then
      # 该中文字符数 + 英文单词数
      local zh
      zh=$(echo "$line" | tr -cd '\344-\377' | wc -c)
      zh=$(( zh / 3 ))                                    # UTF-8 中文 3 字节
      local en
      en=$(echo "$line" | sed 's/[^a-zA-Z0-9 ]/g' | wc -w)
      # 中文每个字算1, 英文每个词算1
      added=$(( added + zh + en ))
    fi
  done < <(diff --unified=0 <(echo "$old") <(echo "$new") 2>/dev/null || true)
  echo "$added"
}

now_iso() { date '+%Y-%m-%d %H:%M:%S'; }
now_ymd() { date '+%Y-%m-%d'; }

# ============================================================================
# BACKEND: JSON (一个文件里存所有博文)
# ============================================================================
handle_json() {
  local file="$1"
  local snap="${STATE_DIR}/$(echo "$file" | md5sum | cut -c1-12).snap"
  local new_content old_content
  new_content=$(cat "$file")
  old_content=$(cat "$snap" 2>/dev/null || true)

  if [ -z "$old_content" ]; then
    # 首次快照
    echo "$new_content" > "$snap"
    log "[json] 首次快照 $(basename "$file")"
    return 0
  fi

  # 如果是单文件 JSON 数组, 用 jq 找出被改过的 item
  # 简单策略: 整个文件的字节约束在后端处理, 这里先对整个文件做快照 diff
  local delta
  delta=$(compute_delta_chars "$old_content" "$new_content")
  log "[json] $(basename "$file") 净新增+修改 ≈ ${delta} 字 (阈值 ${THRESHOLD})"

  if [ "$delta" -gt "$THRESHOLD" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "[dry-run] 应触发: >80 字改动, 日期应更新为 $(now_iso)"
    else
      # JSON 格式假设: 有 date 字段或 created / updated
      # 原地替换所有 "date": "..." 或 "created": "..." (只改时间戳格式的)
      local new_date
      new_date=$(now_iso)
      # 用 python 做安全替换 (sed 容易破坏 JSON 转义)
      if command -v python3 >/dev/null 2>&1; then
        python3 - "$file" "$new_date" <<'PY'
import json, sys, re, os
path, new_date = sys.argv[1], sys.argv[2]
with open(path,'r',encoding='utf-8') as f:
    data = json.load(f)

updated = 0
def walk(obj):
    global updated
    if isinstance(obj, dict):
        for k in obj:
            if k in ('date','created','publish_time','published_at') and \
               isinstance(obj[k], str) and re.match(r'\d{4}[-/]\d{2}', obj[k]):
                obj[k] = new_date; updated += 1
            else: walk(obj[k])
    elif isinstance(obj, list):
        for it in obj: walk(it)
walk(data)
if updated:
    with open(path,'w',encoding='utf-8') as f: json.dump(data,f,ensure_ascii=False,indent=2)
    print(f"[json] 已更新 {updated} 处日期 → {new_date}")

PY
      else
        # fallback: sed 粗暴替换所有 ISO 日期模式 (有风险)
        sed -i "s/\"date\": *\"[0-9T:\ -]*\"/\"date\": \"$new_date\"/g" "$file"
      fi
      # 更新快照 (用新内容, 下次以它为基准)
      echo "$(cat "$file")" > "$snap"
      log "[json] 日期已刷新"
    fi
  else
    # 低于阈值: 刷新快照但不动日期, 让下一次以当前内容为基准
    echo "$new_content" > "$snap"
    log "[json] ≤${THRESHOLD}字, 日期保持不变"
  fi
}

# ============================================================================
# BACKEND: Markdown (每篇一个 .md 文件, front-matter 有 date: YYYY-MM-DD)
# ============================================================================
handle_markdown() {
  local file="$1"
  local snap="${STATE_DIR}/$(echo "$file" | md5sum | cut -c1-12).snap"
  local new_content old_content
  new_content=$(cat "$file")
  old_content=$(cat "$snap" 2>/dev/null || true)

  if [ -z "$old_content" ]; then
    echo "$new_content" > "$snap"
    log "[md] 首次快照 $(basename "$file")"
    return 0
  fi

  local delta
  delta=$(compute_delta_chars "$old_content" "$new_content")
  log "[md] $(basename "$file") 净新增+修改 ≈ ${delta} 字 (阈值 ${THRESHOLD})"

  if [ "$delta" -gt "$THRESHOLD" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "[dry-run] $(basename "$file") >${THRESHOLD}字改动, 应刷新日期"
    else
      local new_ymd
      new_ymd=$(now_ymd)
      local new_iso
      new_iso=$(now_iso)
      # 改 front-matter 里的 date: 行 (支持 YAML 和 / 或 - 格式)
      sed -i -E "s/^date:[[:space:]]*[0-9T:\ -]+$/date: $new_ymd/" "$file"
      # 再尝试 datetime / publish_date
      sed -i -E "s/^(datetime|publish_date|published):[[:space:]]*.*$/\1: $new_iso/" "$file" || true
      echo "$(cat "$file")" > "$snap"
      log "[md] $(basename "$file") 日期 → $new_ymd"
    fi
  else
    echo "$new_content" > "$snap"
    log "[md] ≤${THRESHOLD}字, 日期保持"
  fi
}

# ============================================================================
# BACKEND: MySQL (需要知道表名和库名, 首次跑 dry-run 给选择菜单)
# ============================================================================
handle_mysql() {
  local host="${DB_HOST:-localhost}"
  local user="${DB_USER:-root}"
  local pass="${DB_PASS:-}"
  local db="${DB_NAME:-}"
  local table="${DB_TABLE:-}"
  local id_col="${DB_ID_COL:-id}"
  local content_col="${DB_CONTENT_COL:-content}"
  local date_col="${DB_DATE_COL:-date}"

  [ -z "$db" ]    && { err "请设置 DB_NAME (库名)"; return 1; }
  [ -z "$table" ] && { err "请设置 DB_TABLE (表名)"; return 1; }

  local conn_args=( -h "$host" -u "$user" )
  [ -n "$pass" ] && conn_args+=( -p"$pass" )

  # 拉取所有博文
  local query
  query="SELECT $id_col, $date_col, LEFT($content_col, 40000) AS _cnt FROM $db.$table;"
  local rows
  rows=$(mysql "${conn_args[@]}" -N -B -e "$query" 2>/dev/null) || {
    err "MySQL 查询失败, 检查 DB_HOST/DB_USER/DB_PASS/DB_NAME/DB_TABLE"
    return 1
  }

  local snap="${STATE_DIR}/mysql.snap"
  # 新快照
  local new_snap=""
  while IFS=$'\t' read -r id dte cnt; do
    local old_cnt=""
    old_cnt=$(grep "^$id|" "$snap" 2>/dev/null | cut -d'|' -f2 || true)
    new_snap+="$id|$cnt"$'\n'

    local delta
    delta=$(compute_delta_chars "$old_cnt" "$cnt")
    if [ "$delta" -gt "$THRESHOLD" ]; then
      log "[mysql] id=$id ≈${delta}字 >${THRESHOLD} 刷新 $date_col → $(now_iso)"
      if [ "$DRY_RUN" -eq 1 ]; then
        warn "[dry-run] UPDATE $db.$table SET $date_col='$(now_iso)' WHERE $id_col=$id;"
      else
        mysql "${conn_args[@]}" -e \
          "UPDATE $db.$table SET $date_col='$(now_iso)' WHERE $id_col=$id;" 2>/dev/null
      fi
    fi
  done <<< "$rows"
  echo "$new_snap" > "$snap"
}

# ============================================================================
# BACKEND: SQLite
# ============================================================================
handle_sqlite() {
  local dbfile="$WATCH_PATH"
  local table="${DB_TABLE:-posts}"
  local id_col="${DB_ID_COL:-id}"
  local content_col="${DB_CONTENT_COL:-content}"
  local date_col="${DB_DATE_COL:-date}"

  local snap="${STATE_DIR}/$(echo "$dbfile$table" | md5sum | cut -c1-12).snap"
  local rows
  rows=$(sqlite3 "$dbfile" "SELECT $id_col, $date_col, $content_col FROM $table;" 2>/dev/null) || {
    err "SQLite 查询失败, 检查 --path 指向正确 db 文件"; return 1; }

  local new_snap=""
  while IFS='|' read -r id dte cnt; do
    local old_cnt
    old_cnt=$(grep "^$id|" "$snap" 2>/dev/null | cut -d'|' -f2 || true)
    new_snap+="$id|$cnt"$'\n'

    local delta
    delta=$(compute_delta_chars "$old_cnt" "$cnt")
    if [ "$delta" -gt "$THRESHOLD" ]; then
      log "[sqlite] id=$id ≈${delta}字, 刷新 $date_col → $(now_iso)"
      if [ "$DRY_RUN" -eq 1 ]; then
        warn "[dry-run] UPDATE $table SET $date_col='$(now_iso)' WHERE $id_col=$id;"
      else
        sqlite3 "$dbfile" "UPDATE $table SET $date_col='$(now_iso)' WHERE $id_col=$id;"
      fi
    fi
  done <<< "$rows"
  echo "$new_snap" > "$snap"
}

# ============================================================================
# 主循环
# ============================================================================
run_poll_json()  { while :; do for f in $(find "$WATCH_PATH" -name "*.json" -type f); do handle_json   "$f"; done; sleep 3; done; }
run_poll_md()    { while :; do for f in $(find "$WATCH_PATH" -name "*.md"   -type f); do handle_markdown "$f"; done; sleep 3; done; }
run_poll_mysql() { while :; do handle_mysql;  sleep 10; done; }
run_poll_sqlite(){ while :; do handle_sqlite; sleep 10; done; }
run_ino_json()   { inotifywait -m -r -e close_write --format '%w%f' "$WATCH_PATH" 2>/dev/null \
                    | while IFS= read -r f; do case "$f" in *.json) handle_json "$f";; esac; done; }
run_ino_md()     { inotifywait -m -r -e close_write --format '%w%f' "$WATCH_PATH" 2>/dev/null \
                    | while IFS= read -r f; do case "$f" in *.md)   handle_markdown "$f";; esac; done; }

run_watch() {
  local HAVE_INO=0
  command -v inotifywait >/dev/null 2>&1 && HAVE_INO=1

  log "开始 watch: backend=$BACKEND  path=$WATCH_PATH  阈值=${THRESHOLD}字  dry-run=$DRY_RUN"

  case "$BACKEND" in
    json)
      if [ -d "$WATCH_PATH" ]; then
        if [ "$HAVE_INO" -eq 1 ]; then run_ino_json; else run_poll_json; fi
      else
        handle_json "$WATCH_PATH"; run_poll_json
      fi
      ;;
    markdown)
      if [ -d "$WATCH_PATH" ]; then
        if [ "$HAVE_INO" -eq 1 ]; then run_ino_md; else run_poll_md; fi
      else
        handle_markdown "$WATCH_PATH"; run_poll_md
      fi
      ;;
    mysql)   run_poll_mysql ;;
    sqlite)  run_poll_sqlite ;;
    *)       err "unknown backend: $BACKEND"; exit 1 ;;
  esac
}

# ============================================================================
# --install 装成 systemd 服务
# ============================================================================
install_systemd() {
  need_root() { [ "$(id -u)" -eq 0 ] || { err "need sudo"; exit 1; }; }
  need_root
  local svc="/etc/systemd/system/blog-date-guard.service"
  cat > "$svc" <<EOF
[Unit]
Description=Blog Date Guard (>${THRESHOLD}字改动刷新日期)
After=network.target

[Service]
Type=simple
ExecStart=$(command -v bash) $0 --backend $BACKEND --path $WATCH_PATH $([ "$DRY_RUN" -eq 1 ] && echo --dry-run)
Restart=on-failure
RestartSec=5
StandardOutput=append:$LOG_DIR/service.log
StandardError=append:$LOG_DIR/service.err

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable blog-date-guard
  systemctl start blog-date-guard
  log "✅ 已装 systemd 服务"
  log "   状态: systemctl status blog-date-guard"
  log "   日志: tail -f $LOG_DIR/service.log"
}

if [ "$INSTALL" -eq 1 ]; then install_systemd; exit 0; fi
run_watch
