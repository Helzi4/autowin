# C:\Deploy\status.ps1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$logPath  = "C:\Deploy\Logs\deploy.log"
$doneFlag = "C:\Deploy\done.flag"

New-Item -ItemType Directory -Path "C:\Deploy\Logs" -Force | Out-Null

$form = New-Object Windows.Forms.Form
$form.Text = "Deploy Status"
$form.Size = New-Object Drawing.Size(920,540)
$form.StartPosition = "CenterScreen"
$form.TopMost = $true

$lbl = New-Object Windows.Forms.Label
$lbl.AutoSize = $false
$lbl.Location = New-Object Drawing.Point(15,15)
$lbl.Size = New-Object Drawing.Size(870,40)
$lbl.Font = New-Object Drawing.Font("Segoe UI", 14, [Drawing.FontStyle]::Bold)
$lbl.Text = "Waiting..."
$form.Controls.Add($lbl)

$bar = New-Object Windows.Forms.ProgressBar
$bar.Location = New-Object Drawing.Point(15,65)
$bar.Size = New-Object Drawing.Size(870,20)
$bar.Minimum = 0
$bar.Maximum = 100
$bar.Value = 0
$form.Controls.Add($bar)

$box = New-Object Windows.Forms.TextBox
$box.Location = New-Object Drawing.Point(15,95)
$box.Size = New-Object Drawing.Size(870,390)
$box.Multiline = $true
$box.ScrollBars = "Vertical"
$box.ReadOnly = $true
$box.Font = New-Object Drawing.Font("Consolas", 9)
$form.Controls.Add($box)

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000

function Get-LastStatusLine {
  if (-not (Test-Path $logPath)) { return $null }
  $lines = Get-Content $logPath -ErrorAction SilentlyContinue
  if (-not $lines) { return $null }
  ($lines | Where-Object { $_ -match '\| STATUS\|' } | Select-Object -Last 1)
}

$timer.Add_Tick({
  if (Test-Path $doneFlag) {
    $timer.Stop()
    $form.Close()
    return
  }

  if (Test-Path $logPath) {
    $tail = Get-Content $logPath -Tail 250 -ErrorAction SilentlyContinue
    if ($tail) { $box.Lines = $tail }
  }

  $s = Get-LastStatusLine
  if ($s) {
    # [time] | STATUS|<percent>|<message>
    $parts = $s -split '\| STATUS\|',2
    if ($parts.Count -eq 2) {
      $rest = $parts[1].Trim()
      $p2 = $rest -split '\|',2
      if ($p2.Count -eq 2) {
        $pct = 0
        [int]::TryParse($p2[0], [ref]$pct) | Out-Null
        $msg = $p2[1]
        $lbl.Text = $msg
        if ($pct -ge 0 -and $pct -le 100) { $bar.Value = $pct }
      }
    }
  }
})

$timer.Start()
[void]$form.ShowDialog()
