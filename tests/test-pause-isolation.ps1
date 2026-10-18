# Replay terminal errors and long read outages with isolated state and fake APIs.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-pause-isolation-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tmp -Force
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json';$Live=$true
$Script:Config.ResumeQuietMin=0;$Script:Config.ResumeMaxRounds=4
$script:events=@();$script:sends=@();$script:switches=0;$script:pauses=0;$script:reject=$false;$script:lost=$false
$script:views=@{};$script:reads=0;$pass=0;$fail=0
function Check($Name,$Ok){if($Ok){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Write-Event($Message,$Level){$script:events+=$Message}
function Write-File($Message,$Level){}
function Get-RecentSessions{return @()}
function Get-CodexDesktopLaunch{return $null}
function Request-ManualPause($State,$Key,$Reason,$Details){
    $script:pauses++;$ex=New-Object InvalidOperationException($Reason);$ex.Data['QuotaManualPause']=$true;throw $ex
}
function New-State{$s=[pscustomobject]@{handled=[pscustomobject]@{legacy='keep'};pendingResumes=[pscustomobject]@{}};Initialize-V2State $s;return $s}
function Get-Accounts{
    return @(1..5|ForEach-Object{[pscustomobject]@{Id="a$_";Email="a$_@fixture";Active=($_ -eq 1);Switchable=$true;UsageError=$null;FiveHour=100;Weekly=80;FiveHourReset=2000000000;WeeklyReset=2000100000}})
}
function Invoke-SwitchAccount($Account){$script:switches++;throw 'Unexpected switch'}
function Start-QuotaBatch($State,$Accounts){throw 'Unexpected quota consumption'}
function Invoke-DesktopTool($Tool,$Arguments){
    if($Tool -eq 'read_thread'){$script:reads++;return $script:views[$Arguments.threadId]}
    if($Tool -ne 'send_message_to_thread'){throw 'Unexpected API'}
    $script:sends+=$Arguments.threadId
    if($script:reject){$ex=New-Object InvalidOperationException('App-server task is not ready: execution-config-loading');$ex.Data['QuotaPreDispatchRejected']=$true;throw $ex}
    if($script:lost){throw 'Desktop pipe response timeout; delivery may be uncertain'}
    return [pscustomobject]@{threadId=$Arguments.threadId;status='sent'}
}
function Set-Turn($Id,$TurnId='turn-1',$ErrorText='',$Status='failed',$DesktopStatus='idle',$User='Implement the feature',$Final=''){
    $script:views[$Id]=[pscustomobject]@{
        thread=[pscustomobject]@{status=[pscustomobject]@{type=$DesktopStatus;activeFlags=@()};updatedAt=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-300)}
        turns=@([pscustomobject]@{id=$TurnId;status=$Status;error=$ErrorText;items=@(
            [pscustomobject]@{type='userMessage';content=@([pscustomobject]@{type='text';text=$User})},
            [pscustomobject]@{type='agentMessage';phase='final_answer';text=$Final}
        )})
    }
}
function Get-DesktopSnapshot{
    $map=@{};$recent=@();foreach($id in @($script:views.Keys|Sort-Object)){$v=Get-TurnView $id;$map[$id]=$v;$recent+=$v}
    return [pscustomobject]@{Recent=$recent;Active=@();Views=$map}
}
try{
    $auth=[pscustomobject]@{message='workspace routing discovery unauthorized (401)';additionalDetails=$null}
    Set-Turn 'auth-thread' -ErrorText $auth
    $v=Get-TurnView 'auth-thread'
    Check 'real 401 incident is recognized as an authorization block' ($v.Outcome -eq 'blocked' -and $v.Reason -eq 'authorization-required')
    foreach($message in @('403 Forbidden','authentication_failed','invalid_api_key','access token expired')){
        Set-Turn 'auth-thread' -ErrorText $message
        Check ('known authorization failure: '+$message) ((Get-TurnView 'auth-thread').Outcome -eq 'blocked')
    }
    Set-Turn 'auth-thread' -ErrorText $auth -DesktopStatus 'active'
    Check 'active work remains protected even with an old auth error' ((Get-TurnView 'auth-thread').Outcome -eq 'running')
    Set-Turn 'auth-thread' -ErrorText $auth -User 'pause this task'
    Check 'explicit user pause remains protected' ((Get-TurnView 'auth-thread').Outcome -eq 'waiting')
    Set-Turn 'auth-thread' -Status 'completed' -User 'Explain unauthorized 401' -Final 'The request returned 401'
    Check 'error words in ordinary text do not block completed work' ((Get-TurnView 'auth-thread').Outcome -eq 'finished')
    Set-Turn 'auth-thread' -ErrorText $auth -Status 'interrupted'
    Check 'terminal interrupted authorization failure is also isolated' ((Get-TurnView 'auth-thread').Outcome -eq 'blocked')
    Set-Turn 'good-thread' -Status 'inProgress' -DesktopStatus 'notLoaded'
    $s=New-State;Invoke-WatchRound $s
    Check 'auth failure does not pause switch or resume the affected chat' ($script:pauses -eq 0 -and $script:switches -eq 0 -and @($script:sends|Where-Object {$_ -eq 'auth-thread'}).Count -eq 0)
    Check 'another interrupted chat continues in the same round' (@($script:sends|Where-Object {$_ -eq 'good-thread'}).Count -eq 1)
    $files=@(Get-ChildItem (Join-Path $tmp 'incidents') -Filter 'thread-*.json')
    $report=Get-Content $files[0].FullName -Raw|ConvertFrom-Json
    Check 'scoped report preserves the original error without global pause' ($files.Count -eq 1 -and $report.scope -eq 'thread' -and $report.details.error -match '401' -and -not(Test-Path (Join-Path $tmp 'manual-pause.json')))
    $beforeEvents=$script:events.Count;$s=Read-State;Invoke-WatchRound $s
    Check 'restart deduplicates reports and accepted prompts' (@(Get-ChildItem (Join-Path $tmp 'incidents') -Filter 'thread-*.json').Count -eq 1 -and $script:events.Count -eq $beforeEvents -and $script:sends.Count -eq 1 -and $s.handled.legacy -eq 'keep')
    Set-Turn 'auth-thread' -TurnId 'new-user-turn' -Status 'inProgress' -DesktopStatus 'notLoaded'
    Invoke-WatchRound $s
    Check 'new user turn is not blocked by a historical auth report' (@($script:sends|Where-Object {$_ -eq 'auth-thread'}).Count -eq 1)

    # Acknowledged automatic turn ending in auth failure is failed, never completed.
    $d=$s.deliveries.'desktop:auth-thread:new-user-turn'
    Set-Turn 'auth-thread' -TurnId 'auto-auth-turn' -ErrorText $auth -User $Script:Config.ResumeMessage
    $script:views['auth-thread'].thread.updatedAt=$d.sentEpoch
    Update-DesktopDeliveries $s
    Check 'auth failure after acknowledged dispatch is recorded as failed' ($d.phase -eq 'failed')

    # Retry exhaustion remains scoped and cannot stop another eligible chat.
    $script:views=@{};Set-Turn 'capped-thread' -ErrorText 'stream_disconnected';Set-Turn 'next-thread' -Status 'inProgress' -DesktopStatus 'notLoaded'
    $s=New-State;1..4|ForEach-Object{Set-StateFlag $s.handled ('desktop:capped-thread:old-'+$_) 'preserved'}
    $sent=$script:sends.Count;Invoke-WatchRound $s
    Check 'network retry cap prevents only that chat from resuming' ($script:pauses -eq 0 -and $script:sends.Count -eq $sent+1 -and $script:sends[-1] -eq 'next-thread')

    # Explicit rejections are safe to retry, but never beyond the fixed limit.
    $script:views=@{};Set-Turn 'config-thread' -Status 'inProgress' -DesktopStatus 'notLoaded'
    $s=New-State;$v=Get-TurnView 'config-thread';$script:reject=$true;$sent=$script:sends.Count
    $key='desktop:config-thread:turn-1'
    for($i=1;$i -le 8;$i++){
        if($i -gt 1){$s.deliveries.$key.nextAttemptEpoch=0}
        Send-DesktopContinue $s $v
    }
    Check 'eighth explicit rejection blocks only that turn' ($script:pauses -eq 0 -and $script:sends.Count -eq $sent+8 -and $s.deliveries.$key.phase -eq 'blocked' -and -not(Get-StateFlag $s.handled $key))
    $s=Read-State;$reads=$script:reads;Update-DesktopDeliveries $s;Send-DesktopContinue $s $v
    Check 'restart neither polls a blocked delivery nor submits a ninth request' ($script:sends.Count -eq $sent+8 -and $script:reads -eq $reads)
    $s.deliveries.$key.phase='deferred';$s.deliveries.$key.nextAttemptEpoch=0
    Send-DesktopContinue $s $v
    Check 'legacy exhausted deferred delivery is blocked without resending' ($script:sends.Count -eq $sent+8 -and $s.deliveries.$key.phase -eq 'blocked')
    $script:reject=$false
    Set-Turn 'config-thread' -TurnId 'manual-new-turn' -Status 'inProgress' -DesktopStatus 'notLoaded'
    Send-DesktopContinue $s (Get-TurnView 'config-thread')
    Check 'a new turn after manual recovery can resume normally' ($script:sends.Count -eq $sent+9)

    # Do not weaken ambiguous dispatch or unknown-programming-error safeguards.
    $s=New-State;$script:lost=$true;$paused=$script:pauses
    try{Send-DesktopContinue $s (Get-TurnView 'config-thread')}catch{if($_.Exception.Data['QuotaManualPause'] -ne $true){throw}}
    $sent=$script:sends.Count;Send-DesktopContinue $s (Get-TurnView 'config-thread')
    Check 'lost dispatch response still pauses globally and cannot replay' ($script:pauses -eq $paused+1 -and $script:sends.Count -eq $sent)
    $script:lost=$false
    $script:views=@{};Set-Turn 'unknown-thread' -ErrorText 'unknown tool policy failure'
    $paused=$script:pauses
    try{Invoke-WatchRound (New-State)}catch{if($_.Exception.Data['QuotaManualPause'] -ne $true){throw}}
    Check 'unclassified failure retains global incident protection' ($script:pauses -eq $paused+1)

    # Simulate long outages without spending time or touching live services.
    function Wait-WithStatus($Seconds,$Summary){return 'ok'}
    function Wait-ManualPause{}
    $script:fakeNow=[datetime]'2026-10-18T00:00:00'
    function Get-Date{$script:fakeNow=$script:fakeNow.AddMinutes(2);return $script:fakeNow}
    $script:mode='no-active';$script:rounds=0
    function Invoke-WatchRound($State){
        $script:rounds++
        if($script:mode -eq 'no-active'){throw 'Codex Switch 没有唯一当前账号'}
        if($script:mode -eq 'quota'){throw '当前账号额度数据未知'}
        if($script:mode -eq 'count'){throw '预期 5 个账号，实际读取 4 个；等待完整数据'}
        if($script:mode -eq 'alternating'){
            if($script:rounds % 2 -eq 0){throw 'connection refused'}
            throw '预期 5 个账号，实际读取 4 个；等待完整数据'
        }
        if($script:mode -eq 'bug'){throw 'property x cannot be found'}
    }
    $paused=$script:pauses;Start-WatchLoop (New-State) -MaxRounds 12
    $script:mode='quota';Start-WatchLoop (New-State) -MaxRounds 12
    Check 'long active-account and quota read outages do not latch a pause' ($script:pauses -eq $paused)
    $script:mode='healthy';$script:rounds=0;Start-WatchLoop (New-State) -MaxRounds 2
    Check 'data recovery needs no manual resume' ($script:rounds -eq 2 -and $script:pauses -eq $paused)
    $script:mode='alternating';$script:rounds=0;Start-WatchLoop (New-State) -MaxRounds 12
    Check 'unrelated service errors reset account-set grace period' ($script:pauses -eq $paused)
    $script:mode='count';Start-WatchLoop (New-State) -MaxRounds 12
    Check 'persistent account-count change still requires inspection' ($script:pauses -gt $paused)
    $paused=$script:pauses;$script:mode='bug';Start-WatchLoop (New-State) -MaxRounds 1
    Check 'unknown programming exception still pauses immediately' ($script:pauses -eq $paused+1)
    Remove-Item Function:\Get-Date
}finally{Remove-TestDirectory $tmp}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
