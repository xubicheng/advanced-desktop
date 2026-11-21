#!/usr/bin/env bash
# ============================================================================
# 腾讯云 CVM 磁盘满涨处置工具链
#   9 个子命令: meta / audit / locate / emergency / migrate / harden /
#             expand / verify / report
#   设计要点:
#     1) 幂等治理：所有动作写入 STATE_FILE，已 in-progress / recovered
#        的动作会被自动跳过
#     2) 风险分级：绿（自动）/ 黄（提示）/ 红（必须 --force 才执行）
#        红色动作显式列出 + 二次确认，绝不越权
#     3) 腾讯云特化：stargate agent 自检 / tccli cbs ResizeDisk /
#        CLS 日志 topic 推送 / 元数据服务取 instance-id & region
#     4) 分层拆解：挂载点 -> 大目录 -> 子目录 -> 文件类型 逐层收敛
#        避免一次性全盘递归卡死
#     5) 可重试工具链：lsof / tccli 未装自动安装；find/du 分拆小粒度
#     6) Forwarding error 根治：所有 curl 访问元数据/外网 API 都强制
#        unset proxy + --noproxy '*'
# ============================================================================

set -euo pipefail

# ---------- 常量 ----------
VERSION="2.1.0"
STATE_FILE="/var/lib/tencent-cvm-disk-tool/state.json"
LOG_DIR="/var/log/tencent-cvm-disk-tool"
THRESHOLD_PCT="${THRESHOLD_PCT:-80}"            # 告警阈值 %

# ---------- 颜色 ----------
C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YLW='\033[1;33m'
C_BLU='\033[0;34m'; C_BLD='\033[1m'; C_NC='\033[0m'
log()  { printf "${C_GRN}[+]${C_NC} %s\n" "$*"; }
warn() { printf "${C_YLW}[!]${C_NC} %s\n" "$*" >&2; }
err()  { printf "${C_RED}[x]${C_NC} %s\n" "$*" >&2; }
info() { printf "${C_BLU}[i]${C_NC} %s\n" "$*"; }
hdr()  { printf "\n${C_BLD}===== %s =====${C_NC}\n" "$*"; }

# ---------- 基础守卫 ----------
need_root() { [ "$(id -u)" -eq 0 ] || { err "need root"; exit 1; }; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || { err "missing: $1"; exit 1; }; }
silent_install() {
  local pkg="$1"
  if command -v apt-get >/dev/null; then apt-get install -y "$pkg" >/dev/null 2>&1 || true
  elif command -v yum   >/dev/null; then yum   install -y "$pkg" >/dev/null 2>&1 || true
  fi
}

# ============================================================================
# 状态机：统一状态解析 + 幂等判定
#   状态枚举（冻结）:
#     action: in-progress / recovered / failed / skipped
#     scenario: audit / emergency / migrate / harden / expand
#     ts / note / result
# ============================================================================
state_dir_init() { mkdir -p "$(dirname "$STATE_FILE")" "$LOG_DIR"; }

state_get() {
  # state_get <scenario>   返回该场景最新的 action 值；无则返回空
  local scenario="$1"
  [ ! -f "$STATE_FILE" ] && { echo ""; return 0; }
  if command -v jq >/dev/null; then
    jq -r --arg s "$scenario" '[.[] | select(.scenario==$s)][-1].action // ""' "$STATE_FILE"
  else
    # 无 jq：grep 匹配最后一次出现
    grep -oE '"scenario":"'"$scenario"'".*?"action":"[^"]*"' "$STATE_FILE" 2>/dev/null \
      | tail -1 | grep -oE '"action":"[^"]*"' | cut -d'"' -f4
  fi
}

