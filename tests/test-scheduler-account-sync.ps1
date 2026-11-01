# Real scheduler and worker, fake HTTP. A roster change must rebuild before consuming.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-scheduler-sync-'+[guid]::NewGuid().ToString('N'))
$pass=0;$fail=0
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
$scheduleStub=@'
function Invoke-RestMethod {
    param($Uri,$Method,$ContentType,$Body,$TimeoutSec)
    if(($Body|ConvertFrom-Json).command -ne 'list_accounts'){throw 'Unexpected scheduler mutation'}
    $path=Join-Path $PSScriptRoot 'reads.txt'
    $count=if(Test-Path $path){3}else{2}
    Add-Content $path $count
    return @{ok=$true;result=@(1..$count|ForEach-Object {@{id="a$_"}})}
}
function Start-Sleep {param($Seconds)}
'@
$workerStub=@'
function Invoke-RestMethod {
    param($Uri,$Method,$ContentType,$Body,$TimeoutSec)
    $request=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json
    if($request.command -eq 'list_accounts'){
        return @{ok=$true;result=@(1..3|ForEach-Object {@{id="a$_";usage=@{primary=@{remainingPercent=100;windowMinutes=300;resetsAt=2000000000};secondary=@{remainingPercent=60;windowMinutes=10080};error=$null}}})}
    }
    if($request.command -ne 'consume_account_quota'){throw 'Unexpected worker mutation'}
    $batch=Get-Content $JobFile -Raw|ConvertFrom-Json
    if(@($batch.accounts|Where-Object {$_.id -eq $request.args.id -and $_.phase -eq 'sending'}).Count -ne 1){throw 'Missing durable intent'}
    Add-Content (Join-Path $PSScriptRoot 'consumed.txt') $request.args.id
    return @{ok=$true;result=@{ok=$true}}
}
function Start-Sleep {param($Seconds)}
'@
try{
    foreach($mode in @('scheduled','manual')){
        $dir=Join-Path $tmp $mode
        $null=New-Item -ItemType Directory (Join-Path $dir 'lib') -Force
        foreach($name in @('scheduler.ps1','account-quota.ps1')){Copy-Item (Join-Path $root ('lib\'+$name)) (Join-Path $dir ('lib\'+$name))}
        $enc=New-Object Text.UTF8Encoding($true)
        $text=Get-Content (Join-Path $root 'scheduler.ps1') -Raw -Encoding UTF8
        $text=$text.Replace("`$ErrorActionPreference='Stop'","`$ErrorActionPreference='Stop'`n"+$scheduleStub)
        [IO.File]::WriteAllText((Join-Path $dir 'scheduler.ps1'),$text,$enc)
        $text=Get-Content (Join-Path $root 'quota-batch.ps1') -Raw -Encoding UTF8
        $text=$text.Replace("`$ErrorActionPreference='Stop'","`$ErrorActionPreference='Stop'`n"+$workerStub)
        [IO.File]::WriteAllText((Join-Path $dir 'quota-batch.ps1'),$text,$enc)
        if($mode -eq 'scheduled'){
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'scheduler.ps1') -RunOnce
        }else{
            $request=Join-Path $dir 'request.json'
            [IO.File]::WriteAllText($request,(@{action='consume';port=18080}|ConvertTo-Json),$enc)
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'scheduler.ps1') -RequestFile $request
        }
        Check ($mode+' refreshes roster before retrying a preflight batch') ($LASTEXITCODE -eq 0 -and ((Get-Content (Join-Path $dir 'reads.txt')) -join ',') -eq '2,3')
        $calls=@(Get-Content (Join-Path $dir 'consumed.txt'))
        Check ($mode+' consumes each latest account exactly once') (($calls -join ',') -eq 'a1,a2,a3')
        $batches=@(Get-ChildItem (Join-Path $dir 'state\quota-batches') -Filter '*.json'|ForEach-Object {Get-Content $_.FullName -Raw|ConvertFrom-Json})
        $old=@($batches|Where-Object {$_.phase -eq 'preflight-retry'})
        $done=@($batches|Where-Object {$_.phase -eq 'success'})
        Check ($mode+' retains untouched old batch and complete new receipts') ($batches.Count -eq 2 -and $old.Count -eq 1 -and @($old[0].accounts|Where-Object {$_.phase -ne 'pending'}).Count -eq 0 -and $done.Count -eq 1 -and $done[0].accounts.Count -eq 3)
    }
}finally{Remove-TestDirectory $tmp}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
