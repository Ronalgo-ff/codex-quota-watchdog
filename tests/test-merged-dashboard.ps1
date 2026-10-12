# Real WinForms lifecycle + harmless isolated watcher. No real account mutations.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-dashboard-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $tmp,(Join-Path $tmp 'state'),(Join-Path $tmp 'logs') -Force
$pass=0;$fail=0;$trayProcess=$null;$complete=$false
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Procs($Leaf){$pattern='(?i)-File\s+"?'+[regex]::Escape((Join-Path $tmp $Leaf))+'"?(?:\s|$)';return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object {$_.CommandLine -match $pattern})}
function Wait-For($Condition){$deadline=(Get-Date).AddSeconds(15);do{if(& $Condition){return};Start-Sleep -Milliseconds 100}while((Get-Date) -lt $deadline);throw 'Dashboard fixture wait timed out'}
try{
 $enc=New-Object Text.UTF8Encoding($true)
 Copy-Item (Join-Path $root 'lib') (Join-Path $tmp 'lib') -Recurse;Copy-Item (Join-Path $root 'assets') (Join-Path $tmp 'assets') -Recurse
 $tray=Get-Content (Join-Path $root 'tray.ps1') -Raw -Encoding UTF8
 $tray=$tray.Replace('Local\CodexQuotaAutopilotTray','Local\DashboardTestTray-'+[guid]::NewGuid().ToString('N')).Replace("if (-not (Test-Csw)) { throw 'Codex Switch 尚未运行，请先启动它' }",'# no external service in test')
 [IO.File]::WriteAllText((Join-Path $tmp 'tray.ps1'),$tray,$enc)
 $gui=Get-Content (Join-Path $root 'dashboard.ps1') -Raw -Encoding UTF8
 $gui=$gui.Replace('Local\CodexQuotaDashboard','Local\DashboardFixture-'+[guid]::NewGuid().ToString('N')).Replace('function Start-AccountRead{','function Start-AccountRead{ return # isolated fixture'+"`n")
 [IO.File]::WriteAllText((Join-Path $tmp 'dashboard.ps1'),$gui,$enc)
 $stub=@'
param([switch]$Live,[switch]$DryRun)
$at=(Get-Date).ToString('o');$file=Join-Path $PSScriptRoot 'logs\events-fixture.log'
[IO.File]::WriteAllText($file,"本轮事件 FIRST_EVENT`r`n",(New-Object Text.UTF8Encoding($true)))
@{id=[guid]::NewGuid().ToString('N');pid=$PID;startedAt=$at;processStartedAt=(Get-Process -Id $PID).StartTime.ToString('o');eventFile=$file;mode='正常模式'}|ConvertTo-Json|Set-Content (Join-Path $PSScriptRoot 'state\current-run.json') -Encoding UTF8
@{pid=$PID;paused=$true;at=$at}|ConvertTo-Json|Set-Content (Join-Path $PSScriptRoot 'state\tray-status.json') -Encoding UTF8
while($true){Start-Sleep -Milliseconds 200}
'@
 [IO.File]::WriteAllText((Join-Path $tmp 'codex-autopilot.ps1'),$stub,$enc)
 $trayProcess=Start-Process powershell -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "'+(Join-Path $tmp 'tray.ps1')+'"') -WindowStyle Hidden -PassThru
 Wait-For { @(Procs 'dashboard.ps1').Count -eq 1 }
 Check 'opening merged app never automatically starts watcher' (@(Procs 'codex-autopilot.ps1').Count -eq 0)
 . (Join-Path $tmp 'lib\dashboard.ps1')
 $null=Send-DashboardCommand $tmp 'start-live';Wait-For {Get-DashboardRun $tmp}
 $first=Get-DashboardRun $tmp
 Check 'explicit normal start launches one isolated watcher' ($first.mode -eq '正常模式' -and @(Procs 'codex-autopilot.ps1').Count -eq 1)
 $null=Send-DashboardCommand $tmp 'start-live';Start-Sleep -Milliseconds 700
 Check 'second start attaches without duplicate watcher' (@(Procs 'codex-autopilot.ps1').Count -eq 1 -and (Get-DashboardRun $tmp).pid -eq $first.pid)
 Check 'elapsed time is derived from same run' ((Format-DashboardElapsed $first ([datetime]::Parse($first.startedAt).AddMinutes(3))) -match '3分')
 Wait-For {$w=Read-DashboardJson (Join-Path $tmp 'state\dashboard-window.json');$w -and $w.visible -and $w.handle -gt 0}
 $w=Read-DashboardJson (Join-Path $tmp 'state\dashboard-window.json')
 Add-Type 'using System;using System.Runtime.InteropServices;public class DashboardTestClose{[DllImport("user32.dll")]public static extern bool PostMessage(IntPtr h,int msg,IntPtr w,IntPtr l);}'
 [void][DashboardTestClose]::PostMessage([IntPtr]([long]$w.handle),0x0010,[IntPtr]::Zero,[IntPtr]::Zero)
 Wait-For {@(Procs 'dashboard.ps1').Count -eq 0}
 Check 'closing actual GUI leaves same watcher and paused state alive' ((Get-DashboardRun $tmp).pid -eq $first.pid -and (Read-DashboardJson (Join-Path $tmp 'state\tray-status.json')).paused)
 Add-Content $first.eventFile '窗口关闭期间 SECOND_EVENT' -Encoding UTF8
 $null=Send-DashboardCommand $tmp 'show';Wait-For {@(Procs 'dashboard.ps1').Count -eq 1}
 Check 'reopen restores identical run with newest events' ((Get-DashboardRun $tmp).pid -eq $first.pid -and (@(Get-DashboardEvents $tmp $first)-join '') -match 'SECOND_EVENT')
 $null=Send-DashboardCommand $tmp 'resume' -Watcher
 Check 'resume requires explicit control command' ((Read-DashboardJson (Join-Path $tmp 'state\tray-control.json')).action -eq 'resume')
 $null=Send-DashboardCommand $tmp 'stop';Wait-For {@(Procs 'codex-autopilot.ps1').Count -eq 0}
 Check 'stop returns to mode choices while GUI remains' ($null -eq (Get-DashboardRun $tmp) -and @(Procs 'dashboard.ps1').Count -eq 1)
 $bad=[pscustomobject]@{eventFile=(Join-Path $root 'README.md')};Check 'events loader cannot show outside project logs' (@(Get-DashboardEvents $tmp $bad).Count -eq 0)
 $complete=$true
}finally{
 foreach($leaf in @('dashboard.ps1','codex-autopilot.ps1','tray.ps1')){foreach($p in @(Procs $leaf)){Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue}}
 if($complete){Remove-TestDirectory $tmp}else{Write-Host "Fixture evidence kept: $tmp"}
}
Write-Host "通过 $pass 项，失败 $fail 项"
exit $(if($fail){1}else{0})
