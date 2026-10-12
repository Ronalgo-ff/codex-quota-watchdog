# Real worker processes using fake responses and a shared durable journal.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-shared-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $tmp,(Join-Path $tmp 'coord') -Force
$pass=0;$fail=0
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
$stub=@'
function Invoke-RestMethod($Uri,$Method,$ContentType,$Body,$TimeoutSec){
 $r=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json
 if($r.command -eq 'list_accounts'){return @{ok=$true;result=@(@{id='a1';usage=@{error=$null;primary=@{remainingPercent=100;resetsAt=[long](Get-Content (Join-Path $PSScriptRoot 'reset.txt'))};secondary=@{remainingPercent=80}}})}}
 $journal=Get-Content (Join-Path $PSScriptRoot 'coord\accounts.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if($journal.a1.phase -ne 'sending'){throw 'No shared write-ahead intent'}
 Add-Content (Join-Path $PSScriptRoot 'calls.txt') $r.args.id
 if(Test-Path (Join-Path $PSScriptRoot 'fail.txt')){throw 'response lost'}
 return @{ok=$true;result=@{ok=$true}}
}
function Start-Sleep($Seconds){}
'@
function Job($Name){$job=Join-Path $tmp ($Name+'.json');@{id=$Name;phase='prepared';waitPolicy='any';endpoint='http://fake';coordinationDir=(Join-Path $tmp 'coord');accounts=@(@{id='a1';phase='pending';error=$null})}|ConvertTo-Json -Depth 5|Set-Content $job -Encoding UTF8;return $job}
function Run($Name){$job=Job $Name;& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'batch.ps1') -JobFile $job;return Get-Content $job -Raw -Encoding UTF8|ConvertFrom-Json}
try{
 Set-Content (Join-Path $tmp 'reset.txt') ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+18000)
 $src=Get-Content (Join-Path $root 'quota-batch.ps1') -Raw -Encoding UTF8;$src=$src.Replace("`$ErrorActionPreference='Stop'","`$ErrorActionPreference='Stop'`n"+$stub);[IO.File]::WriteAllText((Join-Path $tmp 'batch.ps1'),$src,(New-Object Text.UTF8Encoding($true)))
 $b=Run 'schedule';Check 'first shared batch consumes with durable shared intent' ($b.phase -eq 'success' -and @(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq 1)
 $b=Run 'watcher';Check 'immediate second source reuses same-window success without consuming twice' ($b.phase -eq 'success' -and $b.accounts[0].reusedReceipt -and @(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq 1)
 $lock=[IO.File]::Open((Join-Path $tmp 'coord\consume.lock'),'OpenOrCreate','ReadWrite','None');try{$b=Run 'overlap';Check 'concurrent source defers before any consume intent' ($b.phase -eq 'preflight-retry' -and $b.accounts[0].phase -eq 'pending' -and @(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq 1)}finally{$lock.Dispose()}
 $j=Get-Content (Join-Path $tmp 'coord\accounts.json') -Raw|ConvertFrom-Json;$j.a1.at-=121;$j|ConvertTo-Json -Depth 5|Set-Content (Join-Path $tmp 'coord\accounts.json') -Encoding UTF8
 Set-Content (Join-Path $tmp 'fail.txt') 'fail';$b=Run 'lost';Check 'unknown consume outcome persists shared journal' ($b.accounts[0].phase -eq 'uncertain' -and @(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq 2)
 Remove-Item -LiteralPath (Join-Path $tmp 'fail.txt');$b=Run 'restart';Check 'different source and restart cannot replay unknown consumption' ($b.accounts[0].phase -eq 'uncertain' -and @(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq 2)
 $j=Get-Content (Join-Path $tmp 'coord\accounts.json') -Raw|ConvertFrom-Json;$j.a1.reset=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-1;$j|ConvertTo-Json -Depth 5|Set-Content (Join-Path $tmp 'coord\accounts.json') -Encoding UTF8
 $b=Run 'new-window';Check 'a proven later reset window releases old uncertain account' ($b.phase -eq 'success' -and @(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq 3)
}finally{Remove-TestDirectory $tmp}
Write-Host "通过 $pass 项，失败 $fail 项"
exit $(if($fail){1}else{0})
