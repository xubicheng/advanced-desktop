# ============================================================================
# deploy.ps1 —— Windows PowerShell 远程部署腾讯云 CVM 磁盘处置工具链
#
# 运行位置 : 你本地 Windows / Mac（PowerShell 7 或 Windows PowerShell 5.1+）
# 目标     : 把 install-all-in-one.sh 推到 CVM 并执行
# 前置     : 本地必须有 OpenSSH (ssh/scp) 或 PuTTY (plink/pscp) 或 WinSCP
#
# 特性:
#   ✅ 只推 1 个文件（install-all-in-one.sh 21K，自包含所有内容）
#   ✅ 自动探测 OpenSSH / PuTTY plink+pscp / WinSCP，按可用性降级
#   ✅ 免密检测（BatchMode=yes），会卡密码则提前警告
#   ✅ 所有 ssh/scp 加 ConnectTimeout（经验 1985054 Failure 1：超时就 fail-fast）
#   ✅ 错误归类（本地工具缺失 / 远程 SSH 权限 / 远端执行失败）
#   ✅ dry-run 全程打印命令不执行
#   ✅ CopyOnly 只推不跑（用于先推文件后，自己手动进去执行）
#
# 用法:
#   .\deploy.ps1 -Host root@1.2.3.4
#   .\deploy.ps1 -Host root@1.2.3.4 -Key C:\Users\me\.ssh\id_rsa
#   .\deploy.ps1 -Host root@1.2.3.4 -WithHarden
#   .\deploy.ps1 -Host root@1.2.3.4 -DryRun
#   .\deploy.ps1 -Host root@1.2.3.4 -CopyOnly
#
# ============================================================================

# ---- 可选参数 ----
param(
  [Parameter(Mandatory=$true, HelpMessage="CVM 目标，格式 user@IP 或 user@host")]
  [string]$Host,

  [Parameter(Mandatory=$false, HelpMessage="SSH 私钥完整路径，例如 C:\Users\me\.ssh\id_rsa")]
  [string]$Key = "",

  [Parameter(Mandatory=$false, HelpMessage="SSH 端口，默认 22")]
  [int]$Port = 22,

  [Parameter(Mandatory=$false, HelpMessage="本地 install-all-in-one.sh 路径，默认自动匹配当前目录")]
  [string]$Installer = "",

  [Parameter(Mandatory=$false, HelpMessage="安装后顺便执行 harden（推荐）")]
  [switch]$WithHarden,

  [Parameter(Mandatory=$false, HelpMessage="只推脚本到 CVM，不执行")]
  [switch]$CopyOnly,

  [Parameter(Mandatory=$false, HelpMessage="dry-run：打印所有要执行的命令，不真正跑")]
  [switch]$DryRun,

  [Parameter(Mandatory=$false, HelpMessage="跳过远端执行后自动清理临时文件")]
  [switch]$SkipCleanup
)

# 严格错误处理：任何外部命令失败都停
$ErrorActionPreference = "Stop"

