$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$pass = 0; $fail = 0
function Check($Name, $Ok) {
    if ($Ok) { $script:pass++; Write-Host "[PASS] $Name" }
    else { $script:fail++; Write-Host "[FAIL] $Name" }
}

$start = Get-Content (Join-Path $root 'start.cmd') -Raw
$console = Get-Content (Join-Path $root 'start-console.cmd') -Raw
$vbs = Get-Content (Join-Path $root 'start-tray.vbs') -Raw
$launch = Get-Content (Join-Path $root 'launch.ps1') -Raw
$trayText = Get-Content (Join-Path $root 'tray.ps1') -Raw -Encoding UTF8
$monitorText = Get-Content (Join-Path $root 'monitor.ps1') -Raw -Encoding UTF8
Check 'default launcher validates machine then uses hidden tray entry' ($start -match 'wscript.exe' -and $vbs -match '-WindowStyle Hidden' -and $vbs -match 'launch.ps1' -and $launch -match 'setup.ps1' -and $launch -match 'tray.ps1')
Check 'original console menu remains available' ($console -match 'start-menu.ps1')
Check 'double click opens or restores terminal monitor' ($trayText -match '\$tray\.add_DoubleClick\(\{ Show-Monitor \}\)')
Check 'watcher is launched as independent hidden process' ($trayText -match 'Start-Process[\s\S]+-WindowStyle Hidden -PassThru')
Check 'right click menu stays minimal' ($trayText -match "ToolStripMenuItem\('打开监控窗口'\)" -and $trayText -match "ToolStripMenuItem\('停止看护并退出'\)" -and $trayText -notmatch "ToolStripMenuItem\('查看日志'\)")
Check 'monitor tails important events and opens with mode selection' ($monitorText -match '实时日志' -and $monitorText -match 'Read-NewLogLines' -and $monitorText -match '\[1\] 演习' -and $monitorText -match '\[2\] 正常模式')
Check 'closing monitor is explicitly non-destructive' ($monitorText -match '关闭窗口并收回托盘（不会停止看护）')
Check 'default tray opens unified native dashboard' ($trayText.Contains("`$MonitorFile = Join-Path `$Here 'dashboard.ps1'") -and $trayText -match '\-STA \-ExecutionPolicy' -and $trayText -match 'codex-quota.ico')

$tray = Join-Path $root 'tray.ps1'
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File $tray -SmokeTest | Out-Null
Check 'Windows PowerShell tray message loop starts and exits' ($LASTEXITCODE -eq 0)
$monitor = Join-Path $root 'monitor.ps1'
& powershell -NoProfile -ExecutionPolicy Bypass -File $monitor -SmokeTest | Out-Null
Check 'Windows PowerShell terminal monitor starts and exits' ($LASTEXITCODE -eq 0)
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $root 'dashboard.ps1') -SmokeTest | Out-Null
Check 'Windows PowerShell merged dashboard starts and closes safely' ($LASTEXITCODE -eq 0)
$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($pwsh) {
    & $pwsh.Source -NoProfile -STA -ExecutionPolicy Bypass -File $tray -SmokeTest | Out-Null
    Check 'PowerShell 7 tray message loop starts and exits' ($LASTEXITCODE -eq 0)
    & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $monitor -SmokeTest | Out-Null
    Check 'PowerShell 7 terminal monitor starts and exits' ($LASTEXITCODE -eq 0)
}
Write-Host "通过 $pass 项，失败 $fail 项"
exit $(if ($fail -eq 0) { 0 } else { 1 })