state_set() {
  # state_set <scenario> <action> [note] [result_json]
  local scenario="$1" action="$2" note="${3:-}" result="${4:-}"
  state_dir_init
  local entry
  entry=$(printf '{"scenario":"%s","action":"%s","ts":"%s","note":"%s","result":%s}' \
    "$scenario" "$action" "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    "$(printf '%s' "$note" | sed 's/"/\\"/g')" "${result:-null}")
  if command -v jq >/dev/null; then
    local tmp
    tmp=$(mktemp)
    if [ -f "$STATE_FILE" ]; then
      jq --argjson e "$entry" '. + [$e]' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    else
      printf '[%s]\n' "$entry" > "$STATE_FILE"
    fi
  else
    # 无 jq：维护一个合法 JSON 数组文件
    if [ ! -f "$STATE_FILE" ]; then
      printf '[%s]\n' "$entry" > "$STATE_FILE"
    else
      # 去掉尾部 ]，插入 entry，补回 ]
      local tmp
      tmp=$(mktemp)
      sed '$ s/],*$/,' "$STATE_FILE" > "$tmp"
      printf '%s\n]\n' "$entry" >> "$tmp"
      mv "$tmp" "$STATE_FILE"
    fi
  fi
}

# ============================================================================
# 元数据服务：多端点回退 + 强制关闭代理 + IMDSv2 支持
#   端点按可用性概率排序:
#     1) http://metadata.tencentyun.com
#     2) http://metadata.instance.tencentyun.com
#     3) http://169.254.0.23           (IP 直连，VPC 内必达)
#     4) http://[fd00:ec2::23]         (IPv6)
#   curl 强制 unset proxy + --noproxy '*'，根治 Forwarding error
# ============================================================================
__MD_URL=""           # 选中的可用 base url
__MD_IMDSV2=0         # 是否启用 IMDSv2 token
__MD_TOKEN=""         # IMDSv2 token

__md_fetch() {
  # __md_fetch <path>   静默取值，失败返回空串，零噪音
  local path="$1"
  # 用 bash 数组安全拼参数（兼容 bash/zsh，避免 token 里有空格被拆）
  local -a curl_args=( -sS --max-time 2 --noproxy '*' )
  if [ "$__MD_IMDSV2" = "1" ] && [ -n "$__MD_TOKEN" ]; then
    curl_args+=( -H "X-metadata-token:${__MD_TOKEN}" )
  fi
  curl_args+=( "${__MD_URL}${path}" )
  # 关闭代理环境变量调用 curl
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY
  curl "${curl_args[@]}" 2>/dev/null || true
}

__md_probe() {
  # __md_probe <url>   探测这个 base 是否可用，打印可用标识，失败返回 1
  local url="$1"
  # 先 IMDSv1（直接 GET /version）
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY
  if curl -sS --max-time 2 --noproxy '*' -o /dev/null "${url}/version" 2>/dev/null; then
    echo "$url"; return 0
  fi
  # IMDSv2: PUT /latest/api/token 拿 TTL 21600s token
  local tok
  tok=$(curl -sS --max-time 2 --noproxy '*' -X PUT \
         -H 'X-metadata-token-ttl-seconds: 21600' \
         "${url}/latest/api/token" 2>/dev/null || true)
  if [ -n "$tok" ]; then
    if curl -sS --max-time 2 --noproxy '*' \
         -H "X-metadata-token:${tok}" -o /dev/null "${url}/version" 2>/dev/null; then
      # 特殊分隔符避免 URL / IPv6 / token 含 __ 冲突
      printf '__IMDSV2__%s__TOK__%s\n' "$url" "$tok"
      return 0
    fi
  fi
  return 1
}

__md_init() {
  # 找一个可用的元数据端点
  local endpoints=(
    "http://metadata.tencentyun.com"
    "http://metadata.instance.tencentyun.com"
    "http://169.254.0.23"
    "http://[fd00:ec2::23]"
  )
  if [ -n "${TENCENT_META_URL:-}" ]; then
    endpoints=("$TENCENT_META_URL" "${endpoints[@]}")
  fi
  for ep in "${endpoints[@]}"; do
    local probe
    probe=$(__md_probe "$ep") || continue
    case "$probe" in
      __IMDSV2__*)
        __MD_IMDSV2=1
        __MD_URL="${probe#__IMDSV2__}"
        __MD_URL="${__MD_URL%__TOK__*}"
        __MD_TOKEN="${probe##*__TOK__}"
        ;;
      *)
        __MD_URL="$probe"
        __MD_IMDSV2=0
        __MD_TOKEN=""
        ;;
    esac
    return 0
  done
  return 1
}

# ============================================================================
# 通用 "安全 curl 到外域" —— 关所有代理 + 静默
#   用法: _safe_curl "https://..."
# ============================================================================
_safe_curl() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY
  curl -sS --max-time 5 --connect-timeout 3 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo "000"
}

_safe_curl_body() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY
  curl -sS --max-time 5 --connect-timeout 3 "$@" 2>/dev/null || true
}

