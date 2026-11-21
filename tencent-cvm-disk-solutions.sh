#!/usr/bin/env bash
# ============================================================================
# 腾讯云 CVM 磁盘满涨 —— 应急清理 + 数据盘迁移 + 持久防护
# 适用：Debian/Ubuntu/CentOS/RHEL 全系 CVM
# 使用方式：在你的 CVM 上 root 身份执行
#   Step 1 应急清理     : bash tencent-cvm-disk-solutions.sh --emergency
#   Step 2 数据盘迁移   : bash tencent-cvm-disk-solutions.sh --migrate /data  # /data 是你扩容的数据盘挂载点
#   Step 3 持久防护部署 : bash tencent-cvm-disk-solutions.sh --harden
#   巡检（每次告警时跑）: bash tencent-cvm-disk-solutions.sh --audit
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GRN}[+]${NC} $*"; }
warn() { echo -e "${YLW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }

need_root() { [ "$(id -u)" -eq 0 ] || { err "need root"; exit 1; }; }

# ============================================================================
# 0. 基线采样
# ============================================================================
audit() {
  echo "=== 磁盘基线 ==="
  df -hT | sed '1s/^/Filesystem/'
  echo; echo "=== inode ==="
  df -hi 2>/dev/null || df -i
  echo; echo "=== deleted-but-open (进程持有的已删文件) ==="
  lsof +L1 2>/dev/null || echo "(lsof 未安装)"; command -v lsof >/dev/null || apt-get install -y lsof 2>/dev/null || yum install -y lsof 2>/dev/null
  echo; echo "=== Top 大文件 (>500MB) ==="
  find / -xdev -type f -size +500M -printf "%s\t%p\n" 2>/dev/null | sort -rn | head -20 | awk '{printf "%.1f GB\t%s\n", $1/1024/1024/1024, $2}'
  echo; echo "=== Top 目录 ==="
  du -sh /* 2>/dev/null | sort -rh | head -15
  echo; echo "=== 日志大户 ==="
  du -sh /var/log/* 2>/dev/null | sort -rh | head -15
  command -v journalctl >/dev/null && { echo "journald:"; journalctl --disk-usage; }
  echo; echo "=== docker 占用 ==="
  command -v docker >/dev/null && docker system df 2>/dev/null || echo "(docker 未安装)"
  echo; echo "=== apt/yum 缓存 ==="
  du -sh /var/cache/apt/archives 2>/dev/null; du -sh /var/cache/yum 2>/dev/null
  echo; echo "=== 定时任务 ==="
  (crontab -l 2>/dev/null || true); ls -la /etc/cron.d/ /etc/cron.daily/ /etc/cron.hourly/ 2>/dev/null
  command -v systemctl >/dev/null && systemctl list-timers --all 2>/dev/null | head -20
}

# ============================================================================
# 1. 应急清理（不碰业务数据，5 分钟释放空间）
# ============================================================================
emergency() {
  need_root
  log "应急清理前:"; df -h /
  local freed=0

  # 1) /tmp /var/tmp 残留（1 天前的可安全删）
  log "清理 /tmp /var/tmp 中 24h 前的残留..."
  find /tmp  /var/tmp -mindepth 1 -mtime +1 -print -delete 2>/dev/null | wc -l | xargs -I{} echo "  删除 {} 个条目"

  # 2) apt / yum 缓存
  if command -v apt-get >/dev/null; then
    log "apt-get clean"
    apt-get clean
  fi
  if command -v yum >/dev/null; then
    log "yum clean all"
    yum clean all
  fi

  # 3) journald 过期日志（保留 50M）
  if command -v journalctl >/dev/null; then
    log "journalctl --vacuum-size=50M"
    journalctl --vacuum-size=50M 2>/dev/null || true
    journalctl --vacuum-time=7d   2>/dev/null || true
  fi

  # 4) docker（如有）
  if command -v docker >/dev/null; then
    log "docker system prune -af --volumes  （谨慎！会删未使用镜像/容器/卷）"
    warn "  请先确认容器状态：docker ps -a"
    read -rp "  是否继续 [y/N]: " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] && docker system prune -af --volumes || echo "跳过"
  fi

  # 5) 业务日志 truncate（保留最后 1MB，不删文件避免断句柄）
  if [ -d /var/log/nginx ]; then
    log "truncate nginx 日志"
    find /var/log/nginx -type f -name "*.log" -size +10M -exec truncate -s 1M {} \; 2>/dev/null || true
  fi
  if [ -d /var/log/mysql ]; then
    log "truncate mysql 慢日志/错误日志"
    find /var/log/mysql -type f -size +50M -exec truncate -s 5M {} \; 2>/dev/null || true
  fi

  # 6) deleted-but-open 处理（进程不重启就释放不了）
  local held
  held=$(lsof +L1 2>/dev/null | awk 'NR>1 {sum+=$7} END {printf "%.1f", sum/1024/1024}')
  if [ "${held:-0}" != "0" ] && [ "${held:-0}" != "" ]; then
    warn "有 ${held}MB 被进程持有但文件已删除"
    warn "  建议重启对应服务后再删空间；或直接 kill 进程（会断业务）"
    lsof +L1 2>/dev/null | head -10
  fi

  log "应急清理后:"; df -h /
  log "如果还有告警，继续跑 Step 2 数据盘迁移 + Step 3 持久防护"
}

# ============================================================================
# 2. 数据盘迁移 —— rsync + 双侧计数校验 + 软链接回填
#    经验教训：必须先做 3 项前置检查，避免软链套软链 / 递归复制 / 误删目标
# ============================================================================
migrate_one() {
  local SRC="$1" DST="$2"
  echo "---------------------------------------------------------------"
  log "迁移: $SRC  ->  $DST"

  # --- 前置检查 ---
  if [ ! -d "$SRC" ]; then warn "源不存在或不是目录，跳过: $SRC"; return 0; fi
  if [ -L "$SRC" ]; then  warn "源本身是软链，跳过（防止套娃）: $SRC"; return 0; fi
  if [ -e "$DST" ]; then  warn "目标已存在，跳过: $DST"; return 0; fi
  local src_size
  src_size=$(du -sb "$SRC" 2>/dev/null | awk '{print $1}')
  local avail
  avail=$(df -k "$(dirname "$DST")" | awk 'NR==2 {print $4}')
  if [ -n "$avail" ] && [ -n "$src_size" ]; then
    local avail_bytes=$(( avail * 1024 ))
    if [ "$avail_bytes" -lt "$(( src_size + src_size/10 ))" ]; then
      err "数据盘剩余不够（需 ${src_size}，剩 ${avail_bytes}），abort"
      return 1
    fi
  fi

  mkdir -p "$(dirname "$DST")"

  # --- rsync（可恢复拷贝）---
  log "rsync -aHAX --info=progress2"
  if ! rsync -aHAX --info=progress2 "$SRC" "$DST"; then
    err "rsync 失败，可能中途断。重新跑本命令即可续传（rsync 幂等）"
    return 1
  fi

  # --- 双侧校验 ---
  local sc dc ss ds
  sc=$(find "$SRC" -type f | wc -l)
  dc=$(find "$DST" -type f | wc -l)
  ss=$(du -sb "$SRC" | awk '{print $1}')
  ds=$(du -sb "$DST" | awk '{print $1}')
  echo "  源文件=$sc  目标文件=$dc"
  echo "  源字节=$ss  目标字节=$ds"
  if [ "$sc" != "$dc" ] || [ "$ss" != "$ds" ]; then
    err "校验不一致！请检查目标端数据后再手动处理"
    return 1
  fi
  log "双侧校验 OK"

  # --- 删源 + 软链 ---
  log "删除源目录..."
  rm -rf "$SRC"
  ln -s "$DST" "$SRC"
  ls -la "$SRC"
  # 验证软链可用
  local probe
  probe=$(ls "$SRC" 2>/dev/null | head -1)
  if [ -z "$probe" ]; then warn "软链指向空目录，请确认"; fi
  log "软链回填 OK: $SRC -> $DST"
  return 0
}

migrate() {
  need_root
  local DATA_MOUNT="${1:-/data}"
  if [ ! -d "$DATA_MOUNT" ]; then err "数据盘挂载点不存在: $DATA_MOUNT"; exit 1; fi
  log "数据盘: $DATA_MOUNT"
  df -h "$DATA_MOUNT"

  # 候选迁移目录（按磁盘满涨高频大户）
  local candidates=(
    "/var/lib/mysql"
    "/var/lib/postgresql"
    "/var/lib/redis"
    "/var/log/nginx"
    "/var/log/mysql"
    "/root/.cache"
    "/root/.npm"
    "/root/.rustup"
    "/var/lib/docker"
    "/opt"
    "/var/www"
    "/var/lib/clickhouse"
    "/var/lib/clickhouse-backup"
  )

  local base="$DATA_MOUNT/migrated-$(date +%Y%m%d)"
  mkdir -p "$base"

  warn "以下目录将被逐一迁移到 $base/ 下"
  warn "迁移前会做 3 项安全检查，迁移后自动软链回填原路径"
  warn "期间服务可能短暂停，建议先在业务低峰执行"

  local choices=()
  for c in "${candidates[@]}"; do
    [ -d "$c" ] && choices+=("$c")
  done

  for c in "${choices[@]}"; do
    local name="${c#/}"        # strip leading /
    local dst="$base/$name"
    migrate_one "$c" "$dst" || warn "本次跳过: $c"
  done

  log "迁移完成。df 新貌:"
  df -hT
  warn "提醒：腾讯云控制台的磁盘用量百分比可能有 5~15 分钟刷新延迟"
  warn "       不要立刻去控制台看 '为什么还 85%'，等一会儿再刷新"
}

# ============================================================================
# 3. 持久防护
# ============================================================================
harden() {
  need_root

  # --- logrotate ---
  log "检查 logrotate..."
  if ! command -v logrotate >/dev/null; then
    apt-get install -y logrotate 2>/dev/null || yum install -y logrotate
  fi
  # MySQL / Nginx / PostgreSQL 默认配置都在 /etc/logrotate.d/ 下
  # 确保 weekly + maxsize + rotate 4 + compress
  for svc in nginx mysql postgresql redis; do
    f="/etc/logrotate.d/$svc"
    if [ -f "$f" ]; then
      sed -i 's/^\(.*compress.*\)/# \1 (ensure compress)/' "$f"
      grep -q "^\s*compress" "$f"   || sed -i '/^}$/i\    compress'  "$f"
      grep -q "^\s*rotate " "$f"   || sed -i '/^}$/i\    rotate 4'  "$f"
      grep -q "^\s*maxsize" "$f"   || sed -i '/^}$/i\    maxsize 100M' "$f"
    fi
  done
  log "logrotate 检查完成"

  # --- journald 限额 ---
  if [ -d /etc/systemd/journald.conf.d ]; then
    cat > /etc/systemd/journald.conf.d/99-disk-limit.conf <<EOF
[Journal]
SystemMaxUse=200M
SystemKeepFree=500M
MaxRetentionSec=7day
EOF
    systemctl restart systemd-journald 2>/dev/null || true
  fi

  # --- /tmp 自动清理 ---
  if ! grep -q "tmpfiles.d" /etc/systemd/journald.conf 2>/dev/null; then
    cat > /etc/tmpfiles.d/tmp-cleanup.conf <<EOF
# 每天清理 /tmp /var/tmp 里 3 天前的文件
D /tmp 1777 root root 3d -
D /var/tmp 1777 root root 3d -
EOF
    systemd-tmpfiles --create 2>/dev/null || true
  fi

  # --- 磁盘水位巡检 cron（每天 03:00）---
  local cronfile=/etc/cron.d/disk-audit
  cat > "$cronfile" <<'EOF'
# 每天 03:00 跑磁盘水位巡检，写入 /var/log/disk-audit.log
0 3 * * * root /usr/local/bin/disk-audit.sh >> /var/log/disk-audit.log 2>&1
EOF
  cat > /usr/local/bin/disk-audit.sh <<'EOF'
#!/usr/bin/env bash
THRESHOLD="${1:-80}"
echo "=== $(date '+%F %T') ==="
df -h | awk 'NR>1 {gsub(/%/,"",$5); if ($5+0 >= '"$THRESHOLD"') print "ALERT "$1" "$5"% -> "$6}'
# deleted-but-open
held=$(lsof +L1 2>/dev/null | awk 'NR>1 {sum+=$7} END {printf "%.1f", sum/1024/1024}')
[ "${held:-0}" != "0" ] && echo "DELETED-BUT-OPEN ${held}MB"
exit 0
EOF
  chmod +x /usr/local/bin/disk-audit.sh
  log "cron 巡检已部署 -> $cronfile, 阈值 ${THRESHOLD:-80}%"

  # --- 腾讯云 stargate / cloud-monitor 告警策略建议 ---
  warn "--- 腾讯云告警策略调整建议（手动在控制台做）---"
  warn "  1) 磁盘使用率告警: 阈值 80% (保持) + 85% 严重告警"
  warn "  2) 磁盘 inode 使用率: 阈值 80%（很多人漏配这个）"
  warn "  3) 磁盘读取 / 写入延迟: 阈值 50ms（慢盘前兆）"
  warn "  4) 新增 '磁盘巡检' 自定义告警: 用 CLS 日志 topic 订阅上面 cron 输出"
  warn "  5) 告警渠道: 邮件 + 企业微信机器人（不要只邮件）"
  warn "  6) 告警抑制: 同一指标 5 分钟内只发一次，避免邮件轰炸"
}

# ============================================================================
# CLI
# ============================================================================
case "${1:-}" in
  --emergency) emergency ;;
  --migrate)   migrate "${2:-/data}" ;;
  --harden)    harden ;;
  --audit)     audit ;;
  "")
    echo "用法: $0 --audit | --emergency | --migrate /data | --harden"
    exit 1 ;;
  *) err "unknown arg: $1"; exit 1 ;;
esac
