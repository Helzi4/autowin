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
$RunKey    = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$RunValue  = "DeployStatus"

New-Item -ItemType Directory -Path $DeployDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Log([string]$m) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$ts] $m" -Encoding UTF8
}

function Status([int]$pct, [string]$msg) {
    Log ("| STATUS|{0}|{1}" -f $pct, $msg)
}

function Set-State([string]$s) {
    Set-Content -Path $StateFile -Value $s -Encoding ASCII
}

function Get-State() {
    if (-not (Test-Path $StateFile)) {
        return "WAIT_ASSET"
    }
    return ((Get-Content $StateFile -ErrorAction Stop) | Out-String).Trim()
}

function Read-Cfg() {
    if (-not (Test-Path $CfgFile)) {
        throw "Missing config.json at C:\Deploy\config.json"
    }

    $cfgRaw = Get-Content $CfgFile -Raw -ErrorAction Stop
    $cfg = $cfgRaw | ConvertFrom-Json

    if ([string]::IsNullOrWhiteSpace($cfg.Domain)) {
        throw "config.json: Domain is empty"
    }
    if ([string]::IsNullOrWhiteSpace($cfg.JoinUser)) {
        throw "config.json: JoinUser is empty"
    }
    if ([string]::IsNullOrWhiteSpace($cfg.JoinPass)) {
        throw "config.json: JoinPass is empty"
    }
    if ($null -eq $cfg.OUPath) {
        $cfg | Add-Member -NotePropertyName OUPath -NotePropertyValue ""
    }

    return $cfg
}

function Pending-Reboot() {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )

    foreach ($p in $paths) {
        if (Test-Path $p) {
            return $true
        }
    }

    try {
        $pfro = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue).PendingFileRenameOperations
        if ($pfro) {
            return $true
        }
    } catch {}

    return $false
}

function Wait-ForNetwork([int]$Seconds = 300) {
    $deadline = (Get-Date).AddSeconds($Seconds)

    while ((Get-Date) -lt $deadline) {
        try {
            $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
            if ($adapters) {
                Log "Network link is up"
                return $true
            }
        } catch {}

        Start-Sleep -Seconds 5
    }

    Log "Network wait timeout"
    return $false
}

function Log-DnsServers() {
    try {
        $dns = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.ServerAddresses -and $_.InterfaceAlias } |
            ForEach-Object { "{0}: {1}" -f $_.InterfaceAlias, ($_.ServerAddresses -join ", ") }

        if ($dns) {
            foreach ($line in $dns) {
                Log ("DNS " + $line)
            }
        }
    } catch {}
}

function Wait-ForDomainReady([string]$Domain, [int]$Seconds = 300) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    $srvName = "_ldap._tcp.dc._msdcs.$Domain"
    $attempt = 0

    while ((Get-Date) -lt $deadline) {
        $attempt++
        $dcName = $null
        $dnsOk = $false
        $dcOk = $false

        try {
            $srv = Resolve-DnsName -Name $srvName -Type SRV -ErrorAction Stop |
                Sort-Object Priority, Weight
            if ($srv -and $srv.Count -gt 0) {
                $dcName = $srv[0].NameTarget
                if ($dcName) {
                    $dcName = $dcName.TrimEnd(".")
                    $dnsOk = $true
                }
            }
        } catch {
            Log ("SRV lookup failed for " + $srvName + ": " + $_.Exception.Message)
        }

        if ($dnsOk -and -not [string]::IsNullOrWhiteSpace($dcName)) {
            try {
                if (Get-Command -Name Test-NetConnection -ErrorAction SilentlyContinue) {
                    $test = Test-NetConnection -ComputerName $dcName -Port 389 -WarningAction SilentlyContinue
                    if ($test -and $test.TcpTestSucceeded) {
                        $dcOk = $true
                    }
                } else {
                    $ping = Test-Connection -ComputerName $dcName -Count 1 -Quiet -ErrorAction Stop
                    if ($ping) {
                        $dcOk = $true
                    }
                }
            } catch {
                Log ("DC connectivity check failed for " + $dcName + ": " + $_.Exception.Message)
            }
        }

        if ($dnsOk -and $dcOk) {
            Log ("Domain services ready. DC=" + $dcName)
            return $true
        }

        if ($attempt -eq 1 -or ($attempt % 3) -eq 0) {
            Log ("Waiting for domain services. DNS_OK={0} DC_OK={1} DC={2}" -f $dnsOk, $dcOk, $dcName)
        }

        Start-Sleep -Seconds 10
    }

    Log "Domain services wait timeout"
    return $false
}

