# 撞墙信号检测测试（含"周额度撞墙"这个特殊情况）
#
# 背景：5 小时窗口和周窗口撞墙用的是**同一个错误码** usage_limit_exceeded，
# 而 rate_limits.limit_name 是 null，光看错误码分不出是哪个窗口。
# 所以脚本用两级判定：
#   A. 明确错误码 → 直接确定
#   B. 措辞类信号 → 标记为疑似，再用当前号的真实额度状态证实

$src = Join-Path (Split-Path $PSScriptRoot -Parent) 'codex-autopilot.ps1'
$tmp = Join-Path $env:TEMP ('autopilot-limit-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

Write-Host ''
Write-Host '构造 3 个合成会话文件...' -ForegroundColor Cyan

function Write-Session {
    param([string]$Name, [string[]]$Lines)
    $p = Join-Path $tmp $Name
    # Keep synthetic session events recent; a fixed 2026-09-27 timestamp expires.
    $started=(Get-Date).ToUniversalTime().AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $ended=(Get-Date).ToUniversalTime().AddMinutes(-2).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $Lines=@($Lines|ForEach-Object { $_.Replace('2026-09-27T08:00:00.000Z',$started).Replace('2026-09-27T08:05:00.000Z',$ended) })
    [System.IO.File]::WriteAllLines($p, $Lines, (New-Object System.Text.UTF8Encoding($false)))
    return $p
}

$threadA = '01a0aaaa-1111-2222-3333-444444444444'
$threadB = '01a0bbbb-1111-2222-3333-444444444444'
$threadC = '01a0cccc-1111-2222-3333-444444444444'

# 场景 A：周额度撞墙——只有措辞，没有明确错误码（模拟 csw 报周额度用尽）
$a = Write-Session "rollout-2026-09-27T16-00-00-$threadA.jsonl" @(
    '{"timestamp":"2026-09-27T08:00:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}',
    '{"timestamp":"2026-09-27T08:05:00.000Z","ordinal":2,"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","error":{"message":"You''ve hit your usage limit. Upgrade to Pro or try again at 3:00 PM.","codex_error_info":"other"}}}'
)

# 场景 B：明确错误码（5 小时或周额度都用这个码）
$b = Write-Session "rollout-2026-09-27T16-00-00-$threadB.jsonl" @(
    '{"timestamp":"2026-09-27T08:00:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}',
    '{"timestamp":"2026-09-27T08:05:00.000Z","ordinal":2,"type":"event_msg","payload":{"type":"task_complete","turn_id":"t2","error":{"message":"You''ve hit your usage limit.","codex_error_info":"usage_limit_exceeded"}}}'
)

# 场景 C：完全正常的会话，不该被误判
$c = Write-Session "rollout-2026-09-27T16-00-00-$threadC.jsonl" @(
    '{"timestamp":"2026-09-27T08:00:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"t3"}}',
    '{"timestamp":"2026-09-27T08:05:00.000Z","ordinal":2,"type":"event_msg","payload":{"type":"task_completed","turn_id":"t3"}}'
)

# 加载主脚本的函数（跳过入口）
$code = Get-Content $src -Raw -Encoding UTF8
$cut = $code.IndexOf('# ══════════════════════════════════════════════════════════════════' + "`r`n" + '#  入口')
if ($cut -lt 0) { $cut = $code.IndexOf('#  入口') }
$body = $code.Substring(0, $cut)
# 去掉 param 块
$body = [regex]::Replace($body, '(?s)^\s*<#.*?#>\s*\[CmdletBinding\(\)\]\s*param\(.*?\)\s*', '')

$harness = @"
`$Script:LogFile = `$null
$body
"@
$hf = Join-Path $tmp 'harness.ps1'
[System.IO.File]::WriteAllText($hf, $harness, (New-Object System.Text.UTF8Encoding($true)))

$test = @"

# 覆盖配置，指向测试目录
`$Script:Config.SessionRoot = '$tmp'
`$Script:Config.SessionMaxAgeMin = 1440

function Write-Log { param([string]`$Message, [string]`$Level='INFO'); Write-Host "     [`$Level] `$Message" }

`$pass = 0; `$fail = 0
function Check(`$n, `$c, `$d) {
    if (`$c) { `$script:pass++; Write-Host "  [PASS] `$n" -ForegroundColor Green }
    else { `$script:fail++; Write-Host "  [FAIL] `$n  -- `$d" -ForegroundColor Red }
}

`$files = @(Get-RecentSessions)
Write-Host ""
Write-Host "扫到 `$(`$files.Count) 个测试会话"
`$facts = @{}
foreach (`$f in `$files) { `$x = Get-SessionFact -File `$f; `$facts[`$x.ThreadId] = `$x }

Write-Host ''
Write-Host '=== A. 周额度撞墙（只有措辞，无明确错误码）===' -ForegroundColor Cyan
`$fa = `$facts['$threadA']
Check '识别为撞墙' (`$fa.LimitHit) "LimitHit=`$(`$fa.LimitHit)"
Check '标记为"疑似"（未证实）' (-not `$fa.LimitCertain) "LimitCertain=`$(`$fa.LimitCertain)"
Check '能抠出恢复时间提示' (`$fa.LimitResetHint -match '3:00') "hint=`$(`$fa.LimitResetHint)"

Write-Host ''
Write-Host '=== B. 明确错误码 ===' -ForegroundColor Cyan
`$fb = `$facts['$threadB']
Check '识别为撞墙' (`$fb.LimitHit) "LimitHit=`$(`$fb.LimitHit)"
Check '标记为"确定"' (`$fb.LimitCertain) "LimitCertain=`$(`$fb.LimitCertain)"

Write-Host ''
Write-Host '=== C. 正常会话不该误报 ===' -ForegroundColor Cyan
`$fc = `$facts['$threadC']
Check '未识别为撞墙' (-not `$fc.LimitHit) "LimitHit=`$(`$fc.LimitHit)"

Write-Host ''
Write-Host '=== D. 第二级判定：用账号状态证实"疑似" ===' -ForegroundColor Cyan
function Confirm-WithAccountState {
    param(`$Fact, `$ActiveAcc)
    if (`$Fact.LimitHit -and -not `$Fact.LimitCertain -and `$ActiveAcc) {
        `$fiveDry = (`$null -ne `$ActiveAcc.FiveHour -and `$ActiveAcc.FiveHour -le 0)
        `$weekDry = (`$null -ne `$ActiveAcc.Weekly -and `$ActiveAcc.Weekly -le 0)
        if (`$fiveDry -or `$weekDry) {
            `$Fact.LimitCertain = `$true
            `$which = if (`$weekDry -and -not `$fiveDry) { '周额度' }
                     elseif (`$fiveDry -and -not `$weekDry) { '5 小时窗口' }
                     else { '5 小时和 周额度' }
            `$Fact.LimitText = "`$(`$Fact.LimitText)  [已由账号状态证实：`$which 已归零]"
        }
    }
    return `$Fact
}

`$d1 = Confirm-WithAccountState -Fact (`$facts['$threadA'] | Select-Object *) -ActiveAcc ([pscustomobject]@{ Email='x@y.com'; FiveHour=99; Weekly=0 })
Check '周额度归零 → 证实为确定' (`$d1.LimitCertain) "LimitCertain=`$(`$d1.LimitCertain)"
Check '指明是"周额度"归零' (`$d1.LimitText -match '周额度 已归零') "text=`$(`$d1.LimitText)"

`$d2 = Confirm-WithAccountState -Fact (`$facts['$threadA'] | Select-Object *) -ActiveAcc ([pscustomobject]@{ Email='x@y.com'; FiveHour=0; Weekly=55 })
Check '5 小时归零 → 证实为确定' (`$d2.LimitCertain) "LimitCertain=`$(`$d2.LimitCertain)"
Check '指明是"5 小时窗口"归零' (`$d2.LimitText -match '5 小时窗口 已归零') "text=`$(`$d2.LimitText)"

`$d3 = Confirm-WithAccountState -Fact (`$facts['$threadA'] | Select-Object *) -ActiveAcc ([pscustomobject]@{ Email='x@y.com'; FiveHour=88; Weekly=55 })
Check '账号状态正常 → 不证实，交出去判断' (-not `$d3.LimitCertain) "LimitCertain=`$(`$d3.LimitCertain)"

Write-Host ''
Write-Host ("  通过 `$pass 项，失败 `$fail 项") -ForegroundColor `$(if (`$fail -eq 0) { 'Green' } else { 'Red' })
Remove-Item '$tmp' -Recurse -Force -ErrorAction SilentlyContinue
exit `$(if (`$fail -eq 0) { 0 } else { 1 })
"@

[System.IO.File]::AppendAllText($hf, $test, (New-Object System.Text.UTF8Encoding($false)))
& $hf
