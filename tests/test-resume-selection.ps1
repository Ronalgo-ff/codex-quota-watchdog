# 续跑选择测试 —— 对应用户明确提出的三个场景
#
#   1. 初始状态：看护先启动、Codex 还没有任何对话 → 不能报错，正常继续盯
#   2. 账号切换：额度耗尽切号后，去最近的对话里挑最近的几条，
#      分辨"正常结束"和"被中断"
#   3. 继续对话：**只给被中断的**发"继续"，正常结束的一条都不发
#
# 做法：把主脚本的"函数部分"抽出来当库（跳过入口），然后：
#   · 把 SessionRoot 指到临时目录
#   · 把 Get-Accounts / Invoke-SwitchAccount / Invoke-ResumeConversation / Save-State
#     全部换成记录版，绝不碰真实账号、绝不发真的 codex queue、绝不写真实状态文件

$src = Join-Path (Split-Path $PSScriptRoot -Parent) 'codex-autopilot.ps1'
$tmp = Join-Path $env:TEMP ('autopilot-resume-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# 加载主脚本的函数（跳过入口）
$code = Get-Content $src -Raw -Encoding UTF8
$cut = $code.IndexOf('# ══════════════════════════════════════════════════════════════════' + "`r`n" + '#  入口')
if ($cut -lt 0) { $cut = $code.IndexOf('#  入口') }
if ($cut -lt 0) { Write-Host '找不到入口标记，测试无法运行' -ForegroundColor Red; exit 1 }
$body = $code.Substring(0, $cut)
$body = [regex]::Replace($body, '(?s)^\s*<#.*?#>\s*\[CmdletBinding\(\)\]\s*param\(.*?\)\s*', '')

$hf = Join-Path $tmp 'harness.ps1'
[System.IO.File]::WriteAllText($hf, $body, (New-Object System.Text.UTF8Encoding($true)))

$test = @"

# ---- 测试环境 ----
# 配置跟生产保持一致（用户 2026-09-27 定的规则：只看最近 5 条，只有中断才发）
`$Script:Config.SessionRoot      = '$tmp'
`$Script:Config.SessionMaxAgeMin = 600
`$Script:Config.ResumeScanThreads = 5
`$Script:Config.ResumeLookbackMin = 720
`$Script:Config.ResumeMaxThreads  = 5
`$Script:Config.ResumeQuietMin    = 2
`$Script:Config.StalledMin        = 3
`$Script:Config.InFlightMin       = 3
# 测试里两种模式都要跑：
#   $Live=$true  → 走"记录指纹"那条路（本轮测试自己就是靠它验证去重）
#   $Live=$false → 干跑，**绝不能落盘**（下面有专门的回归用例）
`$Script:Config.ResumeGapSec     = 0
`$Script:Config.ResumeSettleSec  = 0
`$Live = `$true

function Write-Log  { param([string]`$Message, [string]`$Level='INFO') }
function Write-File { param([string]`$Message, [string]`$Level='INFO') }
function Write-Event{ param([string]`$Message, [string]`$Level='INFO') }
function Save-State { param(`$State) }          # 绝不写真实状态文件
function Get-QuotaSnapshot { return `$null }

# 记录版：不切真号、不发真消息
`$script:Switched = @()
`$script:Resumed  = @()
function Invoke-SwitchAccount { param(`$Account) `$script:Switched += `$Account.Email; return `$true }
function Invoke-ResumeConversation { param([string]`$ThreadId, [string]`$Label) `$script:Resumed += `$ThreadId; return `$true }

# 假账号：当前号 5h 归零（这样"疑似撞墙"能被证实），另有一个满血号可切
function Get-Accounts {
    return @(
        [pscustomobject]@{ Email='active@x.com'; Id='id-active'; Active=`$true;  Switchable=`$true; FiveHour=`$script:ActiveFive; Weekly=50; FiveHourReset=(Get-Date).AddMinutes(30); WeeklyReset=(Get-Date).AddDays(3) },
        [pscustomobject]@{ Email='fresh@x.com';  Id='id-fresh';  Active=`$false; Switchable=`$true; FiveHour=100; Weekly=80; FiveHourReset=(Get-Date).AddMinutes(30); WeeklyReset=(Get-Date).AddDays(3) }
    )
}
`$script:ActiveFive = 50      # 当前号 5 小时剩余，各个场景自己改

`$pass = 0; `$fail = 0
function Check(`$n, `$c, `$d) {
    if (`$c) { `$script:pass++; Write-Host "  [PASS] `$n" -ForegroundColor Green }
    else { `$script:fail++; Write-Host "  [FAIL] `$n  -- `$d" -ForegroundColor Red }
}
function TS([double]`$minAgo) { return (Get-Date).ToUniversalTime().AddMinutes(-`$minAgo).ToString('yyyy-MM-ddTHH:mm:ss.fff') + 'Z' }
function New-Session([string]`$thread, [string[]]`$lines) {
    `$p = Join-Path '$tmp' ("rollout-2026-09-27T00-00-00-" + `$thread + '.jsonl')
    [System.IO.File]::WriteAllLines(`$p, `$lines, (New-Object System.Text.UTF8Encoding(`$false)))
}
`$st  = '{"timestamp":"__T__","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}'
`$ok  = '{"timestamp":"__T__","ordinal":2,"type":"event_msg","payload":{"type":"task_completed","turn_id":"t1"}}'
`$ab  = '{"timestamp":"__T__","ordinal":3,"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t1","reason":"interrupted"}}'
`$lim = '{"timestamp":"__T__","ordinal":4,"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","error":{"message":"You''ve hit your usage limit.","codex_error_info":"usage_limit_exceeded"}}}'
`$tok = '{"timestamp":"__T__","ordinal":5,"type":"event_msg","payload":{"type":"token_count","info":{}}}'
# task_complete，但模型自己承认"没干完"
`$unc = '{"timestamp":"__T__","ordinal":2,"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"已检查中断状态：此前修改仍在，功能尚未完成。这次只做了只读检查。"}}'
function L([string]`$tpl, [double]`$minAgo) { return `$tpl.Replace('__T__', (TS `$minAgo)) }