function Install-AllUpdates([int]$MaxPasses = 8) {
    Status 35 "Windows Updates: starting"

    [void](Wait-ForNetwork -Seconds 300)

    $pass = 0
    while ($pass -lt $MaxPasses) {
        $pass++
        Status 40 ("Windows Updates: scanning (pass {0}/{1})" -f $pass, $MaxPasses)

        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and IsHidden=0")

        $count = $result.Updates.Count
        Log "WU found: $count"

        if ($count -eq 0) {
            break
        }

        $updatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl

        for ($i = 0; $i -lt $count; $i++) {
            $u = $result.Updates.Item($i)

            if (-not $u.EulaAccepted) {
                $u.AcceptEula() | Out-Null
            }

            [void]$updatesToInstall.Add($u)
        }

        Status 55 ("Windows Updates: downloading {0}" -f $updatesToInstall.Count)
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $updatesToInstall
        $downloader.Download() | Out-Null

        Status 70 ("Windows Updates: installing {0}" -f $updatesToInstall.Count)
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $updatesToInstall
        $installer.ForceQuiet = $true
        $installResult = $installer.Install()

        Log ("WU result={0} rebootRequired={1}" -f $installResult.ResultCode, $installResult.RebootRequired)

        if ($installResult.RebootRequired -or (Pending-Reboot)) {
            Status 75 "Windows Updates: reboot required"
            Restart-Computer -Force
            exit
        }
    }

    Status 80 "Windows Updates: completed"
}

function Join-Domain([string]$Domain, [string]$JoinUser, [string]$JoinPass, [string]$OUPath) {
    Status 85 "Domain join: starting"

    [void](Wait-ForNetwork -Seconds 300)
    Log-DnsServers

    $ready = Wait-ForDomainReady -Domain $Domain -Seconds 300
    if (-not $ready) {
        throw "Domain services are not reachable for $Domain"
    }

    $sec = ConvertTo-SecureString $JoinPass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($JoinUser, $sec)

    $attempt = 0
    while ($attempt -lt 3) {
        $attempt++
        try {
            if ([string]::IsNullOrWhiteSpace($OUPath)) {
                Log ("Add-Computer attempt {0}: joining without OUPath" -f $attempt)
                Add-Computer -DomainName $Domain -Credential $cred -ErrorAction Stop
            } else {
                Log ("Add-Computer attempt {0}: joining with OUPath {1}" -f $attempt, $OUPath)
                Add-Computer -DomainName $Domain -Credential $cred -OUPath $OUPath -ErrorAction Stop
            }

            Log "Add-Computer completed"
            return
        } catch {
            $msg = $_.Exception.Message
            Log ("Add-Computer attempt {0} failed: {1}" -f $attempt, $msg)

            if ($attempt -lt 3) {
                Start-Sleep -Seconds 20
                [void](Wait-ForDomainReady -Domain $Domain -Seconds 120)
            } else {
                throw
            }
        }
    }
}

function GPUpdate-Force() {
    Status 92 "Group Policy: gpupdate /force"
    $p = Start-Process -FilePath "gpupdate.exe" -ArgumentList "/force" -Wait -PassThru
    Log ("gpupdate exitcode=" + $p.ExitCode)
}

function Finish-And-Cleanup() {
    New-Item -Path $DoneFlag -ItemType File -Force | Out-Null
    Log "done.flag created"

    try {
        schtasks /Delete /F /TN $StatTask 2>$null | Out-Null
    } catch {}
    try {
        schtasks /Delete /F /TN $OrchTask 2>$null | Out-Null
    } catch {}

    try {
        reg delete $RunKey /v $RunValue /f 2>$null | Out-Null
        Log "HKLM Run removed: DeployStatus"
    } catch {}

    Log "Scheduled tasks removed"

    $cleanupCmd = 'cmd /c timeout /t 20 /nobreak >nul & rmdir /s /q C:\Deploy & schtasks /delete /f /tn Deploy-Cleanup'
    schtasks /Create /F /TN $CleanTask /SC ONCE /ST 00:00 /RU "SYSTEM" /RL HIGHEST /TR $cleanupCmd | Out-Null
    schtasks /Run /TN $CleanTask | Out-Null

    Log "Cleanup scheduled"
}

