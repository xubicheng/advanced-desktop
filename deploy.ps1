# ============================================================================
# deploy.ps1 - PowerShell remote deployer for Tencent Cloud CVM disk toolchain
#
# Runs on: Windows PowerShell 5.1+ / PowerShell 7 (Win / Mac / Linux)
# Deploys: install-all-in-one.sh to target CVM, then executes it
#
# Requirements on local machine:
#   - OpenSSH Client (ssh + scp)   OR   PuTTY (plink + pscp)
#
# Usage:
#   .\deploy.ps1 -Host ubuntu@129.211.170.72
#   .\deploy.ps1 -Host root@1.2.3.4 -Key C:\Users\me\.ssh\id_rsa -WithHarden
#   .\deploy.ps1 -Host root@1.2.3.4 -DryRun
#   .\deploy.ps1 -Host root@1.2.3.4 -CopyOnly
#
# NOTE: This file MUST be saved as UTF-8 WITH BOM or pure ASCII.
#       PowerShell 5.1 on Chinese Windows defaults to GBK; UTF-8 without BOM
#       will cause parser errors on any non-ASCII character.
# ============================================================================

param(
  [Parameter(Mandatory=$true)]
  [string]$Host,

  [Parameter(Mandatory=$false)]
  [string]$Key = "",

  [Parameter(Mandatory=$false)]
  [int]$Port = 22,

  [Parameter(Mandatory=$false)]
  [string]$Installer = "",

  [Parameter(Mandatory=$false)]
  [switch]$WithHarden,

  [Parameter(Mandatory=$false)]
  [switch]$CopyOnly,

  [Parameter(Mandatory=$false)]
  [switch]$DryRun,

  [Parameter(Mandatory=$false)]
  [switch]$SkipCleanup
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Output helpers
# ============================================================================
function Write-Info($msg)  { Write-Host "[i] $msg"  -ForegroundColor Blue   }
function Write-OK($msg)    { Write-Host "[+] $msg"  -ForegroundColor Green  }
function Write-Warn($msg)  { Write-Host "[!] $msg"  -ForegroundColor Yellow }
function Write-Fail($msg)  { Write-Host "[x] $msg"  -ForegroundColor Red    }
function Write-Step($n,$t,$m) {
  Write-Host ""
  Write-Host "===== [$n/$t] $m =====" -ForegroundColor Cyan
}

# ============================================================================
# Cross-path exe probe (Windows PATH often misses OpenSSH dir)
# ============================================================================
function Test-Exe($name) {
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
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
# Banner
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Tencent CVM Disk Toolchain  PowerShell Deploy" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# ============================================================================
# Step 1 - Probe local SSH toolchain (OpenSSH preferred, PuTTY fallback)
# ============================================================================
Write-Step 1 5 "Probe local SSH toolchain"

$sshBin  = $null; $scpBin  = $null
$plinkBin = $null; $pscpBin = $null
$sshStyle = $null   # "OpenSSH" | "PuTTY"

# --- OpenSSH ---
$sshBin = Test-Exe "ssh"
$scpBin = Test-Exe "scp"
if ($sshBin -and $scpBin) {
  $sshStyle = "OpenSSH"
  Write-OK "OpenSSH ready"
  Write-Info "  ssh : $sshBin"
  Write-Info "  scp : $scpBin"
}

# --- PuTTY fallback ---
if (-not $sshStyle) {
  $plinkBin = Test-Exe "plink"
  $pscpBin  = Test-Exe "pscp"
  if ($plinkBin -and $pscpBin) {
    $sshStyle = "PuTTY"
    Write-OK "PuTTY ready"
    Write-Info "  plink : $plinkBin"
    Write-Info "  pscp  : $pscpBin"
  }
}

if (-not $sshStyle) {
  Write-Fail "No SSH toolchain found."
  Write-Host ""
  Write-Host "  Option A: Settings > Apps > Optional features > Add feature > OpenSSH Client" -ForegroundColor White
  Write-Host "  Option B: https://www.chiark.greenend.org.uk/~sgtatham/putty/ download PuTTY" -ForegroundColor White
  Write-Host "  Option C: Use git-bash or WSL, they include ssh/scp" -ForegroundColor White
  exit 1
}

# Build shared arg arrays
$commonSshArgs = [System.Collections.Generic.List[string]]::new()
$commonScpArgs = [System.Collections.Generic.List[string]]::new()

if ($sshStyle -eq "OpenSSH") {
  # fail-fast on timeout (avoid stuck on network)
  $commonSshArgs.Add("-o"); $commonSshArgs.Add("ConnectTimeout=5")
  $commonSshArgs.Add("-o"); $commonSshArgs.Add("ServerAliveInterval=15")
  $commonSshArgs.Add("-o"); $commonSshArgs.Add("BatchMode=yes")   # no password prompt blocking
  $commonScpArgs.Add("-o"); $commonScpArgs.Add("ConnectTimeout=5")

  if ($Key)  { $commonSshArgs.Add("-i"); $commonSshArgs.Add($Key); $commonScpArgs.Add("-i"); $commonScpArgs.Add($Key) }
  if ($Port -ne 22) { $commonSshArgs.Add("-p"); $commonSshArgs.Add("$Port"); $commonScpArgs.Add("-P"); $commonScpArgs.Add("$Port") }
} else {
  $commonSshArgs.Add("-batch")
  $commonSshArgs.Add("-no-antispoof")
  if ($Key) { $commonSshArgs.Add("-i"); $commonSshArgs.Add($Key); $commonScpArgs.Add("-i"); $commonScpArgs.Add($Key) }
  if ($Port -ne 22) { $commonSshArgs.Add("-P"); $commonSshArgs.Add("$Port"); $commonScpArgs.Add("-P"); $commonScpArgs.Add("$Port") }
}

# ============================================================================
# Step 2 - Locate install-all-in-one.sh
# ============================================================================
Write-Step 2 5 "Locate install-all-in-one.sh"

if (-not $Installer) {
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
  Write-Fail "install-all-in-one.sh not found"
  Write-Info "Current dir: $(Get-Location)"
  Write-Host "  Use -Installer to specify path, or place the file in current dir." -ForegroundColor White
  Write-Host ""
  Write-Host "  Get this file from: /workspace/install-all-in-one.sh on the dev machine." -ForegroundColor White
  exit 1
}

$instSize = (Get-Item $Installer).Length
Write-OK "install-all-in-one.sh: $Installer ($instSize bytes)"

# ============================================================================
# Step 3 - SSH connectivity + auth probe (touch the road first)
# ============================================================================
Write-Step 3 5 "SSH connectivity / auth probe"

if ($DryRun) {
  Write-Warn "[dry-run] skipping probe"
} else {
  $probeOut = if ($sshStyle -eq "OpenSSH") {
    & $sshBin $commonSshArgs $Host "echo __SSH_OK__" 2>&1
  } else {
    & $plinkBin $commonSshArgs $Host "echo __SSH_OK__" 2>&1
  }
  $probeExit = $LASTEXITCODE

  if ($probeExit -eq 0 -and $probeOut -match "__SSH_OK__") {
    Write-OK "SSH connected and authenticated"
  } elseif ($probeOut -match "Permission denied") {
    Write-Fail "SSH auth failed"
    Write-Host "  Check: key pair match? Public key in CVM ~/.ssh/authorized_keys?" -ForegroundColor White
    exit 1
  } elseif ($probeOut -match "timed out|Connection refused|No route to host") {
    Write-Fail "Network unreachable"
    Write-Host "  Check: CVM security group open 22? Public IP correct? CVM powered on?" -ForegroundColor White
    exit 1
  } elseif ($probeExit -ne 0) {
    Write-Fail "SSH probe failed (exit=$probeExit)"
    Write-Host "  Output: $probeOut" -ForegroundColor DarkGray
    Write-Host "  Likely: key-based auth not set up, BatchMode blocked password prompt." -ForegroundColor Yellow
    Write-Host "  Try first: ssh $Host  # manually input password once, then rerun deploy.ps1" -ForegroundColor Yellow
    exit 1
  } else {
    Write-Fail "SSH probe returned unexpected result"
    Write-Host "  Output: $probeOut" -ForegroundColor DarkGray
    exit 1
  }
}

# ============================================================================
# Step 4 - Push installer to CVM
# ============================================================================
Write-Step 4 5 "Push to $Host"

$remoteTmp = "/tmp/tencent-cvm-disk-tool-$(Get-Date -Format yyyyMMddHHmmss)"
$remoteInst = "$remoteTmp/install-all-in-one.sh"

if ($DryRun) {
  Write-Info "[dry-run] would run:"
  Write-Info "  ssh  $Host  mkdir -p $remoteTmp"
  Write-Info "  scp  $Installer  $Host : $remoteInst"
} else {
  # 4.1 Create remote dir
  Write-Info "Creating remote temp dir..."
  if ($sshStyle -eq "OpenSSH") {
    & $sshBin $commonSshArgs $Host "mkdir -p $remoteTmp" 2>&1 | Out-Null
  } else {
    & $plinkBin $commonSshArgs $Host "mkdir -p $remoteTmp" 2>&1 | Out-Null
  }
  if ($LASTEXITCODE -ne 0) { Write-Fail "mkdir failed"; exit 1 }
  Write-OK "Remote dir: $remoteTmp"

  # 4.2 SCP the single self-contained installer
  Write-Info "Pushing install-all-in-one.sh..."
  if ($sshStyle -eq "OpenSSH") {
    & $scpBin $commonScpArgs $Installer "${Host}:${remoteInst}" 2>&1
  } else {
    & $pscpBin @("-batch") $commonScpArgs $Installer "${Host}:${remoteInst}" 2>&1
  }
  if ($LASTEXITCODE -ne 0) {
    Write-Fail "SCP push failed (exit=$LASTEXITCODE)"
    Write-Host "  Categories: local file permission / SSH port / key permission" -ForegroundColor White
    exit 1
  }
  Write-OK "Push done"
}

# ============================================================================
# Step 5 - Execute remotely (+ cleanup)
# ============================================================================
Write-Step 5 5 "Execute on CVM"

if ($CopyOnly) {
  Write-Warn "[CopyOnly] skipping remote execute"
  Write-Info "Run this manually on CVM:"
  Write-Host "  bash $remoteInst --with-harden" -ForegroundColor Yellow
} else {
  $remoteCmd = @"
set -e
if [ "`$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi
`$SUDO chmod +x $remoteInst
`$SUDO bash $remoteInst $(if ($WithHarden) { "--with-harden" }) $(if ($DryRun) { "--dry-run" })
"@

  if ($DryRun) {
    Write-Info "[dry-run] would execute remotely:"
    Write-Host $remoteCmd -ForegroundColor DarkGray
  } else {
    Write-Info "Running (live output follows)..."
    Write-Host "---------------------------------------------------------------" -ForegroundColor Gray

    if ($sshStyle -eq "OpenSSH") {
      & $sshBin $commonSshArgs $Host "bash -lc '$remoteCmd'"
    } else {
      & $plinkBin $commonSshArgs $Host "bash -lc `"$remoteCmd`""
    }
    $remoteExit = $LASTEXITCODE

    Write-Host "---------------------------------------------------------------" -ForegroundColor Gray

    if ($remoteExit -eq 0) {
      Write-OK "Remote execution success (exit=0)"
    } else {
      Write-Fail "Remote execution failed (exit=$remoteExit)"
      Write-Host "  Common causes:" -ForegroundColor White
      Write-Host "    - bash missing on target (busybox ash won't work, need real bash)" -ForegroundColor DarkGray
      Write-Host "    - $remoteInst truncated in transit (retry push)" -ForegroundColor DarkGray
      exit 1
    }

    # cleanup
    if (-not $SkipCleanup) {
      Write-Info "Cleaning up remote temp files..."
      if ($sshStyle -eq "OpenSSH") {
        & $sshBin $commonSshArgs $Host "rm -f $remoteInst && rmdir $remoteTmp 2>/dev/null || true" 2>&1 | Out-Null
      } else {
        & $plinkBin $commonSshArgs $Host "rm -f $remoteInst && rmdir $remoteTmp 2>/dev/null || true" 2>&1 | Out-Null
      }
      Write-OK "Cleanup done"
    }
  }
}

# ============================================================================
# Done
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Done" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Useful commands (SSH into CVM first):" -ForegroundColor White
Write-Host "    tencent-cvm-disk-tool audit"              -ForegroundColor Yellow
Write-Host "    tencent-cvm-disk-tool locate / --top 15"  -ForegroundColor Yellow
Write-Host "    tencent-cvm-disk-tool emergency"          -ForegroundColor Yellow
Write-Host "    tencent-cvm-disk-tool emergency --force"  -ForegroundColor Yellow
Write-Host "    tencent-cvm-disk-tool migrate /data"      -ForegroundColor Yellow
Write-Host "    tencent-cvm-disk-tool verify"             -ForegroundColor Yellow
Write-Host "    tencent-cvm-disk-tool report"             -ForegroundColor Yellow
Write-Host ""
Write-Host "  All install/harden steps are idempotent." -ForegroundColor DarkGray
Write-Host ""