`$thA='01a0aaaa-0000-0000-0000-000000000001'   # 正常结束
`$thB='01a0bbbb-0000-0000-0000-000000000002'   # 任务开着、停了 35 分钟（被中断）
`$thC='01a0cccc-0000-0000-0000-000000000003'   # turn_aborted（被中断）
`$thD='01a0dddd-0000-0000-0000-000000000004'   # 正在跑
`$thE='01a0eeee-0000-0000-0000-000000000005'   # 撞额度墙
`$thF='01a0ffff-0000-0000-0000-000000000006'   # 收尾了但自认没干完

function Reset-Fixtures {
    Get-ChildItem '$tmp' -Filter '*.jsonl' | Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '=== 场景 1：先开看护、Codex 还没有任何对话（当前号正常）===' -ForegroundColor Cyan
Reset-Fixtures
`$script:ActiveFive = 50
`$script:Switched=@(); `$script:Resumed=@()
`$state = [pscustomobject]@{ handled = [pscustomobject]@{} }
`$err = `$null
try { `$r = Invoke-Round -State `$state } catch { `$err = `$_.Exception.Message }
Check '不抛异常（不会一启动就报错）' (`$null -eq `$err) "异常：`$err"
Check '判为正常（不是 needs-review、不是 stop）' (`$r.Kind -eq 'ok') "Kind=`$(`$r.Kind)"
Check '什么都没切、什么都没续' (`$script:Switched.Count -eq 0 -and `$script:Resumed.Count -eq 0) "switch=`$(`$script:Switched -join ',') resume=`$(`$script:Resumed -join ',')"

Write-Host ''
Write-Host '=== 场景 1c：还没有对话，但当前号 5 小时已归零 → 也要主动切 ===' -ForegroundColor Cyan
Reset-Fixtures
`$script:ActiveFive = 0
`$script:Switched=@(); `$script:Resumed=@()
`$state = [pscustomobject]@{ handled = [pscustomobject]@{} }
`$r = Invoke-Round -State `$state
Check '主动切号（不等对话撞墙）' (`$script:Switched -contains 'fresh@x.com') "switch=`$(`$script:Switched -join ',')"
Check '没有对话可续，也不乱发"继续"' (`$script:Resumed.Count -eq 0) "resumed=`$(`$script:Resumed -join ',')"

Write-Host ''
Write-Host '=== 场景 1b：会话目录还不存在（Codex 从没启动过）===' -ForegroundColor Cyan
`$Script:Config.SessionRoot = Join-Path '$tmp' 'not-exist-yet'
`$err = `$null
try { `$files = Get-RecentSessions } catch { `$err = `$_.Exception.Message }
Check '不抛异常' (`$null -eq `$err) "异常：`$err"
Check '返回空列表' (@(`$files).Count -eq 0) "count=`$(@(`$files).Count)"
`$Script:Config.SessionRoot = '$tmp'

Write-Host ''
Write-Host '=== 场景 2/3：最近的对话里，只续"被中断"的（当前号正常，不该切号）===' -ForegroundColor Cyan
Reset-Fixtures
New-Session `$thA @((L `$st 30), (L `$ok 29))            # 正常结束
New-Session `$thB @((L `$st 40), (L `$tok 35))          # 任务开着、停了 35 分钟
New-Session `$thC @((L `$st 20), (L `$ab 19))           # 被中断（turn_aborted）
New-Session `$thD @((L `$st 1))                          # 正在跑
`$script:ActiveFive = 50
`$script:Switched=@(); `$script:Resumed=@()
`$state = [pscustomobject]@{ handled = [pscustomobject]@{} }
`$r = Invoke-Round -State `$state
Check '判为已处理' (`$r.Kind -eq 'handled') "Kind=`$(`$r.Kind) Reason=`$(`$r.Reason)"
Check '续了"停住"的那条' (`$script:Resumed -contains `$thB) "resumed=`$(`$script:Resumed -join ',')"
Check '续了 turn_aborted 的那条' (`$script:Resumed -contains `$thC) "resumed=`$(`$script:Resumed -join ',')"
Check '**没**续正常结束的那条' (-not (`$script:Resumed -contains `$thA)) "resumed=`$(`$script:Resumed -join ',')"
Check '**没**续正在跑的那条' (-not (`$script:Resumed -contains `$thD)) "resumed=`$(`$script:Resumed -join ',')"
Check '当前号没归零 → 不切号' (`$script:Switched.Count -eq 0) "switch=`$(`$script:Switched -join ',')"
Check '只发了 2 条"继续"' (`$script:Resumed.Count -eq 2) "count=`$(`$script:Resumed.Count)"

Write-Host ''
Write-Host '=== 场景 2d：当前号 5 小时归零 → 先主动切号，再只续中断的 ===' -ForegroundColor Cyan
Reset-Fixtures
New-Session `$thA @((L `$st 30), (L `$ok 29))            # 正常结束
New-Session `$thB @((L `$st 40), (L `$tok 35))          # 被中断
`$script:ActiveFive = 0
`$script:Switched=@(); `$script:Resumed=@()
`$state = [pscustomobject]@{ handled = [pscustomobject]@{} }
`$r = Invoke-Round -State `$state
Check '余额归零 → 不用等撞墙就切号' (`$script:Switched -contains 'fresh@x.com') "switch=`$(`$script:Switched -join ',')"
Check '切号后只续被中断的那条' (`$script:Resumed.Count -eq 1 -and `$script:Resumed -contains `$thB) "resumed=`$(`$script:Resumed -join ',')"
Check '正常结束的仍然一条不碰' (-not (`$script:Resumed -contains `$thA)) "resumed=`$(`$script:Resumed -join ',')"
`$script:ActiveFive = 50

Write-Host ''
Write-Host '=== 场景 3b：同一个中断现场不会重复发第二次 ===' -ForegroundColor Cyan
`$script:Resumed=@()
`$r2 = Invoke-Round -State `$state
Check '第二轮不再重复续跑' (`$script:Resumed.Count -eq 0) "resumed=`$(`$script:Resumed -join ',')"

Write-Host ''
Write-Host '=== 场景 3c：干跑（演习）绝不能把"已处理"落盘 ===' -ForegroundColor Cyan
# 回归用例：干跑如果记了指纹，正式跑起来反而会漏掉这条被中断的对话。
Reset-Fixtures
New-Session `$thC @((L `$st 20), (L `$ab 19))           # 被中断
`$Live = `$false
`$script:Resumed=@()
`$stateDry = [pscustomobject]@{ handled = [pscustomobject]@{} }
`$null = Invoke-Round -State `$stateDry
Check '干跑第一轮挑中了它' (`$script:Resumed -contains `$thC) "resumed=`$(`$script:Resumed -join ',')"
Check '干跑没往 handled 里写东西' (@(`$stateDry.handled.PSObject.Properties).Count -eq 0) "handled 有 `$(@(`$stateDry.handled.PSObject.Properties).Count) 项"
`$script:Resumed=@()
`$null = Invoke-Round -State `$stateDry
Check '干跑第二轮仍然挑中它（说明真的没落盘）' (`$script:Resumed -contains `$thC) "resumed=`$(`$script:Resumed -join ',')"
`$Live = `$true

Write-Host ''
Write-Host '=== 场景 2b：撞额度墙 → 切号 → 只续撞墙的与中断的 ===' -ForegroundColor Cyan
Reset-Fixtures
New-Session `$thA @((L `$st 30), (L `$ok 29))            # 正常结束
New-Session `$thB @((L `$st 40), (L `$tok 35))          # 被中断
New-Session `$thE @((L `$st 10), (L `$lim 9))           # 撞墙
`$script:Switched=@(); `$script:Resumed=@()
`$state = [pscustomobject]@{ handled = [pscustomobject]@{} }
`$r = Invoke-Round -State `$state
Check '切了号' (`$r.Kind -eq 'handled' -and `$script:Switched.Count -eq 1) "Kind=`$(`$r.Kind) switch=`$(`$script:Switched -join ',')"
Check '切到满血号 fresh@x.com' (`$script:Switched -contains 'fresh@x.com') "switch=`$(`$script:Switched -join ',')"
Check '续了撞墙的那条' (`$script:Resumed -contains `$thE) "resumed=`$(`$script:Resumed -join ',')"
Check '续了被中断的那条' (`$script:Resumed -contains `$thB) "resumed=`$(`$script:Resumed -join ',')"
Check '正常结束的仍然不续' (-not (`$script:Resumed -contains `$thA)) "resumed=`$(`$script:Resumed -join ',')"

Write-Host ''
Write-Host '=== 场景 2c：正在跑的时候不切号（避免打断）===' -ForegroundColor Cyan
Reset-Fixtures
New-Session `$thD @((L `$st 1))                          # 正在跑
New-Session `$thE @((L `$st 10), (L `$lim 9))           # 撞墙
`$script:Switched=@(); `$script:Resumed=@()
`$state = [pscustomobject]@{ handled = [pscustomobject]@{} }
`$r = Invoke-Round -State `$state
Check '判为等待（不切号）' (`$r.Kind -eq 'wait') "Kind=`$(`$r.Kind)"
Check '一个号都没切' (`$script:Switched.Count -eq 0) "switch=`$(`$script:Switched -join ',')"

Write-Host ''
Write-Host '=== 场景 4：收尾了但模型自己说"没干完" → 还要继续催 ===' -ForegroundColor Cyan
# 真实案例：脚本发"继续"，模型跑 6 秒回了句
#   "已检查中断状态：此前修改仍在，功能尚未完成。这次只做了只读检查……"
# 然后 task_complete 正常收尾。光看标记是"正常结束"，可活儿根本没干完。
Reset-Fixtures
New-Session `$thF @((L `$st 20), (L `$unc 19))          # task_complete，但自认没干完
`$script:ActiveFive = 50
`$script:Switched=@(); `$script:Resumed=@()
`$state = [pscustomobject]@{ handled = [pscustomobject]@{} }
`$r = Invoke-Round -State `$state
`$factF = Get-SessionFact -File (Get-ChildItem '$tmp' -Filter "*`$thF*" | Select-Object -First 1)
Check '判定为 unfinished（不是 finished）' ((Get-ConversationOutcome -Fact `$factF -Verdict (Get-SessionVerdict -Fact `$factF)) -eq 'unfinished') "outcome"
Check '会继续催它' (`$script:Resumed -contains `$thF) "resumed=`$(`$script:Resumed -join ',')"

Write-Host ''
Write-Host '=== 场景 4b：同一条对话续太多次还不见好 → 停手，不再刷"继续" ===' -ForegroundColor Cyan
Reset-Fixtures
New-Session `$thF @((L `$st 20), (L `$unc 19))
`$handled = [pscustomobject]@{}
`$factF2 = Get-SessionFact -File (Get-ChildItem '$tmp' -Filter "*`$thF*" | Select-Object -First 1)
# 伪造"N 次已经续过"的历史（键形如 res:<thread>:<时刻>）
1..`$Script:Config.ResumeMaxRounds | ForEach-Object {
    `$handled | Add-Member -NotePropertyName ("res:" + `$thF + ":fake`$_") -NotePropertyValue 'x' -Force
}
`$state = [pscustomobject]@{ handled = `$handled }
`$script:Resumed=@()
`$r = Invoke-Round -State `$state
Check '达到上限后不再自动续' (`$script:Resumed.Count -eq 0) "resumed=`$(`$script:Resumed -join ',')"

Write-Host ''
Write-Host '=== 场景 5：只看最近 5 条 —— 更早的中断对话不碰（用户规则第 1、4 条）===' -ForegroundColor Cyan
Reset-Fixtures
# 最近 5 条全是正常结束；第 6、7 条（更早）才是被中断的
New-Session `$thB @((L `$st 300), (L `$tok 295))         # 更早、被中断 —— 不该被看
New-Session `$thC @((L `$st 280), (L `$ab 279))          # 更早、被中断 —— 不该被看
New-Session '01a0g001-0000-0000-0000-00000000000a' @((L `$st 60), (L `$ok 59))
New-Session '01a0g002-0000-0000-0000-00000000000b' @((L `$st 50), (L `$ok 49))
New-Session '01a0g003-0000-0000-0000-00000000000c' @((L `$st 40), (L `$ok 39))
New-Session '01a0g004-0000-0000-0000-00000000000d' @((L `$st 30), (L `$ok 29))
New-Session '01a0g005-0000-0000-0000-00000000000e' @((L `$st 20), (L `$ok 19))
`$script:ActiveFive = 50
`$script:Switched=@(); `$script:Resumed=@()
`$state = [pscustomobject]@{ handled = [pscustomobject]@{} }
`$r = Invoke-Round -State `$state
Check '更早的中断对话一条都不发' (`$script:Resumed.Count -eq 0) "resumed=`$(`$script:Resumed -join ',')"
Check '最近 5 条都正常结束 → 什么都不做' (`$r.Kind -eq 'ok') "Kind=`$(`$r.Kind)"

Write-Host ''
Write-Host '=== 场景 5b：中断的那条就在最近 5 条里 → 才发（用户规则第 2、3 条）===' -ForegroundColor Cyan
Reset-Fixtures
New-Session '01a0g001-0000-0000-0000-00000000000a' @((L `$st 60), (L `$ok 59))
New-Session '01a0g002-0000-0000-0000-00000000000b' @((L `$st 50), (L `$ok 49))
New-Session '01a0g003-0000-0000-0000-00000000000c' @((L `$st 40), (L `$ok 39))
New-Session '01a0g004-0000-0000-0000-00000000000d' @((L `$st 30), (L `$ok 29))
New-Session `$thC @((L `$st 20), (L `$ab 19))            # 最近第 5 条，被中断
`$script:Switched=@(); `$script:Resumed=@()
`$state = [pscustomobject]@{ handled = [pscustomobject]@{} }
`$r = Invoke-Round -State `$state
Check '只发那一条中断的' (`$script:Resumed.Count -eq 1 -and `$script:Resumed -contains `$thC) "resumed=`$(`$script:Resumed -join ',')"

Write-Host ''
Write-Host ("  通过 `$pass 项，失败 `$fail 项") -ForegroundColor `$(if (`$fail -eq 0) { 'Green' } else { 'Red' })
Set-Location `$env:TEMP
Remove-Item '$tmp' -Recurse -Force -ErrorAction SilentlyContinue
exit `$(if (`$fail -eq 0) { 0 } else { 1 })
"@

[System.IO.File]::AppendAllText($hf, $test, (New-Object System.Text.UTF8Encoding($true)))
& $hf
exit $LASTEXITCODE
