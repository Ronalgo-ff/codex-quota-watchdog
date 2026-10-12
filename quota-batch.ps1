# The same consume_account_quota API as the user's scheduler, with per-account write-ahead receipts.
param([Parameter(Mandatory=$true)][string]$JobFile)
$ErrorActionPreference='Stop'
function Save-Batch {
    $tmp=$JobFile+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($tmp,($batch|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($true)))
    [IO.File]::Replace($tmp,$JobFile,$JobFile+'.bak')
}
function Call-Switch([string]$Command,[hashtable]$Arguments=@{}){
    $body=@{command=$Command;args=$Arguments}|ConvertTo-Json -Compress
    # Deliberately one request only: timeouts can occur after an account was charged.
    $r=Invoke-RestMethod -Uri $batch.endpoint -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 90
    if(-not $r.ok){throw [string]$r.error}
    return $r.result
}
$lock=$null
$entered=$false
try{
    $lock=[IO.File]::Open($JobFile+'.lock','OpenOrCreate','ReadWrite','None')
    $batch=Get-Content -LiteralPath $JobFile -Raw -Encoding UTF8|ConvertFrom-Json
    if($batch.phase -ne 'prepared'){throw 'Batch already started; never replay it'}
    $entered=$true
    try{$actual=@(Call-Switch 'list_accounts')}catch{
        # This operation only reads. No consume intent/request exists yet, so a later
        # fresh batch is safe. Failures AFTER sending remain uncertain and never retry.
        $batch.phase='preflight-retry'
        $batch|Add-Member -NotePropertyName error -NotePropertyValue $_.Exception.Message -Force
        Save-Batch
        exit 0
    }
    if((@($actual.id|Sort-Object)-join ',') -ne (@($batch.accounts.id|Sort-Object)-join ',')){throw 'Account set changed before batch'}
    if($batch.waitPolicy -eq 'weekly-eligible'){
        # Recheck the whole eligible cohort before the first consume request.
        foreach($a in $actual){
            $week=0.0;$five=0.0
            $weekKnown=$null -ne $a.usage.secondary.remainingPercent -and [double]::TryParse([string]$a.usage.secondary.remainingPercent,[ref]$week) -and $week -ge 0 -and $week -le 100
            $fiveReady=$null -ne $a.usage.primary.remainingPercent -and [double]::TryParse([string]$a.usage.primary.remainingPercent,[ref]$five) -and $five -gt 0 -and $five -le 100
            if($a.usage.error -or -not $weekKnown -or ($week -gt 0 -and -not $fiveReady)){
                $batch.phase='not-ready';Save-Batch;exit 0
            }
        }
    }
    $eligible=@($actual|Where-Object {
        $five=0.0;$week=0.0
        -not $_.usage.error -and $null -ne $_.usage.primary.remainingPercent -and $null -ne $_.usage.secondary.remainingPercent -and
        [double]::TryParse([string]$_.usage.primary.remainingPercent,[ref]$five) -and
        [double]::TryParse([string]$_.usage.secondary.remainingPercent,[ref]$week) -and
        $five -gt 0 -and $five -le 100 -and $week -gt 0 -and $week -le 100
    }|ForEach-Object {$_.id})
    if($eligible.Count -eq 0){
        $batch.phase='not-ready';Save-Batch
        exit 0 # No consume request was sent; safe to wait and check again.
    }
    $batch.phase='running';Save-Batch
    foreach($account in $batch.accounts){
        if($account.phase -ne 'pending'){throw 'Account already attempted; refusing replay'}
        if($account.id -notin $eligible){
            $account.phase='skipped';$account.error='No confirmed available quota at preflight';Save-Batch
            continue
        }
        $account.phase='sending';Save-Batch
        try{
            $receipt=Call-Switch 'consume_account_quota' @{id=$account.id}
            $account.phase='success'
            # Store only status metadata; responses may contain private account fields.
        }catch{$account.phase='uncertain';$account.error=$_.Exception.Message}
        Save-Batch
        Start-Sleep -Seconds 2
    }
    $batch.phase=if(@($batch.accounts|Where-Object {$_.phase -eq 'success'}).Count -eq $batch.accounts.Count){'success'}elseif(@($batch.accounts|Where-Object {$_.phase -eq 'success'}).Count -gt 0){'partial'}else{'failed'}
    Save-Batch
}catch{
    if($entered -and $lock){$batch.phase='failed';$batch|Add-Member -NotePropertyName error -NotePropertyValue $_.Exception.Message -Force;Save-Batch}
    exit 2
}finally{if($lock){$lock.Dispose()}}
if($batch.phase -notin @('success','partial')){exit 2}
