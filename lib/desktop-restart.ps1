# Only recover a desktop that this watchdog has just asked Switch to restart.
function Get-CodexDesktopProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe' OR Name='Codex.exe'" -ErrorAction Stop | Where-Object {
        $_.CommandLine -notmatch '\s--type=' -and $_.CommandLine -notmatch '\bapp-server\b' -and
        $_.ExecutablePath -match '(?i)\\(OpenAI\.Codex_[^\\]+\\app|OpenAI\\Codex[^\\]*)\\(ChatGPT|Codex)\.exe$'
    })
}
function Get-CodexDesktopAppId([string]$Executable) {
    if($Executable -notmatch '(?i)\\WindowsApps\\OpenAI\.Codex_[^_\\]+_[^_\\]+_[^_\\]*_(?<publisher>[a-z0-9]+)\\app\\(ChatGPT|Codex)\.exe$'){return $null}
    $family='OpenAI.Codex_'+$Matches.publisher
    # Start menu identity survives Store version/path changes. Never select by
    # display name (the installed Codex can be displayed as ChatGPT).
    $apps=@(Get-StartApps -ErrorAction Stop|Where-Object {$_.AppID.StartsWith($family+'!',[StringComparison]::OrdinalIgnoreCase)})
    if($apps.Count -eq 1){return [string]$apps[0].AppID}
    $packageRoot=Split-Path (Split-Path $Executable -Parent) -Parent
    $manifest=Join-Path $packageRoot 'AppxManifest.xml'
    if(Test-Path -LiteralPath $manifest){
        [xml]$xml=Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop
        $relative='app\'+[IO.Path]::GetFileName($Executable)
        $entries=@($xml.Package.Applications.Application|Where-Object {([string]$_.Executable).Replace('/','\') -eq $relative})
        if($entries.Count -eq 1){
            $id=$family+'!'+[string]$entries[0].Id
            if(@($apps|Where-Object {$_.AppID -eq $id}).Count -eq 1){return $id}
        }
    }
    throw '商店版 Codex 未找到唯一的已注册应用启动入口'
}

function Initialize-CodexDesktopActivation {
    if(-not ('QuotaWatchdog.DesktopActivation' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'desktop-activation.cs')}
}
function Invoke-CodexDesktopActivation([string]$AppId,[string]$Arguments) {
    Initialize-CodexDesktopActivation
    return [QuotaWatchdog.DesktopActivation]::Activate($AppId,$Arguments)
}
function Test-CodexActivationExiting($Exception) {
    while($Exception){
        # Windows explicitly rejected activation because the app is exiting.
        # Only this proven rejection permits retry; a timeout is ambiguous.
        if($Exception.HResult -eq -2147483622){return $true} # 0x8000001A
        $Exception=$Exception.InnerException
    }
    return $false
}

function Initialize-CodexDesktopProcess {
    if(-not ('QuotaWatchdog.DesktopProcess' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'desktop-process.cs')}
}
function Stop-CodexDesktopExact($Launch) {
    $sourcePid=[int](Get-StateFlag $Launch 'processId')
    $started=[DateTimeOffset]::MinValue
    $exe=[string](Get-StateFlag $Launch 'executable')
    if($sourcePid -le 0 -or $exe -notmatch '(?i)\\(OpenAI\.Codex_[^\\]+\\app|OpenAI\\Codex[^\\]*)\\(ChatGPT|Codex)\.exe$' -or
        -not [DateTimeOffset]::TryParse([string](Get-StateFlag $Launch 'startedAt'),[ref]$started)){
        throw '切号前的桌面进程身份不完整，不能强制退出'
    }
    Initialize-CodexDesktopProcess
    return [QuotaWatchdog.DesktopProcess]::StopExact($sourcePid,$exe,$started.UtcDateTime)
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
    $launch=[pscustomobject]@{executable=$exe;arguments=$args;processId=$p.ProcessId;startedAt=$p.CreationDate.ToString('o')}
    $appId=Get-CodexDesktopAppId $exe
    if($appId){Set-StateFlag $launch 'appUserModelId' $appId}
    return $launch
}
function Start-CodexDesktopFallback($Launch) {
    if(-not $Launch -or $Launch.executable -notmatch '(?i)\\(ChatGPT|Codex)\.exe$'){throw '切号后未找到有效的 Codex 桌面启动路径'}
    # Resolve legacy saved launches too. A Store update can remove the old exe,
    # so use registered application identity before testing that versioned path.
    $appId=Get-CodexDesktopAppId $Launch.executable
    if($appId){
        $saved=Get-StateFlag $Launch 'appUserModelId'
        if($saved -and $saved -ne $appId){throw '商店版 Codex 启动身份与切号前记录不一致'}
        return Invoke-CodexDesktopActivation $appId ([string]$Launch.arguments)
    }
    if($Launch.executable -match '(?i)\\WindowsApps\\' -or -not(Test-Path -LiteralPath $Launch.executable)){throw '切号后未找到有效的 Codex 桌面启动路径'}
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
        forceExitAfter=(Get-Date).AddSeconds(30).ToString('o');forceExitAttempted=$false
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
    $processes=@(Get-CodexDesktopProcesses)
    $sourcePid=Get-StateFlag $recovery.launch 'processId'
    $new=@($processes|Where-Object {
        if(-not $sourcePid -or $_.ProcessId -ne $sourcePid){return $true}
        $created=Get-StateFlag $_ 'CreationDate';$started=Get-StateFlag $recovery.launch 'startedAt'
        return $created -and $started -and [Math]::Abs((([datetime]$created)-[datetime]::Parse($started)).TotalSeconds) -gt 2
    })
    if($new.Count -gt 0){return $true}
    if((Get-Date) -ge [datetime]::Parse($recovery.deadline)){
        Request-ManualPause $State ('desktop-restart:'+ $recovery.id) '账号已切换，但 Codex 桌面未能重新打开' @{target=$recovery.targetId;fallbackAttempted=$recovery.fallbackAttempted;executable=$recovery.launch.executable}
        return $false
    }
    if($processes.Count -gt 0){
        # Only a confirmed automatic switch enters this recovery. Force at most
        # the exact captured old main process after its normal exit grace period.
        # A new instance above, or an accepted/ambiguous launch, cannot be killed.
        $forceAfter=Get-StateFlag $recovery 'forceExitAfter'
        if(-not $forceAfter){$forceAfter=([datetime]::Parse($recovery.deadline).AddSeconds(-60)).ToString('o')}
        $started=[DateTimeOffset]::MinValue
        $identityComplete=$sourcePid -and (Get-StateFlag $recovery.launch 'executable') -and
            [DateTimeOffset]::TryParse([string](Get-StateFlag $recovery.launch 'startedAt'),[ref]$started)
        if($identityComplete -and -not(Get-StateFlag $recovery 'forceExitAttempted') -and
            (Get-Date) -ge [datetime]::Parse($forceAfter) -and
            (-not $recovery.fallbackAttempted -or $recovery.phase -eq 'activation-rejected')){
            Set-StateFlag $recovery 'forceExitAttempted' $true
            Set-StateFlag $recovery 'forceExitAt' ((Get-Date).ToString('o'))
            Save-State $State # Persist before termination; never repeat after a crash.
            Write-Event "切号后旧 Codex 进程超过 30 秒仍未退出，将核对进程身份并强制退出一次：PID=$sourcePid" 'WARN'
            try{
                $result=Stop-CodexDesktopExact $recovery.launch
                Set-StateFlag $recovery 'forceExitResult' $result
                if($result -in @('terminated','already-exited','termination-pending')){
                    $recovery.allowLaunchAfter=(Get-Date).AddSeconds(2).ToString('o')
                    Write-Event '旧 Codex 已提交退出，核实其退出后按原启动参数打开；切号不会重复执行' 'WARN'
                }else{
                    Write-Event '旧 Codex 进程身份已变化，已跳过强制退出并重新核实现场' 'WARN'
                }
                Save-State $State
            }catch{
                Set-StateFlag $recovery 'forceExitError' $_.Exception.Message;Save-State $State
                Request-ManualPause $State ('desktop-restart:'+ $recovery.id) '强制退出旧 Codex 失败' @{error=$_.Exception.Message;processId=$sourcePid;executable=$recovery.launch.executable}
            }
        }
        return $false # Re-read processes on the next round before any activation.
    }
    if((Get-Date) -lt [datetime]::Parse($recovery.allowLaunchAfter)){return $false}
    if(-not $recovery.fallbackAttempted -or $recovery.phase -eq 'activation-rejected'){
        $attempts=[int](Get-StateFlag $recovery 'launchAttempts')
        if($attempts -ge 3){
            Request-ManualPause $State ('desktop-restart:'+ $recovery.id) 'Windows 连续三次拒绝打开 Codex，暂停等待人工处理' $recovery
            return $false
        }
        Set-StateFlag $recovery 'launchAttempts' ($attempts+1)
        $recovery.fallbackAttempted=$true;$recovery.phase='launching';Save-State $State
        Write-Event '账号已切换，但桌面未打开；按记录的应用身份和启动参数补启动' 'WARN'
        try{$pidValue=Start-CodexDesktopFallback $recovery.launch;Set-StateFlag $recovery 'fallbackPid' $pidValue;$recovery.phase='launched';Save-State $State}
        catch{
            if(Test-CodexActivationExiting $_.Exception){
                $recovery.phase='activation-rejected'
                Set-StateFlag $recovery 'lastLaunchError' $_.Exception.Message
                $recovery.allowLaunchAfter=(Get-Date).AddSeconds(15).ToString('o');Save-State $State
                Write-Event 'Windows 明确拒绝启动：旧应用仍在退出，15 秒后核实进程再重试（最多三次）' 'WARN'
            }else{
                Request-ManualPause $State ('desktop-restart:'+ $recovery.id) '切号后补启动 Codex 失败' @{error=$_.Exception.Message;executable=$recovery.launch.executable}
            }
        }
    }
    return $false
}
