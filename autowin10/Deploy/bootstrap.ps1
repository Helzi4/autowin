# C:\Deploy\bootstrap.ps1
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Windows.Forms

$DeployDir = "C:\Deploy"
$AssetFile = "$DeployDir\asset.txt"
$StateFile = "$DeployDir\state.txt"
$CfgFile   = "$DeployDir\config.json"
$SysScript = "$DeployDir\deploy-system.ps1"

$OrchTask  = "Deploy-Orchestrator"
$BootTask  = "Deploy-Bootstrap"
$StatTask  = "Deploy-Status"

function Msg([string]$m, [string]$title="Deploy", [string]$icon="Information") {
  $i = [System.Windows.Forms.MessageBoxIcon]::$icon
  [System.Windows.Forms.MessageBox]::Show($m, $title, [System.Windows.Forms.MessageBoxButtons]::OK, $i) | Out-Null
}

function Fail([string]$m) { Msg $m "Deploy error" "Error"; exit 1 }

if (-not (Test-Path $CfgFile))   { Fail "Missing: C:\Deploy\config.json" }
if (-not (Test-Path $SysScript)) { Fail "Missing: C:\Deploy\deploy-system.ps1" }
if (-not (Test-Path "$DeployDir\status.ps1")) { Fail "Missing: C:\Deploy\status.ps1" }

New-Item -ItemType Directory -Path "$DeployDir\Logs" -Force | Out-Null

# If done.flag exists from old test, remove it (otherwise status window closes instantly)
Remove-Item -Path "$DeployDir\done.flag" -Force -ErrorAction SilentlyContinue

# Ensure Status shows after every reboot/login while deploy is running
try {
  schtasks /Create /F /TN $StatTask /SC ONLOGON /RU "Admin" /RL HIGHEST `
    /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Deploy\status.ps1" | Out-Null
  schtasks /Run /TN $StatTask | Out-Null
} catch {}

# If asset already set, do not ask again
if (Test-Path $AssetFile) {
  $existing = (Get-Content $AssetFile -ErrorAction SilentlyContinue).Trim()
  if ($existing -match '^u\d+-\d+x?$') {
    Msg "Asset already set: $existing`nContinuing deploy." "Deploy"
  } else {
    Remove-Item $AssetFile -Force -ErrorAction SilentlyContinue
  }
}

if (-not (Test-Path $AssetFile)) {
  while ($true) {
    $uid = [Microsoft.VisualBasic.Interaction]::InputBox(
      "Enter u-id (example: u1-1870 or u1-0101x)",
      "Asset ID",
      ""
    )

    if ([string]::IsNullOrWhiteSpace($uid)) { Fail "Asset ID is empty" }

    $uid = $uid.Trim().ToLower()
    if ($uid -notmatch '^u\d+-\d+x?$') {
      [System.Windows.Forms.MessageBox]::Show(
        "Bad u-id format. Example: u1-1870 or u1-0101x",
        "Deploy",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
      ) | Out-Null
      continue
    }

    $ans = [System.Windows.Forms.MessageBox]::Show(
      "u-id: $uid`nConfirm?",
      "Confirm Asset ID",
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { continue }

    Set-Content -Path $AssetFile -Value $uid -Encoding ASCII
    break
  }
}

# State for system script
if (-not (Test-Path $StateFile)) {
  Set-Content -Path $StateFile -Value "NEED_RENAME" -Encoding ASCII
}

# Create SYSTEM task (runs on boot)
$ps = "powershell.exe"
$tr = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$SysScript`""
schtasks /Create /F /TN $OrchTask /SC ONSTART /DELAY 0000:15 /RU "SYSTEM" /RL HIGHEST /TR $tr | Out-Null

# Start now (no need to wait reboot)
schtasks /Run /TN $OrchTask | Out-Null

# Remove fallback bootstrap mechanisms (if they exist)
schtasks /Delete /F /TN $BootTask 2>$null | Out-Null
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v DeployBootstrap /f 2>$null | Out-Null

Msg "Deploy started. Watch 'Deploy Status' window." "Deploy"
