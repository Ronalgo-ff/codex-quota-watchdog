# Real missed-resume wording and discovery-window recovery, with isolated state and no live sends.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-resume-selection-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $tmp
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json';$Live=$true
$Script:Config.ResumeQuietMin=0;$Script:Config.FallbackAccountIds=@()
$pass=0;$fail=0;$script:sends=@();$script:events=@();$script:reads=@();$script:data=@{};$script:activeAccount='a1';$script:switches=0
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Write-Event($Message,$Level){$script:events+=$Message}
function Write-File($Message,$Level){}
function Get-RecentSessions{return @()}
function Get-LocalDesktopThreads{return @()}
function Get-Accounts{return @('a1','a2'|ForEach-Object{[pscustomobject]@{Id=$_;Email=($_+'@test');Active=($_ -eq $script:activeAccount);Switchable=$true;FiveHour=100;Weekly=80;FiveHourReset=2000000000;WeeklyReset=2000100000;UsageError=$null}})}
function Get-CodexDesktopLaunch{return $null}
function Invoke-SwitchAccount($Account){$script:switches++;$script:activeAccount=$Account.Id;return $true}
function New-State{$s=[pscustomobject]@{handled=[pscustomobject]@{legacy='keep'};pendingResumes=[pscustomobject]@{}};Initialize-V2State $s;return $s}
function Set-Turn($Id,$User,$Status='failed',$ErrorText='Your workspace is out of credits. Add credits to continue.',$DesktopStatus='idle',$TurnId='source'){
    $items=@($User|ForEach-Object{[pscustomobject]@{type='userMessage';content=@([pscustomobject]@{type='text';text=$_})}})
    $script:data[$Id]=[pscustomobject]@{thread=[pscustomobject]@{id=$Id;status=[pscustomobject]@{type=$DesktopStatus;activeFlags=@()};updatedAt=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-300)};turns=@([pscustomobject]@{id=$TurnId;status=$Status;error=$ErrorText;items=$items})}
}
function Invoke-DesktopTool($Tool,$Arguments){
    if($Tool -eq 'read_thread'){$script:reads+=$Arguments.threadId;return $script:data[$Arguments.threadId]}
    if($Tool -eq 'list_threads'){return [pscustomobject]@{pinnedThreads=@();threads=$script:listed;unavailableHosts=@()}}
    if($Tool -eq 'send_message_to_thread'){$script:sends+=$Arguments.threadId;return @{threadId=$Arguments.threadId;status='sent'}}
    throw 'Unexpected tool'
}
function Listing($Ids){$i=0;return @($Ids|ForEach-Object{$i++;[pscustomobject]@{id=$_;kind='codex';hostId='local';status='idle';updatedAt=(2000000000-$i)}})}
try{
    # This exact instruction was incorrectly matched as "不要...任务" on 2026-11-07.
    $actual='你这个对话就一直保持这样，不要停下来，直到所有的任务完成再停下来，因为中间可能有一些等待仿真完成的过程。'
    Set-Turn 'research' $actual
    $v=Get-TurnView 'research'
    Check 'real do-not-stop instruction retains structured credits failure' ($v.Outcome -eq 'limit')
    foreach($text in @('不要停止执行任务，直到完成','任务没完成不要停','别暂停，继续执行','不要因为等待仿真就停止工作','keep working, do not stop','do not pause this task',"don't stop this task")){
        Set-Turn 'research' $text
        Check ('negative stop is not a pause: '+$text) ((Get-TurnView 'research').Outcome -eq 'limit')
    }
    foreach($text in @('暂停任务，不要继续','不要自动继续','请先停止执行','请先暂停这项任务','先停一下','先等我确认','pause this task','stop this task','pause this task.',"don't continue")){
        Set-Turn 'research' $text
        Check ('prompt pause wording cannot veto credit recovery: '+$text) ((Get-TurnView 'research').Outcome -eq 'limit')
    }
    Set-Turn 'research' @('暂停任务，不要继续','现在继续执行')
    Check 'steered user wording never vetoes credit recovery' ((Get-TurnView 'research').Outcome -eq 'limit')
    $reply='<send_user_message_question_reply>'+"`n"+'[{"question":"暂停任务还是继续？","answer":"继续执行"}]'+"`n"+'</send_user_message_question_reply>'
    Set-Turn 'research' @('继续执行',$reply)
    Check 'assistant question echoed in answer envelope is not a user pause' ((Get-TurnView 'research').Outcome -eq 'limit')
    Set-Turn 'research' ('<send_user_message_question_reply>'+"`n"+'[{"question":"如何处理？","answer":"暂停任务，不要继续"}]'+"`n"+'</send_user_message_question_reply>')
    Check 'pause answer in reply envelope cannot veto credit recovery' ((Get-TurnView 'research').Outcome -eq 'limit')
    Set-Turn 'research' '暂停任务，不要继续' -ErrorText 'stream_disconnected: connection reset'
    Check 'prompt pause wording cannot veto network recovery' ((Get-TurnView 'research').Outcome -eq 'retryable')
    Set-Turn 'research' '暂停任务，不要继续' -Status 'completed' -ErrorText ''
    Check 'normally completed turn still finishes regardless of prompt wording' ((Get-TurnView 'research').Outcome -eq 'finished')

    # Preserve a running task discovered among five even when newer chats push it out.
    Set-Turn 'research' $actual -Status 'inProgress' -ErrorText '' -DesktopStatus 'active'
    foreach($id in @('a','b','c','d','e')){Set-Turn $id '已完成' -Status 'completed' -ErrorText ''}
    $script:listed=Listing @('research','a','b','c','d');$s=New-State
    Invoke-WatchRound $s
    Save-State $s;$s=Read-State
    $script:listed=Listing @('a','b','c','d','e')
    Set-Turn 'research' '暂停任务，不要继续'
    $script:reads=@();Invoke-WatchRound $s
    Check 'tracked running task is checked after falling outside recent five across restart' ($script:reads -contains 'research')
    Check 'tracked credits failure triggers one confirmed switch' ($script:switches -eq 1)
    Clear-StateFlag $s 'desktopReadyAfter';Save-State $s;$s=Read-State;Invoke-WatchRound $s
    Check 'fallen-out credit failure is continued exactly once' (@($script:sends|Where-Object {$_ -eq 'research'}).Count -eq 1)
    Save-State $s;$s=Read-State;Invoke-WatchRound $s
    Check 'retained candidate never duplicates an accepted continuation after restart' (@($script:sends|Where-Object {$_ -eq 'research'}).Count -eq 1)
    Check 'unseen historical chat outside discovery window is never resumed' ($script:sends -notcontains 'e')
    Set-Turn 'research' '继续' -Status 'inProgress' -ErrorText '' -DesktopStatus 'active' -TurnId 'automatic'
    $script:data.research.thread.updatedAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Invoke-WatchRound $s
    Set-Turn 'research' '继续' -Status 'completed' -ErrorText '' -TurnId 'automatic'
    $script:data.research.thread.updatedAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Invoke-WatchRound $s;$script:reads=@();Invoke-WatchRound $s
    Check 'completed retained task stops being tracked outside discovery window' ($script:reads -notcontains 'research')
    Check 'legacy dedup survives recovery tracking' ($s.handled.legacy -eq 'keep')

    Set-Turn 'old-running' '执行任务' -Status 'inProgress' -ErrorText '' -DesktopStatus 'active'
    $script:listed=Listing @('a','b','c','d','e','old-running');$script:listed[-1].status='active'
    $script:reads=@();Invoke-WatchRound $s
    Check 'watcher started after task left recent five still discovers listed running work' ($script:reads -contains 'old-running' -and $s.recoveryWatch.PSObject.Properties['old-running'])
    Set-Turn 'old-running' '暂停任务，不要继续' -Status 'completed' -ErrorText '';Invoke-WatchRound $s
    $script:listed=Listing @('a','b','c','d','e')

    Set-Turn 'approval' '执行任务' -Status 'inProgress' -ErrorText '' -DesktopStatus 'active'
    $script:data.approval.thread.status.activeFlags=@('waitingOnApproval')
    $script:listed=Listing @('approval','a','b','c','d');Invoke-WatchRound $s
    Save-State $s;$s=Read-State;$script:listed=Listing @('a','b','c','d','e');$script:reads=@();Invoke-WatchRound $s
    Check 'pending tool approval outside recent five remains tracked without a prompt' ($script:reads -contains 'approval' -and $script:sends -notcontains 'approval')
    $before=(Get-Content (Join-Path $tmp 'resume-history.jsonl')).Count;Invoke-WatchRound $s
    Check 'unchanged polls do not grow decision history' ((Get-Content (Join-Path $tmp 'resume-history.jsonl')).Count -eq $before)
    Set-Turn 'approval' '暂停任务，不要继续' -Status 'completed' -ErrorText ''
    Invoke-WatchRound $s;$script:reads=@();Invoke-WatchRound $s
    Check 'completed tracked task is released based on status regardless of pause wording' ($script:reads -notcontains 'approval' -and $script:sends -notcontains 'approval')
    $audit=Get-Content (Join-Path $tmp 'resume-history.jsonl')|ForEach-Object{$_|ConvertFrom-Json}
    Check 'decision history retains credit failure and actual completion without text pause classification' (@($audit|Where-Object {$_.threadId -eq 'research' -and $_.outcome -eq 'limit' -and $_.selectedBy -eq 'tracked'}).Count -eq 1 -and @($audit|Where-Object {$_.threadId -eq 'approval' -and $_.outcome -eq 'finished'}).Count -eq 1 -and @($audit|Where-Object {$_.reason -eq 'user-pause'}).Count -eq 0)
    $auditPath=Join-Path $tmp 'resume-history.jsonl'
    [IO.File]::WriteAllText($auditPath,(' ' * 2MB))
    Write-ResumeAudit @{at='fixture';threadId='research';outcome='running'}
    Check 'decision history rotates at two MB with one retained previous file' ((Get-Item ($auditPath+'.1')).Length -eq 2MB -and (Get-Item $auditPath).Length -lt 1024)
}finally{Remove-TestDirectory $tmp}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
