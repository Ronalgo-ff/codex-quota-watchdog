<#
    控制台菜单 —— 给用户双击用的开关。
    中文界面放在这里而不是 .cmd 里，因为 cmd 会按系统 ANSI 码页读 .cmd，中文会乱。
    这个文件必须以「UTF-8 带 BOM」保存。
#>
[CmdletBinding()]
param(
    # 非交互模式：直接执行一个动作后退出。不带参数 = 交互菜单。
    [ValidateSet('status', 'logs', 'stop', 'start', 'start-live', 'check')]
    [string]$Action,
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try { $Host.UI.RawUI.WindowTitle = 'Codex Quota Autopilot' } catch { }

$Here   = $PSScriptRoot
$Script = Join-Path $Here 'codex-autopilot.ps1'
$LogF   = Join-Path $Here 'logs\watch.log'
$RepF   = Join-Path $Here 'state\last-report.json'
$HndF   = Join-Path $Here 'state\handled.json'
$TrayF  = Join-Path $Here 'tray.ps1'
$HostCommandF = Join-Path $Here 'state\tray-host-command.json'

function Write-Head {
    Clear-Host
    Write-Host ''
    Write-Host '  ==========================================================' -ForegroundColor Cyan
    Write-Host '     Codex 额度看护  -  控制台' -ForegroundColor Cyan
    Write-Host '  ==========================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "     脚本：$Script" -ForegroundColor DarkGray
    Write-Host ''
}

function Get-AutopilotProcs {
    # 找出真正在跑看护的进程；必须排除自己和父进程，否则会杀掉自己
    $self = $PID
    $parent = try { (Get-CimInstance Win32_Process -Filter "ProcessId=$self" -ErrorAction Stop).ParentProcessId } catch { -1 }
    $out = @()
    $pattern = '(?i)(?:^|\s)-File\s+"?' + [regex]::Escape([IO.Path]::GetFullPath($Script)) + '"?(?:\s|$)'
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.ProcessId -eq $self -or $p.ProcessId -eq $parent) { continue }
        try {
            $cl = $p.CommandLine
            if ($cl -and $cl -match $pattern) {
                $mode = if ($cl -match '-Live') { '正式' } else { '演习' }
                $out += [pscustomobject]@{ Id = $p.ProcessId; Mode = $mode; Since = $p.CreationDate }
            }
        } catch { }
    }
    return $out
}

function Get-TrayProcs {
    $out = @()
    $full = [IO.Path]::GetFullPath($TrayF)
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.CommandLine -and $p.CommandLine.IndexOf($full, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $out += $p }
    }
    return $out
}

