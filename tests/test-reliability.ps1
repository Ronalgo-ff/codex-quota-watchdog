$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
$tmp=Join-Path $env:TEMP ('autopilot-reliability-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp,(Join-Path $tmp 'sessions'),(Join-Path $tmp 'logs') -Force|Out-Null
$Script:Config.StateDir=$tmp; $Script:Config.LogDir=Join-Path $tmp 'logs'
$Script:Config.SessionRoot=Join-Path $tmp 'sessions'; $Script:StateFile=Join-Path $tmp 'handled.json'
$Script:Config.ResumeGapSec=0; $Script:Config.ResumeSettleSec=0; $Script:Config.SwitchVerifySec=1
$Live=$true
function Write-Event {param($Message,$Level)}
function Write-File {param($Message,$Level)}
function Write-Log {param($Message,$Level)}
function Get-QuotaSnapshot {return $null}
function New-State { [pscustomobject]@{handled=[pscustomobject]@{};pendingResumes=[pscustomobject]@{}} }
$script:accounts=@(
    [pscustomobject]@{Id='a';Email='a@test';Active=$true;Switchable=$true;FiveHour=80;Weekly=80;FiveHourReset=1800000000;WeeklyReset=1800000000},
    [pscustomobject]@{Id='b';Email='b@test';Active=$false;Switchable=$true;FiveHour=100;Weekly=90;FiveHourReset=1800000000;WeeklyReset=1800000000})
function Get-Accounts { $script:accounts }
$pass=0;$fail=0
function Check($Name,$Ok) {if($Ok){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Session([int]$Number,[string]$Marker,[int]$Minutes,[switch]$Limit) {
    $id='12345678-1234-1234-1234-'+$Number.ToString('000000000000')
    $path=Join-Path $Script:Config.SessionRoot "rollout-$id.jsonl"
    $payload=@{type=$Marker}
    if($Limit){$payload.error=@{message='usage limit';codex_error_info='usage_limit_exceeded'}}
    $line=@{timestamp=(Get-Date).ToUniversalTime().AddMinutes(-$Minutes).ToString('o');type='event_msg';payload=$payload}
    # ordered top-level timestamp for rollout layout
    $line=[ordered]@{timestamp=$line.timestamp;type=$line.type;payload=$payload}
    [IO.File]::WriteAllText($path,($line|ConvertTo-Json -Compress -Depth 5)+"`n",(New-Object Text.UTF8Encoding($false)))
    return $path
}
try {
    $s=New-State; $script:accounts[0].Active=$false
    $r=Invoke-Round $s
    Check 'missing active account waits without throwing' ($r.Kind -eq 'wait')
    Set-StateFlag $s 'missingActiveSince' ((Get-Date).AddMinutes(-2).ToString('o'))
    $r=Invoke-Round $s
    Check 'persistent missing active account escalates' ($r.Kind -eq 'needs-review' -and $r.Immediate)
    $script:accounts[0].Active=$true
    $script:accounts[0].Weekly=$null; $script:accounts[1].Weekly=$null
    $r=Invoke-Round (New-State)
    Check 'unknown weekly quota is not reported as exhausted' ($r.Kind -eq 'needs-review')
    $script:accounts[0].Weekly=80; $script:accounts[1].Weekly=90

    $path=Session 1 'task_complete' 1
    $old=Join-Path $Script:Config.SessionRoot '2025\01\01'; New-Item -ItemType Directory $old -Force|Out-Null
    Move-Item -LiteralPath $path -Destination $old
    $path=Join-Path $old (Split-Path $path -Leaf)
    [IO.File]::SetCreationTime($path,(Get-Date).AddDays(-10)); [IO.File]::SetLastWriteTime($path,(Get-Date).AddDays(-10))
    Check 'old directory and frozen mtime retain recent event' (@(Get-RecentSessions).Count -eq 1)
    foreach($i in 2..5){$null=Session $i 'task_complete' $i}
    $null=Session 6 'task_complete' 30 -Limit
    $r=Invoke-Round (New-State)
    Check 'sixth older quota-hit cannot trigger switching or resume' ($r.Kind -eq 'ok')
    $p=Session 7 'token_count' 0
    $r=Invoke-Round (New-State)
    Check 'missing marker escalates instead of declaring finished' ($r.Kind -eq 'needs-review')
    Remove-Item -LiteralPath $p

$ruleDefaults=@{PollSeconds=10;WaitForResetEnabled=$true;ResumeMode='unattended';UnfinishedMarkers=@('unfinished')}
    $rules=Join-Path $tmp 'bad-rules.json'
    '{"PollSeconds":-1,"WaitForResetEnabled":"false","ResumeMode":"typo","UnfinishedMarkers":null}'|Set-Content $rules -Encoding UTF8
    $null=Import-Rules $rules $ruleDefaults
    Check 'invalid typed rules retain usable defaults' ($ruleDefaults.PollSeconds -eq 10 -and $ruleDefaults.WaitForResetEnabled -eq $true -and $ruleDefaults.ResumeMode -eq 'unattended')
    '{"ResumeMode":"queue"}'|Set-Content $rules -Encoding UTF8
    $applied=@(Import-Rules $rules $ruleDefaults)
    Check 'queue setting cannot disable unattended execution' ($ruleDefaults.ResumeMode -eq 'unattended' -and @($applied | Where-Object { $_ -like 'ResumeMode(*' }).Count -eq 1)

    # State persistence and pending job reconciliation.
    $s=New-State; Save-State $s
    $s.handled|Add-Member NoteProperty 'test' 'ok'; Save-State $s
    $loaded=Read-State
    Check 'atomic state survives roundtrip and retains backup' ($loaded.handled.test -eq 'ok' -and (Test-Path "$Script:StateFile.bak"))
    $jobId=[guid]::NewGuid().ToString('N'); $rf=Join-Path $tmp 'result.json'
    $job=[pscustomobject]@{JobId=$jobId;ThreadId='12345678-1234-1234-1234-000000000008';ResumeFp='res:test';LimitFp='limit:test';
        Pid=$PID;ProcessStartedAt=(Get-Process -Id $PID).StartTime.ToString('o');ResultFile=$rf;ErrorFile=(Join-Path $tmp 'none.err')}
    $s=New-State; $s.pendingResumes|Add-Member NoteProperty $jobId $job
    $p=Update-PendingResumes $s
    Check 'running job is pending, not marked successful' ($p.PendingCount -eq 1 -and @(Get-HandledKeys $s).Count -eq 0)
    @{jobId=$jobId;exitCode=0}|ConvertTo-Json|Set-Content $rf -Encoding UTF8
    $p=Update-PendingResumes $s
    Check 'zero exit confirms both fingerprints once' ($p.PendingCount -eq 0 -and @(Get-HandledKeys $s).Count -eq 2)
    $s=New-State; $s.pendingResumes|Add-Member NoteProperty $jobId $job
    @{jobId=$jobId;exitCode=7}|ConvertTo-Json|Set-Content $rf -Encoding UTF8
    $r=Invoke-Round $s
    Check 'nonzero exit escalates and does not mark handled' ($r.Kind -eq 'needs-review' -and $r.Immediate -and @(Get-HandledKeys $s).Count -eq 0)

    # Fake CLI checks the true headless resume command without touching a real chat.
    $exe=Join-Path $tmp 'fake codex.exe';New-TestNative $exe; $Script:CodexExe=$exe
    $Script:Config.ResumeTimeoutSec=30
    $Script:Config.ResumeMode='unattended' # legacy runner only, production uses desktop
    Set-Content (Join-Path $tmp 'fake-mode.txt') 'runner-ok' -Encoding UTF8
    $launch=Invoke-ResumeConversation -ThreadId $job.ThreadId -Label 'integration' -WorkDir $tmp
    $deadline=(Get-Date).AddSeconds(15); while(-not (Test-Path $launch.ResultFile) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 100}
    $argv=@(Get-Content (Join-Path $tmp 'argv.txt') -Encoding UTF8)
    Check 'resume launches asynchronously without opening desktop conversation' ($launch.Async -and $launch.Pid -gt 0 -and (Test-Path $launch.ResultFile))
    Check 'resume submits exec resume for the exact thread' ($argv.Count -eq 5 -and $argv[0] -eq 'exec' -and $argv[1] -eq 'resume' -and $argv[2] -eq '--skip-git-repo-check' -and $argv[3] -eq $job.ThreadId -and $argv[4] -eq '-')
    Check 'resume sends exact continuation message through stdin' ([IO.File]::ReadAllText((Join-Path $tmp 'stdin.txt')) -eq '继续')
    $callsBefore=@(Get-Content (Join-Path $tmp 'calls.txt')).Count
    $Script:Config.ResumeMode='queue'
    $blocked=Invoke-ResumeConversation -ThreadId $job.ThreadId -Label 'blocked' -WorkDir $tmp
    Check 'queue mode is refused because it cannot run unattended' ($blocked -eq $false -and @(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq $callsBefore)
    $Script:Config.ResumeMode='unattended'
    Set-Content (Join-Path $tmp 'fake-mode.txt') 'runner-error' -Encoding UTF8
    $failedLaunch=Invoke-ResumeConversation -ThreadId $job.ThreadId -Label 'failed headless run' -WorkDir $tmp
    $deadline=(Get-Date).AddSeconds(15); while(-not (Test-Path $failedLaunch.ResultFile) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 100}
    $failedState=New-State
    $failedState.pendingResumes|Add-Member NoteProperty $failedLaunch.JobId ([pscustomobject]@{
        JobId=$failedLaunch.JobId;ThreadId=$job.ThreadId;ResumeFp='res:failed';LimitFp='limit:failed';
        Pid=$failedLaunch.Pid;ProcessStartedAt=$failedLaunch.ProcessStartedAt;ResultFile=$failedLaunch.ResultFile;ErrorFile=$failedLaunch.ErrorFile})
    $failedCheck=Update-PendingResumes $failedState
    Check 'nonzero headless run is reported as failure, not success' ($failedCheck.Failure -and @(Get-HandledKeys $failedState).Count -eq 0)

    $Script:Config.ResumeSettleSec=0
    $Script:Config.SwitchVerifySec=1
    function Invoke-Csw {param($Command,$Arguments) $script:accounts[0].Active=$false; $script:accounts[1].Active=$true; return $true}
    $switched=Invoke-SwitchAccount $script:accounts[1]
    Check 'switch is successful only after target account becomes active' ($switched -eq $true)
    $script:accounts[0].Active=$true; $script:accounts[1].Active=$false
    function Invoke-Csw {param($Command,$Arguments) return $true}
    $switched=Invoke-SwitchAccount $script:accounts[1]
    Check 'switch without active-account confirmation fails' ($switched -eq $false)

    # Failed switch must not be reported as successful or consume resume fingerprints.
    function Invoke-SwitchAccount {param($Account) return $false}
    $script:accounts[0].FiveHour=0
    $s=New-State; $r=Invoke-Round $s
    Check 'failed switch escalates without recording success' ($r.Kind -eq 'needs-review' -and @(Get-HandledKeys $s).Count -eq 0)
} finally { Remove-TestDirectory $tmp }
Write-Host "通过 $pass 项，失败 $fail 项"
exit $(if($fail -eq 0){0}else{1})
