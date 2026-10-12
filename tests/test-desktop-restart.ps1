# A switch may succeed while the desktop stays closed. Never replay the switch.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-restart-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $tmp
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json'
$Live=$true
$script:launches=0;$script:pauses=0;$script:present=$false;$pass=0;$fail=0
function Check($Name,$Ok){if($Ok){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Write-Event($Message,$Level){}
function Get-CodexDesktopProcesses{if($script:present){return @([pscustomobject]@{ProcessId=10})};return @()}
function Start-CodexDesktopFallback($Launch){
    $disk=Get-Content $Script:StateFile -Raw|ConvertFrom-Json
    if(-not $disk.desktopRestart.fallbackAttempted){throw 'Launch has no durable intent'}
    $script:launches++;return 4321
}
function Request-ManualPause($State,$Key,$Reason,$Details){$script:pauses++;throw $Reason}
function New-TestRecovery{
    $s=[pscustomobject]@{handled=[pscustomobject]@{legacy='keep'}}
    $intent=[pscustomobject]@{id='switch-1';targetId='account-2';desktopLaunch=[pscustomobject]@{executable='C:\fixture\ChatGPT.exe';arguments='--user-data-dir="C:\fixture profile"'}}
    Set-CodexDesktopRecovery $s $intent
    return $s
}
try{
    $s=New-TestRecovery
    Check 'initial grace waits without launching' (-not(Test-CodexDesktopRecovery $s 'account-2') -and $script:launches -eq 0)
    $deadline=$s.desktopRestart.deadline;Set-CodexDesktopRecovery $s ([pscustomobject]@{id='new';desktopLaunch=@{}})
    Check 'polling never resets recovery deadline' ($s.desktopRestart.deadline -eq $deadline)
    $s.desktopRestart.allowLaunchAfter=(Get-Date).AddSeconds(-1).ToString('o')
    $ok=Test-CodexDesktopRecovery $s 'account-2'
    Check 'missing desktop launches exactly once with durable intent' (-not $ok -and $script:launches -eq 1 -and $s.desktopRestart.fallbackPid -eq 4321)
    $s=Read-State;Test-CodexDesktopRecovery $s 'account-2'|Out-Null
    Check 'process restart never replays an unconfirmed launch' ($script:launches -eq 1 -and $s.handled.legacy -eq 'keep')
    $script:present=$true
    Check 'existing desktop does not launch a duplicate' ((Test-CodexDesktopRecovery $s 'account-2') -and $script:launches -eq 1)
    $script:present=$false;$s.desktopRestart.deadline=(Get-Date).AddSeconds(-1).ToString('o')
    $threw=$false;try{Test-CodexDesktopRecovery $s 'account-2'|Out-Null}catch{$threw=$_.Exception.Message -match '未能重新打开'}
    Check 'expired restart explicitly pauses without sending another switch' ($threw -and $script:launches -eq 1)
    $s=New-TestRecovery;$threw=$false;try{Test-CodexDesktopRecovery $s 'other-account'|Out-Null}catch{$threw=$true}
    Check 'user account change prevents relaunch' ($threw -and $script:launches -eq 1)
    $Live=$false;$s=New-TestRecovery;$s.desktopRestart.allowLaunchAfter=(Get-Date).AddSeconds(-1).ToString('o')
    $null=Test-CodexDesktopRecovery $s 'account-2'
    Check 'dry run never launches even with saved recovery state' ($script:launches -eq 1)
    $Live=$true
    # Exercise the actual round ordering with an absent desktop and saved switch.
    function Get-Accounts{return @([pscustomobject]@{Id='account-2';Active=$true;FiveHour=100;Weekly=80;UsageError=$null})}
    function Invoke-ResetCycle{return 'none'}
    function Get-DesktopSnapshot{throw 'Desktop reads must wait for relaunch'}
    $Script:Config.ExpectedAccounts=1
    $s=New-TestRecovery
    $s|Add-Member NoteProperty switchIntent ([pscustomobject]@{id='switch-1';targetId='account-2';desktopLaunch=$s.desktopRestart.launch;incidents=@()})
    Invoke-WatchRound $s
    Check 'closed desktop recovery happens before any thread read' ($s.desktopRestart.phase -eq 'waiting' -and $script:launches -eq 1)
}finally{Remove-TestDirectory $tmp}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
