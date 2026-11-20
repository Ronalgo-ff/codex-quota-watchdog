# Exercise the production continuation limit across human turns and restarts.
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-resume-chain-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $tmp
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json';$Live=$true
$Script:Config.ResumeQuietMin=0;$Script:Config.ResumeMaxRounds=4
$Script:Config.FallbackAccountIds=@();$script:sends=0;$script:pauses=0;$pass=0;$fail=0
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Write-Event {param($Message,$Level)}
function Write-File {param($Message,$Level)}
function Request-ManualPause {$script:pauses++}
function Get-RecentSessions {return @()}
function Get-Accounts {return @([pscustomobject]@{Id='a1';Email='a1@test';Active=$true;Switchable=$true;FiveHour=100;Weekly=100;UsageError=$null})}
function Get-DesktopSnapshot {return [pscustomobject]@{Recent=@($script:view);Active=@();Views=@{($script:view.Id)=$script:view}}}
function Get-TurnView {param($ThreadId) return $script:view}
function Invoke-DesktopTool {
    param($Tool,$Arguments)
    if($Tool -ne 'send_message_to_thread'){throw 'Unexpected desktop call'}
    $script:sends++;return @{threadId=$Arguments.threadId}
}
function Invoke-SwitchAccount {throw 'Unexpected switch'}
function New-View($TurnId,$Outcome='interrupted',$User='Implement this feature',$At=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-300)){
    return [pscustomobject]@{Id='thread-1234';TurnId=$TurnId;Outcome=$Outcome;Status='idle';User=$User;At=$At;Error='';Reason='open-turn';DesktopMessage=$false}
}
function New-State {
    $s=[pscustomobject]@{handled=[pscustomobject]@{legacy='preserved'};pendingResumes=[pscustomobject]@{}}
    Initialize-V2State $s;return $s
}
try{
    $s=New-State
    Set-StateFlag $s.deliveries 'historical-receipt' ([pscustomobject]@{phase='completed';receipt='preserved'})
    foreach($i in 1..5){
        $key='desktop:thread-1234:historical-'+$i
        Set-StateFlag $s.handled $key '2026-11-05T01:00:00+08:00'
        Set-StateFlag $s.deliveries $key ([pscustomobject]@{threadId='thread-1234';sourceTurnId=('historical-'+$i);observedTurnId=('old-auto-'+$i);sentEpoch=1;phase='completed'})
    }
    $script:view=New-View 'new-human-task';Invoke-WatchRound $s
    Check 'five historical resumes do not prevent a new human task from recovering' ($script:sends -eq 1 -and $s.deliveries.'desktop:thread-1234:new-human-task'.phase -eq 'accepted')
    Save-State $s;$s=Read-State;Invoke-WatchRound $s
    Check 'same source turn is still deduplicated after restart' ($script:sends -eq 1 -and $s.handled.legacy -eq 'preserved')
    for($i=1;$i -le 4;$i++){
        $source=if($i -eq 1){'new-human-task'}else{'auto-'+($i-1)}
        $d=Get-StateFlag $s.deliveries ('desktop:thread-1234:'+$source)
        $outcome=if($i -eq 4){'retryable'}else{'unfinished'}
        $script:view=New-View ('auto-'+$i) $outcome $Script:Config.ResumeMessage $d.sentEpoch
        Update-DesktopDeliveries $s
        Save-State $s;$s=Read-State
        Check ('verified automatic chain survives restart at depth '+$i) ((Get-ResumeChainCount $s $script:view) -eq $i)
        Invoke-WatchRound $s
        Check ('continuous automatic recovery respects four-attempt boundary at depth '+$i) ($script:sends -eq [Math]::Min($i+1,4))
    }
    Check 'persistent network failure blocks only that chain with a durable report' ($script:pauses -eq 0 -and @($s.threadIssues.PSObject.Properties).Count -eq 1)
    $before=$script:sends;$script:view=New-View 'another-human-task';Invoke-WatchRound $s
    Check 'new user turn after capped chain permits recovery again' ($script:sends -eq $before+1 -and (Get-ResumeChainCount $s $script:view) -eq 0)
    Check 'historical handled records remain intact for deduplication' (@($s.handled.PSObject.Properties|Where-Object {$_.Name -like 'desktop:thread-1234:historical-*'}).Count -eq 5)
    Check 'legacy receipt without chain metadata survives and cannot break counting' ($s.deliveries.'historical-receipt'.receipt -eq 'preserved')
    $other=New-State
    Set-StateFlag $other.deliveries 'desktop:another-thread:source' ([pscustomobject]@{threadId='another-thread';sourceTurnId='source';observedTurnId='another-human-task';phase='failed'})
    Check 'other threads never contribute to the current recovery chain' ((Get-ResumeChainCount $other $script:view) -eq 0)
    Set-StateFlag $other.deliveries 'desktop:thread-1234:loop' ([pscustomobject]@{threadId='thread-1234';sourceTurnId='another-human-task';observedTurnId='another-human-task';phase='failed'})
    Check 'corrupt cyclic receipt cannot bypass bounded recovery' ((Get-ResumeChainCount $other $script:view) -eq 4)
}finally{Remove-TestDirectory $tmp}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