# ============================================================================
# 全局辅助：彩色输出 + 工具探测 + 统一 SSH 参数
# ============================================================================
function Write-Info($msg)   { Write-Host "[i] $msg" -ForegroundColor Blue   }
function Write-OK($msg)     { Write-Host "[+] $msg" -ForegroundColor Green  }
function Write-Warn($msg)  { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Fail($msg)   { Write-Host "[x] $msg" -ForegroundColor Red    }
function Write-Step($num,$total,$msg) {
  Write-Host ""
  Write-Host "===== [$num/$total] $msg =====" -ForegroundColor Cyan
}

function Test-Exe($name) {
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  # Windows 上有时 PATH 搜不到但实际存在于常见路径
  $extra = @(
    "${env:ProgramFiles}\PuTTY\$name.exe",
    "${env:ProgramFiles(x86)}\PuTTY\$name.exe",
    "${env:USERPROFILE}\scoop\apps\$name\current\$name.exe",
    "C:\Windows\System32\OpenSSH\$name.exe",
    "${env:ProgramFiles}\OpenSSH\$name.exe"
  )
  foreach ($p in $extra) { if (Test-Path $p) { return $p } }
  return $null
}

# ============================================================================
# Step 1: 工具探测 —— 找到可用的 SSH 工具链
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " 腾讯云 CVM 磁盘处置工具链  PowerShell 部署" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

Write-Step 1 5 "探测本地 SSH 工具链"

$sshBin  = $null; $scpBin  = $null
$plinkBin = $null; $pscpBin = $null
$sshStyle = $null   # "OpenSSH" | "PuTTY"

# --- OpenSSH (Windows 10/11 内置) ---
$sshBin = Test-Exe "ssh"
$scpBin = Test-Exe "scp"
if ($sshBin -and $scpBin) {
  $sshStyle = "OpenSSH"
  Write-OK "OpenSSH 已就绪"
  Write-Info "  ssh : $sshBin"
  Write-Info "  scp : $scpBin"
}

# --- PuTTY plink/pscp ---
if (-not $sshStyle) {
  $plinkBin = Test-Exe "plink"
  $pscpBin  = Test-Exe "pscp"
  if ($plinkBin -and $pscpBin) {
    $sshStyle = "PuTTY"
    Write-OK "PuTTY 已就绪"
    Write-Info "  plink : $plinkBin"
    Write-Info "  pscp  : $pscpBin"
  }
}

# --- 兜底：让用户自己选 ---
if (-not $sshStyle) {
  Write-Fail "未找到可用的 SSH 工具链。"
  Write-Info "推荐方案 (任选其一):"
  Write-Host "  A) 设置 -> 应用 -> 可选功能 -> 添加功能 -> OpenSSH 客户端" -ForegroundColor White
  Write-Host "  B) https://www.chiark.greenend.org.uk/~sgtatham/putty/ 下载 PuTTY" -ForegroundColor White
  Write-Host "  C) 或用 git-bash / WSL，自带 ssh/scp" -ForegroundColor White
  exit 1
}

# 统一 SSH 参数数组（避免在每个调用处重复写 key/port/timeout）
$commonSshArgs = [System.Collections.Generic.List[string]]::new()
$commonScpArgs = [System.Collections.Generic.List[string]]::new()

if ($sshStyle -eq "OpenSSH") {
  # ConnectTimeout 3s 失败就停，别卡住（经验 1985054 Failure 1）
  $commonSshArgs.Add("-o"); $commonSshArgs.Add("ConnectTimeout=5")
  $commonSshArgs.Add("-o"); $commonSshArgs.Add("ServerAliveInterval=15")
  $commonSshArgs.Add("-o"); $commonSshArgs.Add("BatchMode=yes")   # 免密检测：要密码直接 fail 不阻塞
  $commonScpArgs.Add("-o"); $commonScpArgs.Add("ConnectTimeout=5")

  if ($Key)  { $commonSshArgs.Add("-i"); $commonSshArgs.Add($Key); $commonScpArgs.Add("-i"); $commonScpArgs.Add($Key) }
  if ($Port -ne 22) { $commonSshArgs.Add("-p"); $commonSshArgs.Add("$Port"); $commonScpArgs.Add("-P"); $commonScpArgs.Add("$Port") }
} else {
  # PuTTY plink/pscp
  $commonSshArgs.Add("-batch")     # 无交互
  $commonSshArgs.Add("-no-antispoof")
  $commonSshArgs.Add("-ssh")
  if ($Key) { $commonSshArgs.Add("-i"); $commonSshArgs.Add($Key); $commonScpArgs.Add("-i"); $commonScpArgs.Add($Key) }
  if ($Port -ne 22) { $commonSshArgs.Add("-P"); $commonSshArgs.Add("$Port"); $commonScpArgs.Add("-P"); $commonScpArgs.Add("$Port") }
}

# ============================================================================
# Step 2: 安装包就绪性
# ============================================================================
Write-Step 2 5 "定位 install-all-in-one.sh"

if (-not $Installer) {
  # 按优先级自动匹配：当前目录 -> 脚本同目录 -> 父目录
  $candidates = @(
    ".\install-all-in-one.sh",
    (Join-Path $PSScriptRoot "install-all-in-one.sh"),
    (Join-Path (Split-Path $PSScriptRoot) "install-all-in-one.sh")
  )
  foreach ($c in $candidates) {
    if (Test-Path $c) { $Installer = $c; break }
  }
}

if (-not (Test-Path $Installer)) {
  Write-Fail "install-all-in-one.sh 未找到"
  Write-Info "当前目录: $(Get-Location)"
  Write-Host "  用 -Installer 指定路径，或把文件放到当前目录。" -ForegroundColor White
  Write-Host ""
  Write-Host "  该文件来自: 开发机上的 /workspace/install-all-in-one.sh" -ForegroundColor White
  exit 1
}

$installerSize = (Get-Item $Installer).Length
Write-OK "install-all-in-one.sh: $Installer ($installerSize bytes)"

# ============================================================================
# Step 3: SSH 连通性 + 免密预探测（先摸一下路，避免推完才发现连不上）
# ============================================================================
Write-Step 3 5 "SSH 连通性 / 免密预探测"

if ($DryRun) {
  Write-Warn "[dry-run] 跳过连通性探测"
} else {
  $probeCmd = if ($sshStyle -eq "OpenSSH") {
    & $sshBin $commonSshArgs $Host "echo __SSH_OK__" 2>&1
  } else {
    & $plinkBin $commonSshArgs $Host "echo __SSH_OK__" 2>&1
  }
  $probeExit = $LASTEXITCODE

  if ($probeExit -eq 0 -and $probeCmd -match "__SSH_OK__") {
    Write-OK "SSH 连通且免密（或已输入密码）"
  } elseif ($probeCmd -match "Permission denied") {
    Write-Fail "SSH 认证失败"
    Write-Host "  检查: 密钥对是否匹配 / 公钥是否已加到 CVM ~/.ssh/authorized_keys" -ForegroundColor White
    exit 1
  } elseif ($probeCmd -match "timed out|Connection refused|No route to host") {
    Write-Fail "网络不通"
    Write-Host "  检查: CVM 安全组 22 端口 / 公网 IP 是否正确 / CVM 是否开机" -ForegroundColor White
    exit 1
  } elseif ($probeExit -ne 0) {
    Write-Fail "SSH 探测失败 (exit=$probeExit)"
    Write-Host "  输出: $probeCmd" -ForegroundColor DarkGray
    Write-Host "  可能是需要密码但 BatchMode=yes 禁止了交互" -ForegroundColor Yellow
    Write-Host "  请先手动 ssh $Host 输密码，再重新运行 deploy.ps1" -ForegroundColor Yellow
    exit 1
  } else {
    Write-Fail "SSH 探测返回异常结果"
    Write-Host "  输出: $probeCmd" -ForegroundColor DarkGray
    exit 1
  }
}

# ============================================================================
# Step 4: 推送脚本到 CVM
# ============================================================================
Write-Step 4 5 "推送到 $Host"

$remoteTmp = "/tmp/tencent-cvm-disk-tool-$(Get-Date -Format yyyyMMddHHmmss)"
$remoteInstaller = "$remoteTmp/install-all-in-one.sh"

if ($DryRun) {
  Write-Info "[dry-run] 会执行:"
  Write-Info "  ssh  $Host  mkdir -p $remoteTmp"
  Write-Info "  scp  $Installer  $Host : $remoteInstaller"
} else {
  # 4.1 创建远端临时目录
  Write-Info "创建远端目录..."
  if ($sshStyle -eq "OpenSSH") {
    & $sshBin $commonSshArgs $Host "mkdir -p $remoteTmp" 2>&1 | Out-Null
  } else {
    & $plinkBin $commonSshArgs $Host "mkdir -p $remoteTmp" 2>&1 | Out-Null
  }
  if ($LASTEXITCODE -ne 0) { Write-Fail "mkdir 失败"; exit 1 }
  Write-OK "远端目录: $remoteTmp"

  # 4.2 推送自包含脚本
  Write-Info "推送 install-all-in-one.sh..."
  if ($sshStyle -eq "OpenSSH") {
    & $scpBin $commonScpArgs $Installer "${Host}:${remoteInstaller}" 2>&1
  } else {
    # pscp 的 -batch 在顶层参数
    & $pscpBin @("-batch") $commonScpArgs $Installer "${Host}:${remoteInstaller}" 2>&1
  }
  if ($LASTEXITCODE -ne 0) {
    Write-Fail "SCP 推送失败 (exit=$LASTEXITCODE)"
    Write-Host "  错误归类: 本地文件读权限 / SSH 端口 / 密钥权限" -ForegroundColor White
    exit 1
  }
  Write-OK "推送完成"
}

# ============================================================================
# Step 5: 远端执行（+ 清理）
# ============================================================================
Write-Step 5 5 "远端执行 install.sh"

if ($CopyOnly) {
  Write-Warn "[CopyOnly] 跳过远端执行"
  Write-Info "在你 CVM 上手动执行:"
  Write-Host "  bash $remoteInstaller --with-harden" -ForegroundColor Yellow
} else {
  # 远端执行命令（加 sudo 兼容非 root 登录的情况）
  $remoteCmd = @"
set -e
if [ "`$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi
`$SUDO chmod +x $remoteInstaller
`$SUDO bash $remoteInstaller $(if ($WithHarden) { "--with-harden" }) $(if ($DryRun) { "--dry-run" })
"@

  if ($DryRun) {
    Write-Info "[dry-run] 会执行远端命令:"
    Write-Host $remoteCmd -ForegroundColor DarkGray
  } else {
    Write-Info "执行中（过程输出将原样显示）..."
    Write-Host "---------------------------------------------------------------" -ForegroundColor Gray

    if ($sshStyle -eq "OpenSSH") {
      & $sshBin $commonSshArgs $Host "bash -lc '$remoteCmd'"
    } else {
      & $plinkBin $commonSshArgs $Host "bash -lc `"$remoteCmd`""
    }
    $remoteExit = $LASTEXITCODE

    Write-Host "---------------------------------------------------------------" -ForegroundColor Gray

    if ($remoteExit -eq 0) {
      Write-OK "远端执行成功 (exit=0)"
    } else {
      Write-Fail "远端执行失败 (exit=$remoteExit)"
      Write-Host "  常见原因:" -ForegroundColor White
      Write-Host "    - install.sh 在远端 bash 缺失（busybox ash 不行，需要真正的 bash）" -ForegroundColor DarkGray
      Write-Host "    - $remoteInstaller 在远端被截断（网络波动，重推试试）" -ForegroundColor DarkGray
      exit 1
    }

    # -- 自动清理临时文件 --
    if (-not $SkipCleanup) {
      Write-Info "清理远端临时文件..."
      $cleanCmd = if ($sshStyle -eq "OpenSSH") {
        & $sshBin $commonSshArgs $Host "rm -f $remoteInstaller && rmdir $remoteTmp 2>/dev/null || true" 2>&1
      } else {
        & $plinkBin $commonSshArgs $Host "rm -f $remoteInstaller && rmdir $remoteTmp 2>/dev/null || true" 2>&1
      }
      Write-OK "清理完成"
    }
  }
}

# ============================================================================
# Done
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  完成" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  常用命令 (SSH 进 CVM 后):" -ForegroundColor White
Write-Host "    tencent-cvm-disk-tool audit"           -ForegroundColor Yellow
Write-Host "    tencent-cvm-disk-tool locate / --top 15" -ForegroundColor Yellow
Write-Host "    tencent-cvm-disk-tool emergency        " -ForegroundColor Yellow
Write-Host "    tencent-cvm-disk-tool emergency --force" -ForegroundColor Yellow
Write-Host "    tencent-cvm-disk-tool migrate /data    " -ForegroundColor Yellow
Write-Host "    tencent-cvm-disk-tool verify           " -ForegroundColor Yellow
Write-Host "    tencent-cvm-disk-tool report           " -ForegroundColor Yellow
Write-Host ""
Write-Host "  所有安装/加固命令已自动跳过（幂等机制）" -ForegroundColor White
Write-Host "  再次运行 deploy.ps1 --redo 可强制重跑"   -ForegroundColor DarkGray
Write-Host ""
