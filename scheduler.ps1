# Unified scheduler worker. GUI tasks and Windows scheduled task use this entry.
[CmdletBinding()]
param([switch]$RunOnce,[string]$RequestFile,[switch]$LibraryOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\scheduler.ps1')
if($LibraryOnly){return}
$request=$null;$resultPath=$null;$guard=$null
try{
    if($RequestFile){$request=Read-ScheduleJson $RequestFile;$resultPath=$RequestFile+'.result.json'}
    $config=Get-ScheduleConfig
    if($request -and $request.action -eq 'save'){
        # Do not redirect a live watcher to a different server mid-round.
        $run=Read-ScheduleJson (Join-Path $PSScriptRoot 'state\current-run.json')
        if($run -and $request.port -ne $config.port){
            $live=$false;try{$p=Get-Process -Id $run.pid -ErrorAction Stop;$live=[Math]::Abs(($p.StartTime-[datetime]::Parse($run.processStartedAt)).TotalSeconds)-lt 2}catch{}
            if($live){throw '更改监听端口前，请先停止看护，再保存并重新启动'}
        }
        Set-ScheduleConfig $request.port @($request.times) ([bool]$request.enabled)
        Write-SchedulerEvent ('定时设置已保存：'+(@($request.times)-join '、'))
        Write-ScheduleJson $resultPath @{ok=$true;message='设置已保存，Windows 定时任务已更新'}
        exit 0
    }
    if($request -and $request.action -eq 'disable'){
        $task=Get-ScheduledTask -TaskName $script:ScheduleTaskName -ErrorAction SilentlyContinue
        if($task){$null=Disable-ScheduledTask -TaskName $script:ScheduleTaskName}
        $config|Add-Member -NotePropertyName enabled -NotePropertyValue $false -Force
        Write-ScheduleJson (Join-Path $PSScriptRoot 'state\scheduler\config.json') $config
        Write-SchedulerEvent '定时任务已停用，时间设置保留'
        Write-ScheduleJson $resultPath @{ok=$true;message='定时任务已停用，时间设置保留'};exit 0
    }
    $port=[int]$config.port;if($request -and $request.PSObject.Properties['port']){$port=[int]$request.port}
    $endpoint="http://127.0.0.1:$port/__codex_switch__/api/invoke"
    $httpOptions=@{}
    if((Get-Command Invoke-RestMethod).Parameters.ContainsKey('NoProxy')){$httpOptions.NoProxy=$true}
    $deadline=(Get-Date).AddMinutes(10);$accounts=@()
    do{
        try{$r=Invoke-RestMethod -Uri $endpoint -Method Post -ContentType application/json -Body '{"command":"list_accounts","args":{}}' -TimeoutSec 8 @httpOptions;if(-not $r.ok){throw $r.error};$accounts=@($r.result);break}
        catch{if(-not $RunOnce -or (Get-Date) -ge $deadline){throw};Start-Sleep -Seconds 10}
    }while($true)
    if($request -and $request.action -eq 'test'){
        Write-ScheduleJson $resultPath @{ok=$true;message="连接成功，读取到 $($accounts.Count) 个账号"};exit 0
    }
    if($accounts.Count -eq 0){throw '没有读取到账号，本次没有发送消耗请求'}
    if(-not $RunOnce -and (-not $request -or $request.action -ne 'consume')){throw '不支持的定时操作'}
    # One scheduler/manual invocation at a time, independently of window lifetime.
    $guardDir=Join-Path $PSScriptRoot 'state\scheduler';$null=New-Item -ItemType Directory $guardDir -Force
    try{$guard=[IO.File]::Open((Join-Path $guardDir 'worker.lock'),'OpenOrCreate','ReadWrite','None')}catch{throw '另一条定时/手动消耗正在执行，本次不重复启动'}
    $source=if($RunOnce){'scheduled'}else{'manual'}
    $job=New-ScheduleBatch $accounts $endpoint $source
    Write-ScheduleJson (Join-Path $guardDir 'last-run.json') @{at=(Get-Date).ToString('o');job=$job;pid=$PID;phase='running';source=$source}
    Write-SchedulerEvent "$source 消耗开始，读取到 $($accounts.Count) 个账号"
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    do{
        & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'quota-batch.ps1') -JobFile $job
        $batch=Read-ScheduleJson $job
        # Only a preflight failure with zero intents is retryable.
        if($RunOnce -and $batch.phase -eq 'preflight-retry' -and @($batch.accounts|Where-Object {$_.phase -ne 'pending'}).Count -eq 0 -and (Get-Date) -lt $deadline){
            Start-Sleep -Seconds 10;$job=New-ScheduleBatch $accounts $endpoint $source;continue
        }
        break
    }while($true)
    $success=@($batch.accounts|Where-Object {$_.phase -eq 'success'}).Count
    $skipped=@($batch.accounts|Where-Object {$_.phase -eq 'skipped'}).Count
    $uncertain=@($batch.accounts|Where-Object {$_.phase -eq 'uncertain' -or $_.phase -eq 'sending'}).Count
    $message="本次完成：成功 $success，跳过 $skipped，未确认 $uncertain"
    if($batch.phase -eq 'not-ready'){$message='当前没有可用账号，本次未消耗额度'}
    if($batch.phase -notin @('success','partial','not-ready')){$message+="；状态 $($batch.phase)"}
    Write-ScheduleJson (Join-Path $guardDir 'last-run.json') @{at=(Get-Date).ToString('o');job=$job;phase=$batch.phase;source=$source;message=$message}
    Write-SchedulerEvent $message $(if($uncertain -or $batch.phase -eq 'failed'){'WARN'}else{'INFO'})
    if($resultPath){Write-ScheduleJson $resultPath @{ok=($batch.phase -in @('success','partial','not-ready'));message=$message;job=$job}}
    if($uncertain -or $batch.phase -eq 'failed'){exit 2}
}catch{
    Write-SchedulerEvent $_.Exception.Message 'ERROR'
    if($resultPath){Write-ScheduleJson $resultPath @{ok=$false;message=$_.Exception.Message}}
    exit 2
}finally{if($guard){$guard.Dispose()}}
