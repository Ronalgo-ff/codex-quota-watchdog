# Manual choices must survive automatic reserve policy and watcher restarts.
# Real quota parsing and engine, isolated state and mocked external operations.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-manual-account-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $tmp -Force
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json';$Live=$true
$Script:Config.ResetWaitPolicy='weekly-eligible';$Script:Config.FallbackAccountIds=@()
$script:switches=@();$script:sends=0;$script:batches=0;$script:pauses=0
$script:snapshot=[pscustomobject]@{Recent=@();Active=@()};$script:changeDuringRead=$false
function Invoke-Csw {param($Command,$Arguments) if($Command -ne 'list_accounts'){throw 'Unexpected external mutation'};return $script:raw}
function Get-DesktopSnapshot {
    if($script:changeDuringRead){Set-Active 'r2';$script:changeDuringRead=$false}
    return $script:snapshot
}
function Get-RecentSessions {return @()}
function Get-CodexDesktopLaunch {return $null}
function Invoke-SwitchAccount {param($Account) $script:switches+=$Account.Id;Set-Active $Account.Id;return $true}
function Send-DesktopContinue {param($State,$View) if(Get-ResumeAccountProof $State){$script:sends++}}
function Start-QuotaBatch {param($State,$Accounts) $script:batches++;$State.waitingReset.phase='running'}
function Request-ManualPause {param($State,$Key,$Reason,$Details) $script:pauses++}
function Write-Event {param($Message,$Level)}
function Write-File {param($Message,$Level)}
function Set-Active([string]$Id){foreach($a in $script:raw){$a.active=$a.id -eq $Id}}
function New-State([int]$Count=0){
    $Script:ReserveAccountCount=$Count
    $s=[pscustomobject]@{handled=[pscustomobject]@{old='preserved'};pendingResumes=[pscustomobject]@{}}
    Initialize-V2State $s;return $s
}
function New-Accounts {
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return @(
        [pscustomobject]@{id='a1';email='a1@test';active=$true;directSwitchCompatible=$true;usage=@{primary=@{remainingPercent=100;windowMinutes=300;resetsAt=$now+18000};secondary=@{remainingPercent=100;windowMinutes=10080;resetsAt=$now+604800}}},
        [pscustomobject]@{id='a2';email='a2@test';active=$false;directSwitchCompatible=$true;usage=@{primary=@{remainingPercent=100;windowMinutes=300;resetsAt=$now+18000};secondary=@{remainingPercent=80;windowMinutes=10080;resetsAt=$now+604800}}},
        [pscustomobject]@{id='r1';email='r1@test';active=$false;directSwitchCompatible=$true;usage=@{primary=@{remainingPercent=100;windowMinutes=10080;resetsAt=$now+10000};secondary=$null}},
        [pscustomobject]@{id='r2';email='r2@test';active=$false;directSwitchCompatible=$true;usage=@{primary=@{remainingPercent=100;windowMinutes=10080;resetsAt=$now+20000};secondary=$null}}
    )
}
$pass=0;$fail=0
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
try{
    $script:raw=New-Accounts;Set-Active 'r2';$s=New-State
    $before=$script:switches.Count;Invoke-WatchRound $s;Invoke-WatchRound $s
    Check 'manual reserve survives even when automatic reserves are disabled and ordinary accounts are full' ($script:switches.Count -eq $before -and $s.accountSelection.mode -eq 'manual' -and $s.accountSelection.accountId -eq 'r2')
    Check 'manual account never joins fixed automatic reserve allowance' ($s.runAccountPolicy.selectedIds.Count -eq 0)
    $proof=Get-ResumeAccountProof $s
    Check 'manual weekly-only active account provides real quota proof' ($proof.accountId -eq 'r2' -and $proof.fiveHourLimitAbsent -and $null -eq $proof.fiveHour)
    Save-State $s;$s=Read-State;Invoke-WatchRound $s
    Check 'manual ownership persists after state reload' ($script:switches.Count -eq $before -and $s.handled.old -eq 'preserved')
    $Script:WatchRunId=[guid]::NewGuid().ToString('N');Invoke-WatchRound $s
    Check 'new watcher run preserves manual ownership while resetting automatic allowance' ($script:switches.Count -eq $before -and $s.runAccountPolicy.selectedIds.Count -eq 0 -and $s.accountSelection.mode -eq 'manual')
    Set-Active 'a1';Invoke-WatchRound $s
    Check 'inactive manually used reserve remains excluded from automatic candidates' ('r2' -notin @((Get-RunAccounts $s @(Get-Accounts)).Id))
    $script:raw[0].usage.primary.remainingPercent=0;Invoke-WatchRound $s
    Check 'later automatic depletion chooses ordinary account without borrowing manual reserve' ($script:switches[-1] -eq 'a2' -and $s.runAccountPolicy.selectedIds.Count -eq 0 -and $s.accountSelection.mode -eq 'automatic')

    $script:raw=New-Accounts;$s=New-State 1;Invoke-WatchRound $s
    Set-Active 'r2';$before=$script:switches.Count;Invoke-WatchRound $s
    Check 'manual switch during monitoring overrides a different selected reserve' ($script:switches.Count -eq $before -and $s.accountSelection.accountId -eq 'r2' -and ($s.runAccountPolicy.selectedIds -join ',') -eq 'r1')
    Set-Active 'a1';Invoke-WatchRound $s;Set-Active 'r1';Invoke-WatchRound $s
    Check 'manual choice of an enabled reserve also prevents ordinary-priority bounce' ($script:switches.Count -eq $before -and (Test-ManualAccountSelection $s 'r1'))

    $script:raw=New-Accounts;foreach($a in $script:raw[0..1]){$a.usage.primary.remainingPercent=0};$s=New-State 1
    Invoke-WatchRound $s
    Check 'automatic reserve activation still records automatic ownership' ($script:switches[-1] -eq 'r1' -and $s.accountSelection.mode -eq 'automatic')
    Clear-StateFlag $s 'desktopReadyAfter';Save-State $s;$s=Read-State
    $script:raw[0].usage.primary.remainingPercent=100;Invoke-WatchRound $s
    Check 'automatic reserve still yields to recovered ordinary account after reload' ($script:switches[-1] -eq 'a1' -and $s.accountSelection.mode -eq 'automatic')

    $script:raw=New-Accounts;$s=New-State;Invoke-WatchRound $s;Set-Active 'r2'
    $script:snapshot.Recent=@([pscustomobject]@{Id='limit-thread';TurnId='old-turn';Outcome='limit';Status='idle';Error='usage_limit_exceeded';At=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-300)})
    $before=$script:switches.Count;$sendBefore=$script:sends;Invoke-WatchRound $s
    Check 'old quota error cannot undo manual switch and current quota can authorize recovery' ($script:switches.Count -eq $before -and $script:sends -eq $sendBefore+1)
    $s.accountSelection.sinceEpoch=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-10
    $script:snapshot.Recent[0].TurnId='new-turn';$script:snapshot.Recent[0].At=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Invoke-WatchRound $s
    Check 'new explicit quota failure after manual choice permits automatic recovery' ($script:switches.Count -eq $before+1 -and $script:switches[-1] -eq 'a1')
    $script:snapshot.Recent=@()

    $script:raw=New-Accounts;Set-Active 'r2';$s=New-State;Invoke-WatchRound $s
    $script:raw[3].usage=@{error='temporarily unavailable';primary=$null;secondary=$null}
    $before=$script:switches.Count;$threw=$false
    try{Invoke-WatchRound $s}catch{$threw=$_.Exception.Message -eq '当前账号额度数据未知'}
    Check 'unknown manual account quota waits without switching or inventing unlimited credit' ($threw -and $script:switches.Count -eq $before -and $null -eq (Get-ResumeAccountProof $s))
    $script:raw=New-Accounts;Set-Active 'r2';$s=New-State;Invoke-WatchRound $s
    $script:raw[3].usage.primary.remainingPercent=0;Invoke-WatchRound $s
    Check 'real manual reserve exhaustion returns to normal automatic selection' ($script:switches[-1] -eq 'a1' -and $s.runAccountPolicy.selectedIds.Count -eq 0)

    $script:raw=New-Accounts;foreach($a in $script:raw[0..1]){$a.usage.primary.remainingPercent=0};$s=New-State
    Invoke-WatchRound $s;Check 'ordinary exhaustion with reserves disabled starts a passive wait' ($s.waitingReset.phase -eq 'waiting')
    Set-Active 'r2';$before=$script:switches.Count;$batchBefore=$script:batches;Invoke-WatchRound $s
    Check 'manual usable reserve exits passive wait without switching or consuming quota' (-not (Get-StateFlag $s 'waitingReset') -and $script:switches.Count -eq $before -and $script:batches -eq $batchBefore -and (Get-ResumeAccountProof $s).accountId -eq 'r2')
    Set-StateFlag $s 'waitingReset' ([pscustomobject]@{phase='running';accountIds=@('a1','a2')})
    $pauseBefore=$script:pauses;Invoke-WatchRound $s
    Check 'manual choice never discards an uncertain batch or its replay protection' ($script:pauses -eq $pauseBefore+1 -and $s.waitingReset.phase -eq 'running' -and $script:switches.Count -eq $before)
    $job=Join-Path $tmp 'original-batch.json'
    Write-JsonAtomic $job @{id='original-batch';phase='success';accounts=@(@{id='a1';phase='success'},@{id='a2';phase='success'})}
    Set-StateFlag $s.waitingReset 'batchFile' $job
    $script:raw[0].usage.primary.remainingPercent=100;Invoke-WatchRound $s
    Check 'successful original batch is reconciled without replacing manual account' (-not (Get-StateFlag $s 'waitingReset') -and (Test-Path -LiteralPath $job) -and $script:switches.Count -eq $before -and (Test-ManualAccountSelection $s 'r2'))

    $script:raw=New-Accounts;$s=New-State;$script:raw[0].usage.primary.remainingPercent=0
    $script:changeDuringRead=$true;$before=$script:switches.Count;Invoke-WatchRound $s
    Check 'manual switch during desktop reads cancels stale automatic dispatch' ($script:switches.Count -eq $before -and -not (Get-StateFlag $s 'switchIntent') -and $script:raw[3].active)
    Invoke-WatchRound $s
    Check 'next round adopts manual account after cancelling stale dispatch' ($script:switches.Count -eq $before -and (Test-ManualAccountSelection $s 'r2'))
    $script:raw=@((New-Accounts)[3]);Set-Active 'r2';$s=New-State;Invoke-WatchRound $s
    Check 'manual reserve works with no enabled ordinary accounts' ($script:switches.Count -eq $before -and (Get-ResumeAccountProof $s).accountId -eq 'r2')
}finally{Remove-TestDirectory $tmp}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
