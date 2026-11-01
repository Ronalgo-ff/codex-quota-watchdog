# Live roster changes through the real parser/engine. No live services or quota use.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-account-sync-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $tmp -Force
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json'
$Script:Config.ExpectedAccounts=6 # A stale legacy override must have no effect.
$Script:Config.ResetWaitPolicy='weekly-eligible';$Script:Config.FallbackAccountIds=@('a2');$Live=$true
$script:switches=@();$script:batches=0;$script:pauses=0
function Invoke-Csw {param($Command,$Arguments) if($Command -ne 'list_accounts'){throw 'Unexpected mutation'};return $script:raw}
function Get-DesktopSnapshot {return [pscustomobject]@{Recent=@();Active=@()}}
function Get-CodexDesktopLaunch {return $null}
function Invoke-SwitchAccount {param($Account) $script:switches+=$Account.Id;foreach($a in $script:raw){$a.active=$a.id -eq $Account.Id};return $true}
function Start-QuotaBatch {param($State,$Accounts) $script:batches++;$State.waitingReset.phase='running'}
function Request-ManualPause {param($State,$Key,$Reason,$Details) $script:pauses++}
function Write-Event {param($Message,$Level)}
function Write-File {param($Message,$Level)}
function New-State {$s=[pscustomobject]@{handled=[pscustomobject]@{old='retained'};pendingResumes=[pscustomobject]@{}};Initialize-V2State $s;return $s}
function New-Accounts([int]$Count,[double]$Five=100){
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return @(1..$Count|ForEach-Object {[pscustomobject]@{
        id="a$_";email="a$_@test";active=($_ -eq 1);plan='team';directSwitchCompatible=$true
        usage=[pscustomobject]@{error=$null;primary=@{remainingPercent=$Five;windowMinutes=300;resetsAt=$now+18000};secondary=@{remainingPercent=40+$_;windowMinutes=10080;resetsAt=$now+604800}}
    }})
}
$pass=0;$fail=0
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
try{
    $s=New-State
    foreach($count in @(2,8,3,1)){
        $script:raw=New-Accounts $count
        Invoke-WatchRound $s
        $proof=Get-ResumeAccountProof $s
        $status=Get-Content (Join-Path $tmp 'quota-status.json') -Raw|ConvertFrom-Json
        Check ("roster size $count works in same process despite stale count") ($status.accountCount -eq $count -and $proof.accountId -eq 'a1' -and $s.handled.old -eq 'retained' -and $script:pauses -eq 0)
    }
    $script:raw=New-Accounts 8;$script:raw[0].usage.primary.remainingPercent=0
    Invoke-WatchRound $s
    Check 'new accounts participate in selection immediately' ($script:switches.Count -eq 1 -and $script:switches[0] -eq 'a8')
    $script:raw=New-Accounts 3;$script:raw[0].usage.primary.remainingPercent=0
    $script:raw[2].id='replacement'
    Invoke-WatchRound $s
    Check 'same-count replacement participates without manual refresh' ($script:switches[-1] -eq 'replacement' -and $Script:Config.FallbackAccountIds[0] -eq 'a2')
    foreach($kind in @('duplicate','blank','missing-id','missing-active','multiple-active','quota')){
        $script:raw=New-Accounts 3
        switch($kind){
            'duplicate' {$script:raw[1].id=$script:raw[0].id}
            'blank' {$script:raw[1].id=' '}
            'missing-id' {$script:raw[1].PSObject.Properties.Remove('id')}
            'missing-active' {$script:raw[0].active=$false}
            'multiple-active' {$script:raw[1].active=$true}
            'quota' {$script:raw[0].usage.primary.remainingPercent=$null}
        }
        $before=$script:switches.Count;$threw=$false
        try{Invoke-WatchRound (New-State)}catch{$threw=$true}
        Check ($kind+' prevents actions and continuation proof') ($threw -and $script:switches.Count -eq $before -and $null -eq (Get-ResumeAccountProof (New-State)))
    }
    $script:raw=@();$message='';$before=$script:switches.Count
    try{Invoke-WatchRound (New-State)}catch{$message=$_.Exception.Message}
    Check 'empty response waits for service without treating it as account deletion' ((Get-RecoveryPolicy $message) -eq 'wait-service' -and $null -eq (Get-ResumeAccountProof (New-State)) -and $script:switches.Count -eq $before)
    $script:raw=New-Accounts 2 0;$s=New-State
    $null=Invoke-ResetCycle $s @(Get-Accounts)
    $script:raw=New-Accounts 8 0
    $null=Invoke-ResetCycle $s @(Get-Accounts)
    Check 'adding accounts while waiting updates cohort without consuming' ($s.waitingReset.accountIds.Count -eq 8 -and $script:batches -eq 0 -and $script:pauses -eq 0)
    $script:raw=New-Accounts 3 0;$script:raw[2].id='replacement'
    $null=Invoke-ResetCycle $s @(Get-Accounts)
    Save-State $s;$s=Read-State
    Check 'removals and replacements persist across restart' (($s.waitingReset.accountIds -join ',') -eq 'a1,a2,replacement' -and $s.handled.old -eq 'retained')
    foreach($a in $script:raw){$a.usage.primary.remainingPercent=100}
    $null=Invoke-ResetCycle $s @(Get-Accounts)
    Check 'updated cohort can start its first batch normally' ($script:batches -eq 1 -and $script:pauses -eq 0)

    # An in-flight batch keeps its original identity, even when the roster changes.
    $job=Join-Path $tmp 'batch.json'
    Set-StateFlag $s.waitingReset 'batchFile' $job
    Set-StateFlag $s.waitingReset 'pid' $PID
    Set-StateFlag $s.waitingReset 'processStartedAt' (Get-Process -Id $PID).StartTime.ToString('o')
    Write-JsonAtomic $job @{id='original';phase='running';accounts=@($s.waitingReset.accountIds|ForEach-Object {@{id=$_;phase='pending'}})}
    $script:raw=New-Accounts 8
    $null=Invoke-ResetCycle $s @(Get-Accounts)
    Check 'running batch is not replaced or expanded after account addition' ($script:batches -eq 1 -and $s.waitingReset.accountIds.Count -eq 3 -and $script:pauses -eq 0)
    Write-JsonAtomic $job @{id='original';phase='partial';accounts=@(@{id='a1';phase='success'},@{id='a2';phase='uncertain'},@{id='replacement';phase='success'})}
    $result=Invoke-ResetCycle $s @(Get-Accounts)
    Check 'original receipts remain valid after roster changes without replay' ($result -eq 'recovered' -and $script:batches -eq 1 -and $script:pauses -eq 0)
    $rawReceipt=[IO.File]::ReadAllText($job)
    $null=Invoke-ResetCycle $s @(Get-Accounts)
    Check 'successful batch does not charge newly added accounts on next poll' ($s.waitingReset.accountIds.Count -eq 8 -and $script:batches -eq 1 -and [IO.File]::ReadAllText($job) -eq $rawReceipt)

    # A preflight membership change is safe to replan: no requests were sent.
    $s=New-State
    Set-StateFlag $s 'waitingReset' ([pscustomobject]@{phase='running';accountIds=@('old');batchFile=$job})
    Write-JsonAtomic $job @{id='preflight';phase='preflight-retry';accounts=@(@{id='old';phase='pending'})}
    $null=Invoke-ResetCycle $s @(Get-Accounts)
    Check 'preflight-only roster change replans automatically without consuming' ($s.waitingReset.phase -eq 'waiting' -and $s.waitingReset.accountIds.Count -eq 8 -and $script:batches -eq 1 -and $script:pauses -eq 0)

    # A removed successful account cannot strand a completed cohort forever.
    $s=New-State
    Set-StateFlag $s 'waitingReset' ([pscustomobject]@{phase='running';accountIds=@('removed');batchFile=$job})
    Write-JsonAtomic $job @{id='removed';phase='success';accounts=@(@{id='removed';phase='success'})}
    $result=Invoke-ResetCycle $s @(Get-Accounts)
    Check 'removed successful accounts do not block the latest roster' ($result -eq 'none' -and -not (Get-StateFlag $s 'waitingReset') -and $script:pauses -eq 0 -and $script:batches -eq 1)
    Set-StateFlag $s 'waitingReset' ([pscustomobject]@{phase='running';accountIds=@('removed');batchFile=$job})
    Write-JsonAtomic $job @{id='uncertain';phase='failed';accounts=@(@{id='removed';phase='uncertain'})}
    $null=Invoke-ResetCycle $s @(Get-Accounts)
    Check 'unknown consume outcome still pauses after account removal' ($script:pauses -eq 1 -and $script:batches -eq 1)
}finally{Remove-TestDirectory $tmp}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
