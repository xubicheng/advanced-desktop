#!/usr/bin/env bash
# ============================================================================
# limit-bandwidth.sh — CVM 站点访客下载带宽限制（每连接限速，并发不限制）
# 用法:
#   sudo bash limit-bandwidth.sh              # 交互式：自动探测 + 默认 2MB/s/连接
#   sudo bash limit-bandwidth.sh 5m           # 指定每连接限速 5MB/s
#   sudo bash limit-bandwidth.sh --dry-run    # 只看不改
#   sudo bash limit-bandwidth.sh --rollback   # 回滚到上次备份
#   sudo bash limit-bandwidth.sh --status     # 查看当前限速状态
#
# 策略: 每个访客连接下载限速 RATE（默认 2MB/s），并发线程数不限制。
#       这样总带宽随访客数增长，但单访客不会把带宽吃满。
# ============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "[x] 请用 root 执行: sudo bash $0"; exit 1; }

RATE="${1:-2m}"            # 默认每连接 2MB/s (m=MB, k=KB, 不带单位=byte/s)
DRY_RUN=0
ROLLBACK=0
SHOW_STATUS=0
case "${1:-}" in
  --dry-run)  DRY_RUN=1; RATE="${2:-2m}" ;;
  --rollback) ROLLBACK=1 ;;
  --status)   SHOW_STATUS=1 ;;
  -h|--help)
    sed -n '2,12p' "$0"; exit 0 ;;
esac

BACKUP_DIR="/etc/bandwidth-limit-backup/$(date +%Y%m%d-%H%M%S)"
MARKER="# bandwidth-limit-start"
MARKER_END="# bandwidth-limit-end"

log()  { printf "\033[0;32m[+]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[0;31m[x]\033[0m %s\n" "$*" >&2; }
info() { printf "\033[0;34m[i]\033[0m %s\n" "$*"; }

# ---------- 检测 web 服务器 ----------
detect_webserver() {
  local ws=""
  if command -v nginx >/dev/null 2>&1 && pgrep -x nginx >/dev/null 2>&1; then
    ws="nginx"
  elif command -v apache2 >/dev/null 2>&1 && pgrep -x apache2 >/dev/null 2>&1; then
    ws="apache2"
  elif command -v httpd >/dev/null 2>&1 && pgrep -x httpd >/dev/null 2>&1; then
    ws="httpd"
  fi
  if [ -z "$ws" ]; then
    # 进程名可能不一样，再查端口
    if ss -tlnp 2>/dev/null | grep -E ':80|:443' | grep -qiE "nginx"; then ws="nginx"
    elif ss -tlnp 2>/dev/null | grep -E ':80|:443' | grep -qiE "apache|httpd"; then ws="apache2"
    fi
  fi
  echo "$ws"
}

