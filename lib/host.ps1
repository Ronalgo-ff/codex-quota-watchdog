# Demand-only interactive task: the tray is owned by Windows, not the Codex job.
function Get-QuotaHostTaskName([string]$Root) {
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$bytes=$hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Root).ToLowerInvariant()))}
    finally{$hash.Dispose()}
    return 'Codex Quota Watchdog Host-'+([BitConverter]::ToString($bytes).Replace('-','').Substring(0,12))
}
function Start-QuotaIndependentHost([string]$Root,[string]$ScriptPath) {
    $name=Get-QuotaHostTaskName $Root
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $source=Join-Path $PSScriptRoot 'hidden-host.cs'
    $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.Substring(0,12)
    $bin=Join-Path $Root 'state\bin';$null=New-Item -ItemType Directory -Path $bin -Force
    $bridge=Join-Path $bin ('QuotaHiddenHost-'+$hash+'.exe')
    if(-not(Test-Path -LiteralPath $bridge)){
        $compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        & $compiler /nologo /target:winexe ('/out:'+$bridge) $source
        if($LASTEXITCODE -ne 0){throw '无法生成无控制台启动器'}
    }
    $action=New-ScheduledTaskAction -Execute $bridge -Argument ('"{0}" "{1}"' -f $exe,$ScriptPath) -WorkingDirectory $Root
    $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if(-not $task -or $task.State -ne 'Running'){
        $null=Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Description '按需独立启动 Codex 额度看护，避免桌面重启连带结束后台。无定时或开机触发。' -Force
        $null=Start-ScheduledTask -TaskName $name
    }else{
        $stateDir=Join-Path $Root 'state';$null=New-Item -ItemType Directory -Path $stateDir -Force
        [IO.File]::WriteAllText((Join-Path $stateDir 'tray-show.json'),[guid]::NewGuid().ToString('N'))
    }
    return $name
}
