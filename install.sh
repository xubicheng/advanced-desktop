#!/usr/bin/env bash
# ============================================================================
# install.sh —— 腾讯云 CVM 磁盘处置工具链 安装脚本
# 位置       : 在目标 CVM 上执行
# 调用方     : ① bash install.sh（本地已拷贝）
#              ② curl -fsSL <URL>/install.sh | bash（远程下载）
#              ③ deploy.ps1 推到远端再执行
#
# 设计要点（来自经验）:
#   - 可重入：每个步骤独立函数，失败能从具体步骤恢复（933170 Failure 3）
#   - 非交互 sudo 兼容：写 /usr/local 失败自动 fallback ~/.local/bin
#     并提示 PATH（1878048 Failure 2）
#   - 不越权：只做 install + 可选 --with-harden，绝不擅自引入
#     systemd/start.sh 等额外交付物（1878048 Failure 1）
#   - Forwarding error 根治：所有 curl 关代理
# ============================================================================

set -euo pipefail

VERSION="2.1.0"
TOOL_NAME="tencent-cvm-disk-tool"
REMOTE_BASE="${TOOL_BASE_URL:-https://cdn.tencentcloud.com/tools/$TOOL_NAME}"

C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YLW='\033[1;33m'; C_BLU='\033[0;34m'; C_BLD='\033[1m'; C_NC='\033[0m'
log()  { printf "${C_GRN}[+]${C_NC} %s\n" "$*"; }
warn() { printf "${C_YLW}[!]${C_NC} %s\n" "$*"; }
err()  { printf "${C_RED}[x]${C_NC} %s\n" "$*" >&2; }
info() { printf "${C_BLU}[i]${C_NC} %s\n" "$*"; }
hdr()  { printf "\n${C_BLD}===== %s =====${C_NC}\n" "$*"; }

# ============================================================================
# 0. 参数解析
# ============================================================================
WITH_HARDEN=0
SKIP_META=0
DRY_RUN=0
SRC_SCRIPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-harden) WITH_HARDEN=1; shift ;;
    --skip-meta)   SKIP_META=1;   shift ;;
    --dry-run)     DRY_RUN=1;     shift ;;
    --src|--file)  SRC_SCRIPT="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<EOF
install.sh —— 腾讯云 CVM 磁盘处置工具链 v${VERSION}

  用法:
    bash install.sh                         # 仅安装
    bash install.sh --with-harden           # 安装 + 持久防护
    bash install.sh --src ./tencent-cvm-disk-tool.sh
    bash install.sh --dry-run

  环境变量:
    TOOL_BASE_URL=...   下载根路径（默认 cdn.tencentcloud.com）
EOF
      exit 0 ;;
    *) err "未知参数: $1"; exit 1 ;;
  esac
done

# ============================================================================
# 1. 环境探测（可重入）
# ============================================================================
probe_env() {
  hdr "[1/5] 探测运行环境"
  local os
  os=$(uname -s)
  [ "$os" = "Linux" ] || { err "只支持 Linux（你是 $os）"; exit 1; }

  for t in bash curl awk sed find sort wc; do
    command -v "$t" >/dev/null 2>&1 || { err "缺少基础工具: $t"; exit 1; }
  done

  # 根治 Forwarding error
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY

  # 决定安装目录：优先 /usr/local/bin，没权限则 ~/.local/bin
  local dest_bin
  if [ "$(id -u)" -eq 0 ]; then
    dest_bin="/usr/local/bin"
  else
    dest_bin="/usr/local/bin"
    [ -w "/usr/local/bin" ] 2>/dev/null || dest_bin="$HOME/.local/bin"
  fi
  INSTALL_BIN="$dest_bin"
  mkdir -p "$INSTALL_BIN"

  info "安装目标: $INSTALL_BIN/$TOOL_NAME"
  info "主机名   : $(hostname) | 用户: $(whoami)"
  info "磁盘     : $(df -h / | awk 'NR==2 {print $5 " used, " $3"/"$2}')"
}

