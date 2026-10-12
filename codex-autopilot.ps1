<#
.SYNOPSIS
    Codex 额度看护脚本 —— 自动切号 + 自动续跑。
.DESCRIPTION
    盯着 Codex 的所有对话和 5 个账号的额度：
      · 额度正常时什么都不做，只写日志
      · 某个对话撞上 "usage limit" → 自动切到周额度最多的账号 → 发"继续"
      · 5 个账号全空 → 持久化等待全部刷新，再逐账号消耗并恢复调度
      · 遇到没预设过的情况 → 保存报告、记录现场，暂停等待人工处理
    生产循环使用 lib/engine-v2.ps1；下方旧 Invoke-Round 保留供历史逻辑回归。
    每做一件事写一行日志，另附一份结构化报告给 AI 读。
.PARAMETER DryRun
    演习模式：照常判断、照常打印"我本来会做什么"，但一行都不真写。默认即演习。
.PARAMETER Live
    真实动作模式。必须显式指定才会动真格。
.PARAMETER Once
    只检查一轮就退出。默认循环监控。
.PARAMETER MaxRounds
    循环上限，0 = 不限。
.EXAMPLE
    .\codex-autopilot.ps1              # 演习，循环
    .\codex-autopilot.ps1 -Once        # 演习，单轮
    .\codex-autopilot.ps1 -Live        # 真实动作，循环
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Live,
    [switch]$Once,
    [int]$MaxRounds = 0,
    [switch]$LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ══════════════════════════════════════════════════════════════════
#  配置
# ══════════════════════════════════════════════════════════════════
$Script:Config = @{
    CswEndpoint      = 'http://127.0.0.1:18080/__codex_switch__/api/invoke'
    CodexHome        = Join-Path $env:USERPROFILE '.codex'
    SessionRoot      = Join-Path $env:USERPROFILE '.codex\sessions'
    StateDir         = Join-Path $PSScriptRoot 'state'
    LogDir           = Join-Path $PSScriptRoot 'logs'
    # ── 轮询节奏 ──
    # 脚本睡觉是纯进程开销，不烧任何模型额度；csw 接口单次只要 3~10ms。
    # 所以高频轮询成本几乎为零，可以贴得很近。
    ResetWaitPolicy = 'weekly-eligible' # Wait for all accounts with weekly quota; exclude weekly-zero.
    WaitForAllAccountsReset = $false # Legacy setting; ResetWaitPolicy takes precedence.
    PollSeconds      = 3        # 每轮完成后等待 3 秒，串行轮询
    DesktopReadyDelaySec = 10   # 切号确认后短暂缓冲，再尝试桌面续跑
    DesktopConfigRetrySec = 10  # 配置明确拒绝时的初始重试间隔
    SwitchVerifyPollSec = 1     # 切号结果先立即核实，未生效时每秒复查
    WarnPercent      = 15.0     # 当前号 5 小时剩余低于这个值 → 加提醒
    QuietConsole     = $true    # 平时不打日志，只在控制台走计时器；有事件才打印
    StatusEverySec   = 60       # 计时器刷新间隔（控制台显示用）
    SessionMaxAgeMin = 720      # 只看 12 小时内动过的会话
    # ── 只看最近这几条对话（用户 2026-09-27 明确指定的规则）──
    #   1. 只看我最近的对话，**最多看 5 个**
    #   2. 判断这 5 个里有没有中断的
    #   3. 只有出现中断，才给它们发"继续"
    #   4. 不要看其他很早之前的
    # 所以这里**按条数**卡死 5 条（多的不看），时间上限只当一道很松的外围保险。
    ResumeScanThreads = 5
    ResumeLookbackMin = 720     # 外围保险：超过 12 小时的一律不看（正常轮不到它生效）
    ResumeMaxThreads  = 5       # 一轮最多续跑几条（= 扫描条数，中断几条就发几条）
    ResumeQuietMin    = 2       # 刚被中断的先等几分钟再续，别跟正在操作的人抢
    ResumeMaxRounds   = 4       # 同一条对话最多自动续几次（防止和模型互相刷"继续"）
    # ── 用什么方式"让对话接着跑" ──
    # desktop 通过桌面自身启动回合，不启动争用会话写入锁的外部 CLI。
    ResumeMode        = 'desktop'
    ExpectedAccounts  = 5
    DesktopCallerThreadId = '01a0e435-3432-7bf3-91a5-572e0194a1a0'
    ResumeMessage     = '继续'
    ResumeTimeoutSec  = 21600    # 单条续跑最多 6 小时，超时会终止并交给 人工处理
    # Codex CLI 的备用工作目录
    HelperWorkDir     = (Split-Path $PSScriptRoot -Parent)
    # "这一轮结束了，但活儿没干完"的自白。
    # 真实案例：对话被中断 → 脚本发"继续" → 模型跑 6 秒回了句
    #   "已检查中断状态：此前修改仍在，功能尚未完成。这次只做了只读检查……"
    # 然后 task_complete 正常收尾。光看标记这是"正常结束"，可用户要的是把活干完。
    # 所以模型自己说没干完的，也算"被中断"，继续催 —— 但有 ResumeMaxRounds 兜底。
    UnfinishedMarkers = @('尚未完成', '还没完成', '未完成', '没有完成', '没做完', '未做完',
                          '尚未做完', '还没做完', '未竟', 'not finished', 'unfinished',
                          'incomplete', 'still not complete')
    StalledMin       = 3        # 多久没动静算停住
    InFlightMin      = 3        # 多久内有动静算正在跑
    SleepGraceMin    = 5        # 故意 sleep 的宽限，超出才算真卡
    TailBytes        = 262144   # 每个会话默认只读尾部 256KB
    # 读不到"回合标记"时往前翻的上限。为什么需要翻：
    # 实测一个 6.8MB 的活跃会话，最后一个回合标记落在离文件末尾 **1652KB** 的地方 ——
    # 只读 256KB 一个标记都看不到，LastMarker 变空、结局被判成"正常结束"，
    # 于是永远不给它发"继续"，同时它还被认为是"没在跑"，切号时不会等它。
    MarkerScanMaxKB  = 65536   # 最多回看 64MB；超长工具输出也不能把本轮标记挤出窗口
    ApiRetries       = 2
    ResumeSettleSec  = 30
    SwitchVerifySec  = 60       # 切号后最多等多久确认 active 真的变了
    ResumeGapSec     = 5
    # ── 5 个号全用完时怎么办（用户 2026-09-27 定的方案）──
    # 额度全空后等所有账号刷新，再调用用户本机的额度定时器，对全部账号各触发一次消耗。
    WaitForResetEnabled    = $true  # 全空时不死等，等窗口刷新后继续（关掉就退回旧的收摊行为）
    WakeBufferSec          = 60     # 比算出来的刷新时刻**晚**这么多秒再看（用户要求 +1 分钟）
    ConsumeGapSec          = 2      # 逐个触发消耗之间的间隔（和用户那个定时器保持一致）
    QuotaSchedulerScript   = Join-Path $PSScriptRoot 'scheduler.ps1'
    QuotaSchedulerTimeoutSec = 900
    # 撞墙信号。分两级：
    #   确定级 —— Codex 的明确错误码，5 小时和周额度撞墙都用这个
    #   疑似级 —— 措辞类信号，单独不足以定论，要配合账号真实额度状态证实
    ConfirmedMarkers = @('"codex_error_info":"usage_limit_exceeded"')
    SuspectedMarkers = @('hit your usage limit', 'usage limit reached',
                         'usage_limit_reached', 'purchase more credits')
}

# ══════════════════════════════════════════════════════════════════
#  外部规则文件（可选）：rules.json
#  为什么要有它：脚本的**判断逻辑是通用的**（不针对任何一条对话），但里面有几处
#  是"经验值"—— 最典型的是 UnfinishedMarkers 那张关键词表（模型换个说法就认不出）。
#  把这类东西放在 rules.json 里，换个场景改文件即可，**不用动脚本**。
#  规则：文件里写哪个键就覆盖哪个键；没写的用脚本默认值；读不了就用默认值，绝不报错退出。
#  另外，以下划线开头的键（_说明 之类）只当注释，不覆盖配置。
# ══════════════════════════════════════════════════════════════════
function Import-Rules {
    param([string]$Path, $Config)
    $applied = @()
    if (-not (Test-Path $Path)) { return $applied }
    try {
        $rules = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $rules.PSObject.Properties) {
            if ($p.Name -like '_*') { continue }          # 下划线开头 = 注释
            if (-not $Config.ContainsKey($p.Name)) {
                # 不认识的键也装上（只是没人读），但要让人看得见，免得以为写错了还在生效
                $applied += "$($p.Name)(未知键)"
                $Config[$p.Name] = $p.Value
                continue
            }
            $positive = @('PollSeconds','StatusEverySec','ResumeScanThreads','ResumeMaxThreads','ResumeMaxRounds',
                'SessionMaxAgeMin','ResumeLookbackMin','StalledMin','InFlightMin','TailBytes','MarkerScanMaxKB',
                'WakeBufferSec','SwitchVerifySec','QuotaSchedulerTimeoutSec','ResumeTimeoutSec',
                'DesktopReadyDelaySec','DesktopConfigRetrySec','SwitchVerifyPollSec')
            $nonnegative = @('ResumeQuietMin','ResumeSettleSec','ResumeGapSec','ConsumeGapSec','SleepGraceMin',
                'SyncWindowToleranceMin','ApiRetries','WarnPercent')
            if ($p.Name -in ($positive + $nonnegative)) {
                $number = 0.0
                $min = if ($p.Name -in $positive) { 1 } else { 0 }
                if (-not [double]::TryParse([string]$p.Value, [ref]$number) -or
                    [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt $min -or $number -gt 2147483) {
                    $applied += "$($p.Name)(数值无效，使用默认值)"; continue
                }
            }
            if ($p.Name -in @('WaitForResetEnabled','WaitForAllAccountsReset','QuietConsole') -and $p.Value -isnot [bool]) {
                $applied += "$($p.Name)(应为 true/false，使用默认值)"; continue
            }
            if ($p.Name -eq 'ResetWaitPolicy' -and $p.Value -notin @('weekly-eligible','all','any')) {
                $applied += 'ResetWaitPolicy(无效，使用默认值)'; continue
            }
            if ($p.Name -eq 'ResumeMode' -and $p.Value -notin @('unattended','desktop')) {
                $applied += 'ResumeMode(仅支持 unattended，已忽略旧配置)'; continue
            }
            if ($p.Name -in @('UnfinishedMarkers','ConfirmedMarkers','SuspectedMarkers') -and
                ($p.Value -isnot [array] -or @($p.Value | Where-Object { $_ -isnot [string] -or -not $_.Trim() }).Count -gt 0)) {
                $applied += "$($p.Name)(应为非空字符串数组，使用默认值)"; continue
            }
            $Config[$p.Name] = $p.Value
            $applied += $p.Name
        }
    } catch {
        # 规则文件坏了绝不能把看护搞崩：退回默认值继续跑
        return @("(rules.json 解析失败，已忽略：$($_.Exception.Message))")
    }
    return $applied
}

$Script:RulesFile    = Join-Path $PSScriptRoot 'rules.json'
$Script:RulesApplied = @(Import-Rules -Path $Script:RulesFile -Config $Script:Config)

$Script:LogFile     = $null
$Script:EventFile   = $null
$Script:StateFile   = Join-Path $Script:Config.StateDir 'handled.json'
$Script:ReportFile  = Join-Path $Script:Config.StateDir 'last-report.json'
$Script:SwitchCount = 0
# 已经为哪个号报过"快到墙了"。同一个号只报一次，别每 10 秒刷一遍。
# 必须在顶层初始化：脚本开了 StrictMode，读没赋过值的 $Script: 变量会直接抛。
$Script:WarnedDryAccount = $null
# 每个会话文件"上次需要读多大尾部才看得见回合标记"，下一轮直接按那个尺寸读，别重复试。
$Script:TailHint = @{}
$Script:FileActivityCache = @{}
$Script:RunLock = $null
$Script:LastTrayControlId = $null
$Script:PauseFromTray = $false

# ── codex.exe 在哪 ──
# `Get-Command codex` 可能解析到 npm 的 codex.ps1 垫片，进程调用需要 exe。优先 PATH 上的 codex.exe，
# 其次去 LOCALAPPDATA\OpenAI\Codex\bin\<hash>\codex.exe 里挑最新的那个。
$Script:CodexExe = $null
try {
    $c = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($c) { $Script:CodexExe = $c.Source }
    if (-not $Script:CodexExe) {
        $cand = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin') -Directory -ErrorAction SilentlyContinue |
                  ForEach-Object { Join-Path $_.FullName 'codex.exe' } |
                  Where-Object { Test-Path $_ } |
                  Sort-Object { (Get-Item $_).LastWriteTime } -Descending)
        if ($cand.Count -gt 0) { $Script:CodexExe = $cand[0] }
    }
} catch { $Script:CodexExe = $null }
# 上一轮"最近 N 条对话判成什么"的结论。只在结论变化时打一行，避免刷屏。
# 必须在**顶层**就初始化：脚本开了 StrictMode，读一个没赋过值的 $Script: 变量会直接抛
# "The variable ... cannot be retrieved because it has not been set"。
$Script:LastScanNote = $null

