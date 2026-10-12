<# 菜单与运行界面。关闭窗口并收回托盘（不会停止看护）。 #>
[CmdletBinding()]
param([switch]$SmokeTest, [switch]$LibraryOnly)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Here = $PSScriptRoot
$HostCommandFile = Join-Path $Here 'state\tray-host-command.json'
$HostResultFile = Join-Path $Here 'state\tray-host-result.json'
$WatcherControlFile = Join-Path $Here 'state\tray-control.json'
$script:ShownRun = $null
$script:Offset = 0L
$script:PendingCommand = $null
$script:PendingAt = $null
$script:View = 'menu'
$script:FooterVisible = $false
$script:FooterText = ''
$script:FooterWidth = 0

function Clear-MonitorFooter {
    if(-not $script:FooterVisible){return}
    try{
        $row=[Console]::CursorTop
        [Console]::SetCursorPosition(0,$row)
        [Console]::Write((' ' * [Math]::Max(0,[Console]::BufferWidth-1)))
        [Console]::SetCursorPosition(0,$row)
    }catch{}
    $script:FooterVisible=$false
    $script:FooterText=''
}

function Format-QuotaFooter {
    param($Snapshot,$Run,[datetime]$Now=(Get-Date))
    $pending=' | 五小时剩余 -- | 周剩余 --（读取中）'
    if(-not $Snapshot -or $Snapshot.pid -ne $Run.pid){return $pending}
    try{
        $at=[datetime]::Parse($Snapshot.at)
        if($at -lt [datetime]::Parse($Run.startedAt)){return $pending}
        $a=$Snapshot.account
        if(-not $a){return ' | 五小时剩余 -- | 周剩余 --（当前账号未知）'}
        $five='--';$week='--'
        if(-not $a.UsageError){
            if($null -ne $a.FiveHour){$five=('{0:0.#}%' -f [double]$a.FiveHour)}
            if($null -ne $a.Weekly){$week=('{0:0.#}%' -f [double]$a.Weekly)}
        }
        $label=' | 五小时剩余 {0} | 周剩余 {1}' -f $five,$week
        if(($Now-$at).TotalSeconds -gt [Math]::Max(15,3*[double]$Snapshot.pollSeconds)){$label+='（数据待更新）'}
        elseif($five -eq '--' -or $week -eq '--'){$label+='（额度未知）'}
        if($Snapshot.PSObject.Properties['waitingReset'] -and $Snapshot.waitingReset){
            $phase=$Snapshot.waitingReset.phase
            if($phase -eq 'waiting'){
                if($Snapshot.PSObject.Properties['resetWaitPolicy'] -and $Snapshot.resetWaitPolicy -eq 'weekly-eligible'){
                    if($Snapshot.weeklyEligibleAccounts -eq 0){$label+=' | 等待周额度恢复'}
                    else{$label+=' | 等五小时恢复 '+$Snapshot.usableAccounts+'/'+$Snapshot.weeklyEligibleAccounts}
                }else{$label+=' | 等待恢复（可用 '+$Snapshot.usableAccounts+'/5）'}
            }
            elseif($phase -in @('running','failed')){$label+=' | 消耗结果核对中'}
        }
        if($Snapshot.PSObject.Properties['desktopHealth'] -and $Snapshot.desktopHealth){
            if($Snapshot.desktopHealth.mode -eq 'fallback'){$label+=' | 列表备用通道'}
            elseif($Snapshot.desktopHealth.mode -in @('degraded','unavailable')){$label+=' | 会话读取受阻'}
        }
        return $label
    }catch{return $pending}
}

