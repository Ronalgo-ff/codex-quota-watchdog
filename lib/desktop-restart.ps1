# Only recover a desktop that this watchdog has just asked Switch to restart.
function Get-CodexDesktopProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe' OR Name='Codex.exe'" -ErrorAction Stop | Where-Object {
        $_.CommandLine -notmatch '\s--type=' -and $_.CommandLine -notmatch '\bapp-server\b' -and
        $_.ExecutablePath -match '(?i)\\(OpenAI\.Codex_[^\\]+\\app|OpenAI\\Codex[^\\]*)\\(ChatGPT|Codex)\.exe$'
    })
}
function Get-CodexDesktopLaunch {
    $processes=@(Get-CodexDesktopProcesses)
    if($processes.Count -ne 1){return $null}
    $p=$processes[0];$exe=[string]$p.ExecutablePath
    $args=[string]$p.CommandLine
    if($args.StartsWith('"')){$args=$args -replace '^"[^"]+"\s*',''}
    elseif($args.StartsWith($exe,[StringComparison]::OrdinalIgnoreCase)){$args=$args.Substring($exe.Length).TrimStart()}
    else{return $null}
    if($args -match '(?i)token|password|authorization|api[_-]?key|bearer'){throw '桌面启动参数包含敏感字段，无法保存重启配置'}
    return [pscustomobject]@{executable=$exe;arguments=$args;processId=$p.ProcessId;startedAt=$p.CreationDate.ToString('o')}
}
function Start-CodexDesktopFallback($Launch) {
    if(-not $Launch -or $Launch.executable -notmatch '(?i)\\(ChatGPT|Codex)\.exe$' -or -not(Test-Path -LiteralPath $Launch.executable)){throw '切号后未找到有效的 Codex 桌面启动路径'}
    $options=@{FilePath=[string]$Launch.executable;WorkingDirectory=(Split-Path $Launch.executable -Parent);WindowStyle='Normal';PassThru=$true}
    if($Launch.arguments){$options.ArgumentList=[string]$Launch.arguments}
    $p=Start-Process @options
    return $p.Id
}
function Set-CodexDesktopRecovery($State,$Intent) {
    if(Get-StateFlag $State 'desktopRestart'){return}
    $launch=Get-StateFlag $Intent 'desktopLaunch'
    if(-not $launch){return}
    Set-StateFlag $State 'desktopRestart' ([pscustomobject]@{
        id=$Intent.id;targetId=$Intent.targetId;launch=$launch;phase='waiting';fallbackAttempted=$false
        allowLaunchAfter=(Get-Date).AddSeconds(15).ToString('o');deadline=(Get-Date).AddSeconds(90).ToString('o')
    })
    Save-State $State
}
function Test-CodexDesktopRecovery($State,$CurrentAccountId) {
    $recovery=Get-StateFlag $State 'desktopRestart'
    if(-not $recovery){return $true}
    if(-not $Live){return $true} # Dry run may inspect saved state but never launches apps.
    if($recovery.targetId -ne $CurrentAccountId){
        Request-ManualPause $State ('desktop-restart:'+ $recovery.id) '桌面恢复期间当前账号发生变化' @{target=$recovery.targetId;actual=$CurrentAccountId}
        return $false
    }
    if(@(Get-CodexDesktopProcesses).Count -gt 0){return $true}
    if((Get-Date) -ge [datetime]::Parse($recovery.deadline)){
        Request-ManualPause $State ('desktop-restart:'+ $recovery.id) '账号已切换，但 Codex 桌面未能重新打开' @{target=$recovery.targetId;fallbackAttempted=$recovery.fallbackAttempted;executable=$recovery.launch.executable}
        return $false
    }
    if((Get-Date) -lt [datetime]::Parse($recovery.allowLaunchAfter)){return $false}
    if(-not $recovery.fallbackAttempted){
        $recovery.fallbackAttempted=$true;$recovery.phase='launching';Save-State $State
        Write-Event '账号已切换，但桌面未打开；使用切号前记录的启动方式补启动一次' 'WARN'
        try{$pidValue=Start-CodexDesktopFallback $recovery.launch;Set-StateFlag $recovery 'fallbackPid' $pidValue;$recovery.phase='launched';Save-State $State}
        catch{Request-ManualPause $State ('desktop-restart:'+ $recovery.id) '切号后补启动 Codex 失败' @{error=$_.Exception.Message;executable=$recovery.launch.executable}}
    }
    return $false
}
