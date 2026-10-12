# Shared local schedule configuration and task registration. No actions at import.
$script:ScheduleRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:ScheduleTaskName='Codex Switch - Quota Window Scheduler'
function Read-ScheduleJson($Path){if(Test-Path -LiteralPath $Path){return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json};return $null}
function Write-ScheduleJson($Path,$Value){
    $null=New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force
    $tmp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($tmp,($Value|ConvertTo-Json -Depth 15),(New-Object Text.UTF8Encoding($true)))
    if(Test-Path -LiteralPath $Path){[IO.File]::Replace($tmp,$Path,$Path+'.bak')}else{[IO.File]::Move($tmp,$Path)}
}
function Normalize-ScheduleTimes($Times){
    $valid=@()
    foreach($t in @($Times)){
        $parsed=[datetime]::MinValue
        if(-not [datetime]::TryParseExact([string]$t,'HH:mm',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)){throw "无效时间：$t，请使用 HH:mm"}
        $valid+=[string]$t
    }
    return @($valid|Sort-Object -Unique)
}
function Get-ScheduleConfig{
    $config=Read-ScheduleJson (Join-Path $script:ScheduleRoot 'state\scheduler\config.json')
    if(-not $config){return [pscustomobject]@{port=18080;times=@();enabled=$false}}
    return $config
}
function Get-ScheduleTaskAction{
    return New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -RunOnce' -f (Join-Path $script:ScheduleRoot 'scheduler.ps1')) -WorkingDirectory $script:ScheduleRoot
}
function Set-ScheduleConfig($Port,$Times,[bool]$Enabled=$true){
    if($Port -lt 1 -or $Port -gt 65535){throw '监听端口必须在 1–65535 之间'}
    $times=@(Normalize-ScheduleTimes $Times)
    # Use the Windows task to keep schedules working while the window is closed.
    $oldTask=Get-ScheduledTask -TaskName $script:ScheduleTaskName -ErrorAction SilentlyContinue
    if($times.Count -gt 0){
        $triggers=@($times|ForEach-Object {New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($_,'HH:mm',[Globalization.CultureInfo]::InvariantCulture))})
        if($oldTask){$null=Set-ScheduledTask -TaskName $script:ScheduleTaskName -Action (Get-ScheduleTaskAction) -Trigger $triggers}
        else{
            $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
            $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
            $null=Register-ScheduledTask -TaskName $script:ScheduleTaskName -Action (Get-ScheduleTaskAction) -Trigger $triggers -Principal $principal -Settings $settings -Description 'Codex 额度看护：在指定时间统一触发可用账号的额度窗口。' -Force
        }
        if($Enabled){$null=Enable-ScheduledTask -TaskName $script:ScheduleTaskName}else{$null=Disable-ScheduledTask -TaskName $script:ScheduleTaskName}
    }elseif($oldTask){$null=Disable-ScheduledTask -TaskName $script:ScheduleTaskName}
    Write-ScheduleJson (Join-Path $script:ScheduleRoot 'state\scheduler\config.json') @{port=[int]$Port;times=$times;enabled=($Enabled -and $times.Count -gt 0)}
    $rules=Read-ScheduleJson (Join-Path $script:ScheduleRoot 'rules.json')
    if($rules){$rules|Add-Member -NotePropertyName CswEndpoint -NotePropertyValue "http://127.0.0.1:$Port/__codex_switch__/api/invoke" -Force;Write-ScheduleJson (Join-Path $script:ScheduleRoot 'rules.json') $rules}
}
function Write-SchedulerEvent($Message,$Level='INFO'){
    $path=Join-Path $script:ScheduleRoot 'logs\scheduler.log';$null=New-Item -ItemType Directory (Split-Path $path -Parent) -Force
    Add-Content -LiteralPath $path -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'MM-dd HH:mm:ss'),$Level,$Message) -Encoding UTF8
}
function New-ScheduleBatch($Accounts,$Endpoint,$Source){
    $id=[guid]::NewGuid().ToString('N');$job=Join-Path $script:ScheduleRoot ('state\quota-batches\'+$id+'.json')
    $batch=@{id=$id;source=$Source;waitPolicy='any';endpoint=$Endpoint;phase='prepared';startedAt=(Get-Date).ToString('o');coordinationDir=(Join-Path $script:ScheduleRoot 'state\quota-coordination');accounts=@($Accounts|ForEach-Object {@{id=$_.id;phase='pending';error=$null}})}
    Write-ScheduleJson $job $batch
    return $job
}