function Send-TrayHostCommand {
    param([ValidateSet('start-live','start-dry','stop')][string]$Command)
    $dir = Split-Path $HostCommandF -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = @{ id = [guid]::NewGuid().ToString('N'); action = $Command; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($HostCommandF, $json, (New-Object Text.UTF8Encoding($false)))
}

function Test-Csw {
    try {
        $endpoint = 'http://127.0.0.1:18080/__codex_switch__/api/invoke'
        $localRules = Join-Path $Here 'rules.local.json'
        if (Test-Path -LiteralPath $localRules) {
            $localConfig = Get-Content -LiteralPath $localRules -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($localConfig.CswEndpoint) { $endpoint = $localConfig.CswEndpoint }
        }
        $httpOptions = @{}
        if (([uri]$endpoint).IsLoopback -and (Get-Command Invoke-RestMethod).Parameters.ContainsKey('NoProxy')) { $httpOptions.NoProxy = $true }
        $body = @{ command = 'get_app_info'; args = @{} } | ConvertTo-Json -Compress
        $r = Invoke-RestMethod -Uri $endpoint -Method POST `
                -Body $body -ContentType 'application/json' -TimeoutSec 8 @httpOptions
        return $r.ok
    } catch { return $false }
}

function Show-Status {
    param([switch]$NoPause)
    Write-Head
    $running = @(Get-AutopilotProcs)
    Write-Host '  ── 看护进程 ──' -ForegroundColor Yellow
    if ($running.Count -eq 0) {
        Write-Host '     （未运行）' -ForegroundColor DarkGray
    } else {
        foreach ($r in $running) {
            $color = if ($r.Mode -eq '正式') { 'Green' } else { 'DarkYellow' }
            Write-Host ("     PID {0}  [{1}]  启动于 {2:HH:mm:ss}" -f $r.Id, $r.Mode, $r.Since) -ForegroundColor $color
        }
    }
    Write-Host ''
    Write-Host '  ── Codex Switch 接口 ──' -ForegroundColor Yellow
    if (Test-Csw) { Write-Host '     本机管理接口在线' -ForegroundColor Green }
    else { Write-Host '     接口未就绪，请检查 Switch 和网页版监听端口' -ForegroundColor Red }

    Write-Host ''
    Write-Host '  ── 最近一次报告 ──' -ForegroundColor Yellow
    if (Test-Path $RepF) {
        try {
            $rep = Get-Content $RepF -Raw -Encoding UTF8 | ConvertFrom-Json
            $map = @{ '0' = '一切正常'; '1' = '已自动处理'; '2' = '需要人工处理'; '3' = '账号全空已收摊' }
            $c = @{ '0' = 'Green'; '1' = 'Green'; '2' = 'Yellow'; '3' = 'Red' }
            $code = "$($rep.exitCode)"
            Write-Host ("     退出码 {0} — {1}" -f $code, $map[$code]) -ForegroundColor $c[$code]
            Write-Host ("     原因：{0}" -f $rep.reason)
            Write-Host ("     时间：{0}" -f $rep.at)
            if ($rep.details) {
                $dj = ($rep.details | ConvertTo-Json -Depth 4 -Compress)
                if ($dj.Length -gt 300) { $dj = $dj.Substring(0, 300) + ' ...' }
                Write-Host ("     细节：{0}" -f $dj) -ForegroundColor DarkGray
            }
        } catch { Write-Host '     报告读不出来' -ForegroundColor Red }
    } else { Write-Host '     （还没有报告）' -ForegroundColor DarkGray }

    Write-Host ''
    Write-Host '  ── 已处理过的撞墙记录 ──' -ForegroundColor Yellow
    if (Test-Path $HndF) {
        try {
            $h = Get-Content $HndF -Raw -Encoding UTF8 | ConvertFrom-Json
            $keys = @($h.handled.PSObject.Properties.Name)
            if ($keys.Count -eq 0) { Write-Host '     （无）' -ForegroundColor DarkGray }
            else { foreach ($k in $keys) { Write-Host ("     · " + $k.Substring(0, [Math]::Min(110, $k.Length))) -ForegroundColor DarkGray } }
        } catch { Write-Host '     （读不出）' -ForegroundColor DarkGray }
    } else { Write-Host '     （无）' -ForegroundColor DarkGray }

    Write-Host ''
    if (-not $NoPause) { Read-Host '  回车返回菜单' | Out-Null }
}

function Show-Logs {
    param([switch]$NoPause)
    Write-Head
    Write-Host '  ── 日志最后 40 行 ──' -ForegroundColor Yellow
    Write-Host ''
    if (Test-Path $LogF) {
        Get-Content $LogF -Tail 40 -Encoding UTF8 | ForEach-Object {
            $color = 'Gray'
            if ($_ -match '\[ALERT|\[ERROR|\[FATAL') { $color = 'Red' }
            elseif ($_ -match '\[WARN') { $color = 'Yellow' }
            elseif ($_ -match '\[OK') { $color = 'Green' }
            Write-Host "  $_" -ForegroundColor $color
        }
    } else { Write-Host '     （还没有日志）' -ForegroundColor DarkGray }
    Write-Host ''
    if (-not $NoPause) { Read-Host '  回车返回菜单' | Out-Null }
}

function Start-Autopilot {
    param([switch]$Live)
    Write-Head
    if (-not (Test-Path $Script)) {
        Write-Host "  找不到脚本：$Script" -ForegroundColor Red
        Read-Host '  回车返回' | Out-Null; return
    }
    if (-not (Test-Csw)) {
        Write-Host '  Switch 本机管理接口未就绪，请在 Switch 设置中启用网页版监听端口。' -ForegroundColor Red
        Read-Host '  回车返回' | Out-Null; return
    }
    $existing = @(Get-AutopilotProcs)
    if ($existing.Count -gt 0) {
        Write-Host "  已有 $($existing.Count) 个看护进程在运行，请先停止旧进程。" -ForegroundColor Yellow
        Read-Host '  回车返回' | Out-Null; return
    }
    $shellExe = (Get-Process -Id $PID).Path
    if (@(Get-TrayProcs).Count -gt 0) {
        $command = if ($Live) { 'start-live' } else { 'start-dry' }
        Send-TrayHostCommand -Command $command
        Write-Host '  已把启动请求交给托盘；关闭本窗口不会影响后台看护。' -ForegroundColor Green
        $deadline = (Get-Date).AddSeconds(5)
        while (@(Get-AutopilotProcs).Count -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        Write-Host ''
        Read-Host '  回车返回菜单' | Out-Null
        return
    }
    if ($Live) {
        Write-Host '  **********************************************************' -ForegroundColor Red
        Write-Host '  *  正式运行会真的切换账号、重启 Codex，' -ForegroundColor Red
        Write-Host '  *  并向撞墙的对话发送"继续"。' -ForegroundColor Red
        Write-Host '  **********************************************************' -ForegroundColor Red
        Write-Host ''
        Write-Host '  >>> 直接开始运行（不再需要确认）' -ForegroundColor Green
        Write-Host '  >>> 按一次 ESC 暂停，暂停中再按一次 ESC 退出' -ForegroundColor Green
        Write-Host ''
        # Run in a child process so status/stop can identify the actual watcher.
        & $shellExe -NoProfile -ExecutionPolicy Bypass -File $Script -Live
    } else {
        Write-Host '  >>> 演习模式：只判断，不会动任何东西。' -ForegroundColor Yellow
        Write-Host '  >>> 按一次 ESC 暂停，暂停中再按一次 ESC 退出' -ForegroundColor DarkGray
        Write-Host ''
        & $shellExe -NoProfile -ExecutionPolicy Bypass -File $Script -DryRun
    }
    Write-Host ''
    Write-Host ("  ---- 结束，退出码 {0} ----" -f $LASTEXITCODE) -ForegroundColor Cyan
    Write-Host '  0=正常  1=已自动处理  2=需要人工处理  3=账号全空' -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '  回车返回菜单' | Out-Null
}

function Stop-Autopilot {
    param([switch]$NoPause)
    Write-Head
    $running = @(Get-AutopilotProcs)
    if ($running.Count -eq 0) {
        Write-Host '  没有正在运行的看护进程。' -ForegroundColor DarkGray
    } else {
        foreach ($r in $running) {
            Write-Host ("  正在停止 PID {0} ..." -f $r.Id) -ForegroundColor Yellow
            Stop-Process -Id $r.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
        $left = @(Get-AutopilotProcs)
        if ($left.Count -eq 0) { Write-Host '  已全部停止。' -ForegroundColor Green }
        else { Write-Host ("  还有 {0} 个没停掉，重试一次。" -f $left.Count) -ForegroundColor Red }
    }
    Write-Host ''
    if (-not $NoPause) { Read-Host '  回车返回菜单' | Out-Null }
}

if ($LibraryOnly) { return }

# ── 非交互模式：执行一个动作就退出（给 AI / 脚本调用）──
if ($Action) {
    switch ($Action) {
        'status'     { Show-Status -NoPause }
        'logs'       { Show-Logs -NoPause }
        'stop'       { Stop-Autopilot -NoPause }
        'check'      { if (Test-Csw) { Write-Host 'csw: 在线' } else { Write-Host 'csw: 连不上' }; exit 0 }
        'start'      { & $Script -DryRun -Once; exit $LASTEXITCODE }
        'start-live' { & $Script -Live -Once; exit $LASTEXITCODE }
    }
    return
}

# ── 主菜单 ──
while ($true) {
    Write-Head
    $running = @(Get-AutopilotProcs)
    if ($running.Count -gt 0) {
        Write-Host ("     当前状态：正在运行（{0} 个进程）" -f $running.Count) -ForegroundColor Green
    } else {
        Write-Host '     当前状态：未运行' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '     [1]  演习模式     只判断，不动任何东西（第一次请先跑这个）' -ForegroundColor White
    Write-Host '     [2]  正式运行     会真的切号 + 重启 Codex + 发"继续"' -ForegroundColor White
    Write-Host '     [3]  停止         结束所有看护进程' -ForegroundColor White
    Write-Host '     [4]  查看状态     进程 / 接口 / 最近报告' -ForegroundColor White
    Write-Host '     [5]  看日志       最后 40 行' -ForegroundColor White
    Write-Host '     [6]  打开目录     在资源管理器里打开' -ForegroundColor White
    Write-Host '     [0]  退出' -ForegroundColor White
    Write-Host ''
    $ch = Read-Host '  请输入编号并回车'

    switch ($ch) {
        '1' { Start-Autopilot }
        '2' { Start-Autopilot -Live }
        '3' { Stop-Autopilot }
        '4' { Show-Status }
        '5' { Show-Logs }
        '6' { Start-Process explorer.exe $Here; Start-Sleep -Milliseconds 300 }
        '0' { return }
        default { }
    }
}