# ============================================================================
# cmd_meta —— 腾讯云元数据 + stargate agent 自检 + CBS 挂载
# ============================================================================
cmd_meta() {
  hdr "腾讯云 CVM 元数据"

  if __md_init; then
    local imds_note=""
    [ "$__MD_IMDSV2" = "1" ] && imds_note="（IMDSv2 token 模式）"
    info "元数据端点: ${__MD_URL}${imds_note}"
    echo "instance-id    : $(__md_fetch /meta-data/instance-id)"
    echo "region / zone  : $(__md_fetch /meta-data/placement/region) / $(__md_fetch /meta-data/placement/zone)"
    echo "hostname       : $(__md_fetch /meta-data/hostname)"
    echo "local-ipv4     : $(__md_fetch /meta-data/local-ipv4)"
    echo "public-ipv4    : $(__md_fetch /meta-data/public-ipv4)"
    echo "instance-type  : $(__md_fetch /meta-data/instance-type)"
    echo "charge-type    : $(__md_fetch /meta-data/instance/instance-charge-type || echo N/A)"
  else
    warn "元数据服务不可达（不在腾讯云内网 / 非 CVM / DNS 不通）"
    info "手动指定: TENCENT_META_URL=http://169.254.0.23"
    info "诊断: ip route get 169.254.0.23"
  fi

  echo; hdr "stargate / cloud-monitor agent 状态"
  local any_agent=0
  for bin in stargate cloud-monitor cloudmonitor cmagent; do
    if command -v "$bin" >/dev/null 2>&1; then
      echo "$bin 已安装: $(command -v "$bin")"; any_agent=1
    fi
  done
  if command -v systemctl >/dev/null; then
    for svc in stargate cloud-monitor cloudmonitor cmagent; do
      if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
        local st
        st=$(systemctl is-active "$svc" 2>/dev/null || echo unknown)
        echo "$svc.service -> $st"; any_agent=1
      fi
    done
  fi
  ps -ef | grep -i "stargate\|cloud-monitor\|cmagent" | grep -v grep && any_agent=1 || echo "(未运行)"
  [ "$any_agent" -eq 0 ] && {
    warn "stargate agent 不在运行 —— 腾讯云控制台磁盘告警会失效"
    info "安装: apt-get install stargate-agent 或 yum install stargate-agent"
  }

  echo; hdr "CBS 挂载"
  lsblk -f 2>/dev/null || df -hT
}

