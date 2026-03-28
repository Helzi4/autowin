# C:\Deploy\deploy-system.ps1
$ErrorActionPreference = "Stop"

$DeployDir = "C:\Deploy"
$LogDir    = Join-Path $DeployDir "Logs"
$LogFile   = Join-Path $LogDir "deploy.log"
$AssetFile = Join-Path $DeployDir "asset.txt"
$StateFile = Join-Path $DeployDir "state.txt"
$CfgFile   = Join-Path $DeployDir "config.json"
$DoneFlag  = Join-Path $DeployDir "done.flag"

$OrchTask  = "Deploy-Orchestrator"
$CleanTask = "Deploy-Cleanup"
$StatTask  = "Deploy-Status"

New-Item -ItemType Directory -Path $DeployDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Log([string]$m) {
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Add-Content -Path $LogFile -Value "[$ts] $m" -Encoding UTF8
}
function Status([int]$pct, [string]$msg) {
  Log ("| STATUS|{0}|{1}" -f $pct, $msg)
}
function Set-State([string]$s) { Set-Content -Path $StateFile -Value $s -Encoding ASCII }
function Get-State() {
  if (-not (Test-Path $StateFile)) { return "WAIT_ASSET" }
  (Get-Content $StateFile -ErrorAction Stop).Trim()
}

function Read-Cfg() {
  if (-not (Test-Path $CfgFile)) { throw "Missing config.json at C:\Deploy\config.json" }
  $cfg = Get-Content $CfgFile -Raw -ErrorAction Stop | ConvertFrom-Json
  if ([string]::IsNullOrWhiteSpace($cfg.Domain))   { throw "config.json: Domain is empty" }
  if ([string]::IsNullOrWhiteSpace($cfg.JoinUser)) { throw "config.json: JoinUser is empty" }
  if ([string]::IsNullOrWhiteSpace($cfg.JoinPass)) { throw "config.json: JoinPass is empty" }
  if ($null -eq $cfg.OUPath) { $cfg | Add-Member -NotePropertyName OUPath -NotePropertyValue "" }
  return $cfg
}

function Pending-Reboot() {
  $paths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
  )
  foreach ($p in $paths) { if (Test-Path $p) { return $true } }
  try {
    $pfro = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfro) { return $true }
  } catch {}
  return $false
}

function Wait-ForNetwork([int]$Seconds = 300) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $up = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
      if ($up) { return }
    } catch {}
    Start-Sleep -Seconds 5
  }
}

function Install-AllUpdates([int]$MaxPasses = 8) {
  Status 35 "Windows Updates: starting"
  Wait-ForNetwork -Seconds 300

  $pass = 0
  while ($pass -lt $MaxPasses) {
    $pass++
    Status 40 ("Windows Updates: scanning (pass {0}/{1})" -f $pass, $MaxPasses)

    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result   = $searcher.Search("IsInstalled=0 and IsHidden=0")

    $count = $result.Updates.Count
    Log "WU found: $count"
    if ($count -eq 0) { break }

    $updatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($i=0; $i -lt $count; $i++) {
      $u = $result.Updates.Item($i)
      if (-not $u.EulaAccepted) { $u.AcceptEula() | Out-Null }
      $updatesToInstall.Add($u) | Out-Null
    }

    Status 55 ("Windows Updates: downloading {0}" -f $updatesToInstall.Count)
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $updatesToInstall
    $downloader.Download() | Out-Null

    Status 70 ("Windows Updates: installing {0}" -f $updatesToInstall.Count)
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $updatesToInstall
    $installer.ForceQuiet = $true
    $instRes = $installer.Install()

    Log "WU result=$($instRes.ResultCode) rebootRequired=$($instRes.RebootRequired)"
    if ($instRes.RebootRequired -or (Pending-Reboot)) {
      Status 75 "Windows Updates: reboot required"
      Restart-Computer -Force
      exit
    }
  }

  Status 80 "Windows Updates: completed"
}

function Join-Domain([string]$Domain, [string]$JoinUser, [string]$JoinPass, [string]$OUPath) {
  Status 85 "Domain join: starting"
  Wait-ForNetwork -Seconds 300

  $sec  = ConvertTo-SecureString $JoinPass -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential($JoinUser, $sec)

  if ([string]::IsNullOrWhiteSpace($OUPath)) {
    Add-Computer -DomainName $Domain -Credential $cred -ErrorAction Stop
  } else {
    Add-Computer -DomainName $Domain -Credential $cred -OUPath $OUPath -ErrorAction Stop
  }
}

