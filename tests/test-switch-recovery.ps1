# Replay partial Switch success and an old intent superseded by a third account.
# All account, desktop and restart operations below are isolated fixtures.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-switch-recovery-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tmp -Force
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json'
$Script:Config.ExpectedAccounts=5;$Script:Config.SwitchVerifySec=1;$Live=$true
$pass=0;$fail=0;$script:mutations=0;$script:sends=0;$script:launches=0;$script:pauses=0;$script:present=$true
$script:activation='success';$script:readMode='normal';$script:readCount=0;$script:events=@()
function Check($Name,$Ok){if($Ok){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Write-Event($Message,$Level){$script:events+=$Message}
function Write-File($Message,$Level){}
function Accounts{
    return @(1..5|ForEach-Object{[pscustomobject]@{Id="a$_";Email="a$_@fixture";Active=($_ -eq 1);Switchable=$true;UsageError=$null;FiveHour=100;Weekly=(50+$_);FiveHourReset=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+18000);WeeklyReset=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+604800)}})
}
function Activate($Id){foreach($a in $script:accounts){$a.Active=$a.Id -eq $Id}}
function Get-Accounts{
    $script:readCount++
    if($script:readMode -eq 'unavailable'){throw 'connection refused'}
    return $script:accounts
}
function Invoke-Csw($Command,$Arguments){
    if($Command -ne 'switch_account_and_restart_chatgpt'){throw 'Unexpected fixture operation'}
    $script:mutations++
    if($script:activation -eq 'success'){Activate $Arguments.id}
    if($script:activation -eq 'ambiguous'){$script:accounts[4].Active=$true}
    throw 'csw not-ok: 账户已切换，但无法自动启动 ChatGPT/Codex (Microsoft Store package is not installed)'
}
function Get-CodexDesktopLaunch{return [pscustomobject]@{executable='C:\fixture\ChatGPT.exe';arguments=''}}
function Get-CodexDesktopProcesses{if($script:present){return @([pscustomobject]@{ProcessId=123})};return @()}
function Start-CodexDesktopFallback($Launch){
    $disk=Get-Content $Script:StateFile -Raw|ConvertFrom-Json
    if(-not $disk.desktopRestart.fallbackAttempted){throw 'Restart intent not persisted'}
    $script:launches++;return 456
}
function Invoke-DesktopTool($Tool,$Arguments){$script:sends++;throw 'Unexpected desktop dispatch'}
function Get-DesktopSnapshot{return $script:snapshot}
function Get-RecentSessions{return @()}
function Request-ManualPause($State,$Key,$Reason,$Details){$script:pauses++;throw $Reason}
function New-FixtureState{
    $s=[pscustomobject]@{handled=[pscustomobject]@{legacy='keep'};deliveries=[pscustomobject]@{existing=[pscustomobject]@{phase='completed';receipt='keep'}}}
    Initialize-V2State $s;return $s
}
function Old-Intent{
    return [pscustomobject]@{id='original-switch';sourceId='a1';targetId='a2';at=(Get-Date).AddHours(-9).ToString('o');incidents=@('fixture-thread:old-turn')}
}
try{
    $script:accounts=Accounts;$script:snapshot=[pscustomobject]@{Recent=@();Active=@()}
    $ok=Invoke-SwitchAccount $script:accounts[4]
    Check 'not-ok after credentials switch is verified by reads without replay' ($ok -and $script:mutations -eq 1 -and $script:readCount -eq 1)
    $script:accounts=Accounts;$script:activation='unchanged';$before=$script:mutations
    $ok=Invoke-SwitchAccount $script:accounts[4]
    Check 'not-ok without target activation remains unsuccessful and single-attempt' (-not $ok -and $script:mutations -eq $before+1)
    $script:accounts=Accounts;$script:activation='ambiguous';$before=$script:mutations
    $ok=Invoke-SwitchAccount $script:accounts[4]
    Check 'two active accounts never count as a confirmed switch' (-not $ok -and $script:mutations -eq $before+1)
    $script:accounts=Accounts;$script:activation='success';$script:readMode='unavailable';$before=$script:mutations
    $ok=Invoke-SwitchAccount $script:accounts[4]
    Check 'unavailable verification cannot turn a failed response into success' (-not $ok -and $script:mutations -eq $before+1)
    $script:readMode='normal';$script:accounts=Accounts;$script:accounts[0].FiveHour=0;$script:present=$false
    $s=New-FixtureState;$before=$script:mutations
    Invoke-WatchRound $s
    Check 'partial switch success arms desktop recovery instead of permanent pause' (-not(Get-StateFlag $s 'switchIntent') -and $s.desktopRestart.targetId -eq 'a5' -and $script:mutations -eq $before+1 -and $script:pauses -eq 0)
    $s.desktopRestart.allowLaunchAfter=(Get-Date).AddSeconds(-1).ToString('o')
    Invoke-WatchRound $s;$s=Read-State;Invoke-WatchRound $s
    Check 'desktop fallback executes once after durable intent and survives restart' ($script:launches -eq 1 -and $script:mutations -eq $before+1 -and $script:sends -eq 0)
    $script:present=$true;Invoke-WatchRound $s
    Check 'desktop recovery clears only after desktop process and snapshot return' (-not(Get-StateFlag $s 'desktopRestart') -and $script:pauses -eq 0)

    $script:accounts=Accounts;Activate 'a3';$s=New-FixtureState;$intent=Old-Intent
    Set-StateFlag $s 'switchIntent' $intent;$before=$script:mutations
    Invoke-WatchRound $s
    Check 'old third-account intent is resolved after fresh desktop and account checks' (-not(Get-StateFlag $s 'switchIntent') -and $script:mutations -eq $before -and $script:pauses -eq 0)
    Check 'original intent is archived as superseded, not reported as target success' ($s.switchHistory.'original-switch'.phase -eq 'superseded' -and $s.switchHistory.'original-switch'.intent.targetId -eq 'a2' -and $s.switchHistory.'original-switch'.observedAccountId -eq 'a3')
    $s=Read-State;Invoke-WatchRound $s
    Check 'restart retains archived outcome, receipt and merged deduplication' ($s.handled.legacy -eq 'keep' -and $s.deliveries.existing.receipt -eq 'keep' -and $s.switchIncidents.'fixture-thread:old-turn' -eq 'a3' -and -not(Get-StateFlag $s 'switchIntent') -and $script:mutations -eq $before)

    $script:snapshot=[pscustomobject]@{Recent=@([pscustomobject]@{Id='fixture-thread';TurnId='old-turn';Outcome='limit';Status='idle';Error='usage_limit_exceeded';At=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-300)});Active=@()}
    $s=New-FixtureState;Set-StateFlag $s 'switchIntent' (Old-Intent);Invoke-WatchRound $s
    Check 'pre-dispatch quota wall does not cause a redundant switch or premature continue' ($script:mutations -eq $before -and $script:sends -eq 0 -and $s.desktopReadyAfter)
    $script:snapshot=[pscustomobject]@{Recent=@();Active=@()}

    $s=New-FixtureState;$intent=Old-Intent;$intent.at=(Get-Date).ToString('o');Set-StateFlag $s 'switchIntent' $intent
    $ok=Confirm-SupersededSwitchIntent $s $intent $script:accounts[2] $script:accounts
    Check 'in-flight switch is not superseded while verification window is open' (-not $ok -and (Get-StateFlag $s 'switchIntent'))
    $s=New-FixtureState;$intent=Old-Intent;Set-StateFlag $s 'switchIntent' $intent
    $ok=Confirm-SupersededSwitchIntent $s $intent $script:accounts[0] $script:accounts
    Check 'original source account does not resolve an unknown switch' (-not $ok -and (Get-StateFlag $s 'switchIntent'))
    $ok=Confirm-SupersededSwitchIntent $s $intent $script:accounts[1] $script:accounts
    Check 'target confirmation remains on the original reconciliation path' (-not $ok -and (Get-StateFlag $s 'switchIntent'))
    $observed=@($script:accounts);Activate 'a4'
    $ok=Confirm-SupersededSwitchIntent $s $intent $observed[2] $observed
    Check 'account changes during verification leave intent unresolved' (-not $ok -and (Get-StateFlag $s 'switchIntent'))
    Activate 'a3';$script:accounts[2].UsageError='unknown'
    $ok=Confirm-SupersededSwitchIntent $s $intent $script:accounts[2] $script:accounts
    Check 'unusable third account cannot release the pending intent' (-not $ok -and (Get-StateFlag $s 'switchIntent'))
    $script:accounts[2].UsageError=$null;$all=$script:accounts;$script:accounts=@($all|Select-Object -First 4)
    $ok=Confirm-SupersededSwitchIntent $s $intent $all[2] $all
    Check 'partial account list cannot release the pending intent' (-not $ok -and (Get-StateFlag $s 'switchIntent'))
    $script:accounts=$all;$Live=$false
    $ok=Confirm-SupersededSwitchIntent $s $intent $all[2] $all
    Check 'dry run never settles a real unknown switch' (-not $ok -and (Get-StateFlag $s 'switchIntent'))
    $Live=$true;$intent.at='invalid'
    $ok=Confirm-SupersededSwitchIntent $s $intent $all[2] $all
    Check 'undated or corrupt intent is not automatically discarded' (-not $ok -and (Get-StateFlag $s 'switchIntent'))
}finally{Remove-TestDirectory $tmp}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