# ============================================================================
# audit —— 基线采样 + JSON 报告
# ============================================================================
cmd_audit() {
  state_dir_init
  local before after
  before=$(df -BG / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')

  hdr "磁盘分区"; df -hT
  echo; hdr "inode 使用"; df -hi 2>/dev/null || df -i
  echo; hdr "Top 大文件 (>500MB)"
  find / -xdev -type f -size +500M -printf "%s\t%p\n" 2>/dev/null \
    | sort -rn | head -20 | awk '{printf "%.1f GB\t%s\n", $1/1024/1024/1024, $2}'
  echo; hdr "deleted-but-open（进程持有已删文件）"
  silent_install lsof
  local held_mb
  held_mb=$(lsof +L1 2>/dev/null | awk 'NR>1 {sum+=$7} END {printf "%.1f", sum/1024/1024}')
  [ "${held_mb:-0}" != "0" ] && lsof +L1 2>/dev/null | head -10 && echo "持有总计 ${held_mb}MB" || echo "(干净)"
  echo; hdr "日志大户"
  du -sh /var/log/* 2>/dev/null | sort -rh | head -15
  command -v journalctl >/dev/null && { echo "journald:"; journalctl --disk-usage; }
  echo; hdr "docker 占用（如有）"
  command -v docker >/dev/null && docker system df 2>/dev/null || echo "(docker 未装)"
  echo; hdr "apt/yum 缓存"
  du -sh /var/cache/apt/archives 2>/dev/null; du -sh /var/cache/yum 2>/dev/null
  echo; hdr "定时器"
  crontab -l 2>/dev/null || echo "(root 无 crontab)"
  ls -la /etc/cron.d/ /etc/cron.daily/ /etc/cron.hourly/ 2>/dev/null || true
  command -v systemctl >/dev/null && systemctl list-timers --all 2>/dev/null | head -20 || true
  echo; hdr "CVM 元数据速览"
  cmd_meta 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' | head -20

  after=$(df -BG / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  local report="${LOG_DIR}/audit-$(date +%F-%H%M%S).json"
  cat > "$report" <<JSON
{
  "ts": "$(date '+%Y-%m-%dT%H:%M:%S%z')",
  "root_used_pct": {"before": ${before:-0}, "after": ${after:-0}},
  "deleted_but_open_mb": ${held_mb:-0}
}
JSON
  log "audit 报告: $report"
  state_set audit recovered "audit 完成" "{\"report\":\"$report\",\"before\":${before:-0},\"after\":${after:-0}}"
}

# ============================================================================
# locate —— 分层定位 Top N 大户
# ============================================================================
cmd_locate() {
  local path="/" top=15
  while [ $# -gt 0 ]; do
    case "$1" in
      --top) top="${2:-15}"; shift 2 ;;
      *) path="$1"; shift ;;
    esac
  done
  hdr "路径 $path 的 Top $top 大户（分层拆解，避免卡死）"
  echo "[第一层] 顶层子目录"
  du -sb "$path"/* 2>/dev/null | sort -rn | head -n "$top" \
    | awk '{printf "%.1f GB\t%s\n", $1/1024/1024/1024, $2}'
  echo; echo "[第二层] Top 5 的子目录 Top 5"
  local big_dirs
  big_dirs=$(du -sb "$path"/* 2>/dev/null | sort -rn | head -5 | awk '{print $2}')
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    echo "--- $d ---"
    du -sb "$d"/* 2>/dev/null | sort -rn | head -5 \
      | awk '{printf "%.1f GB\t%s\n", $1/1024/1024/1024, $2}'
  done <<< "$big_dirs"
  echo; hdr "文件类型聚合（/var/lib + /var/log + /var/cache）"
  for d in /var/lib /var/log /var/cache; do
    [ -d "$d" ] || continue
    echo "--- $d ---"
    # 先 basename 再取后缀，避免含点号的路径干扰
    find "$d" -type f 2>/dev/null | while IFS= read -r f; do
      local bn ext
      bn=$(basename "$f")
      if [[ "$bn" == *.* ]]; then ext="${bn##*.}"; else ext="<no-ext>"; fi
      printf '%s\n' "$ext"
    done | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn | head -5
  done
}

# ============================================================================
# emergency —— 幂等应急清理（绿=自动 黄=提示 红=--force 才执行）
# ============================================================================
cmd_emergency() {
  need_root
  if [ "$(state_get emergency)" = "recovered" ] && [ "${REDO:-}" != "1" ]; then
    info "上次 emergency 已 recovered，跳过。加 --redo 强制重跑。"
    return 0
  fi
  state_set emergency "in-progress" "开始应急清理"

  local before after force="${FORCE:-}"
  before=$(df -BG / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  hdr "应急清理前 根分区: ${before}%"

  # ---------- 绿区（自动，不碰业务数据）----------
  log "[绿区] /tmp /var/tmp 24h 前残留"
  local tmp_del
  tmp_del=$(find /tmp /var/tmp -mindepth 1 -mtime +1 -print -delete 2>/dev/null | wc -l || echo 0)
  info "删除 ${tmp_del} 个条目"

  command -v apt-get >/dev/null && { log "[绿区] apt-get clean"; apt-get clean 2>/dev/null || true; }
  command -v yum >/dev/null   && { log "[绿区] yum clean all";   yum clean all   2>/dev/null || true; }
  if command -v journalctl >/dev/null; then
    log "[绿区] journalctl vacuum"; journalctl --vacuum-size=50M 2>/dev/null || true
    journalctl --vacuum-time=7d 2>/dev/null || true
  fi

  # ---------- 黄区（提示，需 --force 才截断）----------
  local force_truncated=""
  if [ "$force" = "1" ]; then
    if [ -d /var/log/nginx ]; then
      log "[黄区] truncate nginx *.log -> 1MB"
      find /var/log/nginx -type f -name "*.log" -size +10M -exec truncate -s 1M {} \; 2>/dev/null || true
      force_truncated="${force_truncated} nginx"
    fi
    if [ -d /var/log/mysql ]; then
      log "[黄区] truncate mysql 慢/错误日志 -> 5MB"
      find /var/log/mysql -type f -size +50M -exec truncate -s 5M {} \; 2>/dev/null || true
      force_truncated="${force_truncated} mysql"
    fi
  else
    warn "[黄区] 如需立即截断 nginx / mysql 日志，请加 --force"
    warn "       不加 --force 时保留日志，等业务低峰处理"
  fi

  # ---------- 红区（必须 --force + 二次 YES 确认）----------
  if [ "$force" = "1" ] && command -v docker >/dev/null; then
    hdr "[红区] docker system prune -af --volumes"
    warn "    危险！删未使用镜像 / 停止容器 / 未挂卷"
    docker ps -a 2>/dev/null || true
    read -rp "    输入 YES 确认执行: " ans
    [ "$ans" = "YES" ] && docker system prune -af --volumes || info "跳过 docker prune"
  fi

  # ---------- deleted-but-open ----------
  silent_install lsof
  local held
  held=$(lsof +L1 2>/dev/null | awk 'NR>1 {sum+=$7} END {printf "%.1f", sum/1024/1024}')
  if [ "${held:-0}" != "0" ] && [ "${held:-0}" != "" ]; then
    warn "[提示] ${held}MB 被已删除文件持有但进程仍开着"
    warn "       lsof +L1 -> 重启对应服务或 kill 进程"
    lsof +L1 2>/dev/null | head -10 || true
  fi

  after=$(df -BG / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  local delta=$(( before - after > 0 ? before - after : 0 ))
  hdr "应急清理后 根分区: ${after}%（释放约 ${delta}%）"

  state_set emergency recovered "清理完成 ${before}%->${after}%" \
    "{\"before\":${before:-0},\"after\":${after:-0},\"force\":\"${force:-0}\"}"
}

# ============================================================================
# migrate —— 幂等数据盘迁移（rsync 可恢复 + 3 前置检查 + 双侧校验 + 软链回填）
# ============================================================================
migrate_one() {
  local SRC="$1" DST="$2"
  echo "---------------------------------------------------------------"
  info "迁移: $SRC  ->  $DST"

  # --- 幂等：已迁移过（软链指向 DST）直接跳过 ---
  if [ -L "$SRC" ] && [ "$(readlink "$SRC" 2>/dev/null)" = "$DST" ]; then
    info "已迁移过（软链回填 OK），跳过: $SRC"; return 0
  fi
  if [ -d "$DST" ] && [ ! -e "$SRC" ]; then
    warn "目标已存在但源消失（上次可能中途失败），请手动检查: $SRC"; return 1
  fi

  # --- 前置 3 检查 ---
  [ -d "$SRC" ] || { warn "源不存在/不是目录: $SRC"; return 0; }
  [ -L "$SRC" ] && { warn "源是软链，跳过（防套娃）: $SRC"; return 0; }
  [ ! -e "$DST" ] || { warn "目标已存在，跳过: $DST"; return 0; }

  local src_size avail avail_bytes need
  src_size=$(du -sb "$SRC" 2>/dev/null | awk '{print $1}')
  avail=$(df -k "$(dirname "$DST")" | awk 'NR==2 {print $4}')
  avail_bytes=$(( avail * 1024 ))
  need=$(( src_size + src_size/10 ))
  if [ "$avail_bytes" -lt "$need" ]; then
    err "数据盘不够（需 $(( need/1024/1024 ))MB，剩 $(( avail_bytes/1024/1024 ))MB）"; return 1
  fi

  mkdir -p "$(dirname "$DST")"

  log "rsync -aHAX $SRC -> $DST（幂等可续传）"
  if ! rsync -aHAX --info=progress2 "$SRC" "$DST"; then
    err "rsync 失败。重跑本命令即可续传"
    return 1
  fi

  # --- 双侧校验 ---
  local sc dc ss ds
  sc=$(find "$SRC" -type f | wc -l); dc=$(find "$DST" -type f | wc -l)
  ss=$(du -sb "$SRC" | awk '{print $1}'); ds=$(du -sb "$DST" | awk '{print $1}')
  echo "  文件: 源 $sc / 目标 $dc"
  echo "  字节: 源 $ss / 目标 $ds"
  if [ "$sc" != "$dc" ] || [ "$ss" != "$ds" ]; then
    err "校验不一致！请手动检查目标端数据后再处理"; return 1
  fi
  log "双侧校验 OK"

  # --- 删源 + 软链 ---
  log "删源，建软链..."
  rm -rf "$SRC"
  ln -s "$DST" "$SRC"
  local probe
  probe=$(ls "$SRC" 2>/dev/null | head -1)
  [ -z "$probe" ] && warn "软链指向空目录" || log "软链回填 OK: $SRC -> $DST"
}

cmd_migrate() {
  need_root
  if [ "$(state_get migrate)" = "recovered" ] && [ "${REDO:-}" != "1" ]; then
    info "上次 migrate 已 recovered，跳过。加 --redo 强制重跑。"; return 0
  fi
  state_set migrate "in-progress" "开始数据盘迁移"

  local DATA_MOUNT="${1:-/data}"
  [ -d "$DATA_MOUNT" ] || { err "数据盘挂载点不存在: $DATA_MOUNT"; state_set migrate failed "mount not found"; exit 1; }

  hdr "数据盘: $DATA_MOUNT"; df -h "$DATA_MOUNT"
  local base="$DATA_MOUNT/migrated-$(date +%Y%m%d)"
  mkdir -p "$base"

  local candidates=(
    "/var/lib/mysql" "/var/lib/postgresql" "/var/lib/redis" "/var/lib/clickhouse"
    "/var/lib/clickhouse-backup" "/var/log/nginx" "/var/log/mysql"
    "/root/.cache" "/root/.npm" "/root/.rustup" "/root/.cargo"
    "/root/.pyenv" "/root/.phpenv" "/root/.local"
    "/var/lib/docker" "/opt" "/var/www"
  )

  warn "迁移到 $base/，每一项都做 3 安全检查 + 双侧校验 + 软链回填"
  warn "业务低峰执行，并先停相关服务（MySQL/Redis/Docker）"

  local before after any_fail=0
  before=$(df -BG / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  for c in "${candidates[@]}"; do
    migrate_one "$c" "$base/${c#/}" || { warn "本次跳过: $c"; any_fail=1; }
  done
  after=$(df -BG / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  hdr "迁移完成 根分区: ${before}% -> ${after}%"; df -hT

  warn "提醒：腾讯云控制台磁盘用量有 5-15 分钟刷新延迟，别立刻去看"

  [ "$any_fail" -eq 0 ] \
    && state_set migrate recovered "全部迁移完成" "{\"before\":${before:-0},\"after\":${after:-0},\"mount\":\"$DATA_MOUNT\"}" \
    || state_set migrate recovered "部分跳过"    "{\"before\":${before:-0},\"after\":${after:-0},\"mount\":\"$DATA_MOUNT\"}"
}

# ============================================================================
# harden —— 持久防护（不改变业务语义）
# ============================================================================
cmd_harden() {
  need_root
  state_set harden "in-progress" "开始持久防护加固"

  hdr "logrotate 基线"
  if ! command -v logrotate >/dev/null; then
    silent_install logrotate; command -v logrotate >/dev/null || warn "logrotate 装不上，跳过"
  fi
  for svc in nginx mysql postgresql redis docker docker-ce nginx-ingress; do
    local f="/etc/logrotate.d/$svc"
    if [ -f "$f" ]; then
      grep -q '^\s*compress' "$f" || { sed -i '/^}$/i\    compress'  "$f"; info "$svc: +compress"; }
      grep -q '^\s*rotate ' "$f" || { sed -i '/^}$/i\    rotate 4'  "$f"; info "$svc: +rotate 4"; }
      grep -q '^\s*maxsize' "$f" || { sed -i '/^}$/i\    maxsize 100M' "$f"; info "$svc: +maxsize 100M"; }
    fi
  done

  # Docker daemon.json 日志限额
  if command -v docker >/dev/null; then
    hdr "Docker daemon.json 日志驱动限额"
    local dd="/etc/docker/daemon.json"; mkdir -p /etc/docker
    if [ -f "$dd" ] && command -v jq >/dev/null; then
      local tmp
      tmp=$(mktemp)
      jq '.["log-driver"]="json-file"
         | .["log-opts"] = ( .["log-opts"] // {} )
         | .["log-opts"]["max-size"]="100m"
         | .["log-opts"]["max-file"]="3"' "$dd" > "$tmp" && mv "$tmp" "$dd"
    elif [ ! -f "$dd" ]; then
      cat > "$dd" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "100m", "max-file": "3" }
}
EOF
    fi
    info "daemon.json: max-size 100m, max-file 3"; warn "重启 docker 生效: systemctl restart docker"
  fi

  # journald 限额
  hdr "journald 磁盘限额"
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-disk-limit.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemKeepFree=500M
MaxRetentionSec=7day
EOF
  command -v systemctl >/dev/null && systemctl restart systemd-journald 2>/dev/null || true
  info "journald: SystemMaxUse=200M SystemKeepFree=500M MaxRetentionSec=7d"

  # systemd-tmpfiles
  hdr "systemd-tmpfiles /tmp 清理"
  cat > /etc/tmpfiles.d/tmp-cleanup.conf <<'EOF'
D /tmp 1777 root root 3d -
D /var/tmp 1777 root root 3d -
EOF
  command -v systemd-tmpfiles >/dev/null && systemd-tmpfiles --create 2>/dev/null || true
  info "tmpfiles.d: /tmp /var/tmp 保留 3 天"

  # 磁盘巡检 cron
  hdr "磁盘水位巡检 cron（每天 03:00）"
  local cronfile=/etc/cron.d/disk-audit
  cat > "$cronfile" <<EOF
# 每天 03:00 磁盘水位巡检，阈值 ${THRESHOLD_PCT}%
0 3 * * * root /usr/local/bin/tencent-cvm-disk-tool emergency 1>>${LOG_DIR}/cron.log 2>&1 || true
EOF
  chmod 644 "$cronfile"
  info "cron -> $cronfile, 阈值 ${THRESHOLD_PCT}%"

  # stargate 健康检查
  hdr "stargate agent 健康检查"
  local any_agent=0
  for svc in stargate cloud-monitor cloudmonitor cmagent; do
    command -v systemctl >/dev/null && systemctl is-active "$svc" >/dev/null 2>&1 \
      && { info "$svc: running"; any_agent=1; }
  done
  if ! pgrep -f "stargate" >/dev/null 2>&1 && [ "$any_agent" -eq 0 ]; then
    warn "stargate agent 不在运行 —— 腾讯云控制台磁盘告警会失效"
    info "安装: apt-get install stargate-agent 或 yum install stargate-agent"
  fi

  state_set harden recovered "持久防护已部署" \
    '{"logrotate":true,"journald":true,"tmpfiles":true,"cron":true}'

  hdr "腾讯云控制台告警策略（手动做）"
  warn "  1) 磁盘使用率: 80% 警告 + 85% 严重"
  warn "  2) inode 使用率: 80%（很多人漏配）"
  warn "  3) 磁盘读写延迟: 50ms（慢盘前兆）"
  warn "  4) 告警渠道: 邮件 + 企业微信机器人"
  warn "  5) 告警抑制: 同一指标 5 分钟内只发一次"
}

# ============================================================================
# expand —— 调用 tccli cbs ResizeDisk 自动扩容
# ============================================================================
cmd_expand() {
  need_root
  local new_size_gb="${1:-}"
  [ -n "$new_size_gb" ] || { err "用法: expand <目标大小GB>"; exit 1; }

  need_cmd tccli || { err "tccli 未装: pip3 install tccli && tccli configure"; exit 1; }

  hdr "腾讯云 CBS 扩容 -> ${new_size_gb}GB"

  # ---- 用统一 __md_init 而不是写死 URL（根治 Forwarding error）----
  local instance_id region zone
  if __md_init; then
    instance_id=$(__md_fetch /meta-data/instance-id)
    region=$(__md_fetch /meta-data/placement/region)
    zone=$(__md_fetch /meta-data/placement/zone)
  fi
  [ -z "${instance_id:-}" ] && { err "无法获取 instance-id（元数据不可达）"; state_set expand failed "meta unreachable"; exit 1; }

  warn "=============================================="
  warn "  实例: $instance_id   区域: $region   可用区: $zone"
  warn "  扩容到: ${new_size_gb}GB"
  warn "=============================================="
  warn "磁盘扩容会触发 CBS 状态变更，期间磁盘可能短暂只读"
  warn "建议: 备份 / 业务低峰 / 有快照在场"

  read -rp "输入 instance-id 确认: " confirm_id
  [ "$confirm_id" = "$instance_id" ] || { err "不匹配，abort"; exit 1; }

  state_set expand "in-progress" "开始扩容 CBS -> ${new_size_gb}GB"

  local disks
  disks=$(unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY;
          tccli cbs DescribeDisks --instance-ids "[$(printf '"%s"' "$instance_id")]" \
          --region "$region" 2>&1) || true

  if command -v jq >/dev/null && echo "$disks" | jq -e . >/dev/null 2>&1; then
    echo "$disks" | jq '.DiskSet[] | {DiskId, DiskName, Size, DiskType, Attached}'
    local disk_id
    disk_id=$(echo "$disks" | jq -r '[.DiskSet[] | select(.Attached==true)][0].DiskId // empty')
  else
    err "DescribeDisks 返回异常: $disks"
    state_set expand failed "DescribeDisks failed"; exit 1
  fi
  [ -n "${disk_id:-}" ] || { err "没找到挂载中的磁盘"; state_set expand failed "no attached disk"; exit 1; }

  warn "将执行: tccli cbs ResizeDisk --DiskId $disk_id --DiskSize $new_size_gb --region $region"
  read -rp "再次输入 YES 确认: " ans
  [ "$ans" = "YES" ] || { warn "abort"; state_set expand skipped "user abort"; exit 0; }

  local ret
  ret=$(unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY;
        tccli cbs ResizeDisk --DiskId "$disk_id" --DiskSize "$new_size_gb" --region "$region" 2>&1) || true
  echo "$ret"
  local task_id=""
  [ -n "${ret:-}" ] && command -v jq >/dev/null && task_id=$(echo "$ret" | jq -r '.TaskId // empty' 2>/dev/null || true)

  if [ -n "${task_id:-}" ]; then
    log "CBS 后台任务已提交: $task_id"
    info "查状态: tccli cbs DescribeTaskStatus --TaskId $task_id --region $region"
    info "扩容完成后 resize 文件系统:"
    info "  裸分区: growpart /dev/vdX 1 && resize2fs /dev/vdX1"
    info "  LVM:    lvextend -r -l +100%FREE /dev/vg/root"
    state_set expand recovered "CBS ResizeDisk 已提交" \
      "{\"DiskId\":\"$disk_id\",\"TaskId\":\"$task_id\",\"sizeGB\":$new_size_gb}"
  else
    err "ResizeDisk 返回异常，检查上方输出"; state_set expand failed "ResizeDisk failed"
  fi
}

# ============================================================================
# verify —— 治理后验证
# ============================================================================
cmd_verify() {
  hdr "治理后验证"
  echo "[根分区]"; df -h /
  echo; echo "[inode]"; df -hi / 2>/dev/null || df -i /
  echo; echo "[deleted-but-open]"
  silent_install lsof
  local held
  held=$(lsof +L1 2>/dev/null | awk 'NR>1 {sum+=$7} END {printf "%.1f", sum/1024/1024}')
  echo "持有空间: ${held}MB"
  lsof +L1 2>/dev/null | head -5 || true
  echo; echo "[stargate agent]"; pgrep -fa stargate 2>/dev/null || echo "未运行"
  echo; echo "[腾讯云控制台延迟]"
  warn "磁盘用量百分比 5-15 分钟刷新延迟，等 10 分钟再看"

  echo; hdr "幂等状态一览"
  if [ -f "$STATE_FILE" ]; then
    if command -v jq >/dev/null; then
      jq -r '[.[] | "\(.ts) | \(.scenario) | \(.action) | \(.note)"] | .[]' "$STATE_FILE"
    else
      cat "$STATE_FILE"
    fi
  else
    echo "(无状态文件)"
  fi
}

# ============================================================================
# report —— 自动生成处置笔录 Markdown
# ============================================================================
cmd_report() {
  state_dir_init
  local out="${1:-${LOG_DIR}/处置笔录-$(date +%F-%H%M%S).md}"
  hdr "生成处置笔录 -> $out"

  # 抓外部 IP（关代理防 Forwarding error）
  local pub_ip
  pub_ip=$(_safe_curl_body --max-time 3 https://api.ipify.org)
  [ -z "$pub_ip" ] && pub_ip=$(_safe_curl_body --max-time 3 https://ifconfig.me)
  [ -z "$pub_ip" ] && pub_ip="N/A"

  {
    echo "# 腾讯云 CVM 磁盘满涨处置笔录"
    echo
    echo "- 生成时间: $(date '+%F %T %Z')"
    echo "- 主机名:   $(hostname)"
    echo "- 公网 IP:  $pub_ip"
    echo "- 内网 IP:  $(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "- 版本:     v${VERSION}"
    echo
    echo "## 一、现象"
    echo "> 腾讯云控制台磁盘使用率告警，邮件告警 → 邮件恢复循环。"
    echo
    echo "## 二、根因定位"
    echo "| 层级 | 结论 |"
    echo "|---|---|"
    echo "| 1. 审计 | 见 audit JSON 报告 $LOG_DIR/audit-*.json |"
    echo "| 2. 大户 | 见 locate 输出 |"
    echo "| 3. deleted-but-open | 见 verify 输出 |"
    echo
    echo "## 三、处置过程（自动从 state.json 读取）"
    echo
    echo "| 时间 | 场景 | 说明 | 状态 |"
    echo "|---|---|---|---|"
    if [ -f "$STATE_FILE" ]; then
      if command -v jq >/dev/null; then
        jq -r '.[] | "| \(.ts) | \(.scenario) | \(.note) | \(.action) |"' "$STATE_FILE"
      else
        sed -E 's/.*"scenario":"([^"]*)".*"action":"([^"]*)".*"ts":"([^"]*)".*"note":"([^"]*)".*/| \3 | \1 | \4 | \2 |/' "$STATE_FILE"
      fi
    else
      echo "| - | 无 | 无状态 | - |"
    fi
    echo
    echo "## 四、结果验证"
    echo
    echo '```bash'
    cmd_verify 2>/dev/null | sed -r 's/\x1b\[[0-9;]*m//g' | sed 's/^/  /'
    echo '```'
    echo
    echo "## 五、后续建议"
    echo
    echo "- 腾讯云控制台告警策略: 80% 警告 / 85% 严重 / 加 inode 告警（很多人漏配）"
    echo "- 告警渠道: 邮件 + 企业微信机器人，同一指标 5 分钟抑制"
    echo "- 业务侧: 确认 MySQL binlog / Docker overlay / 日志保留策略"
    echo "- 平台口径延迟: 控制台磁盘用量有 5-15 分钟刷新延迟，不要立刻去看"
    echo
    echo "## 六、命令速查"
    echo
    echo '```bash'
    echo "tencent-cvm-disk-tool audit"
    echo "tencent-cvm-disk-tool locate / --top 15"
    echo "tencent-cvm-disk-tool emergency"
    echo "tencent-cvm-disk-tool emergency --force"
    echo "tencent-cvm-disk-tool migrate /data"
    echo "tencent-cvm-disk-tool harden"
    echo "tencent-cvm-disk-tool expand 500"
    echo "tencent-cvm-disk-tool verify"
    echo "tencent-cvm-disk-tool report"
    echo '```'
  } > "$out"

  log "处置笔录已生成: $out"
}

