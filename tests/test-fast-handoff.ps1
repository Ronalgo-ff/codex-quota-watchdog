# Timing, rejection and safety regressions against isolated services/state.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$switchFunction=${function:Invoke-SwitchAccount}
$tmp=Join-Path $env:TEMP ('quota-fast-handoff-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $tmp
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json';$Live=$true
$pass=0;$fail=0;$script:sends=0;$script:reads=0;$script:pauses=0;$script:events=@()
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Write-Event($Message,$Level){$script:events+=$Message}
function Write-File($Message,$Level){}
function Request-ManualPause($State,$Key,$Reason,$Details){$script:pauses++;$ex=New-Object InvalidOperationException($Reason);$ex.Data['QuotaManualPause']=$true;throw $ex}
function New-State{$s=[pscustomobject]@{handled=[pscustomobject]@{legacy='preserved'}};Initialize-V2State $s;return $s}
function Accounts{return @(1..5|ForEach-Object {[pscustomobject]@{Id="a$_";Email="a$_@test";Active=($_ -eq 1);Switchable=$true;FiveHour=100;Weekly=(40+$_);UsageError=$null;FiveHourReset=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+18000);WeeklyReset=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+604800)}})}
$script:accounts=Accounts;$script:quotaReads=0;$script:activateAt=0;$script:nativeSwitches=0
function Get-Accounts{
    $script:quotaReads++
    if($script:activateAt -gt 0 -and $script:quotaReads -ge $script:activateAt){foreach($a in $script:accounts){$a.Active=($a.Id -eq 'a5')}}
    return $script:accounts
}
function Invoke-Csw($Command,$Arguments){if($Command -ne 'switch_account_and_restart_chatgpt'){throw 'Unexpected mutation'};$script:nativeSwitches++}
function Get-RecentSessions{return @()}
function Get-CodexDesktopLaunch {return $null} # Isolate desktop restart from real apps.
$script:mode='accept';$script:turn='source';$script:status='idle';$script:outcome='limit'
function Get-TurnView($ThreadId){
    $script:reads++
    return [pscustomobject]@{Id=$ThreadId;TurnId=$script:turn;Outcome=$script:outcome;Status=$script:status;Error='usage_limit_exceeded';User='';At=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-300);StartedEpoch=0;DesktopMessage=$false;Reason='';Final=''}
}
function Invoke-DesktopTool($Tool,$Arguments){
    if($Tool -ne 'send_message_to_thread'){throw 'Unexpected tool'}
    $script:sends++
    if($script:mode -eq 'reject'){$ex=New-Object InvalidOperationException('App-server task is not ready: execution-config-loading');$ex.Data['QuotaPreDispatchRejected']=$true;throw $ex}
    if($script:mode -eq 'timeout'){throw 'Desktop pipe response timeout; delivery may be uncertain'}
    return [pscustomobject]@{threadId=$Arguments.threadId}
}
try{
    Check 'default handoff buffer and initial rejection delay are 10 seconds' ($Script:Config.DesktopReadyDelaySec -eq 10 -and $Script:Config.DesktopConfigRetrySec -eq 10)
    $script:activateAt=1;$watch=[Diagnostics.Stopwatch]::StartNew()
    $ok=& $switchFunction $script:accounts[4];$watch.Stop()
    Check 'already switched account is confirmed immediately' ($ok -and $watch.Elapsed.TotalSeconds -lt 1 -and $script:quotaReads -eq 1 -and $script:nativeSwitches -eq 1)
    $script:accounts=Accounts;$script:quotaReads=0;$script:activateAt=2;$watch.Restart()
    $ok=& $switchFunction $script:accounts[4];$watch.Stop()
    Check 'pending switch is checked again after one second without resending' ($ok -and $watch.Elapsed.TotalSeconds -ge 0.9 -and $watch.Elapsed.TotalSeconds -lt 2.5 -and $script:quotaReads -eq 2 -and $script:nativeSwitches -eq 2)
    $script:accounts=Accounts;$script:quotaReads=0;$script:activateAt=0;$Script:Config.SwitchVerifySec=1;$watch.Restart()
    $ok=& $switchFunction $script:accounts[4];$watch.Stop()
    Check 'unconfirmed switch still fails safely with one mutation' (-not $ok -and $watch.Elapsed.TotalSeconds -lt 2.5 -and $script:nativeSwitches -eq 3)
    $Script:Config.SwitchVerifySec=60
    $s=New-State;$view=Get-TurnView 'fast-thread'
    Set-StateFlag $s 'desktopReadyAfter' ((Get-Date).AddSeconds(10).ToString('o'));Send-DesktopContinue $s $view
    Check '10 second gate creates no premature delivery or dedup entry' ($script:sends -eq 0 -and @($s.deliveries.PSObject.Properties).Count -eq 0 -and $s.handled.legacy -eq 'preserved')
    Set-StateFlag $s 'desktopReadyAfter' ((Get-Date).AddSeconds(-1).ToString('o'));$script:mode='reject';Send-DesktopContinue $s $view
    $key='desktop:fast-thread:source';$d=$s.deliveries.$key;$remaining=$d.nextAttemptEpoch-[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Check 'loading rejection defers ten seconds and is never marked handled' ($d.phase -eq 'deferred' -and $remaining -ge 9 -and $remaining -le 10 -and -not $s.handled.PSObject.Properties[$key] -and $script:pauses -eq 0)
    Send-DesktopContinue $s $view;Save-State $s;$s=Read-State;Send-DesktopContinue $s $view
    Check 'polling and restart both respect deferred deadline' ($script:sends -eq 1)
    $s.deliveries.$key.nextAttemptEpoch=0;$script:mode='accept';Send-DesktopContinue $s $view;Send-DesktopContinue $s $view
    Check 'ready retry accepts once and deduplicates' ($script:sends -eq 2 -and $s.deliveries.$key.phase -eq 'accepted' -and $s.handled.PSObject.Properties[$key])
    $s=New-State;$script:mode='reject';Send-DesktopContinue $s $view;$s.deliveries.$key.nextAttemptEpoch=0
    $script:outcome='running';$script:status='active';$before=$script:sends;Send-DesktopContinue $s $view
    Check 'running task blocks retry before it can send' ($script:sends -eq $before)
    $script:turn='user-new-turn';Update-DesktopDeliveries $s;Send-DesktopContinue $s $view
    Check 'user new turn supersedes deferred request' ($script:sends -eq $before -and $s.deliveries.$key.phase -eq 'superseded')
    $script:turn='source';$script:outcome='limit';$script:status='idle';$script:mode='reject';$s=New-State;Send-DesktopContinue $s $view
    $s.deliveries.$key.nextAttemptEpoch=0;$script:accounts[0].FiveHour=0;$before=$script:sends;Send-DesktopContinue $s $view
    Check 'quota spent while loading blocks retry' ($script:sends -eq $before)
    $script:accounts=Accounts;$script:mode='timeout';$s=New-State;$paused=$false
    try{Send-DesktopContinue $s $view}catch{$paused=$_.Exception.Data['QuotaManualPause'] -eq $true}
    $before=$script:sends;Send-DesktopContinue $s $view
    Check 'lost response pauses and never retries' ($paused -and $s.deliveries.$key.phase -eq 'uncertain' -and $script:sends -eq $before)
    $script:mode='reject';$s=New-State;$beforePause=$script:pauses
    foreach($attempt in 1..8){
        if($s.deliveries.PSObject.Properties[$key]){$s.deliveries.$key.nextAttemptEpoch=0}
        try{Send-DesktopContinue $s $view}catch{if($_.Exception.Data['QuotaManualPause'] -ne $true){throw}}
    }
    Check 'prolonged loading blocks this turn at eight without pausing other work' ($s.deliveries.$key.attempts -eq 8 -and $script:pauses -eq $beforePause -and $s.deliveries.$key.phase -eq 'blocked' -and (Get-StateFlag $s.threadIssues ('resume-config:'+ $key)))
    $script:mode='accept';$s=New-State;$old='desktop:old-thread:older'
    Set-StateFlag $s.deliveries $old ([pscustomobject]@{phase='superseded';threadId='old-thread';sourceTurnId='older';sentEpoch=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-86400)})
    $before=$script:reads;Update-DesktopDeliveries $s
    Check 'settled historical replacement is not read every round' ($script:reads -eq $before -and $s.deliveries.$old.phase -eq 'superseded')
    $s.deliveries.$old.sentEpoch=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();$before=$script:reads
    Update-DesktopDeliveries $s
    Check 'recent replacement still checks for late acknowledgement evidence' ($script:reads -eq $before+1)
    $s.deliveries.$old.sentEpoch-=86400
    $d=[pscustomobject]@{phase='accepted';threadId='fast-thread';sourceTurnId='source';sentEpoch=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()}
    Set-StateFlag $s.deliveries $key $d;$views=@{'fast-thread'=$view};$before=$script:reads
    Update-DesktopDeliveries $s -Views $views
    Check 'pending receipt reuses same-round authoritative snapshot' ($script:reads -eq $before -and $d.phase -eq 'accepted')
    $views=@{};$before=$script:reads;Update-DesktopDeliveries $s -Views $views
    Check 'unlisted pending receipt is still authoritatively checked' ($script:reads -eq $before+1)
    $s=New-State;Set-StateFlag $s.deliveries $key ([pscustomobject]@{phase='accepted';threadId='fast-thread';sourceTurnId='source';sentEpoch=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-121)})
    $beforePause=$script:pauses;$paused=$false
    try{Update-DesktopDeliveries $s -Views @{'fast-thread'=$view}}catch{$paused=$_.Exception.Data['QuotaManualPause'] -eq $true}
    Check 'uncertain receipt protection remains before any new action' ($paused -and $script:pauses -eq $beforePause+1)
    $script:accounts=Accounts;$script:accounts[0].FiveHour=0;$s=New-State
    function Invoke-SwitchAccount($Account){foreach($a in $script:accounts){$a.Active=$a.Id -eq $Account.Id};return $true}
    function Get-DesktopSnapshot{return [pscustomobject]@{Recent=@($view);Active=@();Views=@{'fast-thread'=$view}}}
    Invoke-WatchRound $s;$after=[datetime]::Parse($s.desktopReadyAfter)
    Check 'new confirmed switch persists ten second buffer' (($after-(Get-Date)).TotalSeconds -gt 9 -and ($after-(Get-Date)).TotalSeconds -le 10)
    $s=New-State;Set-StateFlag $s 'switchIntent' ([pscustomobject]@{id='crashed';targetId='a5';incidents=@('fast-thread:source')})
    Invoke-WatchRound $s
    Check 'reconciled switch also uses ten seconds' (-not (Get-StateFlag $s 'switchIntent') -and ([datetime]::Parse($s.desktopReadyAfter)-(Get-Date)).TotalSeconds -gt 9)
    $s=New-State;$script:accounts=Accounts;$script:accounts[0].FiveHour=0;$before=$script:accounts[0].Active
    function Get-DesktopSnapshot{return [pscustomobject]@{Recent=@($view);Active=@(@{id='other-running'});Views=@{'fast-thread'=$view}}}
    Invoke-WatchRound $s
    Check 'speed changes never restart unrelated running work' ($script:accounts[0].Active -eq $before -and -not (Get-StateFlag $s 'desktopReadyAfter'))
    $invalid=Join-Path $tmp 'invalid.json'
    [IO.File]::WriteAllText($invalid,'{"DesktopReadyDelaySec":0,"DesktopConfigRetrySec":-1,"SwitchVerifyPollSec":"oops"}')
    $config=@{DesktopReadyDelaySec=10;DesktopConfigRetrySec=10;SwitchVerifyPollSec=1};$applied=@(Import-Rules $invalid $config)
    Check 'invalid timing configuration retains safe defaults' ($config.DesktopReadyDelaySec -eq 10 -and $config.DesktopConfigRetrySec -eq 10 -and $config.SwitchVerifyPollSec -eq 1 -and @($applied|Where-Object {$_ -match '数值无效'}).Count -eq 3)
}finally{Remove-TestDirectory $tmp}
Write-Host "通过 $pass 项，失败 $fail 项"
exit $(if($fail){1}else{0})