try {
    Log ("START state={0} computer={1}" -f (Get-State), $env:COMPUTERNAME)

    if (-not (Test-Path $AssetFile)) {
        Status 5 "Waiting for Asset ID"
        exit
    }

    $cfg = Read-Cfg
    $uid = ((Get-Content $AssetFile -ErrorAction Stop) | Out-String).Trim().ToLower()

    if ($uid -notmatch '^u\d+-\d+x?$') {
        Status 0 "ERROR: Bad asset format in asset.txt"
        Log ("ERROR: Bad asset format in asset.txt: " + $uid)
        exit
    }

    $state = Get-State

    if ($state -eq "WAIT_ASSET") {
        Set-State "NEED_RENAME"
        $state = "NEED_RENAME"
    }

    if ($state -eq "NEED_RENAME") {
        if ($env:COMPUTERNAME.ToLower() -ne $uid) {
            Status 15 "Renaming computer"
            Log ("Renaming from {0} to {1}" -f $env:COMPUTERNAME, $uid)
            Rename-Computer -NewName $uid -Force -ErrorAction Stop
            Restart-Computer -Force
            exit
        }

        Log "Rename OK"
        Set-State "NEED_UPDATES"
        $state = "NEED_UPDATES"
    }

    if ($state -eq "NEED_UPDATES") {
        Install-AllUpdates -MaxPasses 8

        if (Pending-Reboot) {
            Status 75 "Windows Updates: pending reboot"
            Restart-Computer -Force
            exit
        }

        Set-State "NEED_DOMAIN_JOIN"
        $state = "NEED_DOMAIN_JOIN"
    }

    if ($state -eq "NEED_DOMAIN_JOIN") {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop

        if ($cs.PartOfDomain -and ($cs.Domain -ieq $cfg.Domain)) {
            Log "Already in domain"
            Set-State "WAIT_DOMAIN"
            $state = "WAIT_DOMAIN"
        } else {
            Join-Domain -Domain $cfg.Domain -JoinUser $cfg.JoinUser -JoinPass $cfg.JoinPass -OUPath $cfg.OUPath
            Set-State "WAIT_DOMAIN"
            Status 88 "Domain join: rebooting"
            Restart-Computer -Force
            exit
        }
    }

    if ($state -eq "WAIT_DOMAIN") {
        Status 90 "Domain confirmation: checking"

        $confirmed = $false
        $deadline = (Get-Date).AddSeconds(300)

        while ((Get-Date) -lt $deadline) {
            try {
                $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
                if ($cs.PartOfDomain -and ($cs.Domain -ieq $cfg.Domain)) {
                    $confirmed = $true
                    break
                }
            } catch {
                Log ("Domain confirmation error: " + $_.Exception.Message)
            }

            Start-Sleep -Seconds 10
        }

        if ($confirmed) {
            Log "Domain confirmed"
            GPUpdate-Force
            Set-State "DONE"
            $state = "DONE"
        } else {
            Log "Domain not confirmed after reboot, retrying join"
            Set-State "NEED_DOMAIN_JOIN"
            $state = "NEED_DOMAIN_JOIN"

            Join-Domain -Domain $cfg.Domain -JoinUser $cfg.JoinUser -JoinPass $cfg.JoinPass -OUPath $cfg.OUPath
            Set-State "WAIT_DOMAIN"
            Status 88 "Domain join: rebooting"
            Restart-Computer -Force
            exit
        }
    }

    if ($state -eq "DONE") {
        Status 100 "DONE"
        Finish-And-Cleanup
        Log "DONE"
        exit
    }

    Status 0 ("ERROR: Unknown state=" + (Get-State))
    Log ("ERROR: Unknown state=" + (Get-State))
}
catch {
    $msg = $_.Exception.Message
    Status 0 ("ERROR: " + $msg)
    Log ("ERROR: " + $msg)
    throw
}
