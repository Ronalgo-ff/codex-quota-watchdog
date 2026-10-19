# Exercise actual exact-process termination on disposable fixtures, never Codex.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-force-exit-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tmp -Force
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json';$Live=$true
$pass=0;$fail=0;$child=$null;$other=$null;$script:forced=0;$script:launches=0;$script:pauses=0
$script:present=@();$script:stopResult='terminated';$script:stopFails=$false
function Check($Name,$Ok){if($Ok){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Write-Event($Message,$Level){}
function Write-File($Message,$Level){}
function Request-ManualPause($State,$Key,$Reason,$Details){$script:pauses++;throw $Reason}
function Get-CodexDesktopProcesses{return $script:present}
function Start-CodexDesktopFallback($Launch){
    $disk=Get-Content $Script:StateFile -Raw|ConvertFrom-Json
    if(-not $disk.desktopRestart.fallbackAttempted){throw 'Missing durable launch intent'}
    $script:launches++;return 12345
}
function New-Recovery{
    $s=[pscustomobject]@{handled=[pscustomobject]@{legacy='keep'}}
    $launch=[pscustomobject]@{executable=$script:exe;arguments='';processId=42;startedAt='2026-10-19T16:00:00+08:00'}
    Set-CodexDesktopRecovery $s ([pscustomobject]@{id='confirmed-switch';targetId='a2';desktopLaunch=$launch})
    $s.desktopRestart.allowLaunchAfter=(Get-Date).AddSeconds(-1).ToString('o')
    return $s
}
try{
    # Win32 verification and termination use the same process handle.
    $script:exe=Join-Path $tmp 'OpenAI\CodexFixture\ChatGPT.exe'
    $null=New-Item -ItemType Directory -Path (Split-Path $script:exe -Parent) -Force
    $source=Join-Path $tmp 'fixture.cs'
    [IO.File]::WriteAllText($source,'public class Fixture { public static void Main() { System.Threading.Thread.Sleep(120000); } }')
    $compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:winexe ('/out:'+$script:exe) $source
    if($LASTEXITCODE -ne 0){throw 'Fixture compilation failed'}
    Initialize-CodexDesktopProcess
    $child=Start-Process -FilePath $script:exe -WindowStyle Hidden -PassThru
    $other=Start-Process -FilePath $script:exe -WindowStyle Hidden -PassThru
    $started=$child.StartTime.ToUniversalTime()
    $result=[QuotaWatchdog.DesktopProcess]::StopExact($child.Id,$script:exe,$started.AddMinutes(-5))
    Check 'wrong start time preserves a reused or replacement PID' ($result -eq 'identity-mismatch' -and -not $child.HasExited)
    $result=[QuotaWatchdog.DesktopProcess]::StopExact($child.Id,(Join-Path $tmp 'Different.exe'),$started)
    Check 'wrong executable cannot terminate even the matching PID' ($result -eq 'identity-mismatch' -and -not $child.HasExited)
    $threw=$false;try{[QuotaWatchdog.DesktopProcess]::StopExact($PID,$script:exe,$started)|Out-Null}catch{$threw=$true}
    Check 'native termination refuses the watchdog process itself' $threw
    $result=[QuotaWatchdog.DesktopProcess]::StopExact($child.Id,$script:exe,$started)
    $null=$child.WaitForExit(2000)
    Check 'matching process handle terminates the selected disposable fixture' ($result -eq 'terminated' -and $child.HasExited)
    Check 'another instance with the same executable is preserved' (-not $other.HasExited)
    $result=[QuotaWatchdog.DesktopProcess]::StopExact($child.Id,$script:exe,$started)
    Check 'already-exited source is harmless to recheck' ($result -eq 'already-exited')
    $unsupported=[pscustomobject]@{processId=$other.Id;executable=(Join-Path $tmp 'Other.exe');startedAt=$other.StartTime.ToString('o')}
    $threw=$false;try{Stop-CodexDesktopExact $unsupported|Out-Null}catch{$threw=$true}
    Check 'desktop wrapper rejects a non-Codex executable identity' ($threw -and -not $other.HasExited)
    $saved=[pscustomobject]@{processId=$other.Id;executable=$script:exe;startedAt=$other.StartTime.ToString('o')}
    $result=Stop-CodexDesktopExact $saved;$null=$other.WaitForExit(2000)
    Check 'desktop wrapper verifies and terminates its exact fixture identity' ($result -eq 'terminated' -and $other.HasExited)

    # Isolated state machine: every mutation below is a stub.
    function Stop-CodexDesktopExact($Launch){
        $disk=Get-Content $Script:StateFile -Raw|ConvertFrom-Json
        if(-not $disk.desktopRestart.forceExitAttempted){throw 'Missing durable force-exit intent'}
        $script:forced++;if($script:stopFails){throw 'access denied'};return $script:stopResult
    }
    $old=[pscustomobject]@{ProcessId=42;ExecutablePath=$script:exe;CreationDate=[datetime]'2026-10-19T16:00:00+08:00'}
    $script:present=@($old);$s=New-Recovery
    $ready=Test-CodexDesktopRecovery $s 'a2'
    Check 'normal exit grace never force-closes a desktop' (-not $ready -and $script:forced -eq 0 -and $script:launches -eq 0)
    $deadline=$s.desktopRestart.deadline;$s.desktopRestart.forceExitAfter=(Get-Date).AddSeconds(-1).ToString('o')
    $ready=Test-CodexDesktopRecovery $s 'a2'
    Check 'stuck source is forced once after durable intent without premature activation' (-not $ready -and $script:forced -eq 1 -and $script:launches -eq 0 -and $s.desktopRestart.forceExitResult -eq 'terminated')
    $s=Read-State;Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'restart preserves force-exit deduplication and original deadline' ($script:forced -eq 1 -and $s.desktopRestart.deadline -eq $deadline -and $s.handled.legacy -eq 'keep')
    $script:present=@();$s.desktopRestart.allowLaunchAfter=(Get-Date).AddSeconds(-1).ToString('o')
    Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'confirmed source exit permits exactly one subsequent activation' ($script:forced -eq 1 -and $script:launches -eq 1)
    $s=Read-State;Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'restart after activation cannot force or launch again' ($script:forced -eq 1 -and $script:launches -eq 1)
    $script:present=@([pscustomobject]@{ProcessId=12345});$s=New-Recovery
    $s.desktopRestart.forceExitAfter=(Get-Date).AddSeconds(-1).ToString('o')
    Check 'a replacement desktop is never force-closed' ((Test-CodexDesktopRecovery $s 'a2') -and $script:forced -eq 1)
    $script:present=@([pscustomobject]@{ProcessId=42;CreationDate=[datetime]'2026-10-19T17:00:00+08:00'})
    Check 'PID reused by a newer desktop is preserved' ((Test-CodexDesktopRecovery $s 'a2') -and $script:forced -eq 1)
    $script:present=@($old);$s=New-Recovery;$s.desktopRestart.launch.startedAt='invalid'
    $s.desktopRestart.forceExitAfter=(Get-Date).AddSeconds(-1).ToString('o')
    # No source timestamp: omit CIM time too, retaining conservative old-process wait.
    $script:present=@([pscustomobject]@{ProcessId=42})
    Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'missing saved identity prevents automatic force-exit' ($script:forced -eq 1)
    $script:present=@($old);$s=New-Recovery;$s.desktopRestart.forceExitAfter=(Get-Date).AddSeconds(-1).ToString('o')
    $s.desktopRestart.fallbackAttempted=$true;$s.desktopRestart.phase='launching'
    Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'uncertain activation cannot authorize killing an instance' ($script:forced -eq 1)
    $s.desktopRestart.phase='launched';Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'accepted activation cannot authorize killing an instance' ($script:forced -eq 1)
    $s.desktopRestart.phase='activation-rejected';Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'explicit exit rejection permits cleanup of only the captured old process' ($script:forced -eq 2)
    $s=New-Recovery;Clear-StateFlag $s.desktopRestart 'forceExitAfter';Clear-StateFlag $s.desktopRestart 'forceExitAttempted'
    $s.desktopRestart.deadline=(Get-Date).AddSeconds(50).ToString('o')
    Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'legacy recovery derives elapsed grace without resetting its deadline' ($script:forced -eq 3)
    $s=New-Recovery;$s.desktopRestart.forceExitAfter=(Get-Date).AddSeconds(-1).ToString('o');$script:stopResult='identity-mismatch'
    Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'last-moment identity mismatch prevents killing or launching' ($s.desktopRestart.forceExitResult -eq 'identity-mismatch' -and $script:launches -eq 1)
    $script:stopResult='terminated';$s=New-Recovery;$s.desktopRestart.forceExitAfter=(Get-Date).AddSeconds(-1).ToString('o')
    Set-StateFlag $s.desktopRestart 'forceExitAttempted' $true
    Test-CodexDesktopRecovery $s 'a2'|Out-Null;$before=$script:forced
    Check 'crash after durable force-exit intent cannot replay termination' ($script:forced -eq 4)
    $s=New-Recovery;$s.desktopRestart.forceExitAfter=(Get-Date).AddSeconds(-1).ToString('o');$script:stopFails=$true;$threw=$false
    try{Test-CodexDesktopRecovery $s 'a2'|Out-Null}catch{$threw=$true}
    $s=Read-State;Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'termination failure saves evidence and pauses without retrying' ($threw -and $script:forced -eq $before+1 -and $s.desktopRestart.forceExitError -eq 'access denied' -and $script:launches -eq 1)
    $script:stopFails=$false;$before=$script:forced;$s=New-Recovery;$s.desktopRestart.forceExitAfter=(Get-Date).AddSeconds(-1).ToString('o')
    $threw=$false;try{Test-CodexDesktopRecovery $s 'user-selected-other-account'|Out-Null}catch{$threw=$true}
    Check 'user account change prevents force-exit' ($threw -and $script:forced -eq $before)
    $s=New-Recovery;$s.desktopRestart.forceExitAfter=(Get-Date).AddSeconds(-1).ToString('o');$s.desktopRestart.deadline=(Get-Date).AddSeconds(-1).ToString('o')
    $threw=$false;try{Test-CodexDesktopRecovery $s 'a2'|Out-Null}catch{$threw=$true}
    Check 'expired recovery cannot force-close any process' ($threw -and $script:forced -eq $before)
    $Live=$false;$s=New-Recovery;$s.desktopRestart.forceExitAfter=(Get-Date).AddSeconds(-1).ToString('o')
    Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'dry run cannot force-close any process' ($script:forced -eq $before)
    $Live=$true;$s=[pscustomobject]@{handled=[pscustomobject]@{}}
    Check 'no automatic switch means no force-exit' ((Test-CodexDesktopRecovery $s 'a2') -and $script:forced -eq $before)
}finally{
    foreach($p in @($child,$other)){if($p){if(-not $p.HasExited){$p.Kill();$null=$p.WaitForExit(2000)};$p.Dispose()}}
    Remove-TestDirectory $tmp
}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
