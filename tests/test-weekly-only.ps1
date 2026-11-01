# Six-account recovery through the real parser and state machine; all APIs are mocked.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-weekly-only-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $tmp -Force
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json'
$Script:Config.ExpectedAccounts=6;$Script:Config.FallbackAccountIds=@('a6');$Live=$true
$Script:ReserveAccountCount=1 # This suite explicitly enables its weekly-only reserve.
$script:switches=@();$script:batches=0;$script:pauses=0;$script:events=@()
$script:snapshot=[pscustomobject]@{Recent=@();Active=@()}
function Invoke-Csw {param($Command,$Arguments) if($Command -ne 'list_accounts'){throw 'Read-only fixture'};return $script:raw}
function Get-DesktopSnapshot {return $script:snapshot}
function Get-CodexDesktopLaunch {return $null}
function Invoke-SwitchAccount {param($Account) $script:switches+= $Account.Id;foreach($a in $script:raw){$a.active=$a.id -eq $Account.Id};return $true}
function Start-QuotaBatch {param($State,$Accounts) $script:batches++;$State.waitingReset.phase='running'}
function Request-ManualPause {param($State,$Key,$Reason,$Details) $script:pauses++}
function Write-Event {param($Message,$Level) $script:events+= $Message}
function Write-File {param($Message,$Level)}
function Write-Log {param($Message,$Level)}
function New-State {$s=[pscustomobject]@{handled=[pscustomobject]@{old='retained'};pendingResumes=[pscustomobject]@{}};Initialize-V2State $s;return $s}
function New-RawAccounts {
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $items=@(1..5|ForEach-Object {[pscustomobject]@{
        id="a$_";email="a$_@test";active=($_ -eq 1);plan='team';directSwitchCompatible=$true
        usage=[pscustomobject]@{error=$null;primary=@{remainingPercent=100;windowMinutes=300;resetsAt=$now+18000};secondary=@{remainingPercent=40+$_;windowMinutes=10080;resetsAt=$now+604800}}
    }})
    $items+=[pscustomobject]@{id='a6';email='reserve@test';active=$false;plan='team';directSwitchCompatible=$true;usage=[pscustomobject]@{error=$null;primary=@{remainingPercent=100;windowMinutes=10080;resetsAt=$now+604800};secondary=$null}}
    return $items
}
$pass=0;$fail=0
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
try{
    $script:raw=New-RawAccounts;$accounts=@(Get-Accounts);$reserve=$accounts[5]
    Check 'weekly primary maps to weekly quota with no fictitious five-hour value' ($null -eq $reserve.FiveHour -and $reserve.Weekly -eq 100 -and $reserve.FiveHourLimitAbsent -and $null -eq $reserve.FiveHourReset -and $reserve.WeeklyReset -gt 0)
    Check 'ordinary dual windows retain their values' ($accounts[0].FiveHour -eq 100 -and $accounts[0].Weekly -eq 41 -and -not $accounts[0].FiveHourLimitAbsent)
    Check 'weekly-only account is usable and displayed honestly' ((Test-AccountQuotaAvailable $reserve) -and (Format-AccountFiveHour $reserve) -eq '无此限制')
    $q=ConvertFrom-AccountUsage @{primary=$null;secondary=@{remainingPercent=70;windowMinutes=10080}}
    Check 'weekly window is recognised in either slot' ($q.Weekly -eq 70 -and $q.FiveHourLimitAbsent)
    $q=ConvertFrom-AccountUsage @{primary=@{remainingPercent=70;windowMinutes=10080};secondary=@{remainingPercent=20;windowMinutes=300}}
    Check 'duration mapping handles swapped dual windows' ($q.Weekly -eq 70 -and $q.FiveHour -eq 20 -and -not $q.FiveHourLimitAbsent)
    foreach($usage in @(
        @{primary=@{remainingPercent=100;windowMinutes=300};secondary=$null},
        @{primary=@{remainingPercent=100};secondary=$null},
        @{primary=@{remainingPercent=100;windowMinutes=60};secondary=$null},
        @{primary=$null;secondary=$null},
        @{primary=@{remainingPercent='NaN';windowMinutes=10080}},
        @{primary=@{remainingPercent=101;windowMinutes=10080}},
        @{primary=@{remainingPercent=-1;windowMinutes=10080}},
        @{primary=@{remainingPercent=100;windowMinutes=10080};error='read failed'}
    )){Check 'unknown or invalid quota never becomes available' (-not (Test-AccountQuotaAvailable (ConvertFrom-AccountUsage $usage)))}
    Check 'ordinary account wins even with far less weekly quota' ((Select-BestAccount $accounts).Best.Id -eq 'a5')
    $script:raw[0].usage.primary.remainingPercent=0;$s=New-State;Invoke-WatchRound $s
    Check 'normal depletion chooses another ordinary account before reserve' ($script:switches.Count -eq 1 -and $script:switches[-1] -eq 'a5')
    $status=Get-Content (Join-Path $tmp 'quota-status.json') -Raw|ConvertFrom-Json
    Check 'six-account snapshot includes available reserve' ($status.usableAccounts -eq 5)
    $script:raw=New-RawAccounts;foreach($a in $script:raw[0..4]){$a.usage.primary.remainingPercent=0};$s=New-State
    Invoke-WatchRound $s
    Check 'all five ordinary accounts empty switches directly to reserve without batch' ($script:switches[-1] -eq 'a6' -and $script:batches -eq 0 -and -not (Get-StateFlag $s 'waitingReset'))
    Clear-StateFlag $s 'desktopReadyAfter';$proof=Get-ResumeAccountProof $s
    Check 'resume quota proof accepts a weekly-only active account' ($proof.accountId -eq 'a6' -and $proof.fiveHourLimitAbsent -and $null -eq $proof.fiveHour)
    $before=$script:switches.Count;Invoke-WatchRound $s
    Check 'active reserve does not repeatedly switch or issue a false five-hour warning' ($script:switches.Count -eq $before -and @($script:events|Where-Object {$_ -match '5 小时剩余'}).Count -eq 0)
    $script:raw[0].usage.primary.remainingPercent=100;$script:snapshot.Active=@([pscustomobject]@{id='busy'})
    Invoke-WatchRound $s
    Check 'ordinary recovery waits while a conversation is running' ($script:switches.Count -eq $before)
    $script:snapshot.Active=@();Invoke-WatchRound $s
    Check 'idle reserve yields back to recovered ordinary account' ($script:switches.Count -eq $before+1 -and $script:switches[-1] -eq 'a1')
    $script:raw=New-RawAccounts;foreach($a in $script:raw[0..4]){$a.usage.primary.remainingPercent=0};$script:raw[5].usage.primary.remainingPercent=0;$s=New-State
    Invoke-WatchRound $s
    Check 'reserve weekly exhaustion enters ordinary reset wait without data error' ($s.waitingReset.phase -eq 'waiting' -and $script:batches -eq 0)
    foreach($a in $script:raw[0..4]){$a.usage.primary.remainingPercent=100}
    Invoke-WatchRound $s
    Check 'empty reserve does not block five ordinary accounts starting reset batch' ($script:batches -eq 1 -and $s.waitingReset.phase -eq 'running')
    foreach($a in $script:raw[0..4]){$a.usage.primary.remainingPercent=0};$s=New-State;Invoke-WatchRound $s
    $script:raw[5].usage.primary.remainingPercent=50;Invoke-WatchRound $s
    Check 'weekly recovery leaves persisted wait without consuming reserve to start timer' ($script:switches[-1] -eq 'a6' -and $script:batches -eq 1 -and -not (Get-StateFlag $s 'waitingReset'))
    $script:raw=New-RawAccounts
    $script:raw[5].usage.secondary=$script:raw[5].usage.primary
    $script:raw[5].usage.primary=@{remainingPercent=20;windowMinutes=300;resetsAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+18000}
    $accounts=@(Get-Accounts)
    Check 'future five-hour limit is detected and enforced while reserve priority persists' (-not $accounts[5].FiveHourLimitAbsent -and $accounts[5].FiveHour -eq 20 -and (Select-BestAccount $accounts).Best.Id -eq 'a5')
    foreach($a in $script:raw[0..4]){$a.usage.primary.remainingPercent=0}
    Check 'future dual-window reserve is selectable only when ordinary accounts empty' ((Select-BestAccount @(Get-Accounts)).Best.Id -eq 'a6')
    $script:raw[5].usage.primary.remainingPercent=0
    Check 'future reserve five-hour exhaustion cannot be bypassed' ($null -eq (Select-BestAccount @(Get-Accounts)).Best)
    # Stale positive quota can coexist with real credits errors. Reserve priority
    # must not reselect the five already-failed accounts until quota truly recovers.
    function Send-DesktopContinue {param($State,$View)} # No real desktop messages.
    $script:raw=New-RawAccounts;foreach($a in $script:raw){$a.active=$a.id -eq 'a6'}
    $accounts=@(Get-Accounts);$s=New-State;$attempts=[pscustomobject]@{}
    foreach($a in $accounts[0..4]){Set-StateFlag $attempts $a.Id ([pscustomobject]@{turnId='old';fiveHour=$a.FiveHour;weekly=$a.Weekly;fiveHourReset=$a.FiveHourReset;weeklyReset=$a.WeeklyReset})}
    Set-StateFlag $s.creditRecoveries 'credit-thread' ([pscustomobject]@{id='chain';accounts=$attempts})
    Set-StateFlag $s.switchIncidents 'credit-thread:old' 'a6'
    $view=[pscustomobject]@{Id='credit-thread';TurnId='old';Outcome='limit';Status='idle';Error='Your workspace is out of credits';At=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-300);Reason=''}
    $script:snapshot.Recent=@($view);$before=$script:switches.Count
    Invoke-WatchRound $s;Save-State $s;$s=Read-State;Invoke-WatchRound $s
    Check 'reserve does not bounce into failed ordinary accounts across restart' ($script:switches.Count -eq $before)
    $script:raw[0].usage.secondary.remainingPercent+=1;Invoke-WatchRound $s
    Check 'real ordinary quota recovery releases prior credit exclusion and restores priority' ($script:switches.Count -eq $before+1 -and $script:switches[-1] -eq 'a1')
    $s=New-State;$accounts=@(Get-Accounts)
    Set-StateFlag $s.creditRecoveries 'credit-thread' ([pscustomobject]@{id='weekly-reset';accounts=[pscustomobject]@{a6=[pscustomobject]@{turnId='old';fiveHour=$null;weekly=100;fiveHourReset=$null;weeklyReset=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-1)}}})
    $excluded=@(Get-CreditRetryExclusions $s @($view) @() $accounts $accounts[0])
    Check 'confirmed later weekly window releases weekly-only credit exclusion at same percent' ('a6' -notin $excluded)
    $script:snapshot.Recent=@()
    . (Join-Path $root 'monitor.ps1') -LibraryOnly
    $now=Get-Date;$run=[pscustomobject]@{pid=123;startedAt=$now.AddMinutes(-1).ToString('o')}
    $footer=Format-QuotaFooter ([pscustomobject]@{pid=123;at=$now.ToString('o');pollSeconds=3;account=$accounts[5]}) $run $now
    Check 'console footer distinguishes absent five-hour limit from unknown data' ($footer -match '无此限制' -and $footer -notmatch '额度未知')
    Check 'no scenario requires manual pause and old deduplication survives' ($script:pauses -eq 0 -and $s.handled.old -eq 'retained')
}finally{Remove-TestDirectory $tmp}
Write-Host "通过 $pass 项，失败 $fail 项"
exit $(if($fail){1}else{0})