# ══════════════════════════════════════════════════════════════════
#  基础设施
# ══════════════════════════════════════════════════════════════════
function Initialize-Paths {
    foreach ($d in @($Script:Config.StateDir, $Script:Config.LogDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $Script:LogFile = Join-Path $Script:Config.LogDir $(if ($Live) { 'watch.log' } else { 'watch-dry-run.log' })
    if (-not $Live) { $Script:ReportFile = Join-Path $Script:Config.StateDir 'last-report.dry-run.json' }
    $Script:StartedAt = Get-Date
    # 每次选择模式开始新日志；重新打开窗口只读取该次运行的重要事件。
    [IO.File]::WriteAllText($Script:LogFile, '', (New-Object Text.UTF8Encoding($true)))
    $runId = [guid]::NewGuid().ToString('N')
    $Script:EventFile = Join-Path $Script:Config.LogDir ("events-$runId.log")
    [IO.File]::WriteAllText($Script:EventFile, '', (New-Object Text.UTF8Encoding($true)))
    Write-JsonAtomic -Path (Join-Path $Script:Config.StateDir 'current-run.json') -Value @{
        id = $runId; pid = $PID; startedAt = $Script:StartedAt.ToString('o')
        processStartedAt = (Get-Process -Id $PID).StartTime.ToString('o')
        mode = $(if ($Live) { '正常模式' } else { '演习模式' }); eventFile = $Script:EventFile
    }
    Write-File ("续跑方式 {0}；codex.exe = {1}" -f $Script:Config.ResumeMode, $(if ($Script:CodexExe) { $Script:CodexExe } else { '(没找到，需要修复后才能续跑)' }))
    $Script:StatusActive = $false
    $mode = if ($Live) { '真实动作' } else { '演习' }
    Write-Event "════════ 启动 ($(Get-Date -Format 'MM-dd HH:mm:ss')) 模式=$mode ════════"
    # 用了外部规则就明说一声 —— 免得以后看到行为不一样、却想不起来改过 rules.json
    if ($Script:RulesApplied.Count -gt 0) {
        Write-File "已加载 rules.json，覆盖：$($Script:RulesApplied -join '，')"
    }
}

function Get-Elapsed {
    <# 已经跑了多久，格式化成 5分30秒 #>
    $s = [int]((Get-Date) - $Script:StartedAt).TotalSeconds
    $m = [math]::Floor($s / 60)
    $r = $s % 60
    if ($m -gt 0) { "${m}分${r}秒" } else { "${r}秒" }
}

function Write-File {
    <# 只写日志文件，不动控制台 —— 用于每次轮询的常规记录 #>
    param([string]$Message, [string]$Level = 'INFO')
    if (-not $Script:LogFile) { return }
    $line = '{0} [+{1,-8}] [{2,-6}] {3}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), (Get-Elapsed), $Level, $Message
    try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 } catch { }
}

function Write-Event {
    <# 事件：控制台 + 日志文件。只有真正值得看的事情才用这个 #>
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [+{1,-8}] [{2,-6}] {3}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), (Get-Elapsed), $Level, $Message
    Show-ConsoleLine -Line $line -Level $Level
    if ($Script:LogFile) {
        try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
    if ($Script:EventFile) {
        try { Add-Content -LiteralPath $Script:EventFile -Value $line -Encoding UTF8 } catch { }
    }
}

function Enable-AnsiConsole {
    <# 打开 ANSI 转义序列支持；失败就返回 $false，调用方改用不刷屏的策略 #>
    try {
        if (-not ('Win32.AnsiMode' -as [type])) {
            Add-Type -Namespace Win32 -Name AnsiMode -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
        }
        $h = [Win32.AnsiMode]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
        $mode = 0
        if (-not [Win32.AnsiMode]::GetConsoleMode($h, [ref]$mode)) { return $false }
        # 0x0004 = ENABLE_VIRTUAL_TERMINAL_PROCESSING
        if (-not [Win32.AnsiMode]::SetConsoleMode($h, $mode -bor 0x0004)) { return $false }
        return $true
    } catch { return $false }
}

function Disable-QuickEdit {
    <#
      关掉控制台的「快速编辑模式」。
      为什么：快速编辑开着时，**在窗口里点一下鼠标就会进入"选择"状态**，
      这期间 Windows 会**阻塞**这个进程的所有输出 —— 表现就是脚本"卡住不动、
      数字不更新、撞墙了也不切号"，直到你回到窗口里按回车/ESC 取消选择，
      它才"突然一下反应过来"把积压的活干完。
      （用户原话："鼠标焦点不在监控窗口上它就可能卡住…点回去按一下回车才会突然反应过来"。）
      0x0040 = ENABLE_QUICK_EDIT_MODE；改它必须先带上 0x0080 = ENABLE_EXTENDED_FLAGS。
    #>
    try {
        if (-not ('Win32.AnsiMode' -as [type])) { return 'no-type' }
        $h = [Win32.AnsiMode]::GetStdHandle(-10)   # STD_INPUT_HANDLE
        $mode = 0
        # 拿不到控制台句柄 ≠ 失败：输出被重定向/管道（比如被别的脚本调用）时本来就没有窗口，
        # 这种情况不用管。只有"有窗口却设不进去"才值得报警。
        if (-not [Win32.AnsiMode]::GetConsoleMode($h, [ref]$mode)) { return 'no-console' }
        $keep = [uint32]::MaxValue - 0x0040        # 除 bit6 全保留
        $new  = [uint32](($mode -bor 0x0080) -band $keep)
        if (-not [Win32.AnsiMode]::SetConsoleMode($h, $new)) { return 'failed' }
        return 'ok'
    } catch { return 'failed' }
}

function Initialize-Keyboard {
    <# 能不能非阻塞读键盘；不能就退化（不支持 ESC 控制，只靠 Ctrl+C） #>
    $Script:KeyOk = $false
    try {
        if (-not [Console]::IsInputRedirected) {
            $null = [Console]::KeyAvailable
            $Script:KeyOk = $true
        }
    } catch { $Script:KeyOk = $false }
    return $Script:KeyOk
}

function Get-TrayControl {
    $path = Join-Path $Script:Config.StateDir 'tray-control.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $control = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $id = [string]$control.id
        if (-not $id -or $id -eq $Script:LastTrayControlId) { return $null }
        $Script:LastTrayControlId = $id
        if ($control.action -in @('pause','resume')) { return [string]$control.action }
    } catch { }
    return $null
}

function Initialize-TrayControl {
    # 新进程忽略上一次运行遗留的控制命令。
    $path = Join-Path $Script:Config.StateDir 'tray-control.json'
    if (Test-Path -LiteralPath $path) {
        try { $Script:LastTrayControlId = [string](Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).id } catch { }
    }
    Set-TrayPauseStatus -Paused $false
}

function Set-TrayPauseStatus {
    param([bool]$Paused)
    try {
        @{ pid = $PID; paused = $Paused; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress |
            Set-Content -LiteralPath (Join-Path $Script:Config.StateDir 'tray-status.json') -Encoding UTF8
    } catch { }
}

function Test-EscPressed {
    <# 非阻塞地看有没有按 ESC；按了就吃掉这个键并返回 $true #>
    $control = Get-TrayControl
    if ($control -eq 'pause') { $Script:PauseFromTray = $true; return $true }
    if (-not $Script:KeyOk) { return $false }
    try {
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq [ConsoleKey]::Escape) { $Script:PauseFromTray = $false; return $true }
        }
    } catch { $Script:KeyOk = $false }
    return $false
}

function Invoke-Pause {
    <#
      暂停。用户要求：按一次 ESC 暂停，再按一次 ESC 直接退出（不确认），
      按其他任意键则继续看护。
    #>
    $Script:Paused = $true
    # 用 Write-Event 而不是 Write-File：万一终端不支持原地刷新，
    # 状态行是画不出来的 —— 那时用户只会看到"卡住不动"，根本不知道是暂停了。
    Write-Event '⏸ 已暂停（再按一次 ESC 退出，按其他任意键继续）' 'WARN'
    Set-TrayPauseStatus -Paused $true
    Show-StatusLine -Text ("⏸ 已暂停 · 再按 ESC 退出，按其他键继续 · 已监控 {0}" -f (Get-Elapsed))
    while ($true) {
        Start-Sleep -Milliseconds 200
        if ((Get-TrayControl) -eq 'resume') {
            Clear-StatusLine
            $Script:Paused = $false
            $Script:PauseFromTray = $false
            Set-TrayPauseStatus -Paused $false
            Write-Event '已从托盘继续看护' 'OK'
            return 'resume'
        }
        if (-not $Script:KeyOk) {
            if ($Script:PauseFromTray) { continue }
            break
        }
        try {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                Clear-StatusLine
                $Script:Paused = $false
                Set-TrayPauseStatus -Paused $false
                if ($k.Key -eq [ConsoleKey]::Escape) {
                    Write-Event '再按一次 ESC —— 退出看护' 'ALERT'
                    return 'exit'
                }
                Write-Event '已继续看护' 'OK'
                return 'resume'
            }
        } catch { $Script:KeyOk = $false; if (-not $Script:PauseFromTray) { break } }
    }
    $Script:Paused = $false
    Set-TrayPauseStatus -Paused $false
    return 'resume'
}

function Invoke-UserExit {
    <# 用户按 ESC 主动退出：干净收场，不叫 人工处理，也不写告警报告 #>
    Clear-StatusLine
    Write-Host ''
    Write-Event ("用户主动退出（已监控 {0}）" -f (Get-Elapsed)) 'ALERT'
    try {
        @{
            exitCode  = 0
            reason    = '用户按 ESC 退出'
            at        = (Get-Date).ToString('o')
            elapsed   = (Get-Elapsed)
            switches  = $Script:SwitchCount
        } | ConvertTo-Json -Depth 4 | Set-Content -Path $Script:ReportFile -Encoding UTF8
    } catch { }
}

function Show-ConsoleLine {
    <# 把计时器那行清掉，打印一行正式内容（事件行永久保留） #>
    param([string]$Line, [string]$Level = 'INFO')
    if ($Script:StatusActive) { Clear-StatusLine }
    $color = switch ($Level) {
        'ALERT'  { 'Yellow' }
        'ERROR'  { 'Red' }
        'FATAL'  { 'Red' }
        'OK'     { 'Green' }
        'WARN'   { 'DarkYellow' }
        default  { 'Gray' }
    }
    Write-Host $Line -ForegroundColor $color
}

function Show-StatusLine {
    <#
      原地覆盖的那一行状态。只有这一行会被反复改写，不产生新行。
      用 ANSI 转义序列（\r 回车 + \e[K 清到行尾）——比 SetCursorPosition 可靠。
    #>
    param([string]$Text)
    if (-not $Script:Config.QuietConsole) { return }
    if (-not $Script:AnsiOk) { return }          # 不支持 ANSI 就干脆不显示，绝不留行

    $w = 100
    try { $w = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 2) } catch { }
    $t = if ($Text.Length -gt $w) { $Text.Substring(0, $w) } else { $Text }

    if ($Script:StatusActive) {
        # 光标已经停在这一行行首：回车回到行首，清掉行尾旧内容，重写
        Write-Host ("`r$t" + [char]27 + '[K') -ForegroundColor DarkCyan -NoNewline
    } else {
        # 第一次：占一行（不换行），之后都在这一行里改
        Write-Host ("$t" + [char]27 + '[K') -ForegroundColor DarkCyan -NoNewline
        $Script:StatusActive = $true
    }
}

function Clear-StatusLine {
    <# 清掉状态行并换行，给事件行腾位置 #>
    if (-not $Script:StatusActive) { return }
    if ($Script:AnsiOk) {
        Write-Host ("`r" + [char]27 + '[K') -NoNewline
    }
    $Script:StatusActive = $false
}

function Write-Log {
    <# 兼容旧调用：默认只写文件，除非是值得上控制台的级别 #>
    param([string]$Message, [string]$Level = 'INFO')
    if ($Level -in @('ALERT', 'ERROR', 'FATAL', 'OK', 'WARN')) {
        Write-Event -Message $Message -Level $Level
    } else {
        Write-File -Message $Message -Level $Level
    }
}

function Read-State {
    $s = $null
    if (Test-Path $Script:StateFile) {
        try { $s = Get-Content $Script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch {
            if (Test-Path "$Script:StateFile.bak") {
                $s = Get-Content "$Script:StateFile.bak" -Raw -Encoding UTF8 | ConvertFrom-Json
                Write-Event '状态文件损坏，已读取上次完整备份' 'WARN'
            } else { throw '状态文件损坏且没有备份；请检查 handled.json，避免重复切号和续跑' }
        }
    }
    if ($null -eq $s) { $s = [pscustomobject]@{} }
    # 保证 handled 一定存在：后面要往它上面 Add-Member，缺了会抛
    if ($null -eq $s.PSObject.Properties['handled'] -or $null -eq $s.handled) {
        $s | Add-Member -NotePropertyName handled -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($null -eq $s.PSObject.Properties['pendingResumes'] -or $null -eq $s.pendingResumes) {
        $s | Add-Member -NotePropertyName pendingResumes -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    return $s
}

function Save-State {
    param($State)
    if ($Live) { Write-JsonAtomic -Path $Script:StateFile -Value $State -Backup }
}

function Write-JsonAtomic {
    param([string]$Path, $Value, [switch]$Backup)
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($true)))
        if (Test-Path -LiteralPath $Path) {
            # Windows PowerShell converts a null string argument to an empty path.
            # Keep one previous file for both reports and state.
            $bak = "$Path.bak"
            [IO.File]::Replace($tmp, $Path, $bak)
        } else { [IO.File]::Move($tmp, $Path) }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

function Get-HandledKeys {
    param($State)
    if ($null -eq $State -or $null -eq $State.handled) { return @() }
    # ⚠️ 不能写 $State.handled.PSObject.Properties.Name：
    #    handled 是空对象时 .Properties 返回 $null，再取 .Name 就抛
    #    "The property 'Name' cannot be found on this object" —— 表现就是
    #    **第一次运行（state 里还没有任何"已处理"记录）时脚本一启动就 FATAL**。
    try {
        return @($State.handled.PSObject.Properties | ForEach-Object { $_.Name })
    } catch { return @() }
}

function Update-PendingResumes {
    <# Reconcile headless jobs before making another switch or sending another prompt. #>
    param($State)
    $pending = Get-StateFlag -State $State -Name 'pendingResumes'
    if ($null -eq $pending) {
        $pending = [pscustomobject]@{}
        Set-StateFlag -State $State -Name 'pendingResumes' -Value $pending
    }
    $changed = $false
    $failure = $null
    foreach ($entry in @($pending.PSObject.Properties)) {
        $job = $entry.Value
        $result = $null
        if (Test-Path -LiteralPath $job.ResultFile) {
            try { $result = Get-Content -LiteralPath $job.ResultFile -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { $failure = "续跑结果文件读不出来：$($job.ResultFile) — $($_.Exception.Message)" }
        } else {
            $proc = Get-Process -Id ([int]$job.Pid) -ErrorAction SilentlyContinue
            $sameProcess = $false
            if ($proc) {
                try { $sameProcess = ([Math]::Abs(($proc.StartTime - [datetime]::Parse($job.ProcessStartedAt)).TotalSeconds) -lt 5) }
                catch { }
            }
            if (-not $sameProcess) { $failure = "续跑进程 PID $($job.Pid) 已结束，但没有写出结果文件" }
        }
        if ($result) {
            if ($result.jobId -ne $job.JobId) {
                $failure = "续跑结果的 jobId 不匹配：$($job.JobId)"
            } elseif ([int]$result.exitCode -eq 0) {
                foreach ($fp in @($job.ResumeFp, $job.LimitFp)) {
                    $State.handled | Add-Member -NotePropertyName $fp -NotePropertyValue ((Get-Date).ToString('o')) -Force
                }
                Write-Event "续跑已确认成功：$($job.ThreadId.Substring(0,8))（PID $($job.Pid)）" 'OK'
            } else {
                $failure = "续跑进程退出码 $($result.exitCode)：$($job.ThreadId)"
            }
        }
        if ($result -or $failure) {
            [void]$pending.PSObject.Properties.Remove($entry.Name)
            $changed = $true
            if ($failure) {
                $tail = if (Test-Path -LiteralPath $job.ErrorFile) { Read-FileTail -Path $job.ErrorFile -Bytes 4096 } else { '' }
                $failure = [pscustomobject]@{ reason = [string]$failure; thread = $job.ThreadId; stderr = $tail }
                break
            }
        }
    }
    if ($changed -and $Live) { Save-State -State $State }
    return [pscustomobject]@{
        PendingCount = @($pending.PSObject.Properties).Count
        Threads = @($pending.PSObject.Properties | ForEach-Object { $_.Value.ThreadId })
        Failure = $failure
    }
}

function Write-Report {
    param([int]$Code, [string]$Reason, $Details)
    $report = [ordered]@{
        reportId = [guid]::NewGuid().ToString('N')
        exitCode = $Code
        reason   = $Reason
        at       = (Get-Date).ToString('o')
        mode     = $(if ($Live) { 'live' } else { 'dry-run' })
        switches = $Script:SwitchCount
        details  = $Details
    }
    Write-JsonAtomic -Path $Script:ReportFile -Value $report
    return $report
}

function Repair-Ps1Encoding {
    <#
      自愈：确保 .ps1 带 UTF-8 BOM。
      为什么需要：这些脚本含中文；一旦被保存成"无 BOM 的 UTF-8"，
      Windows PowerShell 会按 ANSI 解码，中文字符串撑坏引号 → "无法解析"。
    #>
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $b = [System.IO.File]::ReadAllBytes($Path)
        $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs) | Out-Null
        if ($hasBom -and (-not $errs -or $errs.Count -eq 0)) { return $true }

        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($true)))
        $errs2 = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs2) | Out-Null
        $ok = (-not $errs2 -or $errs2.Count -eq 0)
        $nm = [System.IO.Path]::GetFileName($Path)
        if ($ok) { Write-Event "已自动修复 $nm 的编码（补了 UTF-8 BOM）" 'OK' }
        else { Write-Event "$nm 语法仍有问题，自动修不了" 'ERROR' }
        return $ok
    } catch {
        Write-Event "修复 $Path 编码时出错：$($_.Exception.Message)" 'ERROR'
        return $false
    }
}


