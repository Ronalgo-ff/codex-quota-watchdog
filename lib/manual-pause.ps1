# Local incident reports and durable operator pause. No external diagnostic process.
$script:ManualPauseMemory=$null
function Get-ManualPausePath {
    Join-Path $Script:Config.StateDir $(if($Live){'manual-pause.json'}else{'manual-pause.dry-run.json'})
}
function Get-ManualPause {
    if($script:ManualPauseMemory){return $script:ManualPauseMemory}
    $path=Get-ManualPausePath
    if(-not (Test-Path -LiteralPath $path)){return $null}
    try {
        $p=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if($p.active){return $p}
    }catch{
        return [pscustomobject]@{active=$true;reason='暂停状态文件无法读取，请检查后手动恢复';reportPath=$path}
    }
    return $null
}
function Request-ManualPause {
    param($State,[string]$Key,[string]$Reason,$Details)
    $id=[guid]::NewGuid().ToString('N')
    $dir=Join-Path $Script:Config.StateDir 'incidents'
    $path=Join-Path $dir ($id+'.json')
    $pause=[pscustomobject]@{active=$true;id=$id;key=$Key;reason=$Reason;at=(Get-Date).ToString('o');reportPath=$path}
    $script:ManualPauseMemory=$pause
    $script:Paused=$true
    try{
        $null=New-Item -ItemType Directory -Path $dir -Force
        Write-JsonAtomic (Get-ManualPausePath) $pause -Backup
        $snapshots=@{}
        foreach($name in @('current-run.json','quota-status.json','last-observation.json')){
            $file=Join-Path $Script:Config.StateDir $name
            if(Test-Path -LiteralPath $file){try{$snapshots[$name]=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json}catch{$snapshots[$name]='unreadable'}}
        }
        $report=[ordered]@{reportId=$id;exitCode=2;at=$pause.at;mode=$(if($Live){'live'}else{'dry-run'});reason=$Reason;key=$Key;details=$Details;stack=(Get-PSCallStack|Out-String);snapshots=$snapshots;state=$State}
        Write-JsonAtomic $path $report
        Write-JsonAtomic $Script:ReportFile $report
        Write-File ($report|ConvertTo-Json -Depth 20 -Compress) 'ERROR'
    }catch{
        Write-Event "保存异常现场遇到错误：$($_.Exception.Message)；内存暂停仍生效" 'ERROR'
    }
    Set-TrayPauseStatus -Paused $true
    Write-Event "已因异常暂停：$Reason；报告：$path。处理后按 P 恢复" 'ALERT'
    $errorObject=New-Object InvalidOperationException($Reason)
    $errorObject.Data['QuotaManualPause']=$true
    throw $errorObject
}
function Wait-ManualPause {
    $pause=Get-ManualPause
    if(-not $pause){return}
    $script:Paused=$true
    Set-TrayPauseStatus -Paused $true
    Write-Event "看护保持异常暂停：$($pause.reason)；报告：$($pause.reportPath)。按 P 手动恢复" 'WARN'
    while($true){
        # Opening a window or pressing an unrelated key must not resume operations.
        if((Get-TrayControl) -eq 'resume'){
            $resolved=[pscustomobject]@{active=$false;at=(Get-Date).ToString('o');previous=$pause;action='manual-resume'}
            Write-JsonAtomic (Get-ManualPausePath) $resolved -Backup
            $script:ManualPauseMemory=$null;$script:Paused=$false
            Set-TrayPauseStatus -Paused $false
            Write-Event '已手动恢复看护，将重新检查现场；未确认的操作不会重复执行' 'OK'
            return
        }
        Start-Sleep -Milliseconds 250
    }
}

# A known terminal failure in one chat must not stop account monitoring or other
# chats. Persist one report per affected turn, without acknowledging any delivery.
function Write-ThreadIssue {
    param($State,[string]$Key,[string]$Reason,$Details)
    if(-not $Live){Write-Transition ('thread-issue:'+ $Key) "[演习] $Reason";return}
    $issues=Get-StateFlag $State 'threadIssues'
    if(-not $issues){$issues=[pscustomobject]@{};Set-StateFlag $State 'threadIssues' $issues}
    if(Get-StateFlag $issues $Key){return}
    $id=[guid]::NewGuid().ToString('N')
    $dir=Join-Path $Script:Config.StateDir 'incidents'
    $null=New-Item -ItemType Directory -Path $dir -Force
    $path=Join-Path $dir ('thread-'+$id+'.json')
    $report=[pscustomobject]@{reportId=$id;scope='thread';at=(Get-Date).ToString('o');reason=$Reason;key=$Key;details=$Details}
    Write-JsonAtomic $path $report
    Set-StateFlag $issues $Key ([pscustomobject]@{at=$report.at;reason=$Reason;reportPath=$path})
    Save-State $State
    Write-Event "$Reason；仅停止该回合的自动续跑，其他看护继续。报告：$path" 'WARN'
}
