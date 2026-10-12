# No real accounts or prompts. Exercise the same raw markers seen on 2026-10-08.
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-interruption-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $tmp
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json';$Live=$true
$pass=0;$fail=0;$script:sends=@();$script:files=@();$script:data=@{}
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Write-Event {param($Message,$Level)}
function Write-File {param($Message,$Level)}
function Request-ManualPause {throw 'Unexpected pause'}
function Get-RecentSessions {return $script:files}
function Record($Type,$Payload){
    $p=[ordered]@{};if($Payload.ContainsKey('type')){$p.type=$Payload.type}
    foreach($key in $Payload.Keys){if($key -ne 'type'){$p[$key]=$Payload[$key]}}
    return [ordered]@{timestamp='2026-10-07T20:30:41.385Z';type=$Type;payload=$p}|ConvertTo-Json -Depth 15 -Compress
}
function Rollout($Id,$End='',$Turn='source-1'){
    $path=Join-Path $tmp ('rollout-'+$Id+'.jsonl')
    $lines=@((Record 'session_meta' @{id=$Id;source='vscode';originator='Codex Desktop'}),(Record 'event_msg' @{type='task_started';turn_id=$Turn}))
    if($End){$lines+=Record 'event_msg' @{type=$End;turn_id=$Turn}}
    [IO.File]::WriteAllText($path,($lines -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
    $script:files=@(Get-ChildItem $tmp -Filter *.jsonl)
    return $path
}
function Desktop($Id,$Status='interrupted',$ErrorText=$null){
    $script:data[$Id]=[pscustomobject]@{thread=[pscustomobject]@{status=[pscustomobject]@{type='idle';activeFlags=@()};updatedAt=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-300)};turns=@([pscustomobject]@{id='source-1';status=$Status;error=$ErrorText;items=@()})}
}
function Invoke-DesktopTool($Tool,$Arguments){
    if($Tool -eq 'read_thread'){return $script:data[$Arguments.threadId]}
    if($Tool -eq 'send_message_to_thread'){$script:sends+=$Arguments.threadId;return @{threadId=$Arguments.threadId}}
    throw 'Unexpected operation'
}
function Get-Accounts {return @(1..5|ForEach-Object {[pscustomobject]@{Id="a$_";Email="a$_@test";Active=($_ -eq 1);Switchable=$true;FiveHour=100;Weekly=90;UsageError=$null;FiveHourReset=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+18000);WeeklyReset=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+604800)}})}
function Invoke-SwitchAccount {throw 'Unexpected switch'}
try{
    $id='11111111-1111-1111-1111-111111111111';$path=Rollout $id;Desktop $id
    $v=Get-TurnView $id
    Check 'lost turn with exact open marker is recoverable' ($v.Outcome -eq 'interrupted' -and $v.Reason -eq 'open-turn')
    $null=Rollout $id 'turn_aborted'
    Check 'explicit Stop with null desktop error remains protected' ((Get-TurnView $id).Outcome -eq 'waiting')
    $null=Rollout $id 'task_complete'
    Check 'completed raw turn is never reopened' ((Get-TurnView $id).Outcome -eq 'waiting')
    $null=Rollout $id '' 'different-turn'
    Check 'different turn marker does not grant recovery' ((Get-TurnView $id).Outcome -eq 'waiting')
    $null=Rollout $id
    Add-Content $path (Record 'response_item' @{type='message';role='assistant';phase='final_answer';content=@(@{type='output_text';text='Done'})}) -Encoding UTF8
    Check 'final answer without terminal marker still protected' ((Get-TurnView $id).Outcome -eq 'waiting')
    $null=Rollout $id
    Add-Content $path (Record 'response_item' @{type='message';role='user';content=@(@{type='input_text';text='task_complete turn_aborted usage_limit_exceeded'})}) -Encoding UTF8
    Check 'marker words in user content cannot spoof events' ((Get-TurnView $id).Outcome -eq 'interrupted')
    $null=Rollout $id
    [IO.File]::AppendAllText($path,'{"timestamp":',(New-Object Text.UTF8Encoding($false)))
    Check 'partial trailing write is not evidence' ((Get-TurnView $id).Outcome -eq 'waiting')
    $null=Rollout $id
    $script:data[$id].thread.status.type='active'
    Check 'running thread always wins over open raw marker' ((Get-TurnView $id).Outcome -eq 'running')
    $script:data[$id].thread.status.activeFlags=@('waitingOnApproval')
    Check 'approval wait protected even with open marker' ((Get-TurnView $id).Outcome -eq 'waiting')
    Desktop $id
    $script:data[$id].turns[0].items=@(@{type='userMessage';content=@(@{type='text';text='先等我确认，不要继续'})})
    Check 'explicit user wait protected' ((Get-TurnView $id).Outcome -eq 'waiting')
    Desktop $id 'aborted'
    Check 'explicit desktop aborted status protected' ((Get-TurnView $id).Outcome -eq 'waiting')
    Desktop $id 'interrupted' 'unknown error'
    Check 'unknown non-null error does not become open-turn recovery' ((Get-TurnView $id).Outcome -eq 'waiting')
    Desktop $id
    $script:files=@()
    Check 'missing rollout cannot grant recovery' ((Get-TurnView $id).Outcome -eq 'waiting')
    $null=Rollout $id
    $id2='22222222-2222-2222-2222-222222222222';$null=Rollout $id2 'task_complete';Desktop $id2 'failed' 'usage_limit_exceeded'
    $id3='33333333-3333-3333-3333-333333333333';$null=Rollout $id3 'turn_aborted';Desktop $id3
    $id4='44444444-4444-4444-4444-444444444444';$null=Rollout $id4 'task_complete';Desktop $id4 'completed'
    function Get-DesktopSnapshot {return [pscustomobject]@{Recent=@($id,$id2,$id3,$id4|ForEach-Object {Get-TurnView $_});Active=@()}}
    $s=[pscustomobject]@{handled=[pscustomobject]@{legacy='keep'}};Initialize-V2State $s
    Set-StateFlag $s.switchIncidents ($id2+':source-1') 'a1'
    Invoke-WatchRound $s
    Check 'same round resumes both abandoned and quota-limited turns' ($script:sends.Count -eq 2 -and $id -in $script:sends -and $id2 -in $script:sends)
    Check 'stopped and finished threads receive nothing' ($id3 -notin $script:sends -and $id4 -notin $script:sends)
    Invoke-WatchRound $s
    $s=Read-State;Invoke-WatchRound $s
    Check 'two-thread recovery deduplicates across polls and restart' ($script:sends.Count -eq 2 -and $s.handled.legacy -eq 'keep')
    $s=[pscustomobject]@{handled=[pscustomobject]@{}};Initialize-V2State $s
    $v=Get-TurnView $id;$null=Rollout $id 'turn_aborted';Send-DesktopContinue $s $v
    Check 'Stop after selection is rechecked before sending' ($script:sends.Count -eq 2)
}finally{Remove-TestDirectory $tmp}
Write-Host "通过 $pass 项，失败 $fail 项"
exit $(if($fail){1}else{0})
