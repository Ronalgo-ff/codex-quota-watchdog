# 5 个号全用完时的"等窗口刷新 + 同步消耗"测试
#
# 用户 2026-09-27 定的方案：
#   1. 全部耗尽 → 不收摊，算好"最晚那个号什么时候刷新"，睡到那个点 +N 秒再回来看
#   2. 等全部账号都刷新后，无论窗口是否对齐，都调用本机额度定时器一次
#   3. 然后按老规则切到周额度最多的号，只给中断的对话发"继续"
#   4. 周额度全部归零时改等 WeeklyReset，不提前收摊
#
# 这里只做"纯逻辑"验证：不切真号、不真调 consume、不写真实状态文件。

$ap = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path $env:TEMP ('wait-reset-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$code = Get-Content (Join-Path $ap 'codex-autopilot.ps1') -Raw -Encoding UTF8
$cut = $code.IndexOf('#  入口')
if ($cut -lt 0) { Write-Host '找不到入口标记' -ForegroundColor Red; exit 1 }
$body = $code.Substring(0, $cut)
$body = [regex]::Replace($body, '(?s)^\s*<#.*?#>\s*\[CmdletBinding\(\)\]\s*param\(.*?\)\s*', '')
$body = [regex]::Replace($body, '(?ms)^\$Script:RulesFile\s*=.*?^\$Script:RulesApplied\s*=.*?$', '')

$hf = Join-Path $tmp 'harness.ps1'
[System.IO.File]::WriteAllText($hf, $body, (New-Object System.Text.UTF8Encoding($true)))

$test = @"

`$Script:Config.SessionRoot       = '$tmp'
`$Script:Config.SessionMaxAgeMin  = 600
`$Script:Config.ResumeScanThreads = 5
`$Script:Config.ResumeLookbackMin = 720
`$Script:Config.ResumeMaxThreads  = 5
`$Script:Config.ResumeQuietMin    = 2
`$Script:Config.ResumeGapSec      = 0
`$Script:Config.ResumeSettleSec   = 0
`$Script:Config.ConsumeGapSec     = 0
`$Script:Config.WaitForResetEnabled = `$true
`$Script:Config.WakeBufferSec     = 60
`$Script:Config.QuotaSchedulerTimeoutSec = 30
`$Live = `$true

function Write-Log  { param([string]`$Message, [string]`$Level='INFO') }
function Write-File { param([string]`$Message, [string]`$Level='INFO') }
function Write-Event{ param([string]`$Message, [string]`$Level='INFO') }
function Save-State { param(`$State) }            # 不写真实状态文件
function Get-QuotaSnapshot { return `$null }

# 记录版：不切真号、不发真消息、不真消耗
`$script:Switched = @()
`$script:Resumed  = @()
`$script:Consumed = @()
`$script:SchedulerCalls = 0
`$script:SchedulerAccounts = @()
`$script:SchedulerShouldFail = `$false
function Invoke-SwitchAccount { param(`$Account) `$script:Switched += `$Account.Email; return `$true }
function Invoke-ResumeConversation { param([string]`$ThreadId, [string]`$Label) `$script:Resumed += `$ThreadId; return `$true }
function Invoke-Csw {
    param([string]`$Command, [hashtable]`$Arguments = @{})
    if (`$Command -eq 'consume_account_quota') { `$script:Consumed += `$Arguments.id; return `$true }
    return `$null
}
function Invoke-QuotaSchedulerOnce {
    param(`$Accounts)
    `$script:SchedulerCalls++
    `$script:SchedulerAccounts = @(`$Accounts | ForEach-Object { `$_.Id })
    if (`$script:SchedulerShouldFail) {
        return [pscustomobject]@{Success=`$false;ExitCode=2;Total=@(`$Accounts).Count;Error='simulated partial failure'}
    }
    return [pscustomobject]@{Success=`$true;ExitCode=0;Total=@(`$Accounts).Count;Error=`$null}
}

# 假账号表（每个场景自己改）
`$script:Acc = @()
function Get-Accounts { return `$script:Acc }
function Acc([string]`$email, [string]`$id, [bool]`$active, [double]`$five, [double]`$week, [double]`$resetInMin) {
    return [pscustomobject]@{
        Email=`$email; Id=`$id; Active=`$active; Switchable=`$true
        FiveHour=`$five; Weekly=`$week
        FiveHourReset=[int64]([DateTimeOffset]::UtcNow.AddMinutes(`$resetInMin).ToUnixTimeSeconds())
        WeeklyReset=[int64]([DateTimeOffset]::UtcNow.AddDays(3).ToUnixTimeSeconds())
        UsageError=`$null
    }
}

`$pass = 0; `$fail = 0
function Check(`$n, `$c, `$d) {
    if (`$c) { `$script:pass++; Write-Host "  [PASS] `$n" -ForegroundColor Green }
    else { `$script:fail++; Write-Host "  [FAIL] `$n  -- `$d" -ForegroundColor Red }
}
function TS([double]`$m) { return (Get-Date).ToUniversalTime().AddMinutes(-`$m).ToString('yyyy-MM-ddTHH:mm:ss.fff') + 'Z' }
`$st  = '{"timestamp":"__T__","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}'
`$ab  = '{"timestamp":"__T__","ordinal":3,"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t1","reason":"interrupted"}}'
function L([string]`$t,[double]`$m) { return `$t.Replace('__T__', (TS `$m)) }
function New-Session([string]`$th,[string[]]`$lines) {
    `$p = Join-Path '$tmp' ("rollout-2026-09-27T00-00-00-" + `$th + '.jsonl')
    [System.IO.File]::WriteAllLines(`$p, `$lines, (New-Object System.Text.UTF8Encoding(`$false)))
}
function Reset-Fixtures { Get-ChildItem '$tmp' -Filter '*.jsonl' | Remove-Item -Force -ErrorAction SilentlyContinue }
`$thX='01a0beef-0000-0000-0000-00000000000f'   # 被中断的对话（必须是合法十六进制，否则线程 ID 认不出来）
function New-State { return [pscustomobject]@{ handled = [pscustomobject]@{} } }

Write-Host ''
Write-Host '=== 1. 5 个号 5h 全空（周额度还有）→ 不收摊，算好时间睡一觉 ===' -ForegroundColor Cyan
Reset-Fixtures
`$script:Acc = @(
    (Acc 'a@x.com' 'id-a' `$true  0 50 60),      # 最早刷新：60 分钟后
    (Acc 'b@x.com' 'id-b' `$false 0 40 100),     # 最晚刷新：100 分钟后
    (Acc 'c@x.com' 'id-c' `$false 0 30 80)
)
`$script:Consumed=@(); `$script:Switched=@()
`$state = New-State
`$r = Invoke-Round -State `$state
Check '判为"等窗口刷新"，不是收摊' (`$r.Kind -eq 'wait-reset') "Kind=`$(`$r.Kind)"
Check '醒来的时刻 = 最晚那个刷新 + 60 秒' ((`$r.Details.wakeAt - (Get-Date)).TotalMinutes -gt 100 -and (`$r.Details.wakeAt - (Get-Date)).TotalMinutes -lt 103) ("还差 {0:N1} 分钟" -f (`$r.Details.wakeAt - (Get-Date)).TotalMinutes)
Check '记下了等待状态（醒来后才好接着办）' (`$null -ne (Get-StateFlag -State `$state -Name 'waitingReset')) 'flag 没设上'
Check '等待期间没有乱切号' (`$script:Switched.Count -eq 0) "switch=`$(`$script:Switched -join ',')"

Write-Host ''
Write-Host '=== 2. 周额度也全部归零 → 等最晚 WeeklyReset，不收摊 ===' -ForegroundColor Cyan
`$script:Acc = @(
    (Acc 'a@x.com' 'id-a' `$true  0 0 60),
    (Acc 'b@x.com' 'id-b' `$false 0 0 100)
)
`$state = New-State
`$r = Invoke-Round -State `$state
Check '判为等待全部窗口刷新' (`$r.Kind -eq 'wait-reset' -and `$r.Details.quotaType -eq 'all') "Kind=`$(`$r.Kind) type=`$(`$r.Details.quotaType)"

Write-Host ''
Write-Host '=== 3. 睡醒后：窗口明显错开 → 同步消耗 + 切号 + 只续中断的 ===' -ForegroundColor Cyan
Reset-Fixtures
New-Session `$thX @((L `$st 20), (L `$ab 19))       # 被中断的对话
`$script:Acc = @(
    (Acc 'a@x.com' 'id-a' `$true  100 50 300),       # 窗口差很大（300 / 200 / 60 分钟）
    (Acc 'b@x.com' 'id-b' `$false 100 40 200),
    (Acc 'c@x.com' 'id-c' `$false 100 90 60)
)
`$state = New-State
Set-StateFlag -State `$state -Name 'waitingReset' -Value ([pscustomobject]@{ since='x'; wakeAt='y'; quotaType='five-hour'; phase='waiting' })
`$script:Consumed=@(); `$script:Switched=@(); `$script:Resumed=@(); `$script:SchedulerCalls=0; `$script:SchedulerShouldFail=`$false
`$r = Invoke-Round -State `$state
Check '本机额度定时器只调用一次' (`$script:SchedulerCalls -eq 1) "calls=`$script:SchedulerCalls"
Check '定时器收到全部 3 个账号' (`$script:SchedulerAccounts.Count -eq 3) "accounts=`$(`$script:SchedulerAccounts -join ',')"
Check '切到了周额度最多的 c@x.com' (`$script:Switched -contains 'c@x.com') "switch=`$(`$script:Switched -join ',')"
Check '只续了那条被中断的对话' (`$script:Resumed.Count -eq 1 -and `$script:Resumed -contains `$thX) "resumed=`$(`$script:Resumed -join ',')"
Check '等待状态已清掉' (`$null -eq (Get-StateFlag -State `$state -Name 'waitingReset')) 'flag 还在'
Check '结果里写明全部账号各消耗一次' (`$r.Reason -match '全部 3 个账号各消耗一次') "reason=`$(`$r.Reason)"

Write-Host ''
Write-Host '=== 4. 窗口本来就齐 → 仍按需求批量消耗一次 ===' -ForegroundColor Cyan
Reset-Fixtures
New-Session `$thX @((L `$st 20), (L `$ab 19))
`$script:Acc = @(
    (Acc 'a@x.com' 'id-a' `$true  100 50 300),
    (Acc 'b@x.com' 'id-b' `$false 100 40 301),       # 只差 1 分钟
    (Acc 'c@x.com' 'id-c' `$false 100 90 299)
)
`$state = New-State
Set-StateFlag -State `$state -Name 'waitingReset' -Value ([pscustomobject]@{ since='x'; wakeAt='y'; quotaType='five-hour'; phase='waiting' })
`$script:Consumed=@(); `$script:Switched=@(); `$script:Resumed=@(); `$script:SchedulerCalls=0
`$r = Invoke-Round -State `$state
Check '窗口对齐时仍调用一次定时器' (`$script:SchedulerCalls -eq 1) "calls=`$script:SchedulerCalls"
Check '照样切号 + 续跑' (`$script:Switched.Count -eq 1 -and `$script:Resumed -contains `$thX) "switch=`$(`$script:Switched -join ',') resumed=`$(`$script:Resumed -join ',')"
Check '等待状态也清掉了' (`$null -eq (Get-StateFlag -State `$state -Name 'waitingReset')) 'flag 还在'

Write-Host ''
Write-Host '=== 5. 全部账号就绪后，批量入口包含所有账号 ===' -ForegroundColor Cyan
Reset-Fixtures
`$script:Acc = @(
    (Acc 'a@x.com' 'id-a' `$true  100 10 300),
    (Acc 'b@x.com' 'id-b' `$false 100 40 200),
    (Acc 'c@x.com' 'id-c' `$false 100 90 60)
)
`$state = New-State
Set-StateFlag -State `$state -Name 'waitingReset' -Value ([pscustomobject]@{ since='x'; wakeAt='y'; quotaType='five-hour'; phase='waiting' })
`$script:Consumed=@(); `$script:SchedulerCalls=0
`$r = Invoke-Round -State `$state
Check '定时器仍只调用一次' (`$script:SchedulerCalls -eq 1) "calls=`$script:SchedulerCalls"
Check '三个账号全部交给定时器' (`$script:SchedulerAccounts.Count -eq 3 -and `$script:SchedulerAccounts -contains 'id-a') "accounts=`$(`$script:SchedulerAccounts -join ',')"

Write-Host ''
Write-Host '=== 6. 看护中途重启：只刷新一个号时不能提前消耗 ===' -ForegroundColor Cyan
Reset-Fixtures
`$script:Acc = @(
    (Acc 'a@x.com' 'id-a' `$true  100 50 60),
    (Acc 'b@x.com' 'id-b' `$false 0   40 100),
    (Acc 'c@x.com' 'id-c' `$false 0   30 80)
)
`$state = New-State
Set-StateFlag -State `$state -Name 'waitingReset' -Value ([pscustomobject]@{since='x';wakeAt=(Get-Date).AddMinutes(90).ToString('o');quotaType='five-hour';phase='waiting'})
`$script:SchedulerCalls=0
`$r = Invoke-Round -State `$state
Check '仍然等待其余账号刷新' (`$r.Kind -eq 'wait-reset') "Kind=`$(`$r.Kind)"
Check '没有提前调用定时器' (`$script:SchedulerCalls -eq 0) "calls=`$script:SchedulerCalls"

Write-Host ''
Write-Host '=== 7. 批量消耗失败后禁止自动重试，避免重复扣额度 ===' -ForegroundColor Cyan
`$script:Acc = @(
    (Acc 'a@x.com' 'id-a' `$true  100 50 60),
    (Acc 'b@x.com' 'id-b' `$false 100 40 100),
    (Acc 'c@x.com' 'id-c' `$false 100 30 80)
)
`$state = New-State
Set-StateFlag -State `$state -Name 'waitingReset' -Value ([pscustomobject]@{since='x';wakeAt='y';quotaType='five-hour';phase='waiting'})
`$script:SchedulerCalls=0; `$script:SchedulerShouldFail=`$true
`$r1 = Invoke-Round -State `$state
`$r2 = Invoke-Round -State `$state
Check '第一次失败保存人工报告' (`$r1.Kind -eq 'needs-review') "Kind=`$(`$r1.Kind)"
Check '第二轮不再次调用定时器' (`$r2.Kind -eq 'needs-review' -and `$script:SchedulerCalls -eq 1) "calls=`$script:SchedulerCalls"

Write-Host ''
Write-Host '=== 8. 5 小时已恢复但仍有周额度为 0 → 继续等待，不提前消耗 ===' -ForegroundColor Cyan
`$script:Acc = @(
    (Acc 'a@x.com' 'id-a' `$true  100 0  60),
    (Acc 'b@x.com' 'id-b' `$false 100 40 100),
    (Acc 'c@x.com' 'id-c' `$false 100 30 80)
)
`$state = New-State
Set-StateFlag -State `$state -Name 'waitingReset' -Value ([pscustomobject]@{since='x';wakeAt=(Get-Date).AddHours(1).ToString('o');quotaType='all';phase='waiting'})
`$script:SchedulerCalls=0; `$script:SchedulerShouldFail=`$false
`$r = Invoke-Round -State `$state
Check '仍然等待周额度未恢复的账号' (`$r.Kind -eq 'wait-reset') "Kind=`$(`$r.Kind)"
Check '没有调用批量消耗' (`$script:SchedulerCalls -eq 0) "calls=`$script:SchedulerCalls"

Write-Host ''
Write-Host '=== 9. 等待期间账号列表变化 → 停止自动批量消耗 ===' -ForegroundColor Cyan
`$script:Acc = @(
    (Acc 'new-a@x.com' 'new-a' `$true  100 50 60),
    (Acc 'new-b@x.com' 'new-b' `$false 100 40 100)
)
`$state = New-State
Set-StateFlag -State `$state -Name 'waitingReset' -Value ([pscustomobject]@{since='x';wakeAt='y';quotaType='all';phase='waiting';accountIds=@('id-a','id-b','id-c')})
`$script:SchedulerCalls=0
`$r = Invoke-Round -State `$state
Check '账号集合变化保存人工报告' (`$r.Kind -eq 'needs-review' -and `$r.Immediate) "Kind=`$(`$r.Kind)"
Check '没有对意外账号执行批量消耗' (`$script:SchedulerCalls -eq 0) "calls=`$script:SchedulerCalls"

Write-Host ''
Write-Host ("  通过 `$pass 项，失败 `$fail 项") -ForegroundColor `$(if (`$fail -eq 0) { 'Green' } else { 'Red' })
Set-Location `$env:TEMP
Remove-Item '$tmp' -Recurse -Force -ErrorAction SilentlyContinue
exit `$(if (`$fail -eq 0) { 0 } else { 1 })
"@

[System.IO.File]::AppendAllText($hf, $test, (New-Object System.Text.UTF8Encoding($true)))
& $hf
exit $LASTEXITCODE