# ══════════════════════════════════════════════════════════════════
#  快速读取文件尾部（避开 Get-Content -Tail 的整文件读入）
# ══════════════════════════════════════════════════════════════════
function Read-FileTailForMarkers {
    <#
      读会话尾部，**一直往前翻到能看见"回合标记"为止**。
      ⚠️ 为什么不能只读固定 256KB（真踩过，用户当场反馈）：
         一个 6.8MB 的活跃会话，最后一个回合标记落在离文件末尾 **1652KB** 的地方。
         只读 256KB → 一个标记都看不到 → LastMarker 为空 → 结局被判成"正常结束"
         → **永远不给它发"继续"**；同时 TaskOpen 也被判成 false，
         它还被当成"没在跑"，切号时不会因为它而在跑就等待，重启一下就把对话切断了。
         用户的原话就是："重启之后它没有正常继续，而只是重启了，换了号没有继续"。
      做法：从 TailBytes 起步，看不到标记就把窗口翻 4 倍，最多到 MarkerScanMaxKB。
      每个文件记住上次够用的尺寸（$Script:TailHint），下一轮一次就读到位。
    #>
    param([System.IO.FileInfo]$File)
    $start = [int]$Script:Config.TailBytes
    if ($Script:TailHint.ContainsKey($File.FullName)) {
        $start = [Math]::Max($start, [int]$Script:TailHint[$File.FullName])
    }
    $max = [Math]::Max($start, [int]$Script:Config.MarkerScanMaxKB * 1KB)
    $size = $start
    while ($true) {
        $text = Read-FileTail -Path $File.FullName -Bytes $size
        if ([string]::IsNullOrEmpty($text)) { return '' }
        if ($text -match '"timestamp":"[^"]+".{0,240}?"type":"(task_started|task_complete|task_completed|turn_aborted)"') {
            $Script:TailHint[$File.FullName] = $size
            return $text
        }
        if ($size -ge $max) { return $text }      # 翻到头了还是没有，交给调用方去告警
        $size = [Math]::Min($max, $size * 4)
    }
}