# ============================================================================
# 2. 获取主脚本（可重入）
# ============================================================================
fetch_script() {
  hdr "[2/5] 获取主脚本 v${VERSION}"
  local target="$INSTALL_BIN/$TOOL_NAME"

  # a) --src 本地文件
  if [ -n "$SRC_SCRIPT" ]; then
    [ -f "$SRC_SCRIPT" ] || { err "--src 文件不存在: $SRC_SCRIPT"; exit 1; }
    cp "$SRC_SCRIPT" "$target"
    log "从本地拷贝: $SRC_SCRIPT -> $target"
    return 0
  fi

  # b) 当前目录就有
  if [ -f "./$TOOL_NAME.sh" ]; then
    cp "./$TOOL_NAME.sh" "$target"
    log "当前目录已有: ./$TOOL_NAME.sh -> $target"
    return 0
  fi

  # c) curl 下载
  local url="${REMOTE_BASE}/${VERSION}/${TOOL_NAME}.sh"
  info "尝试下载: $url"
  local code
  code=$(curl -sS --max-time 10 --connect-timeout 3 --noproxy '*' \
        -o "$target" -w '%{http_code}' "$url" 2>/dev/null || echo "000")

  if [ "$code" = "200" ]; then
    log "下载成功 (HTTP $code)"
  else
    # d) 失败 → 写占位文件，提示用户贴内容
    warn "下载失败 (HTTP $code)，写入占位文件"
    cat > "$target" <<EOF
#!/usr/bin/env bash
# ============================================================
# 离线占位 —— 请把完整脚本内容贴到此文件，或从本地拷贝:
#   scp tencent-cvm-disk-tool.sh root@<IP>:$target
#   curl -fsSL <你的脚本URL> -o $target
# install.sh 下载失败，请检查 TOOL_BASE_URL 和网络。
# ============================================================
echo "[install.sh] 请把 tencent-cvm-disk-tool.sh 放到: $0" >&2
exit 3
EOF
  fi
}

# ============================================================================
# 3. 校验 + 权限（可重入）
# ============================================================================
install_verify() {
  hdr "[3/5] 校验 + 权限"
  local target="$INSTALL_BIN/$TOOL_NAME"
  chmod +x "$target"

  if bash -n "$target" 2>/dev/null; then
    log "语法检查 OK"
  else
    warn "bash -n 未通过（可能是占位文件 / 版本不匹配）"
  fi

  local got_version
  got_version=$(grep -oE 'VERSION="[0-9.]+"' "$target" 2>/dev/null | head -1 | cut -d'"' -f2)
  info "检测到工具版本: v${got_version:-unknown}"

  # PATH 提醒
  case ":$PATH:" in
    *":$INSTALL_BIN:"*) : ;;
    *)
      if [ "$INSTALL_BIN" != "/usr/local/bin" ]; then
        warn "$INSTALL_BIN 不在 PATH"
        warn "  echo 'export PATH=\"\$PATH:$INSTALL_BIN\"' >> ~/.bashrc"
      fi
      ;;
  esac
}

# ============================================================================
# 4. 首次运行 meta + audit（可重入）
# ============================================================================
first_run() {
  hdr "[4/5] 首次运行 meta + audit"
  local target="$INSTALL_BIN/$TOOL_NAME"

  [ "$SKIP_META" = "1" ] && { info "--skip-meta 跳过元数据"; return 0; }
  [ "$DRY_RUN"   = "1" ] && { info "--dry-run 跳过首次运行"; return 0; }

  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY

  log "meta（非腾讯云 CVM 会显示 '元数据服务不可达'，属正常）"
  "$target" meta 2>&1 | tail -18 || true

  echo
  log "audit（生成 JSON 报告到 /var/log/$TOOL_NAME/）"
  "$target" audit 2>&1 | tail -10 || warn "audit 返回非零"
}

# ============================================================================
# 5. 可选 harden（可重入）
# ============================================================================
do_harden() {
  [ "$WITH_HARDEN" = "1" ] || return 0
  hdr "[5/5] 持久防护加固（--with-harden）"
  local target="$INSTALL_BIN/$TOOL_NAME"

  # harden 内含 read -rp，非交互环境传 FORCE=1 会走红区但跳过二次确认
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY
  FORCE=1 "$target" harden 2>&1 | tail -25 || warn "harden 返回非零"

  echo
  info "生成处置笔录..."
  "$target" report "/root/处置笔录-$(date +%F).md" 2>&1 | tail -3 || true
}

# ============================================================================
# Main
# ============================================================================
main() {
  probe_env
  fetch_script
  install_verify
  first_run
  do_harden

  printf "\n${C_BLD}✅ 安装完成${C_NC}\n"
  info "工具位置: $INSTALL_BIN/$TOOL_NAME"
  info "帮助    : $TOOL_NAME --help"
  echo
  info "常用命令:"
  echo "  $TOOL_NAME audit"
  echo "  $TOOL_NAME locate / --top 15"
  echo "  $TOOL_NAME emergency"
  echo "  $TOOL_NAME emergency --force"
  echo "  $TOOL_NAME migrate /data"
  echo "  $TOOL_NAME verify"
  echo "  $TOOL_NAME report"
  echo
  [ "$WITH_HARDEN" != "1" ] && warn "提示: 下次执行加 --with-harden 可顺便部署持久防护"
  return 0
}
main "$@"