# ============================================================================
# CLI 入口
# ============================================================================
usage() { cat <<EOF
腾讯云 CVM 磁盘满涨处置工具链 v${VERSION}

  用法: tencent-cvm-disk-tool <cmd> [args] [flags]

  命令:
    meta                 元数据 & stargate agent 自检
    audit                基线采样 + JSON 报告（幂等）
    locate [path] [--top N]   分层定位 Top N 大户
    emergency [--force] [--redo]   应急清理（绿自动/黄提示/红--force）
    migrate [/data] [--redo]      数据盘迁移（rsync+校验+软链回填）
    harden               持久防护加固
    expand <GB>          tccli cbs ResizeDisk 自动扩容（需 SecretId/Key）
    verify               治理后验证
    report [out.md]      生成处置笔录

  环境变量: THRESHOLD_PCT=80  TENCENT_META_URL=...  FORCE=1  REDO=1

  示例:
    tencent-cvm-disk-tool audit
    tencent-cvm-disk-tool emergency
    tencent-cvm-disk-tool emergency --force --redo
    tencent-cvm-disk-tool migrate /data
    tencent-cvm-disk-tool harden
    tencent-cvm-disk-tool report
EOF
}

main() {
  [ $# -ge 1 ] || { usage; exit 1; }
  local cmd="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) FORCE=1; shift ;;
      --redo)  REDO=1;  shift ;;
      -h|--help) usage; exit 0 ;;
      *) break ;;
    esac
  done
  case "$cmd" in
    meta)     cmd_meta ;;
    audit)    cmd_audit ;;
    locate)   cmd_locate "$@" ;;
    emergency) cmd_emergency ;;
    migrate)  cmd_migrate "${1:-/data}" ;;
    harden)   cmd_harden ;;
    expand)   cmd_expand "${1:-}" ;;
    verify)   cmd_verify ;;
    report)   cmd_report "${1:-}" ;;
    -h|--help|help) usage ;;
    *) err "unknown cmd: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
