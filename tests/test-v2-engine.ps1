# Isolated state-machine regression tests. No real accounts, prompts, or model calls.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-v2-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tmp -Force
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json';$Live=$true
$Script:Config.ResetWaitPolicy='all' # Retain regression coverage of optional strict mode.
$script:events=@();$script:sends=0;$script:switches=0;$script:batches=0;$script:diagnosed=0
function Write-Event {param($Message,$Level) $script:events+= $Message}
function Write-File {param($Message,$Level)}
function Request-ManualPause {param($State,$Key,$Reason,$Details) $script:diagnosed++}
function Get-RecentSessions {return @()}
function Get-CodexDesktopLaunch {return $null} # Isolate desktop restart from real apps.
function New-State { $s=[pscustomobject]@{handled=[pscustomobject]@{legacy='preserved'};pendingResumes=[pscustomobject]@{}};Initialize-V2State $s;return $s }
function Accounts {
    return @(1..5|ForEach-Object {[pscustomobject]@{Id="a$_";Email="a$_@test";Active=($_ -eq 1);Switchable=$true;FiveHour=100;Weekly=(40+$_);FiveHourReset=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+18000);WeeklyReset=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+604800);UsageError=$null}})
}
function Get-Accounts {return $script:accounts}
function Invoke-SwitchAccount {param($Account) $script:switches++;$script:target=$Account.Id;foreach($a in $script:accounts){$a.Active=$a.Id -eq $Account.Id};return $true}
function Start-QuotaBatch {param($State,$Accounts) $script:batches++;$State.waitingReset.phase='running'}
$script:accounts=Accounts
$script:data=$null;$script:sendFails=$false
function Invoke-DesktopTool {
    param($Tool,$Arguments)
    if($Tool -eq 'read_thread'){return $script:data}
    if($Tool -eq 'send_message_to_thread'){
        $script:sends++
        $disk=Get-Content $Script:StateFile -Raw -Encoding UTF8|ConvertFrom-Json
        if(@($disk.deliveries.PSObject.Properties|Where-Object {$_.Value.phase -eq 'sending'}).Count -ne 1){throw 'No write-ahead intent!'}
        if($script:sendFails){throw 'Lost response after dispatch'}
        return [pscustomobject]@{status='sent';threadId=$Arguments.threadId}
    }
    throw 'Unexpected test operation'
}
function Turn([string]$Status='completed',[string]$DesktopStatus='idle',[string]$User='实现这个功能',[string]$Final='已完成',[string]$ErrorText=''){
    $script:data=[pscustomobject]@{thread=[pscustomobject]@{status=[pscustomobject]@{type=$DesktopStatus;activeFlags=@()};updatedAt=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-300)};turns=@([pscustomobject]@{id='turn-1';status=$Status;error=$ErrorText;items=@([pscustomobject]@{type='userMessage';content=@([pscustomobject]@{type='text';text=$User})},[pscustomobject]@{type='agentMessage';phase='final_answer';text=$Final})})}
}
$pass=0;$fail=0
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
try{
    Turn -User '总结一下项目需求和现状，写成一段文字' -Final '功能尚未完成，之后需要继续'
    Check 'completed handoff summary is not unfinished' ((Get-TurnView 'thread-1234').Outcome -eq 'finished')
    Turn -Final '功能尚未完成，这次只做了只读检查'
    Check 'explicit unfinished work is eligible' ((Get-TurnView 'thread-1234').Outcome -eq 'unfinished')
    Turn -Final '功能尚未完成，请你确认再继续'
    Check 'intentional approval wait is not resumed' ((Get-TurnView 'thread-1234').Outcome -eq 'waiting')
    Turn -Status 'inProgress' -DesktopStatus 'active'
    Check 'desktop active is authoritative, not file inactivity' ((Get-TurnView 'thread-1234').Outcome -eq 'running')
    $script:data.thread.status.activeFlags=@('waitingOnApproval')
    Check 'pending tool approval is protected' ((Get-TurnView 'thread-1234').Outcome -eq 'waiting')
    Turn -Status 'failed' -ErrorText 'stream_disconnected: connection reset'
    Check 'completed network failure is eligible for bounded recovery' ((Get-TurnView 'thread-1234').Outcome -eq 'retryable')
    Turn -Status 'failed' -ErrorText 'unknown tool policy failure'
    Check 'unknown failure still requires diagnosis' ((Get-TurnView 'thread-1234').Outcome -eq 'unknown')
    foreach($message in @('Your workspace is out of credits. Add credits to continue.','insufficient_credits','purchase more credits','no credits remaining')){
        Turn -Status 'failed' -ErrorText $message
        Check ('credit wall classified: '+$message) ((Get-TurnView 'thread-1234').Outcome -eq 'limit')
    }
    Turn -Status 'failed' -ErrorText 'Your workspace is out of credits' -User '暂停任务，不要继续'
    Check 'explicit user pause wins over credit failure' ((Get-TurnView 'thread-1234').Outcome -eq 'waiting')
    Turn -Final '诊断报告：Your workspace is out of credits'
    Check 'credits in completed output do not trigger account actions' ((Get-TurnView 'thread-1234').Outcome -eq 'finished')
    Check 'closed desktop does not need manual pause' ((Get-RecoveryPolicy 'Codex 桌面通道不可用；保持看护，等待桌面恢复') -eq 'wait-service')
    Check 'temporary service overload waits' ((Get-RecoveryPolicy '接口返回 503 Service Unavailable') -eq 'wait-service')
    Check 'incomplete account data gets a grace period' ((Get-RecoveryPolicy '当前账号额度数据未知') -eq 'wait-data')
    Check 'programming exception remains diagnostic-worthy' ((Get-RecoveryPolicy 'property x cannot be found') -eq 'unknown')
    Turn -Status 'inProgress' -DesktopStatus 'notLoaded'
    $v=Get-TurnView 'thread-1234'
    Check 'interrupted turn eligible' ($v.Outcome -eq 'interrupted')
    $s=New-State;Send-DesktopContinue $s $v
    Check 'desktop submission records accepted, not completed' ($s.deliveries.'desktop:thread-1234:turn-1'.phase -eq 'accepted')
    Check 'old merged state retained' ($s.handled.legacy -eq 'preserved')
    Send-DesktopContinue $s $v
    Check 'same incident submitted once' ($script:sends -eq 1)
    $s=Read-State;Send-DesktopContinue $s $v
    Check 'restart retains deduplication' ($script:sends -eq 1)
    $script:data.turns[0].id='turn-2';$script:data.turns[0].status='inProgress';$script:data.thread.status.type='active'
    $script:data.turns[0].items[0].content[0].text='继续';$script:data.thread.updatedAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Update-DesktopDeliveries $s
    Check 'new desktop turn is required for started' ($s.deliveries.'desktop:thread-1234:turn-1'.phase -eq 'started')
    $d=$s.deliveries.'desktop:thread-1234:turn-1';$d.phase='superseded'
    $script:data.turns[0].items=@([pscustomobject]@{type='functionCallOutput';name='send_message_to_thread';namespace='codex_app'})
    $script:data.turns[0]|Add-Member -NotePropertyName startedAt -NotePropertyValue $d.sentEpoch -Force
    Update-DesktopDeliveries $s
    Check 'actual desktop cross-thread message confirms started without userMessage item' ($d.phase -eq 'started')
    $script:data.turns[0].items+= [pscustomobject]@{type='agentMessage';phase='final_answer';text='已完成'}
    $script:data.turns[0].status='completed';$script:data.thread.status.type='idle';Update-DesktopDeliveries $s
    Check 'terminal desktop evidence records completed' ($s.deliveries.'desktop:thread-1234:turn-1'.phase -eq 'completed')
    Turn -Status 'inProgress' -DesktopStatus 'notLoaded';$script:sendFails=$true;$s=New-State;$v=Get-TurnView 'thread-1234'
    Send-DesktopContinue $s $v;Send-DesktopContinue $s $v
    Check 'lost response is uncertain and never blindly retried' ($script:sends -eq 2 -and $s.deliveries.'desktop:thread-1234:turn-1'.phase -eq 'uncertain')
    $script:sendFails=$false
    Turn -Status 'inProgress' -DesktopStatus 'active';$s=New-State;Send-DesktopContinue $s $v
    Check 'race: now running conversation not sent to' ($script:sends -eq 2)
    $script:accounts=Accounts;$s=New-State
    $script:accounts[0].FiveHour=0;$script:accounts[1].Weekly=0;$script:accounts[2].FiveHour=0;$script:accounts[3].Weekly=0;$script:accounts[4].FiveHour=0
    $r=Invoke-ResetCycle $s $script:accounts
    Check 'mixed weekly and five-hour exhaustion enters persistent wait' ($r -eq 'waiting' -and $s.waitingReset.phase -eq 'waiting')
    $originalIds=@($s.waitingReset.accountIds)
    $script:accounts[0].FiveHour=100;$s.waitingReset.wakeAt=(Get-Date).AddMinutes(-1).ToString('o')
    $r=Invoke-ResetCycle $s $script:accounts
    Check 'partial reset does not consume' ($r -eq 'waiting' -and $script:batches -eq 0)
    Save-State $s;$s=Read-State;$r=Invoke-ResetCycle $s $script:accounts
    Check 'restart during partial reset still waits' ($r -eq 'waiting' -and $script:batches -eq 0)
    $script:accounts=Accounts;$s.waitingReset.wakeAt=(Get-Date).AddMinutes(1).ToString('o')
    $r=Invoke-ResetCycle $s $script:accounts
    Check 'wake buffer respected even if quota looks refreshed' ($script:batches -eq 0)
    $s.waitingReset.wakeAt=(Get-Date).AddMinutes(-1).ToString('o');$r=Invoke-ResetCycle $s $script:accounts
    Check 'all five ready starts exactly one batch' ($script:batches -eq 1 -and $s.waitingReset.phase -eq 'running')
    $r=Invoke-ResetCycle $s $script:accounts
    Check 'missing receipt never triggers second batch' ($script:batches -eq 1)
    $batchFile=Join-Path $tmp 'batch.json';Write-JsonAtomic $batchFile @{id='batch';phase='failed';accounts=@()};Set-StateFlag $s.waitingReset 'batchFile' $batchFile
    $r=Invoke-ResetCycle $s $script:accounts
    Check 'failed batch stays blocked from duplicate consumption' ($script:batches -eq 1 -and $s.waitingReset.phase -eq 'failed')
    Write-JsonAtomic $batchFile @{id='batch';phase='success';accounts=@(1..5|ForEach-Object {@{id="a$_";phase='success'}})};$r=Invoke-ResetCycle $s $script:accounts
    Check 'success receipt and future reset times allow recovery' ($r -eq 'recovered')
    Save-State $s;$s=Read-State;$r=Invoke-ResetCycle $s $script:accounts
    Check 'restart after successful batch does not consume again' ($r -eq 'recovered' -and $script:batches -eq 1)
    $s.waitingReset.phase='running'
    Write-JsonAtomic $batchFile @{id='batch';phase='not-ready';accounts=@(1..5|ForEach-Object {@{id="a$_";phase='pending'}})}
    $diagBefore=$script:diagnosed;$r=Invoke-ResetCycle $s $script:accounts
    Check 'preflight quota changes return to waiting without manual pause or consumption' ($r -eq 'waiting' -and $s.waitingReset.phase -eq 'waiting' -and $script:diagnosed -eq $diagBefore -and $script:batches -eq 1)
    function Get-DesktopSnapshot {return $script:snapshot}
    $script:snapshot=[pscustomobject]@{Recent=@();Active=@()};$script:accounts=Accounts;$script:accounts[0].Weekly=0;$s=New-State
    Invoke-WatchRound $s
    Check 'weekly-zero current account switches to highest weekly balance' ($script:switches -eq 1 -and $script:target -eq 'a5')
    $script:accounts=Accounts;$script:accounts[0].FiveHour=0;$script:snapshot.Active=@([pscustomobject]@{id='busy'})
    Invoke-WatchRound (New-State)
    Check 'other running thread prevents restart interruption' ($script:switches -eq 1)
    $script:snapshot.Active=@();$script:accounts=Accounts;$script:accounts[0].FiveHour=0;$s=New-State
    Set-StateFlag $s 'switchIntent' ([pscustomobject]@{id='uncertain';targetId='a3';incidents=@()})
    Invoke-WatchRound $s;Invoke-WatchRound $s
    Check 'uncertain switch not reissued' ($script:switches -eq 1)
    foreach($a in $script:accounts){$a.Active=$a.Id -eq 'a3'};Invoke-WatchRound $s
    Check 'restart can reconcile switch by actual active account' (-not (Get-StateFlag $s 'switchIntent'))
    $script:accounts=Accounts;$script:accounts[0].Weekly=99
    Turn -Status 'failed' -ErrorText 'usage_limit_exceeded'
    $v=Get-TurnView 'thread-1234';$script:snapshot=[pscustomobject]@{Recent=@($v);Active=@()}
    $s=New-State;Set-StateFlag $s 'waitingReset' ([pscustomobject]@{phase='success';accountIds=@($script:accounts.Id)})
    $beforeSwitch=$script:switches;$beforeSend=$script:sends
    Invoke-WatchRound $s;Invoke-WatchRound $s
    Check 'recovered current best account resumes without a redundant next-round switch' ($script:switches -eq $beforeSwitch -and $script:sends -eq $beforeSend+1)
    Check 'old limit acknowledged only after recovery and delivery intent retained' ($s.switchIncidents.PSObject.Properties['thread-1234:turn-1'] -and $s.deliveries.PSObject.Properties['desktop:thread-1234:turn-1'])
    # Replay the actual incident: weekly exhausted, credit wording, successful switch,
    # then exactly one desktop continuation. No manual pause and no second account switch.
    $script:accounts=Accounts;$script:accounts[0].Weekly=0
    Turn -Status 'failed' -ErrorText 'Your workspace is out of credits. Add credits to continue.'
    $v=Get-TurnView 'thread-credit';$script:snapshot=[pscustomobject]@{Recent=@($v);Active=@()}
    $s=New-State;$bs=$script:switches;$bd=$script:diagnosed;$bm=$script:sends
    Invoke-WatchRound $s
    Check 'real credit incident selects maximum weekly usable account' ($script:switches -eq $bs+1 -and $script:target -eq 'a5')
    Clear-StateFlag $s 'desktopReadyAfter' # Advance simulated post-switch readiness.
    Invoke-WatchRound $s;Invoke-WatchRound $s
    Check 'after confirmed switch credit incident continues once without manual pause' ($script:switches -eq $bs+1 -and $script:sends -eq $bm+1 -and $script:diagnosed -eq $bd)
    Save-State $s;$s=Read-State;Invoke-WatchRound $s
    Check 'credit continuation is deduplicated across restart' ($script:sends -eq $bm+1)
    # All accounts report credit errors despite positive quota snapshots: each tried
    # at most once, no infinite bouncing, no fictitious all-reset consume batch.
    $script:accounts=Accounts;$s=New-State;$bs=$script:switches;$bd=$script:diagnosed;$bb=$script:batches
    foreach($i in 1..5){
        Turn -Status 'failed' -ErrorText 'Your workspace is out of credits. Add credits to continue.'
        $script:data.turns[0].id="credit-$i"
        $v=Get-TurnView 'thread-credit';$script:snapshot=[pscustomobject]@{Recent=@($v);Active=@()}
        Invoke-WatchRound $s
    }
    Check 'persistent credit failure tries each account once then diagnoses' ($script:switches -eq $bs+4 -and $script:diagnosed -eq $bd+1 -and $script:batches -eq $bb)
    Save-State $s;$s=Read-State;Invoke-WatchRound $s
    Check 'restart does not restart failed credit account cycle' ($script:switches -eq $bs+4)
    $script:accounts[0].Weekly+=1;Invoke-WatchRound $s
    Check 'observed quota increase permits recovery after credit blockage' ($script:switches -eq $bs+5 -and $script:target -eq 'a1')
    # Confirmed all-account consumption ends the old credit failure chain.
    # Old snapshots can equal restored quota, so percent-growth heuristics are insufficient.
    $script:accounts=Accounts;$script:accounts[0].Weekly=99;$s=New-State
    Turn -Status 'failed' -ErrorText 'Your workspace is out of credits. Add credits to continue.'
    $v=Get-TurnView 'reset-credit';$script:snapshot=[pscustomobject]@{Recent=@($v);Active=@()}
    $oldAttempts=[pscustomobject]@{}
    foreach($a in $script:accounts){Set-StateFlag $oldAttempts $a.Id ([pscustomobject]@{fiveHour=$a.FiveHour;weekly=$a.Weekly;fiveHourReset=$a.FiveHourReset})}
    Set-StateFlag $s.creditRecoveries $v.Id ([pscustomobject]@{id='old-cycle';accounts=$oldAttempts})
    Set-StateFlag $s 'waitingReset' ([pscustomobject]@{phase='success';accountIds=@($script:accounts.Id)})
    $bs=$script:switches;$bd=$script:diagnosed;$bm=$script:sends
    Invoke-WatchRound $s
    Check 'confirmed reset clears old credit exclusions and continues current best' ($script:switches -eq $bs -and $script:sends -eq $bm+1 -and $script:diagnosed -eq $bd -and -not (Get-StateFlag $s 'waitingReset'))
    $s=New-State;Set-StateFlag $s 'waitingReset' ([pscustomobject]@{phase='running';accountIds=@($script:accounts.Id);batchFile=$batchFile})
    Write-JsonAtomic $batchFile @{id='read-only-failure';phase='preflight-retry';accounts=@(1..5|ForEach-Object {@{id="a$_";phase='pending'}})}
    $bb=$script:batches;$bd=$script:diagnosed;$result=Invoke-ResetCycle $s $script:accounts
    Check 'read-only failure returns to durable wait without manual pause or consumption' ($result -eq 'waiting' -and $s.waitingReset.phase -eq 'waiting' -and $script:batches -eq $bb -and $script:diagnosed -eq $bd)
    Save-State $s;$s=Read-State;Invoke-ResetCycle $s $script:accounts|Out-Null
    Check 'read-only retry backoff survives restart' ($script:batches -eq $bb -and [datetime]$s.waitingReset.wakeAt -gt (Get-Date))
    # User relaxed batch acceptance: one confirmed usable success is sufficient.
    $script:accounts=Accounts;$s=New-State
    foreach($a in $script:accounts){if($a.Id -ne 'a1'){$a.Weekly=0}}
    $script:accounts[4].UsageError='quota unavailable';$script:accounts[4].Weekly=$null
    Set-StateFlag $s 'waitingReset' ([pscustomobject]@{phase='running';accountIds=@($script:accounts.Id);batchFile=$batchFile})
    $partialAccounts=@(1..5|ForEach-Object {@{id="a$_";phase=$(if($_ -eq 1){'success'}elseif($_ -eq 2){'uncertain'}else{'skipped'})}})
    Write-JsonAtomic $batchFile @{id='one-success';phase='partial';accounts=$partialAccounts}
    $bb=$script:batches;$bd=$script:diagnosed
    $script:accounts[0].FiveHourReset=0
    Check 'one success without confirmed timer does not release' ((Invoke-ResetCycle $s $script:accounts) -eq 'waiting')
    $script:accounts[0].FiveHourReset=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+18000
    Check 'one usable success releases despite others depleted or unknown' ((Invoke-ResetCycle $s $script:accounts) -eq 'recovered' -and $script:diagnosed -eq $bd)
    Save-State $s;$s=Read-State
    Check 'partial release persisted and never starts another batch' ((Invoke-ResetCycle $s $script:accounts) -eq 'recovered' -and $script:batches -eq $bb)
    Turn -Status 'failed' -ErrorText 'usage_limit_exceeded'
    $v=Get-TurnView 'partial-resume';$script:snapshot=[pscustomobject]@{Recent=@($v);Active=@()}
    $bm=$script:sends;Invoke-WatchRound $s;Invoke-WatchRound $s
    Check 'partial batch continues available current account exactly once' ($script:sends -eq $bm+1 -and $script:batches -eq $bb)
    $s=New-State;Set-StateFlag $s 'waitingReset' ([pscustomobject]@{phase='running';accountIds=@($script:accounts.Id);batchFile=$batchFile})
    Write-JsonAtomic $batchFile @{id='crashed-after-one';phase='running';accounts=$partialAccounts}
    Check 'exited worker with one durable success can recover without replay' ((Invoke-ResetCycle $s $script:accounts) -eq 'recovered' -and $script:batches -eq $bb)
    $Script:Config.ResetWaitPolicy='any'
    $script:accounts=Accounts;$s=New-State
    foreach($a in $script:accounts){$a.Weekly=0}
    $bb=$script:batches
    Check 'any-ready mode still waits when no account is usable' ((Invoke-ResetCycle $s $script:accounts) -eq 'waiting' -and $script:batches -eq $bb)
    $s.waitingReset.wakeAt=(Get-Date).AddDays(5).ToString('o')
    Save-State $s;$s=Read-State
    $script:accounts[1].Weekly=90;$script:accounts[4].Weekly=$null;$script:accounts[4].UsageError='offline'
    Invoke-ResetCycle $s $script:accounts|Out-Null
    Check 'one restored account starts batch despite old days-long wait and other unknown quota' ($script:batches -eq $bb+1 -and $s.waitingReset.phase -eq 'running')
    Set-StateFlag $s.waitingReset 'batchFile' $batchFile
    Write-JsonAtomic $batchFile @{id='any-retry';phase='preflight-retry';accounts=@(1..5|ForEach-Object {@{id="a$_";phase='pending'}})}
    Invoke-ResetCycle $s $script:accounts|Out-Null;Save-State $s;$s=Read-State
    Invoke-ResetCycle $s $script:accounts|Out-Null
    Check 'any-ready mode preserves real read-only retry backoff after restart' ($script:batches -eq $bb+1 -and $s.waitingReset.phase -eq 'waiting')
    $s.waitingReset.retryAfter=(Get-Date).AddSeconds(-1).ToString('o')
    Invoke-ResetCycle $s $script:accounts|Out-Null
    Check 'any-ready mode starts fresh batch after safe preflight backoff' ($script:batches -eq $bb+2)
    $Script:Config.ResetWaitPolicy='weekly-eligible'
    $script:accounts=Accounts;$s=New-State;$bb=$script:batches
    $script:accounts[0].Weekly=0
    $script:snapshot=[pscustomobject]@{Recent=@();Active=@()};$bs=$script:switches
    Invoke-WatchRound $s
    Check 'normal switch with four usable accounts ignores the weekly-zero account' ($script:switches -eq $bs+1 -and $script:target -eq 'a5' -and $script:batches -eq $bb -and -not (Get-StateFlag $s 'waitingReset'))
    $script:accounts=Accounts;$s=New-State
    foreach($a in $script:accounts){$a.FiveHour=0}
    $script:accounts[0].Weekly=0;$script:accounts[0].FiveHour=$null
    Invoke-ResetCycle $s $script:accounts|Out-Null
    Check 'all unavailable persists wait even when weekly-zero has no five-hour data' ($s.waitingReset.phase -eq 'waiting' -and $script:batches -eq $bb)
    $s.waitingReset.wakeAt=(Get-Date).AddDays(7).ToString('o')
    $script:accounts[1].FiveHour=100;$script:accounts[2].FiveHour=100;$script:accounts[3].FiveHour=100
    Invoke-ResetCycle $s $script:accounts|Out-Null;Save-State $s;$s=Read-State
    Invoke-ResetCycle $s $script:accounts|Out-Null
    Check 'three of four eligible refreshed still waits across restart' ($script:batches -eq $bb -and @($s.waitingReset.eligibleIds).Count -eq 4 -and -not (Get-StateFlag $s.waitingReset 'wakeAt'))
    $script:accounts[4].FiveHour=100;Invoke-ResetCycle $s $script:accounts|Out-Null
    Check 'last eligible account ready starts batch without waiting for weekly-zero account' ($script:batches -eq $bb+1 -and $s.waitingReset.phase -eq 'running')
    $s=New-State;foreach($a in $script:accounts){$a.Weekly=0;$a.FiveHour=100}
    Invoke-ResetCycle $s $script:accounts|Out-Null;Invoke-ResetCycle $s $script:accounts|Out-Null
    Check 'zero weekly-eligible accounts never passes vacuous all-ready condition' ($script:batches -eq $bb+1 -and $s.waitingReset.phase -eq 'waiting')
    $script:accounts[1].Weekly=25;$script:accounts[1].FiveHour=0
    Invoke-ResetCycle $s $script:accounts|Out-Null
    Check 'new weekly recovery joins cohort and waits for five-hour quota' ($script:batches -eq $bb+1 -and @($s.waitingReset.eligibleIds).Count -eq 1)
    $script:accounts[1].FiveHour=100;Invoke-ResetCycle $s $script:accounts|Out-Null
    Check 'single remaining weekly-eligible account can recover after its reset' ($script:batches -eq $bb+2)
    $s=New-State;Set-StateFlag $s 'waitingReset' ([pscustomobject]@{phase='waiting';accountIds=@($script:accounts.Id);wakeAt=(Get-Date).AddDays(6).ToString('o')})
    $script:accounts[2].Weekly=20;$script:accounts[2].FiveHour=$null
    Invoke-ResetCycle $s $script:accounts|Out-Null
    Check 'unknown five-hour quota on weekly-positive account still blocks consumption' ($script:batches -eq $bb+2)
    $script:accounts[2].Weekly=0
    Set-StateFlag $s.waitingReset 'retryAfter' ((Get-Date).AddSeconds(60).ToString('o'))
    Invoke-ResetCycle $s $script:accounts|Out-Null
    Check 'weekly policy preserves safe preflight backoff' ($script:batches -eq $bb+2)
    # Config-loading is an explicit rejection, unlike a lost acknowledgement.
    $script:accounts=Accounts
    $s=New-State;Turn -Status 'failed' -ErrorText 'usage_limit_exceeded';$v=Get-TurnView 'config-thread'
    Set-StateFlag $s 'desktopReadyAfter' ((Get-Date).AddSeconds(60).ToString('o'))
    $bm=$script:sends;Send-DesktopContinue $s $v
    Check 'post-switch preparation gate prevents premature send' ($script:sends -eq $bm -and @($s.deliveries.PSObject.Properties).Count -eq 0)
    Clear-StateFlag $s 'desktopReadyAfter'
    $script:rejectConfig=$true;$script:loseResponse=$false
    function Invoke-DesktopTool {
        param($Tool,$Arguments)
        if($Tool -eq 'read_thread'){return $script:data}
        $script:sends++
        if($script:rejectConfig){$ex=New-Object InvalidOperationException('App-server task is not ready: execution-config-loading');$ex.Data['QuotaPreDispatchRejected']=$true;throw $ex}
        if($script:loseResponse){throw 'Desktop pipe response timeout; delivery may be uncertain'}
        return [pscustomobject]@{threadId=$Arguments.threadId}
    }
    $bd=$script:diagnosed;Send-DesktopContinue $s $v
    $key='desktop:config-thread:turn-1'
    Check 'explicit config rejection stays deferred and does not call manual pause immediately' ($s.deliveries.$key.phase -eq 'deferred' -and $script:diagnosed -eq $bd -and -not $s.handled.PSObject.Properties[$key])
    Send-DesktopContinue $s $v
    Check 'rejected request respects retry delay' ($script:sends -eq $bm+1)
    Save-State $s;$s=Read-State;Update-DesktopDeliveries $s
    Check 'deferred delivery persists across restart and verification' ($s.deliveries.$key.phase -eq 'deferred')
    $s.deliveries.$key.nextAttemptEpoch=0;$script:rejectConfig=$false;Send-DesktopContinue $s $v
    Send-DesktopContinue $s $v
    Check 'ready desktop receives exactly one accepted retry' ($s.deliveries.$key.phase -eq 'accepted' -and $script:sends -eq $bm+2 -and $s.handled.PSObject.Properties[$key])
    $s=New-State;$script:rejectConfig=$true;Send-DesktopContinue $s $v
    $script:data.turns[0].id='user-new-turn';Update-DesktopDeliveries $s
    $prior=$script:sends;Send-DesktopContinue $s $v
    Check 'user-started new turn cancels deferred retry' ($s.deliveries.$key.phase -eq 'superseded' -and $script:sends -eq $prior)
    Turn -Status 'failed' -ErrorText 'usage_limit_exceeded';$v=Get-TurnView 'config-thread'
    $s=New-State;$script:rejectConfig=$true;Send-DesktopContinue $s $v
    $s.deliveries.$key.nextAttemptEpoch=0;$script:rejectConfig=$false;$script:loseResponse=$true;Send-DesktopContinue $s $v
    $prior=$script:sends;Send-DesktopContinue $s $v
    Check 'timeout after retry becomes uncertain and is never resent' ($s.deliveries.$key.phase -eq 'uncertain' -and $script:sends -eq $prior)
    $s.deliveries.$key.error='App-server task is not ready: execution-config-loading';Update-DesktopDeliveries $s
    Check 'exact old rejection without receipt can migrate to deferred' ($s.deliveries.$key.phase -eq 'deferred')
    Turn -Status 'interrupted' -User '推送' -Final ''
    Check 'actual stopped push is protected even without textual stop instruction' ((Get-TurnView 'stopped-push').Outcome -eq 'waiting')
    Turn -Status 'aborted' -Final ''
    Check 'aborted turn without proven recoverable error is not resumed' ((Get-TurnView 'stopped-push').Outcome -eq 'waiting')
    Turn -Status 'interrupted' -ErrorText 'usage_limit_exceeded' -Final ''
    Check 'explicit quota evidence still enables quota recovery' ((Get-TurnView 'stopped-push').Outcome -eq 'limit')
    Turn -Status 'interrupted' -ErrorText 'stream_disconnected' -Final ''
    Check 'proven network interruption remains recoverable' ((Get-TurnView 'stopped-push').Outcome -eq 'retryable')
    $script:accounts=Accounts;$s=New-State
    Turn -Status 'inProgress' -DesktopStatus 'notLoaded';$v=Get-TurnView 'quota-race';$bm=$script:sends
    $script:accounts[0].FiveHour=0;Send-DesktopContinue $s $v
    Check 'quota drains between scan and dispatch: no continue or dedup record' ($script:sends -eq $bm -and @($s.deliveries.PSObject.Properties).Count -eq 0)
    $script:accounts[0].FiveHour=$null;Send-DesktopContinue $s $v
    Check 'unknown current quota blocks continuation' ($script:sends -eq $bm)
    $script:accounts=Accounts
    Set-StateFlag $s 'waitingReset' ([pscustomobject]@{phase='waiting'})
    Send-DesktopContinue $s $v
    Check 'durable reset wait blocks sending even if one account now looks ready' ($script:sends -eq $bm)
    Clear-StateFlag $s 'waitingReset';Set-StateFlag $s 'switchIntent' ([pscustomobject]@{id='pending'})
    Send-DesktopContinue $s $v
    Check 'unconfirmed switch blocks continuation' ($script:sends -eq $bm)
    Clear-StateFlag $s 'switchIntent';$script:rejectConfig=$false;$script:loseResponse=$false
    Send-DesktopContinue $s $v
    Check 'fresh available quota is recorded with accepted continuation' ($script:sends -eq $bm+1 -and $s.deliveries.'desktop:quota-race:turn-1'.quotaProof.accountId -eq 'a1')
    $script:iterations=0
    function Invoke-WatchRound {param($State) $script:iterations++;if($script:iterations -eq 1){throw 'test transient failure'}}
    function Wait-WithStatus {param($Seconds,$Summary) return 'ok'}
    Start-WatchLoop (New-State) -MaxRounds 3
    Check 'unexpected round failure does not end monitoring' ($script:iterations -eq 3)
    $beforeDiagnostics=$script:diagnosed
    function Invoke-WatchRound {param($State) throw 'Codex 桌面通道不可用；保持看护，等待桌面恢复'}
    Start-WatchLoop (New-State) -MaxRounds 6
    Check 'repeated desktop outage never launches automatic diagnosis' ($script:diagnosed -eq $beforeDiagnostics)
    function Invoke-WatchRound {param($State) throw 'property x cannot be found'}
    Start-WatchLoop (New-State) -MaxRounds 3
    Check 'unknown error requests immediate pause on its first occurrence' ($script:diagnosed -eq $beforeDiagnostics+3)
}finally{Remove-TestDirectory $tmp}
Write-Host "通过 $pass 项，失败 $fail 项"
exit $(if($fail){1}else{0})
