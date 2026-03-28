# C:\Deploy\bootstrap.ps1
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Windows.Forms

$DeployDir  = "C:\Deploy"
$LogDir     = Join-Path $DeployDir "Logs"
$LogFile    = Join-Path $LogDir "deploy.log"

$AssetFile  = Join-Path $DeployDir "asset.txt"
$StateFile  = Join-Path $DeployDir "state.txt"
$CfgFile    = Join-Path $DeployDir "config.json"
$SysScript  = Join-Path $DeployDir "deploy-system.ps1"
$StatScript = Join-Path $DeployDir "status.ps1"
$DoneFlag   = Join-Path $DeployDir "done.flag"

$OrchTask   = "Deploy-Orchestrator"
$BootTask   = "Deploy-Bootstrap"
$RunKey     = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$RunValue   = "DeployStatus"
$StatusCmd  = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Deploy\status.ps1"'

function Log([string]$m) {
    try {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $LogFile -Value "[$ts] [BOOTSTRAP] $m" -Encoding UTF8
    } catch {}
}

function Msg([string]$m, [string]$title, [string]$iconName) {
    $icon = [System.Windows.Forms.MessageBoxIcon]::$iconName
    [System.Windows.Forms.MessageBox]::Show(
        $m,
        $title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $icon
    ) | Out-Null
}

function Fail([string]$m) {
    Log ("ERROR: " + $m)
    Msg $m "Deploy error" "Error"
    exit 1
}

function Ask-AssetId() {
    while ($true) {
        $uid = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Enter u-id (example: u1-1870 or u1-0101x)",
            "Asset ID",
            ""
        )

        if ($null -eq $uid) {
            $uid = ""
        }

        $uid = $uid.Trim().ToLower()

        if ([string]::IsNullOrWhiteSpace($uid)) {
            $ansEmpty = [System.Windows.Forms.MessageBox]::Show(
                "Asset ID is empty. Try again?",
                "Deploy",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($ansEmpty -eq [System.Windows.Forms.DialogResult]::Yes) {
                continue
            }
            Fail "Asset ID is empty"
        }

        if ($uid -notmatch '^u\d+-\d+x?$') {
            [System.Windows.Forms.MessageBox]::Show(
                "Bad u-id format.`r`nExample: u1-1870 or u1-0101x",
                "Deploy",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            continue
        }

        $ans = [System.Windows.Forms.MessageBox]::Show(
            "u-id: $uid`r`nConfirm?",
            "Confirm Asset ID",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            return $uid
        }
    }
}

try {
    New-Item -ItemType Directory -Path $DeployDir -Force | Out-Null
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

    Log "Bootstrap started"

    if (-not (Test-Path $CfgFile))    { Fail "Missing: C:\Deploy\config.json" }
    if (-not (Test-Path $SysScript))  { Fail "Missing: C:\Deploy\deploy-system.ps1" }
    if (-not (Test-Path $StatScript)) { Fail "Missing: C:\Deploy\status.ps1" }

    Remove-Item -Path $DoneFlag -Force -ErrorAction SilentlyContinue

    reg add $RunKey /v $RunValue /t REG_SZ /d $StatusCmd /f | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Log "HKLM Run added: DeployStatus"
    } else {
        Log "ERROR: Failed to add HKLM Run DeployStatus"
    }

    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Deploy\status.ps1"' | Out-Null
        Log "Deploy-Status started"
    } catch {
        Log ("ERROR: Failed to start Deploy-Status: " + $_.Exception.Message)
    }

    $uid = $null

    if (Test-Path $AssetFile) {
        try {
            $existing = ((Get-Content $AssetFile -ErrorAction Stop) | Out-String).Trim().ToLower()
        } catch {
            $existing = ""
        }

        if ($existing -match '^u\d+-\d+x?$') {
            $uid = $existing
            Log ("Existing asset detected: " + $uid)
            Msg ("Asset already set: " + $uid + "`r`nContinuing deploy.") "Deploy" "Information"
        } else {
            Remove-Item -Path $AssetFile -Force -ErrorAction SilentlyContinue
            Log "Invalid existing asset.txt removed"
        }
    }

    if ([string]::IsNullOrWhiteSpace($uid)) {
        $uid = Ask-AssetId
        Set-Content -Path $AssetFile -Value $uid -Encoding ASCII
        Log ("Asset saved: " + $uid)
    }

    if (-not (Test-Path $StateFile)) {
        Set-Content -Path $StateFile -Value "NEED_RENAME" -Encoding ASCII
        Log "state.txt created: NEED_RENAME"
    } else {
        try {
            $existingState = ((Get-Content $StateFile -ErrorAction Stop) | Out-String).Trim()
        } catch {
            $existingState = ""
        }
        Log ("state.txt already exists: " + $existingState)
    }

    try {
        schtasks /Delete /F /TN $OrchTask 2>$null | Out-Null
    } catch {}

    $ps = "powershell.exe"
    $tr = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$SysScript`""

    schtasks /Create /F /TN $OrchTask /SC ONSTART /DELAY 0000:15 /RU "SYSTEM" /RL HIGHEST /TR $tr | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Log "Scheduled task created: Deploy-Orchestrator"
    } else {
        Fail "Failed to create Deploy-Orchestrator"
    }

    schtasks /Run /TN $OrchTask | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Log "Deploy-Orchestrator started"
    } else {
        Fail "Failed to run Deploy-Orchestrator"
    }

    try {
        schtasks /Delete /F /TN $BootTask 2>$null | Out-Null
        Log "Fallback task removed: Deploy-Bootstrap"
    } catch {}

    try {
        reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v DeployBootstrap /f 2>$null | Out-Null
        Log "RunOnce fallback removed: DeployBootstrap"
    } catch {}

    Msg "Deploy started. Watch 'Deploy Status' window." "Deploy" "Information"
    Log "Bootstrap finished successfully"
}
catch {
    $msg = $_.Exception.Message
    Log ("ERROR: " + $msg)
    Msg $msg "Deploy error" "Error"
    throw
}
