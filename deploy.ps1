# ============================================================================
# deploy.ps1 —— 本地 PowerShell 远程部署到腾讯云 CVM
# 运行位置 : 你的本地电脑（Windows / Mac）
# 目标    : 把 install.sh + 主脚本 推到 CVM 并执行
#
# 设计要点（来自经验 933170）:
#   - 错误归类：本地工具缺失 / 远程 SSH 权限 / 远程执行失败 分开报
#   - 工具探测：优先系统自带 OpenSSH（ssh/scp），PuTTY 的 plink/pscp 自动 fallback
#   - 步骤可重入：每步独立 try/catch，失败可单独重跑
#   - CVM 上跑 install.sh，而不是在 Windows 侧用 bash 驱动（Failure 1 教训）
#
# 用法:
#   .\deploy.ps1 -Host root@1.2.3.4
#   .\deploy.ps1 -Host root@1.2.3.4 -Key C:\Users\me\id_rsa
#   .\deploy.ps1 -Host root@1.2.3.4 -WithHarden -Src .\tencent-cvm-disk-tool.sh
# ============================================================================

param(
  [Parameter(Mandatory=$true, HelpMessage="CVM 目标，格式 user@IP 或 user@host")]
  [string]$Host,

  [Parameter(Mandatory=$false, HelpMessage="SSH 私钥路径（可选）")]
  [string]$Key = "",

  [Parameter(Mandatory=$false, HelpMessage="SSH 端口，默认 22")]
  [int]$Port = 22,

  [Parameter(Mandatory=$false, HelpMessage="本地 install.sh 路径")]
  [string]$InstallSh = "./install.sh",

  [Parameter(Mandatory=$false, HelpMessage="本地主脚本路径（自动匹配 tencent-cvm-disk-tool.sh）")]
  [string]$MainTool = "",

  [Parameter(Mandatory=$false, HelpMessage="安装后顺便执行 harden")]
  [switch]$WithHarden,

  [Parameter(Mandatory=$false, HelpMessage="只推脚本，不执行")]
  [switch]$CopyOnly,

  [Parameter(Mandatory=$false, HelpMessage="dry-run，打印命令不执行")]
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "===== 腾讯云 CVM 磁盘处置工具链 远程部署 =====" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Step 1: 工具探测（本地 OpenSSH / PuTTY）
# ============================================================================
function Test-Cmd($name) {
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

Write-Host "[1/4] 探测本地工具链" -ForegroundColor Green

$useOpenSsh = Test-Cmd "ssh"
$usePsTool  = Test-Cmd "plink"

if (-not $useOpenSsh -and -not $usePsTool) {
  Write-Host "[x] 未找到 ssh 或 plink（PuTTY）" -ForegroundColor Red
  Write-Host "    Windows 10/11: 设置 -> 可选功能 -> 安装 OpenSSH 客户端"
  Write-Host "    或安装 PuTTY (plink + pscp)"
  exit 1
}

if ($useOpenSsh) {
  Write-Host "    使用 OpenSSH (ssh/scp)"
  $sshBin = "ssh"; $scpBin = "scp"
  $keyArg = if ($Key) { "-i", $Key } else { @() }
  $portArg = if ($Port -ne 22) { "-p", $Port } else { @() }
} else {
  Write-Host "    使用 PuTTY (plink/pscp)"
  $sshBin = "plink"; $scpBin = "pscp"
  $keyArg = if ($Key) { "-i", $Key } else { @() }
  $portArg = if ($Port -ne 22) { "-P", $Port } else { @() }
}

# ============================================================================
# Step 2: 本地脚本就绪性
# ============================================================================
Write-Host ""
Write-Host "[2/4] 本地脚本就绪性" -ForegroundColor Green

if (-not (Test-Path $InstallSh)) {
  Write-Host "[x] install.sh 未找到: $InstallSh" -ForegroundColor Red
  Write-Host "    请先把 install.sh 放到当前目录"
  exit 1
}
Write-Host "    install.sh: OK"

if (-not $MainTool) {
  # 自动匹配
  $MainTool = Join-Path (Split-Path $InstallSh) "tencent-cvm-disk-tool.sh"
}
if (Test-Path $MainTool) {
  Write-Host "    主脚本:     OK ($MainTool)"
} else {
  Write-Host "    主脚本:     未找到（install.sh 会尝试从 TOOL_BASE_URL 下载）" -ForegroundColor Yellow
  Write-Host "                或用 -Src 指定路径"
  $MainTool = ""
}

# ============================================================================
# Step 3: 推送
# ============================================================================
Write-Host ""
Write-Host "[3/4] 推送到 $Host" -ForegroundColor Green

$remoteTmp = "/tmp/tencent-cvm-disk-tool-$(Get-Date -Format yyyyMMddHHmmss)"

if ($DryRun) {
  Write-Host "    [dry-run] 会创建目录: $remoteTmp"
  Write-Host "    [dry-run] 会推 install.sh"
  if ($MainTool) { Write-Host "    [dry-run] 会推 $MainTool" }
} else {
  # 先在远端创建目录
  Write-Host "    创建远端临时目录..."
  & $sshBin @portArg @keyArg $Host "mkdir -p $remoteTmp" 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[x] SSH 连接失败，退出码 $LASTEXITCODE" -ForegroundColor Red
    Write-Host "    错误归类：本地工具缺失 / 远程 SSH 权限 / 网络"
    Write-Host "    试试手动 ssh $Host 看能否连通"
    exit 1
  }

  # 推 install.sh
  Write-Host "    推送 install.sh..."
  & $scpBin @portArg @keyArg $InstallSh "${Host}:${remoteTmp}/install.sh" 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[x] SCP install.sh 失败" -ForegroundColor Red; exit 1
  }

  # 推主脚本（如果有）
  if ($MainTool) {
    Write-Host "    推送 tencent-cvm-disk-tool.sh..."
    & $scpBin @portArg @keyArg $MainTool "${Host}:${remoteTmp}/tencent-cvm-disk-tool.sh" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "[x] SCP 主脚本失败" -ForegroundColor Red; exit 1
    }
  }
}

# ============================================================================
# Step 4: 远端执行 install.sh
# ============================================================================
if (-not $CopyOnly) {
  Write-Host ""
  Write-Host "[4/4] 远端执行 install.sh" -ForegroundColor Green

  $remoteCmd = "bash $remoteTmp/install.sh"
  if ($MainTool) { $remoteCmd += " --src $remoteTmp/tencent-cvm-disk-tool.sh" }
  if ($WithHarden) { $remoteCmd += " --with-harden" }
  if ($DryRun)     { $remoteCmd += " --dry-run" }

  Write-Host "    命令: $remoteCmd" -ForegroundColor DarkGray
  if (-not $DryRun) {
    & $sshBin @portArg @keyArg $Host $remoteCmd 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Host "[x] 远端执行失败，退出码 $LASTEXITCODE" -ForegroundColor Red
      Write-Host "    错误归类: install.sh 参数错误 / 远端 bash 缺失 / 网络下载失败"
      exit 1
    }
  }
} else {
  Write-Host ""
  Write-Host "[4/4] CopyOnly，跳过远端执行" -ForegroundColor Yellow
}

# ============================================================================
# Done
# ============================================================================
Write-Host ""
Write-Host "===== 完成 =====" -ForegroundColor Cyan
Write-Host "  远端临时目录: $remoteTmp（可清理: ssh $Host rm -rf $remoteTmp）"
Write-Host "  常用命令: ssh $Host '/usr/local/bin/tencent-cvm-disk-tool audit'"
Write-Host ""
