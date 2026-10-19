# Isolated packaged-app activation and exit-race regression. Never launches Codex.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-store-launch-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tmp -Force
$Script:Config.StateDir=$tmp;$Script:StateFile=Join-Path $tmp 'handled.json';$Live=$true
$pass=0;$fail=0;$script:activations=0;$script:direct=0;$script:pauses=0;$script:mode='ok'
$script:processes=@();$script:apps=@();$script:events=@()
$store=Join-Path $tmp 'WindowsApps\OpenAI.Codex_26.1013.4894.0_x64__fixturepub\app\ChatGPT.exe'
$appId='OpenAI.Codex_fixturepub!App'
$arguments='--remote-debugging-port=9335 --user-data-dir="C:\fixture profile"'
$realFallback=${function:Start-CodexDesktopFallback}
function Check($Name,$Ok){if($Ok){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Write-Event($Message,$Level){$script:events+=$Message}
function Write-File($Message,$Level){}
function Get-StartApps{[CmdletBinding()]param() return $script:apps}
function Get-CodexDesktopProcesses{return $script:processes}
function Request-ManualPause($State,$Key,$Reason,$Details){$script:pauses++;throw $Reason}
function Start-Process($FilePath,$WorkingDirectory,$WindowStyle,[switch]$PassThru,$ArgumentList){
    $script:direct++;$script:directArgs=$ArgumentList;return [pscustomobject]@{Id=1234}
}
function Invoke-CodexDesktopActivation($AppId,$Arguments){
    $script:activations++;$script:activatedApp=$AppId;$script:activatedArgs=$Arguments
    if($script:mode -eq 'exiting'){
        $inner=New-Object Runtime.InteropServices.COMException('Application is exiting',-2147483622)
        throw (New-Object InvalidOperationException('Wrapped activation rejection',$inner))
    }
    if($script:mode -eq 'unknown'){throw 'activation response timeout'}
    return 5678
}
function New-Recovery{
    $s=[pscustomobject]@{handled=[pscustomobject]@{legacy='keep'}}
    $launch=[pscustomobject]@{executable=$store;arguments=$arguments;processId=42;startedAt='2026-10-19T16:04:29+08:00';appUserModelId=$appId}
    Set-CodexDesktopRecovery $s ([pscustomobject]@{id='switch-1';targetId='a2';desktopLaunch=$launch})
    $s.desktopRestart.allowLaunchAfter=(Get-Date).AddSeconds(-1).ToString('o')
    return $s
}
try{
    Initialize-CodexDesktopActivation
    Check 'native activation helper compiles without starting an app' ([bool]('QuotaWatchdog.DesktopActivation' -as [type]))
    $script:apps=@([pscustomobject]@{Name='ChatGPT';AppID=$appId})
    $script:processes=@([pscustomobject]@{ProcessId=42;ExecutablePath=$store;CommandLine=('"'+$store+'" '+$arguments);CreationDate=[datetime]'2026-10-19T16:04:29+08:00'})
    $launch=Get-CodexDesktopLaunch
    Check 'capture records registered identity and exact profile arguments' ($launch.appUserModelId -eq $appId -and $launch.arguments -eq $arguments -and $launch.processId -eq 42)
    $pidValue=& $realFallback $launch
    Check 'packaged exe uses Windows activation with unchanged arguments' ($pidValue -eq 5678 -and $script:activatedApp -eq $appId -and $script:activatedArgs -eq $arguments -and $script:direct -eq 0)
    $legacy=[pscustomobject]@{executable=$store;arguments=$arguments}
    $pidValue=& $realFallback $legacy
    Check 'legacy saved launch and deleted version path use current registered app' ($pidValue -eq 5678 -and -not(Test-Path $store) -and $script:direct -eq 0)
    $launch.appUserModelId='OpenAI.Codex_otherpub!App';$before=$script:activations;$threw=$false
    try{& $realFallback $launch|Out-Null}catch{$threw=$true}
    Check 'identity mismatch cannot activate another installed app' ($threw -and $script:activations -eq $before -and $script:direct -eq 0)
    $script:apps=@([pscustomobject]@{Name='Codex';AppID='Different.Package!App'});$threw=$false
    try{& $realFallback $legacy|Out-Null}catch{$threw=$true}
    Check 'missing registration never falls back to protected WindowsApps exe' ($threw -and $script:direct -eq 0)
    $script:apps=@([pscustomobject]@{Name='ChatGPT';AppID=$appId},[pscustomobject]@{Name='Runner';AppID='OpenAI.Codex_fixturepub!CodexCoreCommandRunner'})
    $packageRoot=Split-Path (Split-Path $store -Parent) -Parent
    $null=New-Item -ItemType Directory -Path (Split-Path $store -Parent) -Force
    [IO.File]::WriteAllText((Join-Path $packageRoot 'AppxManifest.xml'),'<Package><Applications><Application Id="App" Executable="app/ChatGPT.exe"/><Application Id="CodexCoreCommandRunner" Executable="app/resources/codex-command-runner.exe"/></Applications></Package>')
    Check 'manifest disambiguates desktop app from command runner' ((Get-CodexDesktopAppId $store) -eq $appId)
    $script:apps=@([pscustomobject]@{Name='ChatGPT';AppID=$appId})
    $portable=Join-Path $tmp 'ChatGPT.exe';[IO.File]::WriteAllText($portable,'fixture')
    $pidValue=& $realFallback ([pscustomobject]@{executable=$portable;arguments=$arguments})
    Check 'unpackaged desktop retains direct launch and profile arguments' ($pidValue -eq 1234 -and $script:direct -eq 1 -and $script:directArgs -eq $arguments)

    # The source process still exiting is not proof that a new desktop is ready.
    $s=New-Recovery;$before=$script:activations
    $ready=Test-CodexDesktopRecovery $s 'a2'
    Check 'source process is neither considered restarted nor duplicated' (-not $ready -and $script:activations -eq $before -and -not $s.desktopRestart.fallbackAttempted)
    $script:processes=@();$script:mode='exiting';$deadline=$s.desktopRestart.deadline
    $ready=Test-CodexDesktopRecovery $s 'a2'
    Check 'explicit application-exiting rejection defers without global pause' (-not $ready -and $s.desktopRestart.phase -eq 'activation-rejected' -and $script:pauses -eq 0 -and $s.desktopRestart.launchAttempts -eq 1)
    $s=Read-State;$before=$script:activations;Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'restart preserves rejection delay without resending early' ($script:activations -eq $before -and $s.desktopRestart.deadline -eq $deadline -and $s.handled.legacy -eq 'keep')
    $s.desktopRestart.allowLaunchAfter=(Get-Date).AddSeconds(-1).ToString('o');$script:mode='ok'
    Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'expired delay retries only the proven rejected activation' ($s.desktopRestart.phase -eq 'launched' -and $s.desktopRestart.launchAttempts -eq 2 -and $s.desktopRestart.fallbackPid -eq 5678)
    $before=$script:activations;$s=Read-State;Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'accepted activation is never repeated after process restart' ($script:activations -eq $before)
    $script:processes=@([pscustomobject]@{ProcessId=5678})
    Check 'replacement process releases desktop-read readiness check' (Test-CodexDesktopRecovery $s 'a2')
    $script:processes=@([pscustomobject]@{ProcessId=42;CreationDate=[datetime]'2026-10-19T17:00:00+08:00'})
    Check 'reused PID is recognized by its new process start time' (Test-CodexDesktopRecovery $s 'a2')

    $script:processes=@();$script:mode='exiting';$s=New-Recovery;$before=$script:activations
    foreach($i in 1..3){$s.desktopRestart.allowLaunchAfter=(Get-Date).AddSeconds(-1).ToString('o');Test-CodexDesktopRecovery $s 'a2'|Out-Null}
    $s=Read-State;$s.desktopRestart.allowLaunchAfter=(Get-Date).AddSeconds(-1).ToString('o');$threw=$false
    try{Test-CodexDesktopRecovery $s 'a2'|Out-Null}catch{$threw=$true}
    Check 'exiting rejection retries are bounded at three across restart' ($threw -and $script:activations -eq $before+3 -and $script:pauses -eq 1)
    $s=New-Recovery;$script:mode='unknown';$before=$script:activations;$threw=$false
    try{Test-CodexDesktopRecovery $s 'a2'|Out-Null}catch{$threw=$true}
    $s=Read-State;Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'ambiguous activation failure pauses and is never blindly retried' ($threw -and $script:activations -eq $before+1 -and $s.desktopRestart.phase -eq 'launching')
    $s=New-Recovery;$script:mode='ok';$s.desktopRestart.fallbackAttempted=$true;$s.desktopRestart.phase='launching';Save-State $s
    $s=Read-State;$before=$script:activations;Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'crash after durable launch intent prevents replay without a rejection receipt' ($script:activations -eq $before)
    $s=New-Recovery;$s.desktopRestart.deadline=(Get-Date).AddSeconds(-1).ToString('o');$before=$script:activations;$threw=$false
    try{Test-CodexDesktopRecovery $s 'a2'|Out-Null}catch{$threw=$true}
    Check 'fixed recovery deadline cannot launch after expiry' ($threw -and $script:activations -eq $before)
    $s=New-Recovery;$before=$script:activations;$threw=$false
    try{Test-CodexDesktopRecovery $s 'other-account'|Out-Null}catch{$threw=$true}
    Check 'account changed by user prevents automatic relaunch' ($threw -and $script:activations -eq $before)
    $Live=$false;$s=New-Recovery;Test-CodexDesktopRecovery $s 'a2'|Out-Null
    Check 'dry run cannot activate any app' ($script:activations -eq $before)
}finally{Remove-TestDirectory $tmp}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
