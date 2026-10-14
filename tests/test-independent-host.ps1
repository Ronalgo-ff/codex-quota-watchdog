# Real Windows task + disposable caller tree. No Codex/account operations.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\host.ps1')
. (Join-Path $root 'lib\process.ps1')
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-host-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $tmp
$taskName=Get-QuotaHostTaskName $tmp;$caller=$null;$hostPid=0;$pass=0;$fail=0
function Check($Name,$Ok){if($Ok){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
try{
    Copy-Item -LiteralPath (Join-Path $root 'lib\host.ps1') -Destination (Join-Path $tmp 'host.ps1')
    Copy-Item -LiteralPath (Join-Path $root 'lib\hidden-host.cs') -Destination (Join-Path $tmp 'hidden-host.cs')
    $enc=New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllText((Join-Path $tmp 'fixture.ps1'),@'
Add-Type 'using System;using System.Runtime.InteropServices;public class FixtureConsole{[DllImport("kernel32.dll")]public static extern IntPtr GetConsoleWindow();}'
@{pid=$PID;startedAt=(Get-Process -Id $PID).StartTime.ToString('o');console=([long][FixtureConsole]::GetConsoleWindow())}|ConvertTo-Json|Set-Content (Join-Path $PSScriptRoot 'ready.json')
while($true){[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'heartbeat.txt'),(Get-Date -Format o));Start-Sleep -Milliseconds 200}
'@,$enc)
    [IO.File]::WriteAllText((Join-Path $tmp 'caller.ps1'),@'
. (Join-Path $PSScriptRoot 'host.ps1')
$null=Start-QuotaIndependentHost $PSScriptRoot (Join-Path $PSScriptRoot 'fixture.ps1')
Start-Sleep -Seconds 60
'@,$enc)
    $caller=Start-Process powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $tmp 'caller.ps1')+'"') -WindowStyle Hidden -PassThru
    $deadline=(Get-Date).AddSeconds(20)
    do{Start-Sleep -Milliseconds 200;if(Test-Path (Join-Path $tmp 'ready.json')){break}}while((Get-Date)-lt $deadline)
    $ready=Get-Content (Join-Path $tmp 'ready.json') -Raw|ConvertFrom-Json;$hostPid=[int]$ready.pid
    $task=Get-ScheduledTask -TaskName $taskName
    Check 'host has no console window or terminal taskbar entry' ($ready.console -eq 0)
    Check 'independent host has no schedule triggers or execution limit' (@($task.Triggers|Where-Object {$_}).Count -eq 0 -and $task.Settings.ExecutionTimeLimit -eq 'PT0S')
    $pidBefore=$hostPid
    $null=Start-QuotaIndependentHost $tmp (Join-Path $tmp 'fixture.ps1')
    Check 'second launch signals same host instead of another process' ((Test-Path (Join-Path $tmp 'state\tray-show.json')) -and (Get-Content (Join-Path $tmp 'ready.json') -Raw|ConvertFrom-Json).pid -eq $pidBefore)
    Stop-OwnedProcessTree $caller
    $stamp=[IO.File]::ReadAllText((Join-Path $tmp 'heartbeat.txt'));Start-Sleep -Milliseconds 700
    Check 'closing entire caller tree leaves same host running' ((Get-Process -Id $hostPid -ErrorAction SilentlyContinue) -and $stamp -ne [IO.File]::ReadAllText((Join-Path $tmp 'heartbeat.txt')))
}finally{
    if($caller -and -not $caller.HasExited){Stop-OwnedProcessTree $caller}
    if($hostPid){$p=Get-CimInstance Win32_Process -Filter ('ProcessId='+$hostPid);if($p -and $p.CommandLine.Contains((Join-Path $tmp 'fixture.ps1'))){Stop-Process -Id $hostPid -Force}}
    $null=Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-TestDirectory $tmp
}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
