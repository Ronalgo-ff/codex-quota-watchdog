# Real batch worker, fake HTTP responses. Never touches Codex Switch.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-batch-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tmp -Force
$pass=0;$fail=0
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
$stub=@'
function Invoke-RestMethod {
    param($Uri,$Method,$ContentType,$Body,$TimeoutSec)
    $r=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json
    if($r.command -eq 'list_accounts'){
        if((Get-Content (Join-Path $PSScriptRoot 'mode.txt') -Raw).Trim() -eq 'preflight-offline'){throw 'connection timeout before any consume request'}
        $mode=(Get-Content (Join-Path $PSScriptRoot 'mode.txt') -Raw).Trim()
        if($mode -in @('weekly-pending','weekly-ready')){
            return @{ok=$true;result=@(1..5|ForEach-Object {@{id="a$_";usage=@{primary=@{remainingPercent=$(if($_ -eq 1 -or ($_ -eq 5 -and $mode -eq 'weekly-pending')){0}else{100})};secondary=@{remainingPercent=$(if($_ -eq 1){0}else{50})};error=$null}}})}
        }
        if((Get-Content (Join-Path $PSScriptRoot 'mode.txt') -Raw).Trim() -eq 'one-ready'){
            return @{ok=$true;result=@(1..5|ForEach-Object {@{id="a$_";usage=@{primary=@{remainingPercent=$(if($_ -eq 1){100}else{0})};secondary=@{remainingPercent=50};error=$null}}})}
        }
        $quota=if((Get-Content (Join-Path $PSScriptRoot 'mode.txt') -Raw).Trim() -eq 'not-ready'){0}else{100}
        return @{ok=$true;result=@(1..5|ForEach-Object {@{id="a$_";usage=@{primary=@{remainingPercent=$quota};secondary=@{remainingPercent=50};error=$null}}})}
    }
    $current=Get-Content $JobFile -Raw -Encoding UTF8|ConvertFrom-Json
    $account=@($current.accounts|Where-Object {$_.id -eq $r.args.id})[0]
    if($account.phase -ne 'sending'){throw 'Missing durable per-account intent'}
    Add-Content (Join-Path $PSScriptRoot 'calls.txt') $r.args.id
    if($r.args.id -eq 'a3' -and (Get-Content (Join-Path $PSScriptRoot 'mode.txt') -Raw).Trim() -eq 'partial'){throw 'timeout after potential consumption'}
    return @{ok=$true;result=@{ok=$true}}
}
function Start-Sleep {param($Seconds)}
'@
try{
    $text=Get-Content (Join-Path $root 'quota-batch.ps1') -Raw -Encoding UTF8
    $text=$text.Replace("`$ErrorActionPreference='Stop'","`$ErrorActionPreference='Stop'`n"+$stub)
    $runner=Join-Path $tmp 'batch.ps1'
    [IO.File]::WriteAllText($runner,$text,(New-Object Text.UTF8Encoding($true)))
    foreach($mode in @('success','partial')){
        Set-Content (Join-Path $tmp 'mode.txt') $mode
        $job=Join-Path $tmp ($mode+'.json')
        @{id=$mode;endpoint='http://fake.invalid';phase='prepared';accounts=@(1..5|ForEach-Object {@{id="a$_";phase='pending';error=$null}})}|ConvertTo-Json -Depth 8|Set-Content $job -Encoding UTF8
        & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -JobFile $job
        $code=$LASTEXITCODE;$b=Get-Content $job -Raw|ConvertFrom-Json
        Check "$mode worker records outcome" ($b.phase -eq $mode -and $code -eq 0)
        Check "$mode each account attempted once" (@(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq $(if($mode -eq 'success'){5}else{10}))
        $before=[IO.File]::ReadAllText($job)
        & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -JobFile $job
        Check "$mode replay preserves receipts" ($LASTEXITCODE -eq 2 -and [IO.File]::ReadAllText($job) -eq $before)
        Check "$mode replay sends no requests" (@(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq $(if($mode -eq 'success'){5}else{10}))
        if($mode -eq 'partial'){Check 'uncertain account preserved alongside four successes' (@($b.accounts|Where-Object {$_.phase -eq 'success'}).Count -eq 4 -and @($b.accounts|Where-Object {$_.phase -eq 'uncertain'}).Count -eq 1)}
    }
    Set-Content (Join-Path $tmp 'mode.txt') 'not-ready'
    $job=Join-Path $tmp 'not-ready.json'
    @{id='not-ready';endpoint='http://fake.invalid';phase='prepared';accounts=@(1..5|ForEach-Object {@{id="a$_";phase='pending';error=$null}})}|ConvertTo-Json -Depth 8|Set-Content $job -Encoding UTF8
    & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -JobFile $job
    $b=Get-Content $job -Raw|ConvertFrom-Json
    Check 'quota change between polling and worker prevents all consumption' ($LASTEXITCODE -eq 0 -and $b.phase -eq 'not-ready' -and @(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq 10 -and @($b.accounts|Where-Object {$_.phase -eq 'pending'}).Count -eq 5)
    Set-Content (Join-Path $tmp 'mode.txt') 'preflight-offline'
    $job=Join-Path $tmp 'preflight-offline.json'
    @{id='preflight-offline';endpoint='http://fake.invalid';phase='prepared';accounts=@(1..5|ForEach-Object {@{id="a$_";phase='pending';error=$null}})}|ConvertTo-Json -Depth 8|Set-Content $job -Encoding UTF8
    & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -JobFile $job
    $b=Get-Content $job -Raw|ConvertFrom-Json
    Check 'read-only preflight timeout is retryable without consuming' ($b.phase -eq 'preflight-retry' -and @(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq 10 -and @($b.accounts|Where-Object {$_.phase -eq 'pending'}).Count -eq 5)
    Set-Content (Join-Path $tmp 'mode.txt') 'one-ready'
    $job=Join-Path $tmp 'one-ready.json'
    @{id='one-ready';endpoint='http://fake.invalid';phase='prepared';accounts=@(1..5|ForEach-Object {@{id="a$_";phase='pending';error=$null}})}|ConvertTo-Json -Depth 8|Set-Content $job -Encoding UTF8
    & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -JobFile $job
    $b=Get-Content $job -Raw|ConvertFrom-Json
    Check 'one available account consumed, four depleted accounts skipped' ($LASTEXITCODE -eq 0 -and $b.phase -eq 'partial' -and @($b.accounts|Where-Object {$_.phase -eq 'success'}).Count -eq 1 -and @($b.accounts|Where-Object {$_.phase -eq 'skipped'}).Count -eq 4 -and @(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq 11)
    & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -JobFile $job
    Check 'partial success is not consumed again on restart' ($LASTEXITCODE -eq 2 -and @(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq 11)
    foreach($mode in @('weekly-pending','weekly-ready')){
        Set-Content (Join-Path $tmp 'mode.txt') $mode
        $job=Join-Path $tmp ($mode+'.json')
        @{id=$mode;endpoint='http://fake.invalid';phase='prepared';waitPolicy='weekly-eligible';accounts=@(1..5|ForEach-Object {@{id="a$_";phase='pending';error=$null}})}|ConvertTo-Json -Depth 8|Set-Content $job -Encoding UTF8
        & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -JobFile $job
        $b=Get-Content $job -Raw|ConvertFrom-Json
        if($mode -eq 'weekly-pending'){
            Check 'worker recheck waits for last weekly-positive account without consuming any' ($b.phase -eq 'not-ready' -and @(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq 11)
        }else{
            Check 'worker consumes four ready accounts and skips weekly-zero account' ($b.phase -eq 'partial' -and @($b.accounts|Where-Object {$_.phase -eq 'success'}).Count -eq 4 -and $b.accounts[0].phase -eq 'skipped' -and @(Get-Content (Join-Path $tmp 'calls.txt')).Count -eq 15)
        }
    }
}finally{Remove-TestDirectory $tmp}
Write-Host "通过 $pass 项，失败 $fail 项"
exit $(if($fail){1}else{0})
