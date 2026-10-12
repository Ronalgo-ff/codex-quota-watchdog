# Real hidden watcher process, isolated files, no accounts/messages/API calls.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-pause-entry-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tmp -Force
Copy-Item (Join-Path $root 'lib') (Join-Path $tmp 'lib') -Recurse
Copy-Item (Join-Path $root 'start-menu.ps1') $tmp
$text=Get-Content (Join-Path $root 'codex-autopilot.ps1') -Raw -Encoding UTF8
$stub=@'
function Invoke-WatchRound {
    param($State)
    Add-Content (Join-Path $PSScriptRoot 'rounds.txt') 'round'
    $mode=(Get-Content (Join-Path $PSScriptRoot 'mode.txt') -Raw).Trim()
    if($mode -eq 'unknown'){throw 'unrecognized test error'}
    if($mode -eq 'incident'){
        Request-ManualPause $State 'test-uncertain' 'Unconfirmed request' @{thread='test';error='Lost response'}
        Add-Content (Join-Path $PSScriptRoot 'unsafe.txt') 'must never run'
    }
}
if ($LibraryOnly) { return }
'@
$text=$text.Replace('if ($LibraryOnly) { return }',$stub)
[IO.File]::WriteAllText((Join-Path $tmp 'codex-autopilot.ps1'),$text,(New-Object Text.UTF8Encoding($true)))
@{PollSeconds=1}|ConvertTo-Json|Set-Content (Join-Path $tmp 'rules.json') -Encoding UTF8
$pass=0;$fail=0;$child=$null
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Read-Status {try{Get-Content (Join-Path $tmp 'state\tray-status.json') -Raw|ConvertFrom-Json}catch{}}
function Wait-For($Condition){$deadline=(Get-Date).AddSeconds(10);do{if(& $Condition){return};Start-Sleep -Milliseconds 100}while((Get-Date)-lt $deadline);throw 'Test condition timed out'}
function Start-TestWatcher {
    Start-Process powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Live' -f (Join-Path $tmp 'codex-autopilot.ps1')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $tmp 'child.log') -RedirectStandardError (Join-Path $tmp 'child.err')
}
function Resume-Test {
    $path=Join-Path $tmp 'state\tray-control.json'
    @{id=[guid]::NewGuid().ToString('N');action='resume'}|ConvertTo-Json|Set-Content ($path+'.tmp')
    Move-Item -LiteralPath ($path+'.tmp') -Destination $path -Force
}
try{
    Set-Content (Join-Path $tmp 'mode.txt') 'unknown'
    $child=Start-TestWatcher
    Wait-For {$st=Read-Status;$st -and $st.pid -eq $child.Id -and $st.paused}
    Start-Sleep -Milliseconds 1200
    Check 'unknown error pauses on first round with process still alive' (@(Get-Content (Join-Path $tmp 'rounds.txt')).Count -eq 1 -and -not $child.HasExited)
    $pause=Get-Content (Join-Path $tmp 'state\manual-pause.json') -Raw|ConvertFrom-Json
    Wait-For {Test-Path $pause.reportPath}
    $report=Get-Content $pause.reportPath -Raw|ConvertFrom-Json
    Check 'durable incident report contains error and context' ($report.details.error -eq 'unrecognized test error' -and $report.stack -and $report.state.handled)
    $raw=[IO.File]::ReadAllText($pause.reportPath)
    Set-Content (Join-Path $tmp 'mode.txt') 'healthy'
    Stop-Process -Id $child.Id -Force;$child.WaitForExit()
    $child=Start-TestWatcher
    Wait-For {$st=Read-Status;$st -and $st.pid -eq $child.Id -and $st.paused}
    Start-Sleep -Milliseconds 1200
    Check 'restart preserves pause even though fault is now gone' (@(Get-Content (Join-Path $tmp 'rounds.txt')).Count -eq 1)
    Check 'restart keeps original incident evidence' ([IO.File]::ReadAllText($pause.reportPath) -eq $raw)
    Resume-Test
    Wait-For {@(Get-Content (Join-Path $tmp 'rounds.txt')).Count -gt 1}
    Check 'explicit P/resume control resumes same process' (-not (Read-Status).paused -and -not $child.HasExited)
    Check 'manual acknowledgement saved' (-not (Get-Content (Join-Path $tmp 'state\manual-pause.json') -Raw|ConvertFrom-Json).active)
    Set-Content (Join-Path $tmp 'mode.txt') 'incident'
    Wait-For {(Read-Status).paused}
    $count=@(Get-Content (Join-Path $tmp 'rounds.txt')).Count
    Start-Sleep -Milliseconds 1200
    Check 'incident immediately unwinds round and no further operations run' (-not(Test-Path (Join-Path $tmp 'unsafe.txt')) -and @(Get-Content (Join-Path $tmp 'rounds.txt')).Count -eq $count)
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'codex-autopilot.ps1') -Once -Live 2>&1
    Check 'paused watcher retains exclusive run lock' ($LASTEXITCODE -eq 2)
    . (Join-Path $tmp 'start-menu.ps1') -LibraryOnly
    Check 'menu recognizes paused watcher' (@(Get-AutopilotProcs|Where-Object {$_.Id -eq $child.Id}).Count -eq 1)
    function Write-Head {}
    Stop-Autopilot -NoPause;$child.Refresh()
    Check 'menu can stop paused watcher' $child.HasExited
    Check 'no diagnostic launcher exists in application root' (-not (Test-Path (Join-Path $root 'invoke-helper.ps1')))
}finally{
    if($child -and -not $child.HasExited){Stop-Process -Id $child.Id -Force}
    Remove-TestDirectory $tmp
}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