function Get-MonitorQuotaText {
    param($Run)
    $now=Get-Date
    # The UI refreshes four times a second; parse this small local snapshot at most once.
    if(-not (Get-Variable QuotaReadAt -Scope Script -ErrorAction SilentlyContinue) -or
        $script:QuotaRunId -ne $Run.id -or ($now-$script:QuotaReadAt).TotalSeconds -ge 1){
        $script:QuotaRunId=$Run.id;$script:QuotaReadAt=$now
        $leaf=if($Run.mode -eq '演习模式'){'quota-status.dry-run.json'}else{'quota-status.json'}
        $script:QuotaSnapshot=Read-JsonQuietly (Join-Path $Here ('state\'+$leaf))
    }
    return (Format-QuotaFooter $script:QuotaSnapshot $Run $now)
}

function Show-MonitorFooter {
    param($Run,[string]$Status)
    # This is display-only. Never append it to events or emit a newline each poll.
    if($SmokeTest -or [Console]::IsOutputRedirected){return}
    try{
        $seconds=[int64][Math]::Max(0,[Math]::Floor(((Get-Date)-[datetime]::Parse($Run.startedAt)).TotalSeconds))
        $minutes=[int64][Math]::Floor($seconds/60)
        $label='  已监视运行 {0}分{1}秒（{2}）' -f $minutes,($seconds%60),$Status
        $label+=Get-MonitorQuotaText $Run
        $width=[Console]::BufferWidth
        if($width -lt 2){return}
        # Leave the last cell unused to prevent wrapping, including Chinese wide glyphs.
        $cells=0;$text=''
        foreach($ch in $label.ToCharArray()){
            $size=if([int]$ch -ge 0x2e80){2}else{1}
            if($cells+$size -ge $width){break}
            $text+=$ch;$cells+=$size
        }
        if($script:FooterVisible -and $script:FooterText -eq $text -and $script:FooterWidth -eq $width){return}
        Clear-MonitorFooter
        $row=[Console]::CursorTop
        [Console]::SetCursorPosition(0,$row)
        $color=[Console]::ForegroundColor
        try{[Console]::ForegroundColor=[ConsoleColor]::Cyan;[Console]::Write($text)}finally{[Console]::ForegroundColor=$color}
        [Console]::SetCursorPosition(0,$row)
        $script:FooterVisible=$true;$script:FooterText=$text;$script:FooterWidth=$width
    }catch{Clear-MonitorFooter}
}

function Read-JsonQuietly {
    param([string]$Path)
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-MonitorRun {
    $run = Read-JsonQuietly (Join-Path $Here 'state\current-run.json')
    if (-not $run) { return $null }
    try {
        $p = Get-Process -Id ([int]$run.pid) -ErrorAction Stop
        if ([Math]::Abs(($p.StartTime - [datetime]::Parse($run.processStartedAt)).TotalSeconds) -ge 2) { return $null }
        return $run
    } catch { return $null }
}

function Send-JsonCommand {
    param([string]$Path, [string]$Action)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $id = [guid]::NewGuid().ToString('N')
    $tmp = "$Path.$id.tmp"
    [IO.File]::WriteAllText($tmp, (@{ id=$id; action=$Action; at=(Get-Date).ToString('o') } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return $id
}

function Show-Menu {
    Clear-MonitorFooter
    if (-not $SmokeTest) { Clear-Host }
    $script:View = 'menu'
    $script:ShownRun = $null
    Write-Host ''
    Write-Host '  ==========================================================' -ForegroundColor Cyan
    Write-Host '     Codex 额度看护  -  主菜单' -ForegroundColor Cyan
    Write-Host '  ==========================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '     [1] 演习模式    只检查，不切号、不发送继续' -ForegroundColor White
    Write-Host '     [2] 正常模式    自动看护、切号和继续任务' -ForegroundColor White
    Write-Host '     [0] 收回托盘' -ForegroundColor White
    Write-Host ''
    Write-Host '  请选择模式（按数字即可）。' -ForegroundColor Yellow
    Write-Host '  运行后关闭窗口，看护仍会在托盘运行。' -ForegroundColor DarkGray
    try { $Host.UI.RawUI.WindowTitle = 'Codex 额度看护 - 请选择模式' } catch { }
}

function Write-EventLine {
    param([string]$Line)
    Clear-MonitorFooter
    $color = 'Gray'
    if ($Line -match '\[(ERROR|FATAL)') { $color='Red' }
    elseif ($Line -match '\[(WARN|ALERT)') { $color='Yellow' }
    elseif ($Line -match '\[OK') { $color='Green' }
    Write-Host "  $Line" -ForegroundColor $color
}

function Read-NewLogLines {
    # 只消费完整 UTF-8 行，写入到一半的行留到下次。
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($stream.Length -lt $script:Offset) { $script:Offset=0L }
        [void]$stream.Seek($script:Offset, 'Begin')
        $count = [int][Math]::Min(1MB, $stream.Length-$script:Offset)
        if ($count -le 0) { return }
        $bytes = New-Object byte[] $count
        $read = $stream.Read($bytes, 0, $count)
        $last = $read - 1
        while ($last -ge 0 -and $bytes[$last] -ne 10) { $last-- }
        if ($last -lt 0) { return }
        $text = [Text.Encoding]::UTF8.GetString($bytes, 0, $last+1).TrimStart([char]0xFEFF)
        $script:Offset += $last+1
        return @($text -split '\r?\n' | Where-Object { $_ -ne '' })
    } finally { $stream.Dispose() }
}

function Show-Run {
    param($Run)
    Clear-MonitorFooter
    if (-not $SmokeTest) { Clear-Host }
    $script:View='running'
    $script:ShownRun=$Run
    Write-Host ''
    Write-Host "  Codex 额度看护 - $($Run.mode)" -ForegroundColor Cyan
    Write-Host ('  启动于 {0}，后台 PID {1}' -f ([datetime]::Parse($Run.startedAt).ToString('MM-dd HH:mm:ss')), $Run.pid) -ForegroundColor DarkGray
    Write-Host '  [P] 暂停/继续   [S] 停止并返回菜单   [Q/ESC] 收回托盘' -ForegroundColor White
    Write-Host '  直接关闭窗口也会继续运行；双击托盘图标可重新查看。' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  ── 本次运行的重要事件（实时日志）──' -ForegroundColor Yellow
    $script:Offset=0L
    $lines=@()
    do {
        $part=@(Read-NewLogLines $Run.eventFile)
        $lines=@($lines+$part | Select-Object -Last 40)
    } while ($part.Count -gt 0)
    foreach ($line in $lines) { Write-EventLine $line }
    if (-not $lines.Count) { Write-Host '  看护已启动，等待重要事件。' -ForegroundColor DarkGray }
}

function Invoke-MonitorKey {
    param([string]$Key)
    Clear-MonitorFooter
    if ($Key -in @('Q','Escape','D0','NumPad0')) { return 'close' }
    $run=Get-MonitorRun
    if ($Key -in @('D1','NumPad1','D2','NumPad2') -and -not $run -and -not $script:PendingCommand) {
        $action=if($Key -in @('D2','NumPad2')){'start-live'}else{'start-dry'}
        $script:PendingCommand=Send-JsonCommand $HostCommandFile $action
        $script:PendingAt=Get-Date
        Write-Host '  正在启动…' -ForegroundColor Yellow
    } elseif ($Key -eq 'S' -and $run -and -not $script:PendingCommand) {
        $script:PendingCommand=Send-JsonCommand $HostCommandFile 'stop'
        $script:PendingAt=Get-Date
        Write-Host '  正在停止看护…' -ForegroundColor Yellow
    } elseif ($Key -eq 'P' -and $run) {
        $s=Read-JsonQuietly (Join-Path $Here 'state\tray-status.json')
        $action=if($s -and $s.pid -eq $run.pid -and $s.paused){'resume'}else{'pause'}
        $null=Send-JsonCommand $WatcherControlFile $action
    } elseif ($Key -eq 'M' -and -not $run) { Show-Menu }
}

function Update-Monitor {
    $run=Get-MonitorRun
    if ($run) {
        if (-not $script:ShownRun -or $script:ShownRun.id -ne $run.id) { Show-Run $run }
        foreach($line in @(Read-NewLogLines $run.eventFile)){ Write-EventLine $line }
        $s=Read-JsonQuietly (Join-Path $Here 'state\tray-status.json')
        $status=if($s -and $s.pid -eq $run.pid -and $s.paused){'已暂停'}else{'运行中'}
        if($status -eq '已暂停'){$p=Read-JsonQuietly (Join-Path $Here 'state\manual-pause.json');if($p -and $p.active){$status='异常暂停，按 P 恢复'}}
        $elapsed=(Get-Date)-[datetime]::Parse($run.startedAt)
        try { $Host.UI.RawUI.WindowTitle='Codex 额度看护 - {0} - {1} - 已运行 {2:00}:{3:00}:{4:00}' -f $run.mode,$status,[int][Math]::Floor($elapsed.TotalHours),$elapsed.Minutes,$elapsed.Seconds } catch { }
        Show-MonitorFooter -Run $run -Status $status
    } elseif ($script:View -eq 'running') {
        Clear-MonitorFooter
        foreach($line in @(Read-NewLogLines $script:ShownRun.eventFile)){ Write-EventLine $line }
        $script:View='ended'
        Write-Host "`n  本次看护已结束。[M] 返回菜单；[1/2] 重新选择模式。" -ForegroundColor Yellow
        try { $Host.UI.RawUI.WindowTitle='Codex 额度看护 - 已结束' } catch { }
    }
    if ($script:PendingCommand) {
        $reply=Read-JsonQuietly $HostResultFile
        if($reply -and $reply.id -eq $script:PendingCommand){
            $script:PendingCommand=$null
            if(-not $reply.success){Clear-MonitorFooter;Write-Host "  操作失败：$($reply.error)" -ForegroundColor Red}
            elseif($reply.action -eq 'stop'){Show-Menu}
        } elseif(((Get-Date)-$script:PendingAt).TotalSeconds -gt 15){
            $script:PendingCommand=$null
            Clear-MonitorFooter
            Write-Host '  托盘未及时回应，请检查 logs/tray.log。' -ForegroundColor Red
        }
    }
}

if ($LibraryOnly) { return }
# Selection mode used to freeze the monitor's output (the user's screenshot said "选择").
try {
    if(-not ('QuotaMonitorConsole' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class QuotaMonitorConsole {
 [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
 [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
 [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint mode);
}
'@
    }
    $consoleHandle=[QuotaMonitorConsole]::GetStdHandle(-10);$consoleMode=[uint32]0
    if([QuotaMonitorConsole]::GetConsoleMode($consoleHandle,[ref]$consoleMode)) {
        [void][QuotaMonitorConsole]::SetConsoleMode($consoleHandle,[uint32](($consoleMode -bor 0x80) -band ([uint32]::MaxValue - 64)))
    }
}catch{}
$owned=$false
$mutexName=if($SmokeTest){'Local\CodexQuotaAutopilotMonitorSmoke-'+$PID}else{'Local\CodexQuotaAutopilotMonitor'}
$mutex=New-Object Threading.Mutex($true,$mutexName,[ref]$owned)
if(-not $owned){$mutex.Dispose();exit 0}
try {
    Show-Menu
    $deadline=(Get-Date).AddSeconds(1)
    do {
        Update-Monitor
        if(-not [Console]::IsInputRedirected -and [Console]::KeyAvailable){
            $key=[Console]::ReadKey($true)
            if((Invoke-MonitorKey ([string]$key.Key)) -eq 'close'){break}
        }
        if($SmokeTest -and (Get-Date) -ge $deadline){break}
        Start-Sleep -Milliseconds 250
    } while($true)
} finally {
    Clear-MonitorFooter
    if($owned){$mutex.ReleaseMutex()}
    $mutex.Dispose()
}
