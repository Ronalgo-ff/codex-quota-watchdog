# Run-scoped reserve limits through the real parser, selection and reset engine.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-reserve-policy-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $tmp -Force
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json';$Live=$true
$Script:Config.ResetWaitPolicy='weekly-eligible';$Script:Config.FallbackAccountIds=@()
$script:switches=@();$script:batches=@();$script:pauses=0;$script:events=@()
function Invoke-Csw {param($Command,$Arguments) if($Command -ne 'list_accounts'){throw 'Unexpected mutation'};return $script:raw}
function Get-DesktopSnapshot {return [pscustomobject]@{Recent=@();Active=@()}}
function Get-CodexDesktopLaunch {return $null}
function Invoke-SwitchAccount {param($Account) $script:switches+=$Account.Id;foreach($a in $script:raw){$a.active=$a.id -eq $Account.Id};return $true}
function Start-QuotaBatch {param($State,$Accounts) $script:batches+=,@($Accounts.Id);$State.waitingReset.phase='running'}
function Request-ManualPause {param($State,$Key,$Reason,$Details) $script:pauses++}
function Write-Event {param($Message,$Level) $script:events+=$Message}
function Write-File {param($Message,$Level)}
function New-State {param([int]$Count=0) $Script:ReserveAccountCount=$Count;$s=[pscustomobject]@{handled=[pscustomobject]@{old='preserved'};pendingResumes=[pscustomobject]@{}};Initialize-V2State $s;return $s}
function New-Accounts {
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $ordinary=@(1..2|ForEach-Object {[pscustomobject]@{id="a$_";email="a$_@test";active=($_ -eq 1);plan='team';directSwitchCompatible=$true;usage=@{error=$null;primary=@{remainingPercent=0;windowMinutes=300;resetsAt=$now+18000};secondary=@{remainingPercent=50;windowMinutes=10080;resetsAt=$now+604800}}}})
    return $ordinary+@(1..3|ForEach-Object {[pscustomobject]@{id="r$_";email="r$_@test";active=$false;plan='team';directSwitchCompatible=$true;usage=@{error=$null;primary=@{remainingPercent=100-$_*10;windowMinutes=10080;resetsAt=$now+604800};secondary=$null}}})
}
$pass=0;$fail=0
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
try{
    $script:raw=New-Accounts;$s=New-State
    Invoke-WatchRound $s
    Check 'reserves are disabled by default even while all three have quota' ($script:switches.Count -eq 0 -and $s.waitingReset.phase -eq 'waiting' -and ($s.waitingReset.accountIds -join ',') -eq 'a1,a2' -and $s.runAccountPolicy.selectedIds.Count -eq 0)
    foreach($a in $script:raw[0..1]){$a.usage.primary.remainingPercent=100}
    Invoke-WatchRound $s
    Check 'disabled reserves do not block uniform ordinary reset batch' ($script:batches.Count -eq 1 -and ($script:batches[-1] -join ',') -eq 'a1,a2')
    foreach($count in @(1,2,3)){
        $script:raw=New-Accounts;$s=New-State $count;$before=$script:switches.Count
        Invoke-WatchRound $s
        Check ("enabling $count binds that many accounts and uses best reserve last") ($s.runAccountPolicy.selectedIds.Count -eq $count -and $s.runAccountPolicy.selectedIds[0] -eq 'r1' -and $script:switches.Count -eq $before+1 -and $script:switches[-1] -eq 'r1')
        foreach($id in @($s.runAccountPolicy.selectedIds)){
            foreach($a in $script:raw|Where-Object {$_.id -eq $id}){$a.usage.primary.remainingPercent=0}
        }
        Clear-StateFlag $s 'desktopReadyAfter';$before=$script:switches.Count
        Invoke-WatchRound $s
        Check ("exhausted $count allowance never borrows an unselected reserve") ($script:switches.Count -eq $before -and $s.waitingReset.phase -eq 'waiting')
    }
    $script:raw=New-Accounts;$s=New-State 2
    Invoke-WatchRound $s;$script:raw[2].usage.primary.remainingPercent=0;Clear-StateFlag $s 'desktopReadyAfter'
    Invoke-WatchRound $s
    Check 'two-account allowance uses second selected reserve after first depletes' ($script:switches[-1] -eq 'r2')
    $script:raw=New-Accounts;$s=New-State 1
    Invoke-WatchRound $s
    $new=$script:raw[4]|ConvertTo-Json -Depth 8|ConvertFrom-Json;$new.id='r4';$new.usage.primary.remainingPercent=100
    $script:raw+=$new;$script:raw[2].usage.primary.remainingPercent=0;Clear-StateFlag $s 'desktopReadyAfter'
    $before=$script:switches.Count;Invoke-WatchRound $s
    Check 'newly added richer reserve cannot replace exhausted selected account' (($s.runAccountPolicy.selectedIds -join ',') -eq 'r1' -and 'r4' -in $s.runAccountPolicy.knownReserveIds -and $script:switches.Count -eq $before)
    $script:raw=@($script:raw|Where-Object {$_.id -ne 'r1'});foreach($a in $script:raw){$a.active=$a.id -eq 'a1'}
    Save-State $s;$s=Read-State;Invoke-WatchRound $s
    Check 'deleted selected reserve is not replaced after state reload' (($s.runAccountPolicy.selectedIds -join ',') -eq 'r1' -and $script:switches.Count -eq $before -and $s.handled.old -eq 'preserved')
    # Known unselected identities remain excluded during a quota read outage.
    foreach($a in $script:raw|Where-Object {$_.id -eq 'r2'}){$a.usage=@{error='temporarily unavailable';primary=$null;secondary=$null}}
    foreach($a in $script:raw|Where-Object {$_.id -in @('a1','a2')}){$a.usage.primary.remainingPercent=100}
    Invoke-WatchRound $s
    Check 'unselected reserve quota outage does not block ordinary batch' (($script:batches[-1] -join ',') -eq 'a1,a2')
    $script:raw=New-Accounts;foreach($a in $script:raw){$a.active=$a.id -eq 'r2'};$s=New-State 1
    $proof=Get-ResumeAccountProof $s
    Check 'unselected active reserve cannot authorize continuation' ($null -eq $proof -and ($s.runAccountPolicy.selectedIds -join ',') -eq 'r1')
    $script:raw=New-Accounts;$script:raw[0].usage.primary.remainingPercent=100;$s=New-State 3;$before=$script:switches.Count
    Invoke-WatchRound $s
    Check 'available ordinary account prevents premature reserve activation' ($script:switches.Count -eq $before)
    $script:raw=New-Accounts;$script:raw[1].usage.primary.remainingPercent=$null;$s=New-State 1;$before=$script:switches.Count
    Invoke-WatchRound $s
    Check 'unknown ordinary quota cannot be treated as ordinary exhaustion' ($script:switches.Count -eq $before)
    $script:raw=New-Accounts;$s=New-State 1;Invoke-WatchRound $s
    foreach($a in $script:raw[0..1]){$a.usage.primary.remainingPercent=100};Clear-StateFlag $s 'desktopReadyAfter'
    Invoke-WatchRound $s
    Check 'recovered ordinary account regains priority over enabled reserve' ($script:switches[-1] -in @('a1','a2'))
    $oldRun=$Script:WatchRunId;$Script:WatchRunId=[guid]::NewGuid().ToString('N');$Script:ReserveAccountCount=0
    $enabled=@(Get-RunAccounts $s @(Get-Accounts))
    Check 'new run defaults off and does not inherit prior selected reserves' ($s.runAccountPolicy.selectedIds.Count -eq 0 -and $enabled.Count -eq 2 -and $s.handled.old -eq 'preserved')
    $Script:WatchRunId=$oldRun
    Check 'all scenarios preserve global error protection without false pauses' ($script:pauses -eq 0)
}finally{Remove-TestDirectory $tmp}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
