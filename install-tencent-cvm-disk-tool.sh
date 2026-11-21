#!/usr/bin/env bash
# ============================================================================
# 一键部署到腾讯云 CVM
#   用法 1（推荐，直接在 CVM 上执行）:
#     curl -fsSL https://your-host/install-tencent-cvm-disk-tool.sh | bash
#   用法 2（本机执行，SSH 到 CVM）:
#     bash install-tencent-cvm-disk-tool.sh root@1.2.3.4
#   用法 3（手动）:
#     scp tencent-cvm-disk-tool.sh root@1.2.3.4:/usr/local/bin/
# ============================================================================
set -euo pipefail
DEST="/usr/local/bin/tencent-cvm-disk-tool"
SRC_NAME="tencent-cvm-disk-tool.sh"

echo "=== 腾讯云 CVM 磁盘处置工具链 安装 ==="

# ---- 如果是 SSH 远程部署 ----
if [ $# -ge 1 ]; then
  REMOTE="$1"
  [ -f "$SRC_NAME" ] || { err "本地找不到 $SRC_NAME"; exit 1; }
  scp "$SRC_NAME" "${REMOTE}:${DEST}"
  ssh "$REMOTE" "chmod +x $DEST && $DEST --help | head -5"
  echo "✅ 已安装到 ${REMOTE}:${DEST}"
  exit 0
fi

# ---- 本地安装 ----
need_root() { [ "$(id -u)" -eq 0 ] || { echo "need root" >&2; exit 1; }; }
need_root

# 如果当前目录没有脚本，尝试从 URL 拉（curl 方式）
if [ ! -f "$SRC_NAME" ]; then
  url="${TOOL_URL:-https://your-host/$SRC_NAME}"
  echo "从 $url 下载..."
  curl -fsSL "$url" -o "$SRC_NAME" || { echo "下载失败，请手动下载 $SRC_NAME" >&2; exit 1; }
fi

cp "$SRC_NAME" "$DEST" && chmod +x "$DEST"

# 首次运行 meta + audit + harden
echo
echo "=== 首次执行 ==="
"$DEST" meta
echo
"$DEST" audit
echo
echo "=== 持久防护 harden ==="
"$DEST" harden
echo
echo "=== 验证 ==="
"$DEST" verify
echo
"$DEST" report "/root/处置笔录-$(date +%F).md"
echo
echo "✅ 安装完成。常用命令:"
echo "  $DEST audit"
echo "  $DEST locate / --top 15"
echo "  $DEST emergency"
echo "  $DEST emergency --force"
echo "  $DEST migrate /data"
echo "  $DEST report"
