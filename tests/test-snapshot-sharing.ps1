# Reproduce the real File.Replace sharing violation with a concurrent reader.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $root 'lib\dashboard.ps1')
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-sharing-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $tmp
$path=Join-Path $tmp 'snapshot.json';$signal=Join-Path $tmp 'locked'
$reader=$null;$runspace=$null;$pass=0;$fail=0
function Check($Name,$Ok){if($Ok){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
try{
    Write-JsonAtomic $path @{version=1;text='中文快照'}
    $runspace=[Management.Automation.PowerShell]::Create()
    [void]$runspace.AddScript({param($Path,$Signal)
        $s=[IO.File]::Open($Path,'Open','Read',[IO.FileShare]::Read)
        try{[IO.File]::WriteAllText($Signal,'locked');[Threading.Thread]::Sleep(600)}finally{$s.Dispose()}
    }).AddArgument($path).AddArgument($signal)
    $handle=$runspace.BeginInvoke();$deadline=(Get-Date).AddSeconds(5)
    while(-not(Test-Path $signal) -and (Get-Date)-lt $deadline){Start-Sleep -Milliseconds 10}
    if(-not(Test-Path $signal)){throw 'Lock fixture did not start'}
    $watch=[Diagnostics.Stopwatch]::StartNew();Write-JsonAtomic $path @{version=2;text='恢复成功'};$watch.Stop()
    Check 'short sharing conflict recovers instead of pausing watcher' ((Read-DashboardJson $path).version -eq 2 -and $watch.Elapsed.TotalMilliseconds -ge 200 -and $watch.Elapsed.TotalSeconds -lt 3)
    Check 'atomic recovery keeps previous complete snapshot as backup' ((Get-Content ($path+'.bak') -Raw|ConvertFrom-Json).version -eq 1)
    $null=$runspace.EndInvoke($handle);$runspace.Dispose();$runspace=$null
    $reader=[IO.File]::Open($path,'Open','Read',[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    Write-JsonAtomic $path @{version=3;text='中文读取'}
    Check 'delete-sharing readers permit snapshot replacement' ((Read-DashboardJson $path).version -eq 3 -and (Read-DashboardJson $path).text -eq '中文读取')
    $reader.Dispose();$reader=$null
    $reader=[IO.File]::Open($path,'Open','Read',[IO.FileShare]::Read)
    $watch.Restart();$threw=$false
    try{Write-JsonAtomic $path @{version=4}}catch{$threw=$true};$watch.Stop()
    Check 'persistent lock has bounded retries and remains an error' ($threw -and $watch.Elapsed.TotalSeconds -lt 4)
    $reader.Dispose();$reader=$null
    Check 'failed atomic write never corrupts prior state' ((Read-DashboardJson $path).version -eq 3 -and @(Get-ChildItem $tmp -Filter '*.tmp').Count -eq 0)
}finally{if($reader){$reader.Dispose()};if($runspace){$runspace.Stop();$runspace.Dispose()};Remove-TestDirectory $tmp}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
