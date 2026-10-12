# Runs the real tray/monitor against a harmless watcher in an isolated temp directory.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-menu-flow-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp,(Join-Path $tmp 'state'),(Join-Path $tmp 'logs') -Force|Out-Null
$pass=0;$fail=0;$trayProcess=$null
$testCompleted=$false
function Check($Name,$Ok){if($Ok){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Wait-For($Condition){$deadline=(Get-Date).AddSeconds(12);do{if(& $Condition){return};Start-Sleep -Milliseconds 100}while((Get-Date)-lt $deadline);throw 'Timed out waiting for test condition'}
function Test-Procs($Leaf) {
    $pattern='(?i)-File\s+"?'+[regex]::Escape((Join-Path $tmp $Leaf))+'"?(?:\s|$)'
    return @(Get-CimInstance Win32_Process|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -match $pattern})
}
try {
    $enc=New-Object Text.UTF8Encoding($true)
    $tray=Get-Content (Join-Path $root 'tray.ps1') -Raw -Encoding UTF8
    $tray=$tray.Replace('Local\CodexQuotaAutopilotTray', 'Local\QuotaFlowTray-'+[guid]::NewGuid().ToString('N'))
    $tray=$tray.Replace("'dashboard.ps1'", "'monitor.ps1'") # Legacy console fallback still supported.
    $tray=$tray.Replace("if (-not (Test-Csw)) { throw 'Codex Switch 尚未运行，请先启动它' }", '# test fixture: no account service')
    $tray=$tray.Replace('-WorkingDirectory $Here | Out-Null','-WorkingDirectory $Here -WindowStyle Hidden | Out-Null')
    [IO.File]::WriteAllText((Join-Path $tmp 'tray.ps1'),$tray,$enc)
    $monitor=Get-Content (Join-Path $root 'monitor.ps1') -Raw -Encoding UTF8
    $monitor=$monitor.Replace('Local\CodexQuotaAutopilotMonitor','Local\QuotaFlowMonitor-'+[guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText((Join-Path $tmp 'monitor.ps1'),$monitor,$enc)
    Copy-Item (Join-Path $root 'codex-autopilot.ps1') (Join-Path $tmp 'watcher-library.ps1')
    Copy-Item (Join-Path $root 'lib') (Join-Path $tmp 'lib') -Recurse
    $stub=@'
param([switch]$Live,[switch]$DryRun)
. (Join-Path $PSScriptRoot 'watcher-library.ps1') -LibraryOnly -Live:$Live
Initialize-Paths
Initialize-TrayControl
$deadline=(Get-Date).AddMinutes(3)
while((Get-Date) -lt $deadline) {
    Write-File 'ROUTINE_POLL_MUST_NOT_APPEAR'
    $signal=Join-Path $PSScriptRoot 'event.txt'
    if(Test-Path $signal){
        $message=Get-Content $signal -Raw -Encoding UTF8
        Remove-Item -LiteralPath $signal
        Write-Event $message 'OK'
    }
    Start-Sleep -Milliseconds 100
}
'@
    [IO.File]::WriteAllText((Join-Path $tmp 'codex-autopilot.ps1'),$stub,$enc)
    Set-Content (Join-Path $tmp 'logs\watch.log') 'OLD_HISTORY_MUST_NOT_APPEAR' -Encoding UTF8
    $trayProcess=Start-Process powershell -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "'+(Join-Path $tmp 'tray.ps1')+'"') -WindowStyle Hidden -PassThru
    Wait-For { @(Test-Procs 'monitor.ps1').Count -eq 1 }
    Check 'launch opens menu without starting watcher' (@(Test-Procs 'codex-autopilot.ps1').Count -eq 0)
    . (Join-Path $tmp 'monitor.ps1') -LibraryOnly -SmokeTest
    $menu=(Show-Menu 6>&1|Out-String)
    Check 'initial menu has normal mode and no historical logs' ($menu -match '\[2\] 正常模式' -and $menu -notmatch 'OLD_HISTORY|最近汇报|本次运行的重要事件')
    Invoke-MonitorKey 'D2' 6>$null
    Wait-For { $null -ne (Get-MonitorRun) }
    $first=Get-MonitorRun
    Check 'choosing 2 launches one normal watcher' ($first.mode -eq '正常模式' -and @(Test-Procs 'codex-autopilot.ps1').Count -eq 1)
    $display=(Update-Monitor 6>&1|Out-String)
    Check 'running screen excludes routine and previous logs' ($display -match '本次运行的重要事件' -and $display -notmatch 'ROUTINE_POLL|OLD_HISTORY')
    Check 'new run clears previous diagnostic log' ((Get-Content (Join-Path $tmp 'logs\watch.log') -Raw) -notmatch 'OLD_HISTORY')
    [IO.File]::WriteAllText((Join-Path $tmp 'event.tmp'),'已切换账号并正常继续 FIRST_EVENT',$enc)
    Move-Item -LiteralPath (Join-Path $tmp 'event.tmp') -Destination (Join-Path $tmp 'event.txt')
    Wait-For { (Get-Content $first.eventFile -Raw) -match 'FIRST_EVENT' }
    $event=(Update-Monitor 6>&1|Out-String)
    Check 'important event appears in running screen' ($event -match 'FIRST_EVENT')
    $quiet=(Update-Monitor 6>&1|Out-String)
    Check 'ordinary refresh emits no repeated messages' ([string]::IsNullOrWhiteSpace($quiet))
    foreach($m in @(Test-Procs 'monitor.ps1')){Stop-Process -Id $m.ProcessId -Force}
    Check 'closing window leaves identical watcher process alive' ((Get-MonitorRun).pid -eq $first.pid)
    [IO.File]::WriteAllText((Join-Path $tmp 'event.tmp'),'窗口关闭期间发生了切号 CLOSED_WINDOW_EVENT',$enc)
    Move-Item -LiteralPath (Join-Path $tmp 'event.tmp') -Destination (Join-Path $tmp 'event.txt')
    Wait-For { (Get-Content $first.eventFile -Raw) -match 'CLOSED_WINDOW_EVENT' }
    $null=Send-JsonCommand $HostCommandFile 'show'
    Wait-For { @(Test-Procs 'monitor.ps1').Count -eq 1 }
    $script:ShownRun=$null
    $reopened=(Update-Monitor 6>&1|Out-String)
    Check 'reopened window shows events from same run including time closed' ($reopened -match 'FIRST_EVENT' -and $reopened -match 'CLOSED_WINDOW_EVENT' -and (Get-MonitorRun).pid -eq $first.pid)
    # A partially written multibyte line must not be lost or decoded early.
    $partial=Join-Path $tmp 'partial.log'
    $bytes=[Text.Encoding]::UTF8.GetBytes("中文完整行`n")
    [IO.File]::WriteAllBytes($partial,$bytes[0..3]);$script:Offset=0L
    Check 'incomplete UTF8 event waits for newline' (@(Read-NewLogLines $partial).Count -eq 0 -and $script:Offset -eq 0)
    [IO.File]::WriteAllBytes($partial,$bytes)
    Check 'completed UTF8 event is read intact once' ((@(Read-NewLogLines $partial)-join '') -eq '中文完整行' -and @(Read-NewLogLines $partial).Count -eq 0)
    # Stop and return to menu, then launch a distinct dry run.
    $script:PendingCommand=$null
    Invoke-MonitorKey 'S' 6>$null
    Wait-For { $null -eq (Get-MonitorRun) }
    $null=Update-Monitor 6>$null
    Check 'stop returns to mode selection' ($script:View -eq 'menu')
    Invoke-MonitorKey 'D1' 6>$null
    Wait-For { $null -ne (Get-MonitorRun) }
    $second=Get-MonitorRun
    $newDisplay=(Update-Monitor 6>&1|Out-String)
    Check 'new mode starts fresh without events from previous run' ($second.mode -eq '演习模式' -and $second.id -ne $first.id -and $newDisplay -notmatch 'FIRST_EVENT|CLOSED_WINDOW_EVENT')
    $testCompleted=$true
} finally {
    foreach($leaf in @('monitor.ps1','codex-autopilot.ps1','tray.ps1')){
        foreach($p in @(Test-Procs $leaf)){Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue}
    }
    if($testCompleted){Remove-TestDirectory $tmp}else{Write-Host "Failed test evidence retained: $tmp"}
}
Write-Host "通过 $pass 项，失败 $fail 项"
exit $(if($fail){1}else{0})