function Read-FileTail {
    param([string]$Path, [int]$Bytes = 262144)
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        if ($len -le 0) { return '' }
        $take = [Math]::Min([long]$Bytes, $len)
        $fs.Seek($len - $take, [System.IO.SeekOrigin]::Begin) | Out-Null
        $buf = New-Object byte[] $take
        $read = 0
        while ($read -lt $take) {
            $n = $fs.Read($buf, $read, [int]($take - $read))
            if ($n -le 0) { break }
            $read += $n
        }
        if ($take -lt $len) {
            for ($i = 0; $i -lt 3; $i++) {
                if (($buf[$i] -band 0xC0) -ne 0x80) { break }
                $buf[$i] = 0x20
            }
        }
        return [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } catch {
        Write-Log "读会话文件失败：$Path — $($_.Exception.Message)" 'WARN'
        return ''
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

# ══════════════════════════════════════════════════════════════════
#  csw 接口
# ══════════════════════════════════════════════════════════════════
function Get-StateFlag {
    <#
      安全地读 state 上的一个自定义字段。
      ⚠️ 不能用 $State.名字：脚本开了 StrictMode，字段不存在时读属性会直接抛
         "The property ... cannot be found on this object"（踩过）。
    #>
    param($State, [string]$Name)
    if ($null -eq $State) { return $null }
    $p = $State.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Set-StateFlag {
    param($State, [string]$Name, $Value)
    $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Clear-StateFlag {
    param($State, [string]$Name)
    $p = $State.PSObject.Properties[$Name]
    if ($null -ne $p) { [void]$State.PSObject.Properties.Remove($Name) }
}

function ConvertFrom-ResetEpoch {
    <# epoch 秒 → 本地 DateTime；给不出来就 $null #>
    param($Epoch)
    if ($null -eq $Epoch) { return $null }
    try {
        $n = [int64]$Epoch
        if ($n -le 0) { return $null }
        return [DateTimeOffset]::FromUnixTimeSeconds($n).LocalDateTime
    } catch { return $null }
}

function Get-WindowSpreadMin {
    <#
      这 5 个号的 5 小时窗口差了多少分钟。
      用户已经有一个每日定时器在批量消耗，所以窗口平时是齐的（实测只差 6 秒）；
      差得明显时（默认 >10 分钟）才值得再同步一次。
    #>
    param($Accounts)
    $times = @()
    foreach ($a in @($Accounts)) {
        $t = ConvertFrom-ResetEpoch $a.FiveHourReset
        if ($t) { $times += $t }
    }
    if ($times.Count -lt 2) { return 0 }
    $max = ($times | Measure-Object -Maximum).Maximum
    $min = ($times | Measure-Object -Minimum).Minimum
    return [math]::Round(($max - $min).TotalMinutes, 1)
}

function Get-WaitPlan {
    <#
      所有账号额度用完时，按相应窗口算出最晚刷新时间，再加缓冲。
      5 小时全空就看 FiveHourReset；周额度也全部归零就看 WeeklyReset。
    #>
    param($Accounts, [ValidateSet('five-hour','weekly','all')][string]$QuotaType = 'all')
    $targets = @($Accounts)
    $times = @(); $unknown = @()
    foreach ($a in $targets) {
        $needed = @()
        if ($QuotaType -in @('five-hour','all') -and $a.FiveHour -le 0) { $needed += $a.FiveHourReset }
        if ($QuotaType -in @('weekly','all') -and $a.Weekly -le 0) { $needed += $a.WeeklyReset }
        foreach ($epoch in $needed) {
            $t = ConvertFrom-ResetEpoch $epoch
            if ($t) { $times += $t } else { $unknown += $a.Email }
        }
    }
    $now = Get-Date
    $latest = if ($times.Count -gt 0) { ($times | Measure-Object -Maximum).Maximum } else { $null }
    # 任一账号读不到刷新时刻时，不能假定其他账号的最晚时间就是全部最晚；10 分钟后重读。
    $wakeAt = if ($unknown.Count -eq 0 -and $latest) { $latest.AddSeconds($Script:Config.WakeBufferSec) }
              else { $now.AddMinutes(10) }
    if ($wakeAt -le $now) { $wakeAt = $now.AddSeconds($Script:Config.WakeBufferSec) }
    return [pscustomobject]@{
        QuotaType = $QuotaType
        WakeAt  = $wakeAt
        Latest  = $latest
        Targets = $targets
        Unknown = $unknown
        WaitSec = [int][Math]::Max(1, ($wakeAt - $now).TotalSeconds)
    }
}

function Invoke-SyncQuotaWindows {
    <#
      让 5 个号的 5 小时窗口重新同时起跑：挨个调一次 consume_account_quota。
      接口是从用户自己那个 CodexSwitchQuotaScheduler_v1.2.ps1 里核对来的：
        POST /__codex_switch__/api/invoke
        {"command":"consume_account_quota","args":{"id":"<账号id>"}}
      只在"窗口明显错开"时才调（调用点负责判断），因为每调一次都会真消耗一点额度。
    #>
    param($Accounts)
    $ok = 0; $failed = @()
    foreach ($a in @($Accounts)) {
        if (-not $Live) {
            Write-Event "[演习] 本来会对 $($a.Email) 调一次 consume_account_quota（触发 5 小时窗口计时）" 'DRYRUN'
            $ok++
            continue
        }
        try {
            $null = Invoke-Csw -Command 'consume_account_quota' -Arguments @{ id = $a.Id }
            $ok++
            Write-File "已触发额度窗口计时：$($a.Email)"
        } catch {
            $failed += $a.Email
            Write-Event "触发额度窗口失败（跳过它）：$($a.Email) — $($_.Exception.Message)" 'WARN'
        }
        if ($Script:Config.ConsumeGapSec -gt 0) { Start-Sleep -Seconds $Script:Config.ConsumeGapSec }
    }
    return [pscustomobject]@{ Ok = $ok; Failed = $failed }
}

function Invoke-QuotaSchedulerOnce {
    <#
      用户桌面“开始额度定时”快捷方式实际打开的是设置界面；它背后的脚本提供 -RunOnce，
      会 list_accounts 后对全部账号逐个调用 consume_account_quota。这里直接使用这个无界面入口。
    #>
    param($Accounts)
    if (-not $Live) {
        Write-Event "[演习] 本来会调用本机额度定时器，对全部 $(@($Accounts).Count) 个账号各消耗一次" 'DRYRUN'
        return [pscustomobject]@{ Success = $true; ExitCode = 0; Total = @($Accounts).Count; Error = $null }
    }
    $scheduler = [string]$Script:Config.QuotaSchedulerScript
    if (-not $scheduler -or -not (Test-Path -LiteralPath $scheduler -PathType Leaf)) {
        return [pscustomobject]@{ Success = $false; ExitCode = $null; Total = @($Accounts).Count; Error = "找不到额度定时器脚本：$scheduler" }
    }
    try {
        . (Join-Path $PSScriptRoot 'lib\process.ps1')
        if (-not (Test-Path -LiteralPath $Script:Config.LogDir)) { New-Item -ItemType Directory -Path $Script:Config.LogDir -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $stdout = Join-Path $Script:Config.LogDir "quota-scheduler-$stamp.log"
        $stderr = "$stdout.err"
        $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $run = Invoke-ManagedProcess -FilePath $shell `
            -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scheduler,'-RunOnce') `
            -WorkDir (Split-Path $scheduler -Parent) -Stdout $stdout -Stderr $stderr `
            -TimeoutSec ([int]$Script:Config.QuotaSchedulerTimeoutSec)
        if ($run.TimedOut) {
            return [pscustomobject]@{ Success = $false; ExitCode = $null; Total = @($Accounts).Count; Error = "额度定时器超过 $($Script:Config.QuotaSchedulerTimeoutSec) 秒未结束" }
        }
        if ($run.ExitCode -ne 0) {
            $tail = (Get-Content -LiteralPath $stderr -Tail 15 -Encoding UTF8 -ErrorAction SilentlyContinue) -join ' '
            return [pscustomobject]@{ Success = $false; ExitCode = $run.ExitCode; Total = @($Accounts).Count; Error = "额度定时器退出码 $($run.ExitCode)：$tail" }
        }
        return [pscustomobject]@{ Success = $true; ExitCode = 0; Total = @($Accounts).Count; Error = $null }
    } catch {
        return [pscustomobject]@{ Success = $false; ExitCode = $null; Total = @($Accounts).Count; Error = $_.Exception.Message }
    }
}

function Format-WaitSpan {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $h = [int][Math]::Floor($Seconds / 3600)
    $m = [int][Math]::Floor(($Seconds % 3600) / 60)
    if ($h -gt 0) { return "$h 小时 $m 分" }
    if ($m -gt 0) { return "$m 分" }
    return "$([int]$Seconds) 秒"
}

function Invoke-Csw {
    param([string]$Command, [hashtable]$Arguments = @{})
    $payload = @{ command = $Command; args = $Arguments } | ConvertTo-Json -Compress -Depth 6
    $lastErr = $null
    $tries = if ($Command -in @('list_accounts','get_app_info')) { $Script:Config.ApiRetries + 1 } else { 1 }
    for ($i = 1; $i -le $tries; $i++) {
        try {
            $r = Invoke-RestMethod -Uri $Script:Config.CswEndpoint -Method POST `
                    -Body $payload -ContentType 'application/json' -TimeoutSec 30
            if (-not $r.ok) { throw "csw 返回 not-ok：$($r.error)" }
            return $r.result
        } catch {
            $lastErr = $_.Exception.Message
            if ($i -lt $tries) {
                Write-Log "接口 $Command 第 $i 次失败，重试：$lastErr" 'WARN'
                Start-Sleep -Seconds 3
            }
        }
    }
    throw "接口 $Command 连续 $tries 次失败：$lastErr"
}

function Get-Accounts {
    $acc = Invoke-Csw -Command 'list_accounts'
    $out = @()
    foreach ($a in @($acc)) {
        $five = $null; $week = $null; $fiveReset = $null; $weekReset = $null
        $usage = Get-StateFlag $a 'usage'
        $primary = Get-StateFlag $usage 'primary'
        $secondary = Get-StateFlag $usage 'secondary'
        foreach ($window in @('primary','secondary')) {
            $value = if ($window -eq 'primary') { $primary } else { $secondary }
            $raw = Get-StateFlag $value 'remainingPercent'
            $number = 0.0
            $valid = ($null -ne $raw -and [double]::TryParse([string]$raw,[ref]$number) -and
                -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and $number -ge 0 -and $number -le 100)
            if ($window -eq 'primary') {
                if ($valid) { $five = $number }; $fiveReset = Get-StateFlag $value 'resetsAt'
            } else {
                if ($valid) { $week = $number }; $weekReset = Get-StateFlag $value 'resetsAt'
            }
        }
        $out += [pscustomobject]@{
            Id            = $a.id
            Email         = $a.email
            Plan          = $a.plan
            Active        = [bool]$a.active
            Switchable    = [bool]$a.directSwitchCompatible
            FiveHour      = $five
            Weekly        = $week
            FiveHourReset = $fiveReset
            WeeklyReset   = $weekReset
            UsageError    = Get-StateFlag $usage 'error'
        }
    }
    return $out
}

function Format-ResetAt {
    <# epoch 秒 → 本地时间字符串 #>
    param($Epoch)
    if ($null -eq $Epoch) { return '未知' }
    try { return ([DateTimeOffset]::FromUnixTimeSeconds([int64]$Epoch)).ToLocalTime().ToString('MM-dd HH:mm') }
    catch { return '未知' }
}

# ══════════════════════════════════════════════════════════════════
#  会话扫描
# ══════════════════════════════════════════════════════════════════
function Get-SessionFileStamp {
    <# Directory mtime can stay frozen while Codex appends. Cache by length and read the last event timestamp. #>
    param([System.IO.FileInfo]$File)
    $key = $File.FullName
    if ($Script:FileActivityCache.ContainsKey($key)) {
        $old = $Script:FileActivityCache[$key]
        if ($old.Length -eq $File.Length -and $old.Mtime -eq $File.LastWriteTime) { return $old.Stamp }
    }
    $stamp = $null
    $size = 8192
    while ($true) {
        $tail = Read-FileTail -Path $key -Bytes $size
        $tsMatches = [regex]::Matches($tail, '(?m)^\s*\{"timestamp":"([^"]+)"')
        if ($tsMatches.Count -gt 0) {
            try {
                $stamp = [datetime]::Parse($tsMatches[$tsMatches.Count-1].Groups[1].Value,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime()
            } catch { }
            if ($stamp) { break }
        }
        if ($File.Length -le $size -or $size -ge 4MB) { break }
        $size = [Math]::Min(4MB, $size * 4)
    }
    if (-not $stamp -and $Script:FileActivityCache.ContainsKey($key) -and
        $File.Length -gt $Script:FileActivityCache[$key].Length) {
        $stamp = Get-Date   # 巨大的未结束事件仍在增长，按正在活动处理
    }
    if (-not $stamp) { $stamp = $File.LastWriteTime }
    $Script:FileActivityCache[$key] = @{ Length = $File.Length; Mtime = $File.LastWriteTime; Stamp = $stamp }
    return $stamp
}

function Get-RecentSessions {
    if (-not (Test-Path $Script:Config.SessionRoot)) {
        Write-File "还没找到 Codex 会话目录（$($Script:Config.SessionRoot)）—— Codex 可能还没启动过，继续盯着"
        return @()
    }
    $cut = (Get-Date).AddMinutes(-$Script:Config.SessionMaxAgeMin)
    # 枚举目录很便宜；只有文件长度/mtime 改变时才重新读尾部。
    # 这样跨日、运行超过 12 小时且 mtime 冻结的会话也不会消失。
    $files = @(Get-ChildItem $Script:Config.SessionRoot -Recurse -File -Filter *.jsonl -ErrorAction SilentlyContinue)
    return @($files | Where-Object { (Get-SessionFileStamp $_) -gt $cut } |
        Sort-Object { Get-SessionFileStamp $_ } -Descending)
}

function Get-CallCommand {
    <#
      从工具调用的原文里把真正的命令抠出来，并还原转义。
      为什么要单独做，而不能直接对整段做正则：
        · DSH 的 **自定义工具调用** 把参数写成 JS 风格、键还没引号：
              "input":"text(await tools.exec_command({cmd:\"git status\"}))"
          这种情况要认 `cmd:`，认 `"cmd":` 是不够的。
        · Codex 原生工具把参数塞在**转义过的 JSON 字符串**里：
              "arguments":"{\"command\":\"Start-Sleep -Seconds 3600\"}"
          这种情况要认 `\"command\":\"…\"`。
      抠不出来时不能傻乎乎把整段 JSON 塞进报告（又长又没信息），只留一小段。
    #>
    param([string]$Raw)
    if ([string]::IsNullOrEmpty($Raw)) { return '' }

    # 两种键都找。注意顺序：先 `cmd` 再 `command`。
    # 因为 JS 风格下工具名是 tools.exec_command(...)，先找 command 会撞上
    # exec_command 这个词本身；而原生工具的转义形式是 \"command\":\"…\" 有冒号，
    # 放到第二步仍然能正确命中。
    # 值一律用 Get-QuotedFieldValue 扫，不靠正则硬啃转义 —— 命令里本身带引号
    # （例：cmd:"echo \"hi\""）时，正则很容易把结尾引号一起吞进来或提前截断。
    foreach ($k in @('cmd', 'command')) {
        $v = Get-QuotedFieldValue -Raw $Raw -Key $k
        if ($v) { return (Restore-CallText -Value $v) }
    }

    # 认不出来的命令（比如 apply_patch 这种长文本），只留一小段可读摘要
    $s = $Raw
    $i = $s.IndexOf('"input"');   if ($i -lt 0) { $i = $s.IndexOf('"arguments"') }
    if ($i -ge 0) { $s = $s.Substring($i) }
    foreach ($marker in @('"internal_chat_message_metadata','"metadata"','"type":"token_usage_record')) {
        $j = $s.IndexOf($marker)
        if ($j -gt 0) { $s = $s.Substring(0, $j) }
    }
    return (Restore-CallText -Value $s -MaxLen 300)
}

function Get-QuotedFieldValue {
    <#
      从原文里找出 Key 后面第一个字符串值，正确处理 \" 这类转义，
      不带引号的值（JS 风格）也认。找不到返回 $null。
    #>
    param([string]$Raw, [string]$Key)

    # 依次尝试：带引号的键 → 被 JSON 转义过的带引号键 → 裸键
    # （每项都要单独括号：PowerShell 里 'a' + $k + 'b', 'c' 会被当成一个表达式，
    #   逗号会被并进拼接，结果整个数组只有一项 —— 这个坑踩过。）
    $forms = @(
        ('"' + $Key + '"'),
        ('\"' + $Key + '\"'),
        ($Key)
    )
    foreach ($form in $forms) {
        $i = $Raw.IndexOf($form, [System.StringComparison]::Ordinal)
        while ($i -ge 0) {
            $j = $i + $form.Length
            # 键后面必须跟冒号（中间只许有空白）。这一条是防误命中的关键：
            # 否则 JS 风格里的工具名 tools.exec_command 会被当成 command 字段。
            $k = $j
            while ($k -lt $Raw.Length -and ($Raw[$k] -eq ' ' -or $Raw[$k] -eq "`t")) { $k++ }
            if ($k -ge $Raw.Length -or $Raw[$k] -ne ':') {
                $i = $Raw.IndexOf($form, $i + 1, [System.StringComparison]::Ordinal); continue
            }
            $j = $k + 1
            while ($j -lt $Raw.Length -and ($Raw[$j] -eq ' ' -or $Raw[$j] -eq "`t")) { $j++ }
            if ($j -ge $Raw.Length) { return $null }

            # 值被 \" 包着（JSON 转义形式）
            if ($j + 1 -lt $Raw.Length -and $Raw[$j] -eq '\' -and $Raw[$j + 1] -eq '"') {
                $j += 2
                $sb = New-Object System.Text.StringBuilder
                while ($j -lt $Raw.Length) {
                    $ch = $Raw[$j]
                    if ($ch -eq '\') {
                        if ($j + 1 -lt $Raw.Length -and $Raw[$j + 1] -eq '"') { $j += 2; break }
                        [void]$sb.Append($ch); $j++; continue
                    }
                    if ($ch -eq '"') { break }
                    [void]$sb.Append($ch); $j++
                }
                return $sb.ToString()
            }
            # 值被普通 " 包着
            if ($Raw[$j] -eq '"') {
                $j++
                $sb = New-Object System.Text.StringBuilder
                while ($j -lt $Raw.Length) {
                    $ch = $Raw[$j]
                    if ($ch -eq '\') {
                        if ($j + 1 -lt $Raw.Length -and ($Raw[$j + 1] -eq '"' -or $Raw[$j + 1] -eq '\')) {
                            [void]$sb.Append($Raw[$j + 1]); $j += 2; continue
                        }
                        [void]$sb.Append($ch); $j++; continue
                    }
                    if ($ch -eq '"') { break }
                    [void]$sb.Append($ch); $j++
                }
                return $sb.ToString()
            }
            # 不带引号的值：读到分隔符为止
            $sb = New-Object System.Text.StringBuilder
            while ($j -lt $Raw.Length -and $Raw[$j] -notin @(',', '}', ')', "`n")) {
                [void]$sb.Append($Raw[$j]); $j++
            }
            $v = $sb.ToString().Trim()
            if ($v) { return $v }
            $i = $Raw.IndexOf($form, $i + 1, [System.StringComparison]::Ordinal)
        }
    }
    return $null
}

function Restore-CallText {
    <# 还原 JSON/JS 转义、压平空白、必要时截断 —— 给人和正则看，不保证是合法 JSON #>
    param([string]$Value, [int]$MaxLen = 400)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $v = $Value -replace '\\\\', '\' -replace '\\"', '"'
    $v = $v -replace '\\n', ' ' -replace '\\r', ' ' -replace '\\t', ' '
    $v = ($v -replace '\s+', ' ').Trim()
    if ($MaxLen -gt 0 -and $v.Length -gt $MaxLen) { $v = $v.Substring(0, $MaxLen) + '…' }
    return $v
}

function Get-SessionFact {
    param([System.IO.FileInfo]$File)
    $fact = [ordered]@{
        File        = $File.FullName
        Name        = $File.Name
        ThreadId    = $File.BaseName
        Mtime       = $File.LastWriteTime
        SizeKB      = [math]::Round($File.Length / 1KB, 1)
        LastEvent   = $null
        LastEventAt = $null
        # 最新的那个"回合标记"的原始类型：task_started / task_complete / task_completed / turn_aborted
        # 分辨"正常结束"和"被中断"就靠它（turn_aborted = 被中断）
        LastMarker  = $null
        # 模型在收尾那一轮自己说了什么（task_complete 的 last_agent_message）。
        # 用来识别"这一轮正常结束了，但它自认没干完"。
        LastAgentMessage = $null
        # 这个对话自己的工作目录（rollout 里 turn_context 的 cwd），
        # 提交队列消息时优先沿用，以保留会话相关的路径环境。
        WorkDir     = $null
        # 真实"最后活动时刻"：取自文件内最后一条 timestamp。
        # 为什么不用 mtime：见下面 Get-SessionFact 里的注释（开着的文件 mtime 是冻结的）
        LastActivityAt = $null
        TaskOpen    = $false
        LimitHit    = $false
        LimitCertain = $false
        LimitText   = $null
        LimitResetHint = $null
        PendingTool = $null
        PendingCmd  = $null
        SleepSec    = $null
    }
    $m = [regex]::Match($File.BaseName, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
    if ($m.Success) { $fact.ThreadId = $m.Groups[1].Value }

    $text = Read-FileTailForMarkers -File $File
    if ([string]::IsNullOrEmpty($text)) { return [pscustomobject]$fact }

    # ── 真实"最后活动时刻" ──
    # ⚠️ 绝不能用文件 mtime 当活动时钟。Codex 的 app-server 一直攥着会话文件的写句柄，
    #    句柄关闭前 Windows 不刷新目录项时间戳 —— 实测 3.29MB / 35 分钟的追加，
    #    CreationTime 和 LastWriteTime 都还停在文件创建那一毫秒（.802 / .803），
    #    mtime 从头到尾没动过。同一目录下【已关闭】的会话文件则 mtime 与文件内
    #    最后一条事件毫秒级相等（17:48:54 / 15:14:39 / 14:41:54 三例）。
    #    用 mtime 算 idle，会把"正在跑"的会话算成"停了几十分钟" → 假警报 + 白烧额度。
    $lastAct = $null
    foreach ($tm in [regex]::Matches($text, '"timestamp":"([^"]+)"')) { $lastAct = $tm.Groups[1].Value }
    if ($lastAct) {
        try {
            $fact.LastActivityAt = [datetime]::Parse(
                $lastAct,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        } catch { $fact.LastActivityAt = $null }
    }

    $lastStart = -1; $lastStartAt = $null; $lastEnd = -1; $lastEndAt = $null; $lastMarker = $null
    foreach ($mm in [regex]::Matches($text, '"timestamp":"([^"]+)".{0,240}?"type":"(task_started|task_complete|task_completed|turn_aborted)"')) {
        $at = $mm.Groups[1].Value
        $ty = $mm.Groups[2].Value
        $lastMarker = $ty                       # 正则按出现顺序匹配，最后一个就是最新的那个
        if ($ty -eq 'task_started') { $lastStart = $mm.Index; $lastStartAt = $at }
        else { $lastEnd = $mm.Index; $lastEndAt = $at }
    }
    $fact.LastMarker = $lastMarker
    if ($null -eq $lastMarker) {
        # 翻到上限还是找不到回合标记。这种情况**绝不能默默当成"正常结束"** ——
        # 之前就是因为这个把一个大活跃会话判成结束、永远不给它发继续。
        Write-Log "读不到回合标记（尾部已翻到 $($Script:Config.MarkerScanMaxKB)KB）：$($File.Name) —— 会在日志里标成『标记读不到』" 'WARN'
    }

    # ── 模型收尾时自己说的话 ──
    # task_complete / task_completed 事件里带 last_agent_message。
    # 用它分辨"正常结束"和"结束了但自己说没干完"（后者要继续催）。
    $lam = $null
    foreach ($mm in [regex]::Matches($text, '"last_agent_message":"((?:[^"\\]|\\.)*)"')) { $lam = $mm.Groups[1].Value }
    if ($lam) { $fact.LastAgentMessage = (Restore-CallText -Value $lam) }

    # 这个对话的工作目录（取最后出现的那个 cwd）—— 续跑时要 cd 进去
    $wd = $null
    foreach ($mm in [regex]::Matches($text, '"cwd":"((?:[^"\\]|\\.)*)"')) { $wd = $mm.Groups[1].Value }
    if ($wd) {
        $w = Restore-CallText -Value $wd
        if ($w -and (Test-Path -LiteralPath $w -PathType Container)) { $fact.WorkDir = $w }
    }
    if (-not $fact.WorkDir) {
        # A completed turn may be tiny while turn_context.cwd is megabytes earlier.
        # The first session_meta event retains the original working directory.
        $reader = $null
        try {
            $stream = [IO.File]::Open($File.FullName, 'Open', 'Read', 'ReadWrite')
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
            $meta = $reader.ReadLine() | ConvertFrom-Json
            if ($meta.type -eq 'session_meta') {
                $cwd = Get-StateFlag -State $meta.payload -Name 'cwd'
                if ($cwd -and (Test-Path -LiteralPath $cwd -PathType Container)) { $fact.WorkDir = $cwd }
            }
        } catch { } finally { if ($reader) { $reader.Dispose() } }
    }
    if ($lastStart -gt $lastEnd -and $lastStart -ge 0) {
        $fact.TaskOpen = $true
        $fact.LastEvent = 'task_started'
        $fact.LastEventAt = $lastStartAt
    } elseif ($lastEnd -ge 0) {
        $fact.TaskOpen = $false
        $fact.LastEvent = 'task_ended'
        $fact.LastEventAt = $lastEndAt
    }

    $from = [Math]::Max(0, [Math]::Max($lastStart, $lastEnd))

    # ── 撞墙信号 ──
    # 5 小时窗口和周窗口撞墙**用的是同一个错误码** usage_limit_exceeded，
    # limit_name 还是 null，光看错误码分不出是哪个窗口。
    # 所以不能只认 5 小时那套措辞，改成分两级判定：
    #   A. 明确错误码（usage_limit_exceeded）→ 确定撞墙
    #   B. 文本疑似额度不足 → 标记待确认，后面用账号真实额度状态证实
    $confirmedIdx = -1; $suspectedIdx = -1
    foreach ($marker in $Script:Config.ConfirmedMarkers) {
        $idx = $text.IndexOf($marker, $from, [System.StringComparison]::Ordinal)
        if ($idx -ge 0 -and ($confirmedIdx -lt 0 -or $idx -lt $confirmedIdx)) { $confirmedIdx = $idx }
    }
    foreach ($marker in $Script:Config.SuspectedMarkers) {
        $idx = $text.IndexOf($marker, $from, [System.StringComparison]::Ordinal)
        if ($idx -ge 0 -and ($suspectedIdx -lt 0 -or $idx -lt $suspectedIdx)) { $suspectedIdx = $idx }
    }

    $limitIdx = if ($confirmedIdx -ge 0) { $confirmedIdx } else { $suspectedIdx }
    if ($limitIdx -ge 0) {
        $fact.LimitHit = $true
        $fact.LimitCertain = ($confirmedIdx -ge 0)
        $seg = $text.Substring($limitIdx, [Math]::Min(500, $text.Length - $limitIdx))
        $msg = [regex]::Match($seg, '"message":"([^"]{0,300})')
        $fact.LimitText = if ($msg.Success) { $msg.Groups[1].Value } else { 'usage limit' }
        # 从报错里抠"几点恢复"，这个对判断是哪个窗口很有用
        $rt = [regex]::Match($seg, 'try again at ([^"\\]{1,40})')
        if ($rt.Success) { $fact.LimitResetHint = $rt.Groups[1].Value.Trim() }
        $head = $text.Substring([Math]::Max(0, $limitIdx - 500), [Math]::Min(500, $limitIdx))
        $ts = [regex]::Match($head, '"timestamp":"([^"]+)"(?:(?!timestamp).)*$')
        if ($ts.Success) { $fact.LastEventAt = $ts.Groups[1].Value }
    }

    # 悬空的工具调用：发了 call 却没有对应 output —— 说明卡在这一步
    $calls = @{}
    $callRe = [regex]'"type":"(function_call|custom_tool_call|local_shell_call)"'
    foreach ($fm in $callRe.Matches($text)) {
        $head = $text.Substring($fm.Index, [Math]::Min(700, $text.Length - $fm.Index))
        # 只取 arguments 之前的头部拿工具名；call_id 在 arguments 之后，需单独找
        $cut = $head.IndexOf('"arguments"')
        if ($cut -lt 0) { $cut = $head.IndexOf('"input"') }
        if ($cut -gt 0) { $head = $head.Substring(0, $cut) }
        $cidM = [regex]::Match($head, '"call_id":"([^"]+)"')
        if (-not $cidM.Success) {
            $cidM = [regex]::Match($text.Substring($fm.Index, [Math]::Min(1200, $text.Length - $fm.Index)),
                                  '"call_id":"([^"]+)"')
        }
        $cid = if ($cidM.Success) { $cidM.Groups[1].Value } else { 'at' + $fm.Index }
        if ($calls.ContainsKey($cid)) { continue }
        $tool = [regex]::Match($head, '"name":"([^"]{0,60})"').Groups[1].Value
        $ns   = [regex]::Match($head, '"namespace":"([^"]{0,60})"').Groups[1].Value
        $tail = $text.Substring($fm.Index, [Math]::Min(1600, $text.Length - $fm.Index))
        # 更可靠的"是否已完成"判据：后面有没有出现执行结果
        $done = ($tail -like '*CommandExecution*') -or ($tail -like '*custom_tool_call_output*') -or
                ($tail -like '*function_call_output*') -or ($tail -like '*item_completed*')
        $cmd  = [regex]::Match($tail, '"(?:command|cmd)"\s*:\s*(?:\[)?"([^"]{0,220})').Groups[1].Value
        $calls[$cid] = [pscustomobject]@{
            Index = $fm.Index; Tool = $tool; Ns = $ns; Cmd = $cmd; Raw = $tail; Done = $done
        }
    }
    $lastCid = $null; $lastIdx = -1
    foreach ($k in $calls.Keys) {
        if ($calls[$k].Index -gt $lastIdx) { $lastIdx = $calls[$k].Index; $lastCid = $k }
    }
    if ($lastCid -and -not $calls[$lastCid].Done) {
        $c = $calls[$lastCid]
        $fact.PendingTool = if ($c.Ns) { "$($c.Ns).$($c.Tool)" } else { $c.Tool }
        $fact.PendingCmd  = Get-CallCommand -Raw $c.Raw

        # ── 已知的「故意长等待」──
        # 有两类，都要认，否则会把正常的等待当成卡住、白叫一次 AI：
        #   1) clock.sleep 工具：参数是 duration_ms
        #   2) shell 里跑 Start-Sleep / sleep：参数是秒
        if ($c.Tool -eq 'sleep') {
            $dm = [regex]::Match($c.Raw, 'duration_ms\D{0,4}([0-9]+)')
            $fact.SleepSec = if ($dm.Success) { [int]([int64]$dm.Groups[1].Value / 1000) } else { 0 }
        } elseif ($fact.PendingCmd -match '(?i)start-sleep') {
            # Start-Sleep 不带 -Seconds 时默认睡到永远，按"在等待、无法估算"处理
            $sm = [regex]::Match($fact.PendingCmd, '(?i)start-sleep[^0-9]{0,20}([0-9]+)')
            $fact.SleepSec = if ($sm.Success) { [int64]$sm.Groups[1].Value } else { 0 }
        } elseif ($fact.PendingCmd -match '(?i)(^|[;&|\s])sleep\s+([0-9]+)') {
            # Unix 风格 sleep N（秒）
            $sm = [regex]::Match($fact.PendingCmd, '(?i)(^|[;&|\s])sleep\s+([0-9]+)')
            $fact.SleepSec = [int64]$sm.Groups[2].Value
        }
    }
    return [pscustomobject]$fact
}

function Get-SessionVerdict {
    param($Fact)
    # 活动时钟优先用文件里的最后一条事件时间戳；尾部读不到任何时间戳时才退回 mtime。
    # （mtime 对"还开着的"会话文件是冻结的，直接用它必然误报，见 Get-SessionFact 注释。）
    $nowUtc = (Get-Date).ToUniversalTime()
    $idleMin = if ($Fact.LastActivityAt) {
        ($nowUtc - $Fact.LastActivityAt.ToUniversalTime()).TotalMinutes
    } else {
        ($nowUtc - $Fact.Mtime.ToUniversalTime()).TotalMinutes
    }
    if ($idleMin -lt 0) { $idleMin = 0 }   # 时钟微偏，别算成负数
    if ($Fact.TaskOpen -and $idleMin -le $Script:Config.InFlightMin) {
        return [pscustomobject]@{ State = 'running'; IdleMin = $idleMin; Say = '正在跑' }
    }
    if ($Fact.TaskOpen -and $idleMin -gt $Script:Config.StalledMin) {
        # 已知的故意长等待：clock.sleep 或 shell 里的 Start-Sleep / sleep。
        # 只要还能算出它要睡多久，没超时就不算停住。
        if ($null -ne $Fact.SleepSec -and $Fact.SleepSec -gt 0) {
            $budgetMin = ($Fact.SleepSec / 60) + $Script:Config.SleepGraceMin
            if ($idleMin -lt $budgetMin) {
                return [pscustomobject]@{
                    State = 'sleeping'; IdleMin = $idleMin
                    Say = "故意等待中（sleep $([math]::Round($Fact.SleepSec/60,1)) 分钟，还能再等 $([math]::Round($budgetMin - $idleMin,1)) 分钟）"
                }
            }
            return [pscustomobject]@{
                State = 'paused'; IdleMin = $idleMin
                Say = "等待已超时（sleep $([math]::Round($Fact.SleepSec/60,1)) 分钟，实际停了 $([math]::Round($idleMin,1)) 分钟）"
            }
        }
        return [pscustomobject]@{ State = 'paused'; IdleMin = $idleMin; Say = '停住了' }
    }
    if ($Fact.LimitHit -and -not $Fact.TaskOpen) {
        return [pscustomobject]@{ State = 'paused'; IdleMin = $idleMin; Say = '撞墙后停住' }
    }
    return [pscustomobject]@{ State = 'idle'; IdleMin = $idleMin; Say = '空闲' }
}

function Get-ActivityStamp {
    <#
      排序/比较用的"最后活动时刻"，**统一按本地时间返回**。
      ⚠️ 两个坑：
      1) 不能直接用 $Fact.Mtime：还开着的会话文件 mtime 冻结在创建时刻
         （见 Get-SessionFact 注释），拿它排序会把最活跃的对话排到最后。
      2) $Fact.LastActivityAt 是 UTC（带 Kind=Utc），而脚本里到处是
         (Get-Date) 这种本地时间。直接相减/相比会**差一个时区**（这里差 8 小时），
         结果就是所有对话都被"时间窗"过滤掉、一个都续不上。所以这里统一转本地。
    #>
    param($Fact)
    if ($Fact.LastActivityAt) { return $Fact.LastActivityAt.ToLocalTime() }
    return $Fact.Mtime
}

function Get-ResumeFingerprint {
    <#
      "这个中断现场"的指纹：同一个对话 + 同一个中断时刻 → 只续一次。
      续跑之后对话会产生新事件，活动时间一变指纹就变了，可以再续 —— 这正是想要的：
      长任务被反复打断就反复续，没人打断就绝不重复发"继续"。
    #>
    param($Fact)
    # 指纹键统一用 UTC ISO 串，避免同一时刻因 Kind/时区不同写成两个键
    $at = if ($Fact.LastActivityAt) { $Fact.LastActivityAt.ToUniversalTime().ToString('o') }
          else { $Fact.Mtime.ToUniversalTime().ToString('o') }
    return 'res:' + $Fact.ThreadId + ':' + $at
}

function Get-ConversationOutcome {
    <#
      把一个对话分成五类。用途只有一个：**切号之后决定给谁发"继续"**。

        running      正在跑          → 不碰（正在跑就别打扰）
        waiting      故意长等待       → 不碰
        limit        撞额度墙        → 发"继续"（切号的目的就是它）
        interrupted  被中断 / 停住    → 发"继续"
        finished     正常结束        → **绝不发**（用户明确要求：不要挨个都发"继续"）

      怎么分辨"正常结束"和"被中断"：
        · 最新一个回合标记是 task_complete / task_completed，而且没有额度报错 → finished
        · 最新标记是 turn_aborted（Codex 明确写的"这一轮被中断了"）          → interrupted
        · 任务开着（task_started 之后没有收尾）但半天没动静                    → interrupted
        · 任务开着且刚刚还在动                                               → running
        · **标记是 task_complete，但模型自己说"尚未完成 / 只做了只读检查"**    → interrupted
          （真实案例：脚本发"继续"，模型跑 6 秒回了句"功能尚未完成，这次只做了只读检查"
            就正常收尾。光看标记是"正常结束"，可用户的活根本没干完。）
      注意 turn_aborted 必须单独认：它会让 TaskOpen=False，
      光看"任务是否开着"会把它误判成"正常结束"，那样中断的对话就永远续不上了。
    #>
    param($Fact, $Verdict)
    if ($Verdict.State -eq 'running')   { return 'running' }
    if ($Verdict.State -eq 'sleeping')  { return 'waiting' }
    if ($Fact.LimitHit)                 { return 'limit' }
    if (-not $Fact.LastMarker)          { return 'unknown' }
    if ($Verdict.State -eq 'paused')    { return 'interrupted' }
    if ($Fact.LastMarker -eq 'turn_aborted') { return 'interrupted' }
    if (Test-UnfinishedClaim -Fact $Fact)    { return 'unfinished' }
    return 'finished'
}

function Test-UnfinishedClaim {
    <#
      模型收尾时自己承认"没干完"了吗？
      只认 task_complete/task_completed 那条 last_agent_message 里的措辞。
      宁可漏认（当成正常结束），也不要乱认 —— 乱认会和模型互相刷"继续"。
    #>
    param($Fact)
    if ($Fact.LastMarker -notin @('task_complete', 'task_completed')) { return $false }
    if ([string]::IsNullOrEmpty($Fact.LastAgentMessage)) { return $false }
    foreach ($m in $Script:Config.UnfinishedMarkers) {
        if ($Fact.LastAgentMessage -like "*$m*") { return $true }
    }
    return $false
}

function Get-QuotaSnapshot {
    foreach ($f in @(Get-RecentSessions | Select-Object -First 5)) {
        $text = Read-FileTail -Path $f.FullName -Bytes 131072
        $i = $text.LastIndexOf('"rate_limits"')
        if ($i -lt 0) { continue }
        $s = $text.LastIndexOf('{', $i)
        if ($s -lt 0) { continue }
        $seg = $text.Substring($s, [Math]::Min(1200, $text.Length - $s))
        try {
            $o = $seg | ConvertFrom-Json
            return [pscustomobject]@{
                FiveHourUsed = [double]$o.primary.used_percent
                WeeklyUsed   = [double]$o.secondary.used_percent
                Plan         = $o.plan_type
            }
        } catch { }
    }
    return $null
}

# ══════════════════════════════════════════════════════════════════
#  动作
# ══════════════════════════════════════════════════════════════════
function Get-UsableAccounts {
    <#
      "还能切过去的号" = 5h 有剩余 + 周额度有剩余 + 支持直连切换 + **不是当前正在用的那个**。
      ⚠️ 最后那一条（排除 active）踩过坑，用户当场就看出来了：
        · 一共 5 个号，正在用 1 个 —— 却显示"可切号 5 个"。
          用户的算法很朴素：5 个号用掉 1 个，剩下最多 4 个。
        · 只剩最后一个号还有余量时显示"可切号 1 个"，
          可那个 1 就是他自己正在用的号 —— 等于"没有可切的号"。
      注意：判断"5 个号是不是全用完了"**不能用这个函数**（那是把 active 也算在内的口径），
      那种地方用 $weeklyAny / $fresh5h。
    #>
    param($Accounts)
    return @($Accounts | Where-Object {
        $_.Switchable -and (-not $_.Active) -and
        (-not $_.PSObject.Properties['UsageError'] -or -not $_.UsageError) -and
        $null -ne $_.Weekly -and $_.Weekly -gt 0 -and
        $null -ne $_.FiveHour -and $_.FiveHour -gt 0
    })
}

function Select-BestAccount {
    <#
      选号规则（用户明确指定）：
        · 5 小时窗口是「门槛」——只有 5h 还有剩余才配被选中。
          切号本来就是因为当前号 5h 用完了（0%），其余账号的 5h 不是 0% 就是 100%，
          拿它排序没有意义。
        · 7 天窗口是「选择依据」——通过门槛的账号里挑周额度最多的。

      返回三态，不要把"选不出"和"全空"混为一谈：
        Best    有值   → 正常可切
        AllDry = true  → 连周额度都归零了，是真·全空，只能等重置
        Cooling 非空   → 周额度还有、只是 5h 在冷却 → 该等待，不是收摊
    #>
    param($Accounts)

    $eligible = @($Accounts | Where-Object {
        $_.Switchable -and (-not $_.Active) -and
        (-not $_.PSObject.Properties['UsageError'] -or -not $_.UsageError) -and
        $null -ne $_.FiveHour -and $_.FiveHour -gt 0 -and
        $null -ne $_.Weekly   -and $_.Weekly   -gt 0
    })

    # 周额度还有、只是 5h 归零 —— 它们在冷却，不是用完了
    $cooling = @($Accounts | Where-Object {
        $_.Switchable -and (-not $_.Active) -and
        ($null -eq $_.FiveHour -or $_.FiveHour -le 0) -and
        $null -ne $_.Weekly -and $_.Weekly -gt 0
    })

    $best = $null
    if ($eligible.Count -gt 0) {
        $best = @($eligible | Sort-Object -Property @{Expression = { $_.Weekly }; Descending = $true },
                                                    @{Expression = { $_.FiveHour }; Descending = $true })[0]
    }

    # 只有"连周额度都没有"才算真空
    $anyWeeklyLeft = @($Accounts | Where-Object { $null -ne $_.Weekly -and $_.Weekly -gt 0 }).Count -gt 0

    if ($best) {
        Write-Event "可切号 $($eligible.Count) 个，选中 $($best.Email)（5h $($best.FiveHour)% / 周 $($best.Weekly)%）"
    } elseif ($cooling.Count -gt 0) {
        $when = @($cooling | ForEach-Object {
            '{0}({1} 恢复)' -f ($_.Email -replace '@.*', ''), (Format-ResetAt $_.FiveHourReset)
        })
        Write-Log ("没有可切号：这些号的 5 小时正在冷却 → " + ($when -join '，')) 'WARN'
    }

    return [pscustomobject]@{
        Best    = $best
        AllDry  = (-not $anyWeeklyLeft)
        Cooling = $cooling
    }
}

function Invoke-SwitchAccount {
    param($Account)
    Write-Event "切号 → $($Account.Email)（5h 剩余 $($Account.FiveHour)% / 周剩余 $($Account.Weekly)% ← 按周额度最大选中）"
    if (-not $Live) {
        Write-Event "[演习] 本来会调用 switch_account_and_restart_chatgpt id=$($Account.Id)" 'DRYRUN'
        return $true
    }
    $null = Invoke-Csw -Command 'switch_account_and_restart_chatgpt' -Arguments @{ id = $Account.Id }
    $Script:SwitchCount++
    Write-Event '切号指令已发出' 'OK'
    Write-Event "最多等 $($Script:Config.SwitchVerifySec) 秒，确认 Codex Switch 已切到目标账号"
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, [int]$Script:Config.SwitchVerifySec))
    do {
        try {
            $active = @(Get-Accounts | Where-Object { $_.Active })
            if ($active.Count -eq 1 -and $active[0].Id -eq $Account.Id) {
                Write-Event "已确认当前账号：$($Account.Email)" 'OK'
                return $true
            }
        } catch {
            Write-File "切号确认暂时读不到账号：$($_.Exception.Message)" 'WARN'
        }
        $remaining=($deadline-(Get-Date)).TotalMilliseconds
        if($remaining -gt 0){Start-Sleep -Milliseconds ([int][Math]::Min($remaining,[int]$Script:Config.SwitchVerifyPollSec*1000))}
    } while ((Get-Date) -lt $deadline)
    Write-Event "切号指令已发出，但未能确认当前账号变成 $($Account.Email)；暂停续跑交给 人工处理" 'ERROR'
    return $false
}

function Invoke-ResumeConversation {
    <#
      在独立隐藏进程里真正启动“继续”回合。codex queue 只负责排队，
      未打开的桌面会话不会主动消费队列，不能满足无人值守。
      runner 完成后写结果文件，主循环下一轮据此确认成功或交给 人工处理。
    #>
    param([string]$ThreadId, [string]$Label, [string]$WorkDir)
    $mode = [string]$Script:Config.ResumeMode
    $msg  = [string]$Script:Config.ResumeMessage
    Write-Event "续跑 → [$Label] thread=$ThreadId（方式 $mode）"
    if ($mode -ne 'unattended') {
        Write-Event "拒绝续跑：ResumeMode=$mode 不能保证无人值守；仅允许 unattended" 'ERROR'
        return $false
    }
    if (-not $Live) {
        Write-Event "[演习] 本来会在后台执行：codex exec resume $ThreadId `"$msg`"" 'DRYRUN'
        return $true
    }
    try {
        if (-not $Script:CodexExe -or -not (Test-Path -LiteralPath $Script:CodexExe)) {
            throw '找不到 codex.exe，无法启动无人值守续跑'
        }
        $cwd = if ($WorkDir -and (Test-Path $WorkDir)) { $WorkDir } else { $Script:Config.HelperWorkDir }
        if (-not (Test-Path -LiteralPath $cwd)) { throw "Codex 工作目录不存在：$cwd" }
        if (-not (Test-Path -LiteralPath $Script:Config.LogDir)) {
            New-Item -ItemType Directory -Path $Script:Config.LogDir -Force | Out-Null
        }
        $resumeJobDir = Join-Path $Script:Config.StateDir 'resume-jobs'
        if (-not (Test-Path -LiteralPath $resumeJobDir)) {
            New-Item -ItemType Directory -Path $resumeJobDir -Force | Out-Null
        }

        . (Join-Path $PSScriptRoot 'lib\process.ps1')
        $jobId = [guid]::NewGuid().ToString('N')
        $stem = "resume-{0}-{1}" -f $ThreadId.Substring(0, 8), $jobId.Substring(0, 8)
        $log = Join-Path $Script:Config.LogDir "$stem.log"
        $jobFile = Join-Path $resumeJobDir "$stem.job.json"
        $resultFile = Join-Path $resumeJobDir "$stem.result.json"
        $job = [ordered]@{
            jobId = $jobId; threadId = $ThreadId; message = $msg; workDir = $cwd
            codexExe = $Script:CodexExe; stdout = $log; stderr = "$log.err"
            resultFile = $resultFile; timeoutSec = [int]$Script:Config.ResumeTimeoutSec
        }
        Write-JsonAtomic -Path $jobFile -Value $job

        $runner = Join-Path $PSScriptRoot 'resume-runner.ps1'
        if (-not (Test-Path -LiteralPath $runner)) { throw "缺少续跑执行器：$runner" }
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $si = New-Object System.Diagnostics.ProcessStartInfo
        $si.FileName = $powershell
        $si.Arguments = (@('-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$runner,'-JobFile',$jobFile) |
            ForEach-Object { ConvertTo-NativeArgument ([string]$_) }) -join ' '
        $si.WorkingDirectory = $cwd
        $si.UseShellExecute = $false
        $si.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($si)
        if (-not $proc) { throw '无人值守续跑进程没有成功启动' }
        $startedAt = $proc.StartTime.ToString('o')
        Write-Event "无人值守续跑已启动：$($ThreadId.Substring(0,8))（PID $($proc.Id)）；无需打开桌面对话" 'OK'
        return [pscustomobject]@{
            Async = $true; JobId = $jobId; Pid = $proc.Id; ProcessStartedAt = $startedAt
            ResultFile = $resultFile; ErrorFile = "$log.err"; JobFile = $jobFile
        }
    } catch {
        Write-Event "续跑异常：$($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Get-LimitFingerprint {
    param($Fact)
    $t = if ($Fact.LimitText) { $Fact.LimitText } else { 'unknown' }
    $at = if ($Fact.LastEventAt) { $Fact.LastEventAt } else { (Get-ResumeFingerprint -Fact $Fact) }
    return 'limit:' + $Fact.ThreadId + ':' + $at + ':' + (($t -replace '\s+', ' ').Trim())
}

# ══════════════════════════════════════════════════════════════════
#  单轮检查
# ══════════════════════════════════════════════════════════════════
function Get-LegacyLimitFingerprint {
    param($Fact)
    $t = if ($Fact.LimitText) { $Fact.LimitText } else { 'unknown' }
    return 'limit:' + $Fact.ThreadId + ':' + (($t -replace '\s+', ' ').Trim())
}

function Invoke-Round {
    param($State)

    $accounts = @(Get-Accounts)
    # ⚠️ 一个账号都读不到时绝不能往下走：Select-BestAccount 对空列表会得出
    #    "连周额度都没有" → 被误判成"5 个账号全部耗尽"→ 退出码 3 收摊。
    #    用户常常"先开看护、再开 Codex/Codex Switch"，那一刻就是空列表。
    if ($accounts.Count -eq 0) {
        Write-Event 'csw 里读不到任何账号（接口刚起或还没登录），本轮不动，等下一轮' 'WARN'
        return [pscustomobject]@{ Kind = 'wait'; Reason = '还没有读到任何账号信息' }
    }
    $pendingCheck = Update-PendingResumes -State $State
    if ($pendingCheck.Failure) {
        return [pscustomobject]@{
            Kind = 'needs-review'; Immediate = $true; Reason = '后台续跑失败'
            Details = [ordered]@{ resumeFailure = $pendingCheck.Failure }
        }
    }
    if ($pendingCheck.PendingCount -gt 0) {
        Write-File "有 $($pendingCheck.PendingCount) 条无人值守续跑仍在执行，本轮不切号、不重复发送"
        return [pscustomobject]@{
            Kind = 'wait'; Reason = '无人值守续跑正在执行'
            Details = @{ threads = $pendingCheck.Threads }
        }
    }
    $desc = @($accounts | ForEach-Object {
        $tag = if ($_.Active) { '*' } else { '' }
        '{0}{1}=5h{2}/周{3}' -f ($_.Email -replace '@.*', ''), $tag, $_.FiveHour, $_.Weekly
    })
    Write-Log ('额度：' + ($desc -join '  '))

    # 可切号 = 有额度 **且不是当前正在用的那个**（见 Get-UsableAccounts 的注释）
    $usable = @(Get-UsableAccounts -Accounts $accounts)
    # 临界判断盯的是「当前在用那个号的 5 小时剩余」——
    # 撞墙的永远是它，其他号的 5h 不是 0 就是 100%。
    $activeList = @($accounts | Where-Object { $_.Active })
    $activeAcc = if ($activeList.Count -gt 0) { $activeList[0] } else { $null }
    if ($activeList.Count -ne 1) {
        $since = Get-StateFlag -State $State -Name 'missingActiveSince'
        if (-not $since) {
            Set-StateFlag -State $State -Name 'missingActiveSince' -Value ((Get-Date).ToString('o'))
            if ($Live) { Save-State -State $State }
            return [pscustomobject]@{ Kind = 'wait'; Reason = '账号状态暂未标出唯一当前号，稍后复查' }
        }
        if (((Get-Date) - [datetime]::Parse($since)).TotalSeconds -lt 60) {
            return [pscustomobject]@{ Kind = 'wait'; Reason = '账号状态暂未标出唯一当前号，稍后复查' }
        }
        return [pscustomobject]@{ Kind = 'needs-review'; Immediate = $true
            Reason = '超过一分钟没有唯一当前账号'; Details = @{ activeCount = $activeList.Count } }
    }
    if (Get-StateFlag -State $State -Name 'missingActiveSince') {
        Clear-StateFlag -State $State -Name 'missingActiveSince'
        if ($Live) { Save-State -State $State }
    }
    if ($activeAcc -and $null -ne $activeAcc.FiveHour) {
        $criticalRemain = $activeAcc.FiveHour
        $criticalWho = $activeAcc.Email
        $criticalWhat = '5 小时'
    } else {
        # 没有 active 标记时退回：看可用账号里最紧的 5 小时
        $fh = @($usable | Where-Object { $null -ne $_.FiveHour } | ForEach-Object { $_.FiveHour })
        $criticalRemain = if ($fh.Count -gt 0) { ($fh | Measure-Object -Minimum).Minimum } else { 0 }
        $criticalWho = '(未标记当前号)'
        $criticalWhat = '5 小时(可用账号最低)'
    }

    # ══════════════════════════════════════════════════════════════
    #  5 个号全用完：等**全部**账号刷新，再调用本机额度定时器批量消耗一次。
    #  waitingReset 会持久化，所以看护中途重启也不能在“只刷新了一个号”时提前执行。
    # ══════════════════════════════════════════════════════════════
    $weeklyAny = @($accounts | Where-Object { $null -ne $_.Weekly -and $_.Weekly -gt 0 })
    $fresh5h   = @($accounts | Where-Object { $null -ne $_.FiveHour -and $_.FiveHour -gt 0 })
    $allFiveDry = ($accounts.Count -gt 0 -and $fresh5h.Count -eq 0)
    $allWeeklyDry = ($accounts.Count -gt 0 -and $weeklyAny.Count -eq 0)
    $waitFlag  = Get-StateFlag -State $State -Name 'waitingReset'
    $unknownQuota = @($accounts | Where-Object { $null -eq $_.FiveHour -or $null -eq $_.Weekly })
    if ($unknownQuota.Count -gt 0 -and ($waitFlag -or $allFiveDry -or $allWeeklyDry)) {
        return [pscustomobject]@{ Kind = 'needs-review'; Immediate = $true
            Reason = '账号额度数据不完整，无法安全判断是否全部耗尽'
            Details = @{ accounts = @($unknownQuota | ForEach-Object { $_.Email }) } }
    }

    $justRecovered = $false
    if ($waitFlag) {
        $expectedIds = @((Get-StateFlag -State $waitFlag -Name 'accountIds') |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ } | Sort-Object)
        $currentIds = @($accounts | ForEach-Object { [string]$_.Id } | Sort-Object)
        if ($expectedIds.Count -gt 0 -and ($expectedIds -join "`n") -ne ($currentIds -join "`n")) {
            return [pscustomobject]@{ Kind = 'needs-review'; Immediate = $true
                Reason = '等待刷新期间账号列表发生变化，不能安全执行批量消耗'
                Details = @{ expectedAccountIds = $expectedIds; currentAccountIds = $currentIds } }
        }
        if ($expectedIds.Count -eq 0) {
            # 兼容升级前已经写下的等待状态；补齐快照后，后续轮次即可检测账号变化。
            Set-StateFlag -State $waitFlag -Name 'accountIds' -Value $currentIds
            if ($Live) { Save-State -State $State }
        }
        $phase = Get-StateFlag -State $waitFlag -Name 'phase'
        if ($phase -in @('running','failed')) {
            return [pscustomobject]@{ Kind = 'needs-review'; Immediate = $true
                Reason = '全部账号消耗任务曾启动但没有完整成功；为避免重复消耗，停止自动重试'
                Details = @{ waitingReset = $waitFlag } }
        }
        $quotaType = 'all'
        $notReady = @($accounts | Where-Object { $_.FiveHour -le 0 -or $_.Weekly -le 0 })
        if ($notReady.Count -eq 0) {
            $justRecovered = $true
            Write-Event "已确认全部 $($accounts.Count) 个账号都完成刷新，准备批量消耗一次" 'OK'
        } else {
            $storedWake = $null
            try { $storedWake = [datetime]::Parse([string](Get-StateFlag -State $waitFlag -Name 'wakeAt')) } catch { }
            if ($storedWake -and $storedWake -gt (Get-Date)) {
                return [pscustomobject]@{ Kind = 'wait-reset'; Reason = "仍有 $($notReady.Count) 个账号未刷新，继续等到 $($storedWake.ToString('MM-dd HH:mm'))"; Details = [ordered]@{
                    wakeAt = $storedWake; waitSec = [int][Math]::Max(1, ($storedWake - (Get-Date)).TotalSeconds); quotaType = $quotaType
                } }
            }
            $plan = Get-WaitPlan -Accounts $accounts -QuotaType 'all'
            Set-StateFlag -State $waitFlag -Name 'wakeAt' -Value $plan.WakeAt.ToString('o')
            if ($Live) { Save-State -State $State }
            return [pscustomobject]@{ Kind = 'wait-reset'; Reason = "到点后仍有 $($notReady.Count) 个账号未刷新，$([int]($plan.WaitSec / 60)) 分钟后复查"; Details = [ordered]@{
                wakeAt = $plan.WakeAt; waitSec = $plan.WaitSec; quotaType = $quotaType
            } }
        }
    } elseif ($Script:Config.WaitForResetEnabled -and ($allWeeklyDry -or $allFiveDry)) {
        $quotaType = 'all'
        $plan = Get-WaitPlan -Accounts $accounts -QuotaType 'all'
        $waitFlag = [pscustomobject]@{
            since = (Get-Date).ToString('o'); wakeAt = $plan.WakeAt.ToString('o')
            quotaType = $quotaType; phase = 'waiting'; accountIds = @($accounts | ForEach-Object { $_.Id })
        }
        Set-StateFlag -State $State -Name 'waitingReset' -Value $waitFlag
        if ($Live) { Save-State -State $State }
        $windowName = if ($allWeeklyDry -and $allFiveDry) { '5 小时额度和周额度' }
                      elseif ($allWeeklyDry) { '周额度' } else { '5 小时额度' }
        Write-Event ("全部 $($accounts.Count) 个账号的${windowName}都用完了；等待全部刷新，最晚按 {0} 回来看" -f $plan.WakeAt.ToString('MM-dd HH:mm')) 'WARN'
        return [pscustomobject]@{ Kind = 'wait-reset'; Reason = "等待全部账号刷新：最晚 $($plan.WakeAt.ToString('MM-dd HH:mm'))"; Details = [ordered]@{
            wakeAt = $plan.WakeAt; waitSec = $plan.WaitSec; quotaType = $quotaType
            latest = if ($plan.Latest) { $plan.Latest.ToString('o') } else { $null }
            targets = @($accounts | ForEach-Object { $_.Email })
        } }
    }

    $items = @()
    foreach ($f in (Get-RecentSessions)) {
        $fact = Get-SessionFact -File $f
        # 第二级判定：疑似撞墙的，用当前号的真实额度状态证实
        # （5 小时和周额度用同一个错误码，只能靠账号状态分辨）
        if ($fact.LimitHit -and -not $fact.LimitCertain -and $activeAcc) {
            $fiveDry = ($null -ne $activeAcc.FiveHour -and $activeAcc.FiveHour -le 0)
            $weekDry = ($null -ne $activeAcc.Weekly -and $activeAcc.Weekly -le 0)
            if ($fiveDry -or $weekDry) {
                $fact.LimitCertain = $true
                $which = if ($weekDry -and -not $fiveDry) { '周额度' }
                         elseif ($fiveDry -and -not $weekDry) { '5 小时窗口' }
                         else { '5 小时和 周额度' }
                $fact.LimitText = "$($fact.LimitText)  [已由账号状态证实：$which 已归零]"
                Write-Event "疑似撞墙信号已被账号状态证实（$which 归零）"
            }
        }
        $verdict = Get-SessionVerdict -Fact $fact
        if ($pendingCheck.Threads -contains $fact.ThreadId) {
            $verdict = [pscustomobject]@{ State = 'running'; IdleMin = $verdict.IdleMin; Say = '后台续跑进程仍在运行' }
        }
        $items += [pscustomobject]@{ Fact = $fact; Verdict = $verdict }
    }
    $best = @{}
    foreach ($it in $items) {
        $k = $it.Fact.ThreadId
        # 同一个 thread 可能有多个 rollout 文件，留"最新还在动"的那个。
        # ⚠️ 比的是真实活动时间，不是 Mtime（开着的文件 mtime 冻结，比不出来）
        if (-not $best.ContainsKey($k) -or
            ((Get-ActivityStamp $best[$k].Fact) -lt (Get-ActivityStamp $it.Fact))) { $best[$k] = $it }
    }
    $items = @($best.Values)

    # 给每个对话判一个"结局"：running / waiting / limit / interrupted / finished
    foreach ($it in $items) {
        $it | Add-Member -NotePropertyName Outcome `
                         -NotePropertyValue (Get-ConversationOutcome -Fact $it.Fact -Verdict $it.Verdict) -Force
    }

    $running = @($items | Where-Object { $_.Verdict.State -eq 'running' })
    $sleeping = @($items | Where-Object { $_.Verdict.State -eq 'sleeping' })
    $paused  = @($items | Where-Object { $_.Verdict.State -eq 'paused' })
    Write-Log ('会话：进行中 {0}，故意等待 {1}，停住 {2}，空闲 {3}（共 {4} 个）' -f `
        $running.Count, $sleeping.Count, $paused.Count,
        ($items.Count - $running.Count - $sleeping.Count - $paused.Count), $items.Count)
    if ($items.Count -gt 0) {
        $byOutcome = @($items | Group-Object Outcome | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })
        Write-Log ('  结局：' + ($byOutcome -join '，'))
    } else {
        # 用户常常"先开看护、再开 Codex"——这一刻没有任何对话是完全正常的，不是异常
        Write-Log '  还没有任何对话（Codex 可能刚启动），继续盯着就行'
    }
    foreach ($it in $sleeping) {
        Write-Log "   · 等待中 $($it.Fact.Name) — $($it.Verdict.Say)"
    }

    # 所有自动动作都以同一批最近对话为准，额度撞墙也不能绕过最近 N 条的边界。
    $lookbackCut = (Get-Date).AddMinutes(-$Script:Config.ResumeLookbackMin)
    $recent = @($items |
        Where-Object { (Get-ActivityStamp $_.Fact) -gt $lookbackCut } |
        Sort-Object { Get-ActivityStamp $_.Fact } -Descending |
        Select-Object -First $Script:Config.ResumeScanThreads)
    $unknown = @($recent | Where-Object { $_.Outcome -eq 'unknown' })
    if ($unknown.Count -gt 0) {
        return [pscustomobject]@{ Kind = 'needs-review'; Reason = '最近对话的回合标记读不到，不能确认是否正在运行'
            Details = @{ stopped = @($unknown | ForEach-Object { @{ thread=$_.Fact.ThreadId; file=$_.Fact.File; why='missing-marker' } }) } }
    }
    # 只处理"确定"的撞墙；只是疑似而不确定的，留给下面的 needs-review 分支交出去
    $hit = @($recent | Where-Object { $_.Verdict.State -eq 'paused' -and $_.Fact.LimitHit -and $_.Fact.LimitCertain })
    $unsureLimit = @($recent | Where-Object { $_.Verdict.State -eq 'paused' -and $_.Fact.LimitHit -and -not $_.Fact.LimitCertain })
    if ($unsureLimit.Count -gt 0) {
        Write-Event "有 $($unsureLimit.Count) 个对话有额度类报错但无法确认是哪个窗口（账号状态正常），交出去判断" 'WARN'
    }
    # ══════════════════════════════════════════════════════════════
    #  续跑决策：到底给谁发"继续"
    #  规则（用户明确指定）：
    #    · 只看最近的几条对话（ResumeLookbackMin / ResumeMaxThreads）
    #    · 分辨"正常结束"和"被中断"，**只给被中断的**发"继续"，
    #      绝不挨个都发
    #    · 每个"中断现场"只发一次（指纹去重，避免死循环刷屏）
    #    · 切号有两个触发条件：①对话撞墙了；②当前号的 5 小时归零了（主动切，
    #      用户明确要求"额度消耗光了切换账号"，不等撞墙）
    # ══════════════════════════════════════════════════════════════
    $handled = Get-HandledKeys -State $State

    $freshLimit = @($hit | Where-Object {
        $handled -notcontains (Get-LimitFingerprint -Fact $_.Fact) -and
        $handled -notcontains (Get-LegacyLimitFingerprint -Fact $_.Fact) -and
        $handled -notcontains (Get-ResumeFingerprint -Fact $_.Fact)
    })
    # ⚠️ 只对"还没处理过的"撞墙喊话。原来是无条件打印，于是只要对话文件里还留着那条
    #    撞墙记录，就每 10 秒喊一次"检测到 1 个对话撞上额度墙" —— 用户截图里那一片
    #    重复的 ALERT 就是这么来的（看着像死循环，其实早就处理完了）。
    if ($freshLimit.Count -gt 0) {
        Write-Event "检测到 $($freshLimit.Count) 个对话撞上额度墙（新的）" 'ALERT'
        foreach ($it in $freshLimit) {
            $hint = if ($it.Fact.LimitResetHint) { "（报错说 $($it.Fact.LimitResetHint) 恢复）" } else { '' }
            Write-Event "   · $($it.Fact.Name) 信号：$($it.Fact.LimitText) $hint"
        }
    } elseif ($hit.Count -gt 0) {
        Write-File "撞墙记录已处理过（$($hit.Count) 个），不再重复告警"
    }

    # ── 主动切号：当前号的 5 小时已经归零，就别等对话撞墙了 ──
    # 用户明确要求："额度消耗光了切换账号"。
    # 旧行为是"只有对话真的撞墙（rollout 里出现 usage limit）才切"，结果就是：
    # 余额早就 0% 了，脚本还在原地每 10 秒打一次"快撞墙了"的警告，
    # 甚至拿着 0% 的号去发"继续"（发完立刻又撞墙）。现在余额一归零就切。
    # 三道保险，防止"切不动"时每 10 秒重启一次 Codex：
    #   1) 必须真的有可切的号（$usable 非空）才切；
    #   2) 同一个"归零现场"只切一次（指纹 = 账号 id + 5h 重置时间）；
    #   3) 有对话正在跑就先不切，免得打断。
    $activeDry = ($activeAcc -and $null -ne $activeAcc.FiveHour -and $activeAcc.FiveHour -le 0)
    $dryFp     = if ($activeAcc) { 'dry:' + $activeAcc.Id + ':' + $activeAcc.FiveHourReset } else { $null }

    # 全部刷新后，无论窗口是否已经接近，都调用用户本机的额度定时器：
    # 对 list_accounts 返回的全部账号各消耗一次，然后才允许切号与续跑。
    $syncNote = $null
    if ($justRecovered) {
        $attemptId = [guid]::NewGuid().ToString('N')
        Set-StateFlag -State $waitFlag -Name 'phase' -Value 'running'
        Set-StateFlag -State $waitFlag -Name 'consumeAttemptId' -Value $attemptId
        Set-StateFlag -State $waitFlag -Name 'consumeAttemptedAt' -Value ((Get-Date).ToString('o'))
        if ($Live) { Save-State -State $State }
        Write-Event "全部账号已刷新 → 调用本机额度定时器，对全部 $($accounts.Count) 个账号各消耗一次" 'ALERT'
        $sync = Invoke-QuotaSchedulerOnce -Accounts $accounts
        if (-not $sync.Success) {
            Set-StateFlag -State $waitFlag -Name 'phase' -Value 'failed'
            Set-StateFlag -State $waitFlag -Name 'error' -Value $sync.Error
            if ($Live) { Save-State -State $State }
            return [pscustomobject]@{ Kind = 'needs-review'; Immediate = $true
                Reason = '全部账号额度刷新后，批量消耗没有完整成功；已禁止自动重试以免重复消耗'
                Details = @{ attemptId = $attemptId; error = $sync.Error; accounts = @($accounts | ForEach-Object { $_.Email }) } }
        }
        $syncNote = "已对全部 $($sync.Total) 个账号各消耗一次"
        Write-Event $syncNote 'OK'
        Set-StateFlag -State $waitFlag -Name 'phase' -Value 'success'
        if ($Live) {
            Save-State -State $State
            if ($Script:Config.ResumeSettleSec -gt 0) { Start-Sleep -Seconds $Script:Config.ResumeSettleSec }
            # 批量消耗后重新读取账号，选号必须使用最新额度。
            $accounts  = @(Get-Accounts)
            $weeklyAny = @($accounts | Where-Object { $null -ne $_.Weekly -and $_.Weekly -gt 0 })
            $activeList = @($accounts | Where-Object { $_.Active })
            $activeAcc = if ($activeList.Count -gt 0) { $activeList[0] } else { $null }
            $usable    = @(Get-UsableAccounts -Accounts $accounts)
            $activeDry = ($activeAcc -and $null -ne $activeAcc.FiveHour -and $activeAcc.FiveHour -le 0)
            $dryFp = if ($activeAcc) { 'dry:' + $activeAcc.Id + ':' + $activeAcc.FiveHourReset } else { $null }
        }
        Clear-StateFlag -State $State -Name 'waitingReset'
        if ($Live) { Save-State -State $State }
    }

    $needSwitch = ($freshLimit.Count -gt 0) -or $justRecovered -or
                  ($activeDry -and $usable.Count -gt 0 -and $dryFp -and ($handled -notcontains $dryFp))
    if ($justRecovered -and $activeAcc -and $activeAcc.FiveHour -gt 0 -and $activeAcc.Weekly -gt 0 -and $usable.Count -eq 0) {
        # The current account may be the only recovered account; it can resume without switching to itself.
        $needSwitch = $false
    }
    # 只在"真的要切"的时候说一次。原来这条是无条件的，只要当前号还是 0% 就每 10 秒
    # 喊一遍（切号还没生效 / 已经切过了都照喊），跟"快到墙了"那条一个毛病。
    if ($needSwitch -and $activeDry -and $usable.Count -gt 0 -and $freshLimit.Count -eq 0) {
        Write-Event "当前号（$($activeAcc.Email)）的 5 小时已经归零，可切号 $($usable.Count) 个 → 主动切号" 'WARN'
    }

    # 最近的那几条对话：按**真实活动时间**排序（mtime 对开着的文件是冻结的，排不出来）。
    # 用户说的是"最近的对话里找最近的几条" —— 按**条数**算，外面再套一个时间上限
    # （免得去复活很早以前的对话）。
    # 先把每一条的结局都记下来（"正常结束"的也留痕，方便人核对有没有漏发）
    if ($recent.Count -gt 0) {
        $byOutcome = @($recent | Group-Object Outcome | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })
        Write-File ('最近 ' + $recent.Count + ' 条对话的结局：' + ($byOutcome -join '，'))
    }
    $finished = @($recent | Where-Object { $_.Outcome -eq 'finished' })
    if ($finished.Count -gt 0) {
        Write-File ('正常结束，不发"继续"：' + (($finished | ForEach-Object {
            $_.Fact.ThreadId.Substring(0, 8) + '(' + $(if ($_.Fact.LastMarker) { $_.Fact.LastMarker } else { '标记读不到' }) + ')' }) -join '，'))
    }
    $unfinished = @($recent | Where-Object { $_.Outcome -eq 'unfinished' })
    foreach ($it in $unfinished) {
        $said = $it.Fact.LastAgentMessage
        if ($said.Length -gt 60) { $said = $said.Substring(0, 60) + '…' }
        Write-File "自己说没干完 → 继续催：$($it.Fact.ThreadId.Substring(0,8))「$said」"
    }

    # ---- 让它"看得见"：最近这几条到底判成什么，最后发没发 ----
    # 用户要的规则就是"看最近 5 条 → 有没有中断 → 有才发"，那就把这三步的结论摆出来，
    # 省得以后再出现"它到底看没看/为什么没发"的疑问。
    # ⚠️ 只在结论变化时吭一声 —— 每 10 秒刷一行会违背"控制台要安静"的要求。
    $scanNote = if ($recent.Count -eq 0) {
        '最近没有对话，无需判断'
    } else {
        $nBad  = @($recent | Where-Object { $_.Outcome -in @('interrupted', 'unfinished', 'limit') }).Count
        $nRun  = @($recent | Where-Object { $_.Outcome -eq 'running' }).Count
        $nWait = @($recent | Where-Object { $_.Outcome -eq 'waiting' }).Count
        $extra = @()
        if ($nRun  -gt 0) { $extra += "进行中 $nRun" }
        if ($nWait -gt 0) { $extra += "等待中 $nWait" }
        $suffix = if ($extra.Count -gt 0) { '（' + ($extra -join '，') + '，这些不碰）' } else { '' }
        if ($nBad -gt 0) {
            "最近 $($recent.Count) 条对话：有 $nBad 条中断 → 会给它们发`"继续`"$suffix"
        } else {
            "最近 $($recent.Count) 条对话：没有中断 → 一句`"继续`"都不发$suffix"
        }
    }
    if ($scanNote -ne $Script:LastScanNote) {
        $Script:LastScanNote = $scanNote
        Write-File $scanNote
    }

    # 只挑"被中断的 / 自认没干完的"：正常结束 / 正在跑 / 故意等待的一律不碰。
    # ⚠️ 名额只给这些，不让"正常结束"的对话占掉（否则最近三条恰好都是结束的，
    #    真正被中断的那条就永远排不上了）。
    # 刚被中断的先等 ResumeQuietMin 再动，别跟正在操作的人抢。
    $quietCut = (Get-Date).AddMinutes(-$Script:Config.ResumeQuietMin)
    $interrupted = @($recent | Where-Object {
        ($_.Outcome -eq 'interrupted' -or $_.Outcome -eq 'unfinished') -and
        (Get-ActivityStamp $_.Fact) -lt $quietCut
    } | Select-Object -First $Script:Config.ResumeMaxThreads)

    # 兜底：同一条对话自动续太多次还不见好 → 停手交给人，别和模型互相刷"继续"。
    # 次数直接从 handled 里数（键形如 res:<thread>:<时刻>），不用另外存状态。
    # ⚠️ 要用 foreach 而不是 Where-Object：管道里 $_ 是"键字符串"，
    #    在外层管道里再引用 $_ 会拿不到 .Fact（踩过）。
    $capped = @()
    $keep = @()
    foreach ($it in $interrupted) {
        $n = @($handled | Where-Object { $_ -like "res:$($it.Fact.ThreadId):*" }).Count
        if ($n -ge $Script:Config.ResumeMaxRounds) { $capped += $it } else { $keep += $it }
    }
    $interrupted = $keep
    foreach ($it in $capped) {
        Write-Event "这条对话已经自动续了 $($Script:Config.ResumeMaxRounds) 次还是没完（$($it.Fact.ThreadId.Substring(0,8))），不再自动催，交给你看一眼" 'ALERT'
    }

    $candidates = @()
    foreach ($it in @($freshLimit) + @($interrupted)) {
        if ($candidates -notcontains $it) { $candidates += $it }
    }
    $toResume = @($candidates | Where-Object { $handled -notcontains (Get-ResumeFingerprint -Fact $_.Fact) })

    if ($toResume.Count -gt 0 -or $needSwitch) {
        $switchedTo = $null
        if ($needSwitch) {
            # 切号会重启 Codex，续跑得等它起来
            if ($running.Count -gt 0 -or $sleeping.Count -gt 0 -or $pendingCheck.PendingCount -gt 0) {
                Write-Event "还有 $($running.Count) 个对话在跑，先不切号以免打断" 'WARN'
                return [pscustomobject]@{ Kind = 'wait'; Reason = '有对话仍在进行中或等待工具完成' }
            }
            $sel = Select-BestAccount -Accounts $accounts
            if ($null -eq $sel.Best) {
                # 只有"对话真的撞墙了"才收摊/报冷却。
                # 仅仅"当前号归零、其他号也在冷却"不算 —— 那只是暂时的，
                # 报出去会把看护自己弄退出，半夜白叫一次 AI。
                if ($freshLimit.Count -eq 0) {
                    Write-Event '当前号 5 小时已归零，但其他号也都在冷却，先不切，等窗口恢复' 'WARN'
                    return [pscustomobject]@{ Kind = 'wait'; Reason = '当前号已归零，暂时没有可切的号' }
                }
                if ($sel.AllDry) {
                    # 真·全空：连周额度都没了，等重置是唯一出路
                    return [pscustomobject]@{ Kind = 'stop'; Reason = '5 个账号额度全部耗尽（周额度也归零）'; Details = [ordered]@{
                        accounts = @($accounts | ForEach-Object { "$($_.Email) 5h=$($_.FiveHour)% 周=$($_.Weekly)%" })
                        stopped  = @($items | ForEach-Object { [ordered]@{ thread = $_.Fact.ThreadId; state = $_.Verdict.Say } })
                    } }
                }
                # 周额度还有 → 只是 5h 在冷却。不猜、不收摊，写清楚几点恢复交回 AI
                return [pscustomobject]@{ Kind = 'cooldown'; Reason = '所有可用账号的 5 小时窗口都在冷却，周额度仍有剩余'; Details = [ordered]@{
                    cooling = @($sel.Cooling | ForEach-Object {
                        [ordered]@{
                            email         = $_.Email
                            fiveHour      = $_.FiveHour
                            weekly        = $_.Weekly
                            fiveHourReset = (Format-ResetAt $_.FiveHourReset)
                            weeklyReset   = (Format-ResetAt $_.WeeklyReset)
                        }
                    })
                    activeFiveHour = $criticalRemain
                    hint           = '等最早那个 fiveHourReset 到点后重新运行看护即可，不需要换号'
                    stopped        = @($items | ForEach-Object { [ordered]@{ thread = $_.Fact.ThreadId; state = $_.Verdict.Say } })
                } }
            }
            $bestAcc = $sel.Best
            if (-not (Invoke-SwitchAccount -Account $bestAcc)) {
                return [pscustomobject]@{ Kind = 'needs-review'; Immediate = $true
                    Reason = '切号后未能确认目标账号已生效'
                    Details = @{ target = $bestAcc.Email; targetId = $bestAcc.Id } }
            }
            $switchedTo = $bestAcc.Email
            # 记下"这个号的这次归零已经处理过"，避免切号没生效时每 10 秒重启一次 Codex
            if ($Live -and $dryFp) {
                $State.handled | Add-Member -NotePropertyName $dryFp -NotePropertyValue ((Get-Date).ToString('o')) -Force
            }
            if ($Live -and $Script:Config.ResumeSettleSec -gt 0) {
                Write-Event "已确认切号，等 $($Script:Config.ResumeSettleSec) 秒让 Codex 完成重启"
                Start-Sleep -Seconds $Script:Config.ResumeSettleSec
            }
        }

        # 只给"被中断的 / 撞墙的"发继续；正常结束、正在跑、故意等待的一条都不碰
        $failed = @()
        foreach ($it in $toResume) {
            $tag = switch ($it.Outcome) {
                'limit'       { '撞墙' }
                'interrupted' { '被中断' }
                'unfinished'  { '自认没干完' }
                default       { $it.Outcome }
            }
            Write-File "选中续跑：$($it.Fact.ThreadId.Substring(0,8)) [$tag] lastMarker=$($it.Fact.LastMarker) idle=$([math]::Round($it.Verdict.IdleMin,1))分"
            $launch = Invoke-ResumeConversation -ThreadId $it.Fact.ThreadId -Label "$tag $($it.Fact.Name)" -WorkDir $it.Fact.WorkDir
            if (-not $launch) {
                $failed += $it.Fact.ThreadId
                continue
            }
            # 两个指纹都记上：既盖住"撞墙"这条线，也盖住"被中断"这条线，
            # 免得同一个中断现场被两条规则各续一次（那样就是重复发"继续"）
            # ⚠️ 只在真实动作模式下记：干跑（演习）绝不能落盘，
            #    否则干跑一次就把这个"中断现场"标成已处理，正式跑起来反而漏掉它。
            if ($Live -and $launch -is [pscustomobject] -and $launch.Async) {
                $State.pendingResumes | Add-Member -NotePropertyName $launch.JobId -NotePropertyValue ([pscustomobject]@{
                    JobId = $launch.JobId; ThreadId = $it.Fact.ThreadId
                    ResumeFp = Get-ResumeFingerprint -Fact $it.Fact
                    LimitFp = Get-LimitFingerprint -Fact $it.Fact
                    Pid = $launch.Pid; ProcessStartedAt = $launch.ProcessStartedAt
                    ResultFile = $launch.ResultFile; ErrorFile = $launch.ErrorFile; JobFile = $launch.JobFile
                }) -Force
                Save-State -State $State
            } elseif ($Live) {
                foreach ($fp in @((Get-ResumeFingerprint -Fact $it.Fact), (Get-LimitFingerprint -Fact $it.Fact))) {
                    $State.handled | Add-Member -NotePropertyName $fp -NotePropertyValue ((Get-Date).ToString('o')) -Force
                }
            }
            if ($Live) { Start-Sleep -Seconds $Script:Config.ResumeGapSec }
        }
        if ($Live) { Save-State -State $State }
        if ($failed.Count -gt 0) {
            return [pscustomobject]@{ Kind = 'needs-review'; Immediate = $true; Reason = '续跑指令发送失败'; Details = [ordered]@{
                failedThreads = $failed; switchedTo = $switchedTo
            } }
        }
        return [pscustomobject]@{
            Kind   = 'handled'
            Reason = $(
                $base = if ($switchedTo -and $toResume.Count -gt 0) { "已切到 $switchedTo，并只给中断的对话发了继续" }
                        elseif ($switchedTo)                        { "已切到 $switchedTo" }
                        else                                        { '只给中断的对话发了继续（没到需要切号的地步）' }
                if ($syncNote) { "$syncNote；$base" } else { $base }
            )
            Details = [ordered]@{
                switchedTo = $switchedTo
                resumed    = @($toResume | ForEach-Object { "$($_.Fact.ThreadId.Substring(0,8)) [$($_.Outcome)]" })
                skippedFinished = @($finished | ForEach-Object { $_.Fact.ThreadId.Substring(0,8) })
            }
        }
    } elseif ($hit.Count -gt 0) {
        Write-File '这些撞墙记录都已处理过，没有需要续跑的对话，跳过'
    }

    # 需要人工处理的"停住"，范围也卡在最近这几条里（用户规则第 4 条：不要看其他很早之前的）。
    # ⚠️ 不卡范围的话，一条几小时前的旧对话停着也会把 AI 叫起来 —— 叫一次就是实打实的额度。
    $odd = @($recent | Where-Object { $_.Verdict.State -eq 'paused' -and -not $_.Fact.LimitHit })
    $unsureRecent = @($recent | Where-Object {
        $_.Verdict.State -eq 'paused' -and $_.Fact.LimitHit -and -not $_.Fact.LimitCertain
    })
    $mystery = @($odd) + @($unsureRecent)
    if ($mystery.Count -gt 0) {
        $why = if ($unsureRecent.Count -gt 0 -and $odd.Count -eq 0) {
            '有对话有额度类报错，但账号状态正常，无法确认是哪个窗口撞墙'
        } elseif ($unsureRecent.Count -gt 0) {
            '有对话停住（部分疑似额度问题但无法确认）'
        } else {
            '有对话停住了，但不是额度问题'
        }
        return [pscustomobject]@{ Kind = 'needs-review'; Reason = $why; Details = [ordered]@{
            stopped = @($mystery | ForEach-Object { [ordered]@{
                thread       = $_.Fact.ThreadId
                file         = $_.Fact.Name
                why          = $_.Verdict.Say
                lastEvent    = $_.Fact.LastEvent
                # 模型收尾时自己说的话（能看出"是不是真干完了"）
                lastSaid     = if ($_.Fact.LastAgentMessage) { $_.Fact.LastAgentMessage.Substring(0, [Math]::Min(200, $_.Fact.LastAgentMessage.Length)) } else { $null }
                outcome      = $_.Outcome
                idleMin      = [math]::Round($_.Verdict.IdleMin, 1)
                # 留证：idle 是拿什么算的、mtime 当时是多少（开着的文件 mtime 是冻结值）
                idleFrom     = if ($_.Fact.LastActivityAt) { 'last-event-ts' } else { 'mtime-fallback' }
                mtime        = $_.Fact.Mtime.ToString('o')
                lastActivity = if ($_.Fact.LastActivityAt) { $_.Fact.LastActivityAt.ToString('o') } else { $null }
                sizeKB       = $_.Fact.SizeKB
                tool         = $_.Fact.PendingTool
                cmd          = $_.Fact.PendingCmd
                limitHit     = $_.Fact.LimitHit
                limitCertain = $_.Fact.LimitCertain
                limitText    = $_.Fact.LimitText
                resetHint    = $_.Fact.LimitResetHint
            } })
            activeAccount = if ($activeAcc) { "$($activeAcc.Email) 5h=$($activeAcc.FiveHour)% 周=$($activeAcc.Weekly)%" } else { '(未标记)' }
            quota = Get-QuotaSnapshot
        } }
    }

    $warnPct = $Script:Config.WarnPercent
    if ($criticalRemain -lt $warnPct) {
        # ⚠️ 只提醒**一次**。用户明确要求："每次额度低于 15% 之后它就一直报 warning，
        #    不需要这样，只需要出来一次就行了，后面不要每过 10 秒就来一次。"
        # 所以记住"已经为哪个号报过了"：同一个号还在警戒线以下就不再重复；
        # 换号（比如切号后新号也低）或者额度回到警戒线以上，才会再提醒一次。
        if ($Script:WarnedDryAccount -ne $criticalWho) {
            $Script:WarnedDryAccount = $criticalWho
            Write-Event "⚠ 注意：当前号（$criticalWho）的 5 小时只剩 $criticalRemain%，快到墙了" 'WARN'
        }
    } else {
        $Script:WarnedDryAccount = $null      # 回到警戒线以上，下次跌破时再提醒
    }
    Write-File "本轮正常：$criticalWho 5h=$criticalRemain% 可切号=$($usable.Count) 个"
    $sesLine = '进行中 {0}，故意等待 {1}，停住 {2}，空闲 {3}（共 {4} 个）' -f `
        $running.Count, $sleeping.Count, $paused.Count,
        ($items.Count - $running.Count - $sleeping.Count - $paused.Count), $items.Count
    return [pscustomobject]@{
        Kind           = 'ok'
        Reason         = '一切正常'
        Summary        = "$criticalWho 5h $criticalRemain% · 可切号 $($usable.Count) 个"
        SessionSummary = $sesLine
        QuotaSummary   = ($desc -join '  ')
    }
}

# ══════════════════════════════════════════════════════════════════
#  入口
# ══════════════════════════════════════════════════════════════════

function Wait-WithStatus {
    <#
      原地走秒。整个等待期间只有一行字，被反复改写——
      形如：已监控 5分30秒 · 当前号 5h 剩 99% · 可切号 2 个
      绝不新增行；只有事件才在它上面打印。
    #>
    param([int]$Seconds, [string]$Summary)
    $poll = [Math]::Max(1, [int]$Script:Config.StatusEverySec)
    $left = $Seconds
    while ($left -gt 0) {
        # ESC 检查要勤一点，按键才跟手；状态行的数字按 StatusEverySec 刷新
        $tick = [Math]::Min(1, $left)
        if ($left % $poll -eq 0 -or $left -eq $Seconds) {
            Show-StatusLine -Text ("已监控 {0} · {1}" -f (Get-Elapsed), $Summary)
        }
        Start-Sleep -Seconds $tick
        $left -= $tick
        # ESC 检查包一层：读键盘出任何意外都只降级，绝不打断裂监控
        try {
            if (Test-EscPressed) {
                $what = Invoke-Pause
                if ($what -eq 'exit') { return 'exit' }
            }
        } catch {
            $Script:KeyOk = $false
            Write-File "键盘监听失效，已降级（用 Ctrl+C 停止）：$($_.Exception.Message)"
        }
    }
    # 用最终秒数再刷一次，让计时看起来是连续的
    Show-StatusLine -Text ("已监控 {0} · {1}" -f (Get-Elapsed), $Summary)
    return 'ok'
}

function Wait-Until {
    <#
      睡到指定时刻再回来（用户明确要求：5 个号都用完时不要每 10 秒空转，
      而是按实时算出来的时间睡一大觉 —— 还差 1 小时 35 分，就 1 小时 36 分之后再来看）。
      实现上仍然 1 秒一跳：这样 ESC 暂停/退出照样跟手，状态行也一直在显示倒计时。
    #>
    param([datetime]$Time, [string]$Summary)
    $poll = [Math]::Max(1, [int]$Script:Config.StatusEverySec)
    $lastShown = -1
    while ($true) {
        $left = [int][Math]::Ceiling(($Time - (Get-Date)).TotalSeconds)
        if ($left -le 0) { break }
        if ($left % $poll -eq 0 -or $lastShown -lt 0) {
            $lastShown = $left
            Show-StatusLine -Text ("{0} · 还有 {1}（到 {2}）" -f $Summary, (Format-WaitSpan $left), $Time.ToString('HH:mm'))
        }
        Start-Sleep -Seconds 1
        # ESC 检查包一层：读键盘出任何意外都只降级，绝不打断裂监控
        try {
            if (Test-EscPressed) {
                $what = Invoke-Pause
                if ($what -eq 'exit') { return 'exit' }
            }
        } catch {
            $Script:KeyOk = $false
            Write-File "键盘监听失效，已降级（用 Ctrl+C 停止）：$($_.Exception.Message)"
        }
    }
    Show-StatusLine -Text ("{0} · 到点了，回来看" -f $Summary)
    return 'ok'
}

. (Join-Path $PSScriptRoot 'lib\desktop.ps1')
. (Join-Path $PSScriptRoot 'lib\manual-pause.ps1')
. (Join-Path $PSScriptRoot 'lib\engine-v2.ps1')

if ($LibraryOnly) { return }

try {
    if ($Live) {
        if (-not (Test-Path $Script:Config.StateDir)) { New-Item -ItemType Directory $Script:Config.StateDir -Force | Out-Null }
        try {
            $Script:RunLock = [IO.File]::Open((Join-Path $Script:Config.StateDir 'watcher.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        } catch {
            Write-Host '已有正式看护在运行（或状态目录无法写入），本次不重复启动。' -ForegroundColor Yellow
            exit 2
        }
    }
    Initialize-Paths
    Initialize-TrayControl
    # 状态行要不要开：只有支持 ANSI 原地覆盖才显示，否则宁可不显示也绝不刷屏
    $Script:AnsiOk = $false
    if ($Script:Config.QuietConsole) {
        $Script:AnsiOk = Enable-AnsiConsole
        if (-not $Script:AnsiOk) {
            Write-File '这个终端不支持原地刷新，本轮不显示状态行（只在出事时打印）' 'WARN'
        }
    }
    $Script:Paused = $false
    # 防抖用：上一轮"疑似停住"的会话签名（null = 没有待复核的）
    $Script:PendingReviewSig = $null
    # 关掉快速编辑模式：避免"在窗口里点一下鼠标就把整个看护冻住"
    switch (Disable-QuickEdit) {
        'ok'         { Write-File '已关闭控制台快速编辑模式（鼠标点选不会再冻住看护）' }
        'no-console' { Write-File '当前没有控制台窗口（输出被重定向），快速编辑模式无需处理' }
        default      { Write-File '没能关闭控制台快速编辑模式：在窗口里点选/拖动可能让看护暂时卡住（点一下再按回车就恢复）' 'WARN' }
    }
    $null = Initialize-Keyboard
    Write-File "脚本位置：$PSCommandPath"
    Write-File "轮询间隔 $($Script:Config.PollSeconds) 秒；平时安静，只有出事才吭声"
    if ($Script:KeyOk) {
        Write-File '按一次 ESC 暂停，暂停中再按一次 ESC 退出'
    } else {
        Write-File '当前环境读不到键盘，ESC 控制不可用（用 Ctrl+C 停止）' 'WARN'
    }

    $state = Read-State
    Start-WatchLoop -State $state -MaxRounds $MaxRounds -Once:$Once
    exit 0

} catch {
    $msg = $_.Exception.Message
    $pos = $_.InvocationInfo.PositionMessage
    Write-Log "未捕获异常：$msg" 'FATAL'
    Write-Log $pos 'FATAL'
    $null = Write-Report -Code 2 -Reason '脚本未捕获异常' -Details @{ error = $msg; at = "$pos" }
    try { Request-ManualPause ([pscustomobject]@{}) 'fatal' '脚本未捕获异常' @{error=$msg;position=$pos} } catch { }
    if(-not $Once){Wait-ManualPause}
    exit 2
} finally {
    Set-TrayPauseStatus -Paused $false
    if ($Script:RunLock) { $Script:RunLock.Dispose(); $Script:RunLock = $null }
}
