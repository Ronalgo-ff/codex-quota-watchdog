<# Windows 托盘宿主：看护独立运行，终端监控窗口可以随时关闭和重新打开。 #>
[CmdletBinding()]
param([switch]$SmokeTest)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$WatcherFile = Join-Path $Here 'codex-autopilot.ps1'
$MonitorFile = Join-Path $Here 'dashboard.ps1'
$LogDir = Join-Path $Here 'logs'
$TrayLog = Join-Path $LogDir 'tray.log'
$StatusFile = Join-Path $Here 'state\tray-status.json'
$HostCommandFile = Join-Path $Here 'state\tray-host-command.json'
$HostResultFile = Join-Path $Here 'state\tray-host-result.json'
$ShowRequestFile = Join-Path $Here 'state\tray-show.json'
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-TrayLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $TrayLog -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 } catch { }
}

$owned = $false
$mutexName = if ($SmokeTest) { 'Local\CodexQuotaAutopilotTraySmokeTest-' + $PID } else { 'Local\CodexQuotaAutopilotTray' }
$mutex = New-Object Threading.Mutex($true, $mutexName, [ref]$owned)
if (-not $owned) {
    $dir = Split-Path $ShowRequestFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
    [IO.File]::WriteAllText($ShowRequestFile, [guid]::NewGuid().ToString('N'))
    Write-TrayLog '托盘已在运行；请求打开菜单/运行窗口'
    $mutex.Dispose()
    exit 0
}