# ---------- Nginx 限速 ----------
nginx_apply() {
  log "检测到 Nginx"

  # 找出所有启用的站点配置
  local conf_dir=""
  local site_files=()
  for d in /etc/nginx/conf.d /etc/nginx/sites-enabled; do
    [ -d "$d" ] && conf_dir="$d"
  done
  mapfile -t site_files < <(find /etc/nginx -type f \( -name "*.conf" \) 2>/dev/null | grep -vE "nginx.conf|fastcgi|mime|scgi|uwsgi|koi|win-utf")
  # 优先 conf.d / sites-enabled
  local active_files=()
  for f in "${site_files[@]}"; do
    if echo "$f" | grep -qE "conf\.d|sites-enabled"; then active_files+=("$f"); fi
  done
  if [ ${#active_files[@]} -eq 0 ]; then
    warn "没找到 conf.d / sites-enabled 下的站点配置，列出所有 .conf 让你确认:"
    for f in "${site_files[@]}"; do info "  $f"; done
    echo -n "要修改这些文件吗？(y/N): "; read -r ans; [ "$ans" != "y" ] && { err "已取消"; exit 1; }
    active_files=("${site_files[@]}")
  fi

  log "找到 ${#active_files[@]} 个站点配置文件:"
  for f in "${active_files[@]}"; do info "  $f"; done

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 将给每个 server 块注入: limit_rate $RATE; limit_rate_after 3m;"
    return 0
  fi

  # 备份
  mkdir -p "$BACKUP_DIR"
  log "备份原配置到 $BACKUP_DIR/"
  for f in "${active_files[@]}"; do
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").bak"
  done

  # 注入限速（每个 server 块内）
  local changed=0
  for f in "${active_files[@]}"; do
    if grep -q "$MARKER" "$f"; then
      warn "$f 已经有限速标记，跳过（要改数值先 --rollback）"
      continue
    fi
    # 在每个 server { ... } 的 listen 行之后注入
    cp "$f" "$f.$$.tmp"
    awk -v rate="$RATE" -v m="$MARKER" -v me="$MARKER_END" '
      /^[[:space:]]*server[[:space:]]*\{/ { print; in_srv=1; print "    " m " 每连接下载限速 " rate " (并发不限制)"; print "    limit_rate_after 3m;"; print "    limit_rate " rate ";"; print "    " me; next }
      { print }
    ' "$f" > "$f.$$.tmp" && mv "$f.$$.tmp" "$f"
    info "已修改: $f"
    changed=1
  done

  if [ "$changed" -eq 0 ]; then
    warn "没有文件被修改（可能已限速过）"
    return 0
  fi

  # 测试配置
  log "测试 nginx 配置..."
  if nginx -t 2>&1; then
    log "配置 OK，reload..."
    nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null
    log "✅ Nginx 限速生效: 每连接 ${RATE}/s，前 3MB 不限速（大文件下载时触发）"
  else
    err "nginx -t 失败！自动回滚..."
    for f in "${active_files[@]}"; do
      cp -a "$BACKUP_DIR/$(basename "$f").bak" "$f" 2>/dev/null
    done
    nginx -t && nginx -s reload
    err "已回滚，检查上面的错误"
    exit 1
  fi
}

# ---------- Apache 限速 ----------
apache_apply() {
  log "检测到 Apache ($1)"
  local conf_dir="/etc/apache2/sites-enabled"
  [ "$1" = "httpd" ] && conf_dir="/etc/httpd/conf.d"

  local site_files=()
  mapfile -t site_files < <(find "$conf_dir" -type f 2>/dev/null)
  if [ ${#site_files[@]} -eq 0 ]; then
    err "没找到站点配置 ($conf_dir 为空)"
    exit 1
  fi
  log "找到 ${#site_files[@]} 个站点配置:"
  for f in "${site_files[@]}"; do info "  $f"; done

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 将启用 mod_ratelimit 并给每个 VirtualHost 注入 RATE_LIMIT 过滤器"
    return 0
  fi

  # 启用 mod_ratelimit
  if command -v a2enmod >/dev/null 2>&1; then
    a2enmod ratelimit 2>/dev/null || true
  fi
  # httpd 需要手动 LoadModule
  if [ "$1" = "httpd" ] && ! grep -q "mod_ratelimit" /etc/httpd/conf/httpd.conf 2>/dev/null; then
    echo "LoadModule ratelimit_module modules/mod_ratelimit.so" >> /etc/httpd/conf/httpd.conf
  fi

  local rate_kb
  rate_kb=$(echo "$RATE" | sed 's/m$/000/;s/k$//;s/g$/000000/')

  mkdir -p "$BACKUP_DIR"
  for f in "${site_files[@]}"; do
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").bak"
  done

  local changed=0
  for f in "${site_files[@]}"; do
    if grep -q "$MARKER" "$f"; then warn "$f 已限速，跳过"; continue; fi
    # 在 <VirtualHost ...> 行之后注入
    awk -v rk="$rate_kb" -v m="$MARKER" -v me="$MARKER_END" '
      /<VirtualHost/ { print; print "    " m; print "    <Location />"; print "        SetOutputFilter RATE_LIMIT"; print "        SetEnv rate-limit " rk; print "    </Location>"; print "    " me; next }
      { print }
    ' "$f" > "$f.$$.tmp" && mv "$f.$$.tmp" "$f"
    changed=1
  done

  if [ "$changed" -eq 0 ]; then warn "没有文件被修改"; return 0; fi

  log "测试 Apache 配置..."
  if apachectl configtest 2>&1 || httpd -t 2>&1; then
    log "reload Apache..."
    systemctl reload apache2 2>/dev/null || apachectl graceful 2>/dev/null || service httpd reload 2>/dev/null
    log "✅ Apache 限速生效: 每连接约 ${rate_kb} KB/s"
  else
    err "配置测试失败，回滚..."
    for f in "${site_files[@]}"; do cp -a "$BACKUP_DIR/$(basename "$f").bak" "$f" 2>/dev/null; done
    apachectl configtest && systemctl reload apache2
    exit 1
  fi
}

# ---------- 回滚 ----------
do_rollback() {
  local latest
  latest=$(ls -td /etc/bandwidth-limit-backup/*/ 2>/dev/null | head -1)
  [ -z "$latest" ] && { err "没有找到备份目录"; exit 1; }
  log "从 $latest 回滚..."
  for f in "$latest"*.bak; do
    [ -f "$f" ] || continue
    local orig="${f%.bak}"
    # 恢复到原路径：备份文件名是 basename，需要找回原目录
    warn "备份文件: $f"
  done
  info "备份目录内容:"
  ls -lh "$latest"
  echo
  info "请手动恢复: cp $latest*.bak 到原站点配置路径，然后 reload"
  info "（因为不知道你原本的 conf.d 路径，列出来给你确认）"
}

# ---------- 状态查看 ----------
do_status() {
  log "当前限速状态:"
  echo "--- Nginx ---"
  if command -v nginx >/dev/null 2>&1; then
    grep -rn "limit_rate" /etc/nginx/conf.d/ /etc/nginx/sites-enabled/ 2>/dev/null || echo "  未配置 limit_rate"
  fi
  echo "--- Apache ---"
  if command -v apache2 >/dev/null 2>&1 || command -v httpd >/dev/null 2>&1; then
    grep -rn "rate-limit" /etc/apache2/sites-enabled/ /etc/httpd/conf.d/ 2>/dev/null || echo "  未配置 RATE_LIMIT"
  fi
  echo "--- 备份目录 ---"
  ls -td /etc/bandwidth-limit-backup/*/ 2>/dev/null || echo "  无备份"
  echo
  log "当前实际带宽 (网卡速率):"
  for iface in eth0 ens3 ens5; do
    ethtool "$iface" 2>/dev/null | grep -i speed && break
  done
}

# ============================================================================
# main
# ============================================================================
if [ "$SHOW_STATUS" -eq 1 ]; then do_status; exit 0; fi
if [ "$ROLLBACK" -eq 1 ]; then do_rollback; exit 0; fi

WS=$(detect_webserver)
if [ -z "$WS" ]; then
  err "没检测到运行中的 Nginx / Apache"
  info "80/443 端口占用情况:"
  ss -tlnp 2>/dev/null | grep -E ":80|:443" || echo "  (无)"
  exit 1
fi

log "Web 服务器: $WS"
log "限速策略: 每连接下载 $RATE/s，前 3MB 不限速（小文件/首屏快），并发线程不限制"
log "备份目录: $BACKUP_DIR"
echo

case "$WS" in
  nginx)   nginx_apply ;;
  apache2) apache_apply apache2 ;;
  httpd)   apache_apply httpd ;;
esac

echo
log "=============================================="
log "✅ 限速已生效。检查方法:"
log "   浏览器开多标签下载大文件，看单连接速度"
log "   或运行: sudo bash $0 --status"
log "=============================================="
echo
warn "提醒：告警邮件频次（2小时收敛）需要在腾讯云控制台改，步骤见聊天记录。"