function GPUpdate-Force() {
  Status 92 "Group Policy: gpupdate /force"
  $p = Start-Process -FilePath "gpupdate.exe" -ArgumentList "/target:computer","/force" -Wait -PassThru
  Log "gpupdate exitcode=$($p.ExitCode)"
}

function Disable-Autologon() {
  $k = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
  Set-ItemProperty -Path $k -Name "AutoAdminLogon" -Value "0" -Type String -Force
  Remove-ItemProperty -Path $k -Name "DefaultPassword" -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $k -Name "DefaultUserName" -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $k -Name "DefaultDomainName" -ErrorAction SilentlyContinue
  Log "Autologon disabled + Winlogon creds cleared"
}

function Finish-And-Cleanup() {
  New-Item -Path $DoneFlag -ItemType File -Force | Out-Null
  schtasks /Delete /F /TN $StatTask 2>$null | Out-Null
  schtasks /Delete /F /TN $OrchTask | Out-Null
  Log "Scheduled task removed: $OrchTask"

  Disable-Autologon

  $cleanupCmd = 'cmd /c timeout /t 30 /nobreak >nul & rmdir /s /q C:\Deploy & schtasks /delete /f /tn Deploy-Cleanup'
  schtasks /Create /F /TN $CleanTask /SC ONCE /ST 00:00 /RU "SYSTEM" /RL HIGHEST /TR $cleanupCmd | Out-Null
  schtasks /Run /TN $CleanTask | Out-Null

  Log "Cleanup scheduled (C:\Deploy will be removed)"
}

try {
  Log "START state=$(Get-State) computer=$env:COMPUTERNAME"

  if (-not (Test-Path $AssetFile)) {
    Status 5 "Waiting for Asset ID"
    exit
  }

  $cfg = Read-Cfg
  $uid = (Get-Content $AssetFile -ErrorAction Stop).Trim().ToLower()

  if ($uid -notmatch '^u\d+-\d+x?$') {
    Status 0 "ERROR: Bad asset format in asset.txt"
    Log "ERROR: Bad asset format in asset.txt: $uid"
    exit
  }

  $state = Get-State

  if ($state -eq "NEED_RENAME") {
    if ($env:COMPUTERNAME.ToLower() -ne $uid) {
      Status 15 "Renaming computer"
      Rename-Computer -NewName $uid -Force
      Restart-Computer -Force
      exit
    }
    Log "Rename OK"
    Set-State "NEED_UPDATES"
  }

  if ((Get-State) -eq "NEED_UPDATES") {
    Install-AllUpdates -MaxPasses 8
    if (Pending-Reboot) {
      Status 75 "Windows Updates: pending reboot"
      Restart-Computer -Force
      exit
    }
    Set-State "NEED_DOMAIN_JOIN"
  }

  if ((Get-State) -eq "NEED_DOMAIN_JOIN") {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain -and ($cs.Domain -ieq $cfg.Domain)) {
      Log "Already in domain"
      Set-State "DONE"
    } else {
      Join-Domain -Domain $cfg.Domain -JoinUser $cfg.JoinUser -JoinPass $cfg.JoinPass -OUPath $cfg.OUPath
      Set-State "WAIT_DOMAIN"
      Status 88 "Domain join: rebooting"
      Restart-Computer -Force
      exit
    }
  }

  if ((Get-State) -eq "WAIT_DOMAIN") {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain -and ($cs.Domain -ieq $cfg.Domain)) {
      Status 90 "Domain confirmed"
      GPUpdate-Force
      Set-State "DONE"
    } else {
      Log "Domain not confirmed yet"
      exit
    }
  }

  if ((Get-State) -eq "DONE") {
    Status 100 "DONE"
    Finish-And-Cleanup
    Log "DONE"
    exit
  }

  Status 0 ("ERROR: Unknown state=" + (Get-State))
  Log ("ERROR: Unknown state=" + (Get-State))

} catch {
  Status 0 ("ERROR: " + $_.Exception.Message)
  Log ("ERROR: " + $_.Exception.Message)
  throw
}