$tray = $null; $menu = $null; $timer = $null; $context = $null
$script:StopOnExit = $false
$script:LastHostCommandId = $null
$script:LastShowRequest = if (Test-Path $ShowRequestFile) { [IO.File]::ReadAllText($ShowRequestFile) } else { '' }
try {
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw '托盘需要 STA；请从 start-tray.vbs 启动'
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class QuotaMonitorWindow {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd,int msg,IntPtr wParam,IntPtr lParam);
}
'@

    function Get-Watchers {
        $pattern = '(?i)(?:^|\s)-File\s+"?' + [regex]::Escape([IO.Path]::GetFullPath($WatcherFile)) + '"?(?:\s|$)'
        $found = @()
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
            if ($p.ProcessId -eq $PID -or -not $p.CommandLine -or $p.CommandLine -notmatch $pattern) { continue }
            $mode = if ($p.CommandLine -match '(?i)(?:^|\s)-Live(?:\s|$)') { '正式' } else { '演习' }
            $found += [pscustomobject]@{ Id = [int]$p.ProcessId; Mode = $mode }
        }
        return $found
    }

    function Test-Csw {
        try {
            $endpoint='http://127.0.0.1:18080/__codex_switch__/api/invoke'
            $rules=Get-Content (Join-Path $Here 'rules.json') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue|ConvertFrom-Json
            if($rules -and $rules.PSObject.Properties['CswEndpoint']){$endpoint=$rules.CswEndpoint}
            $body = @{ command = 'get_app_info'; args = @{} } | ConvertTo-Json -Compress
            $reply = Invoke-RestMethod -Uri $endpoint -Method POST `
                -Body $body -ContentType 'application/json' -TimeoutSec 8
            return [bool]$reply.ok
        } catch { return $false }
    }

    function Start-Watcher {
        param([switch]$Live)
        if (@(Get-Watchers).Count -gt 0) { return }
        if (-not (Test-Path -LiteralPath $WatcherFile)) { throw "找不到看护脚本：$WatcherFile" }
        if (-not (Test-Csw)) { throw 'Codex Switch 尚未运行，请先启动它' }
        $mode = if ($Live) { '-Live' } else { '-DryRun' }
        $args = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $WatcherFile, $mode
        $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $args `
            -WorkingDirectory $Here -WindowStyle Hidden -PassThru
        Write-TrayLog "启动 $mode 看护 PID=$($p.Id)"
        $deadline=(Get-Date).AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 100
            $p.Refresh()
            if ($p.HasExited) { throw "看护启动失败（退出码 $($p.ExitCode)），请查看 logs/watch.log" }
            try {
                $run=Get-Content (Join-Path $Here 'state\current-run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($run.pid -eq $p.Id) { return }
            } catch { }
        } while ((Get-Date) -lt $deadline)
        throw '看护尚未完成初始化，请查看运行状态和日志'
    }

    function Stop-Watcher {
        foreach ($p in @(Get-Watchers)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Write-TrayLog "停止看护 PID=$($p.Id)"
        }
    }

    function Get-PauseStatus {
        param($Running)
        if (@($Running).Count -eq 0 -or -not (Test-Path -LiteralPath $StatusFile)) { return $false }
        try {
            $s = Get-Content -LiteralPath $StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json
            return ([bool]$s.paused -and @($Running | Where-Object { $_.Id -eq [int]$s.pid }).Count -gt 0)
        } catch { return $false }
    }

    function Get-MonitorProcess {
        $full = [IO.Path]::GetFullPath($MonitorFile)
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
            if ($p.CommandLine -and $p.CommandLine.IndexOf($full, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
            }
        }
        return $null
    }

    function Show-Monitor {
        $existing = Get-MonitorProcess
        if ($existing) {
            $existing.Refresh()
            $handle=$existing.MainWindowHandle
            try{$ui=Get-Content (Join-Path $Here 'state\dashboard-window.json') -Raw -Encoding UTF8|ConvertFrom-Json;if($ui.pid -eq $existing.Id){$handle=[IntPtr]([long]$ui.handle)}}catch{}
            if ($handle -ne [IntPtr]::Zero) {
                [void][QuotaMonitorWindow]::ShowWindow($handle, 9)
                [void][QuotaMonitorWindow]::SetForegroundWindow($handle)
            }
            return
        }
        $args = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $MonitorFile
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $args -WorkingDirectory $Here -WindowStyle Hidden | Out-Null
    }

    function Read-InitialHostCommand {
        if (-not (Test-Path -LiteralPath $HostCommandFile)) { return }
        try { $script:LastHostCommandId = [string](Get-Content -LiteralPath $HostCommandFile -Raw -Encoding UTF8 | ConvertFrom-Json).id } catch { }
    }

    function Process-HostCommand {
        if (-not (Test-Path -LiteralPath $HostCommandFile)) { return }
        $reply = $null
        $id = $null
        $command = $null
        try {
            $command = Get-Content -LiteralPath $HostCommandFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $id = [string]$command.id
            if (-not $id -or $id -eq $script:LastHostCommandId) { return }
            $script:LastHostCommandId = $id
            switch ([string]$command.action) {
                'start-live' { Start-Watcher -Live }
                'start-dry'  { Start-Watcher }
                'stop'       { Stop-Watcher }
                'show'       { Show-Monitor }
                default      { throw '无法识别的控制命令' }
            }
            $reply = @{ id=$id; action=[string]$command.action; success=$true; error=$null }
        } catch {
            Write-TrayLog "处理监控窗口命令失败：$($_.Exception.Message)"
            if ($id) { $reply = @{ id=$id; action=[string]$command.action; success=$false; error=$_.Exception.Message } }
        }
        if ($reply) {
            $tmp = "$HostResultFile.tmp"
            [IO.File]::WriteAllText($tmp, ($reply | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tmp -Destination $HostResultFile -Force
        }
    }

    function Update-Tray {
        $running = @(Get-Watchers)
        $state = if ($running.Count -eq 0) { '未运行' }
                 elseif (Get-PauseStatus -Running $running) { '已暂停' }
                 else { '运行中：' + (($running | ForEach-Object { $_.Mode }) -join '、') }
        $tray.Text = 'Codex 额度看护 - ' + $state
    }

    $context = New-Object System.Windows.Forms.ApplicationContext
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $open = New-Object System.Windows.Forms.ToolStripMenuItem('打开监控窗口')
    $exit = New-Object System.Windows.Forms.ToolStripMenuItem('停止看护并退出')
    [void]$menu.Items.Add($open)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($exit)

    $tray = New-Object System.Windows.Forms.NotifyIcon
    $iconPath=Join-Path $Here 'assets\codex-quota.ico'
    $tray.Icon = if(Test-Path $iconPath){New-Object System.Drawing.Icon($iconPath)}else{[System.Drawing.SystemIcons]::Application}
    $tray.Text = 'Codex 额度看护'
    $tray.ContextMenuStrip = $menu
    $open.add_Click({ Show-Monitor })
    $exit.add_Click({
        $script:StopOnExit = $true;Stop-Watcher;$window=Get-MonitorProcess
        if($window){
            try{$ui=Get-Content (Join-Path $Here 'state\dashboard-window.json') -Raw -Encoding UTF8|ConvertFrom-Json;if($ui.pid -eq $window.Id){[void][QuotaMonitorWindow]::PostMessage([IntPtr]([long]$ui.handle),0x0010,[IntPtr]::Zero,[IntPtr]::Zero)}else{[void]$window.CloseMainWindow()}}catch{[void]$window.CloseMainWindow()}
        }
        $context.ExitThread()
    })
    $tray.add_DoubleClick({ Show-Monitor })
    $menu.add_Opening({ Update-Tray })

    Read-InitialHostCommand
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = if ($SmokeTest) { 1000 } else { 500 }
    $timer.add_Tick({
        if ($SmokeTest) { $context.ExitThread(); return }
        Process-HostCommand
        if (Test-Path $ShowRequestFile) {
            $request=[IO.File]::ReadAllText($ShowRequestFile)
            if($request -ne $script:LastShowRequest){$script:LastShowRequest=$request;Show-Monitor}
        }
        Update-Tray
    })
    $tray.Visible = $true
    Update-Tray
    Write-TrayLog '托盘已启动'
    if (-not $SmokeTest) { Show-Monitor }
    $timer.Start()
    [System.Windows.Forms.Application]::Run($context)
} catch {
    Write-TrayLog "托盘异常：$($_.Exception.ToString())"
    exit 2
} finally {
    if ($timer) { $timer.Stop(); $timer.Dispose() }
    if ($tray) { $tray.Visible = $false; $tray.Dispose() }
    if ($menu) { $menu.Dispose() }
    if ($context) { $context.Dispose() }
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
