# 会话尾部读取窗口测试
#
# 真事（用户 2026-09-27 反馈）：一个 6.8MB 的活跃会话，**最后一个回合标记落在离文件末尾
# 1652KB 的地方**，而脚本只读尾部 256KB —— 读不到标记 → LastMarker 为空 →
# 结局被判成"正常结束" → **永远不给它发"继续"**；同时它还被当成"没在跑"，
# 切号时不会因为它正在跑就等待，重启一下就把对话切断了。
# 用户的原话："重启之后它没有正常继续，而只是重启了，换了号没有继续。"
#
# 这个测试把"标记再深也要翻出来"钉死。

$ap = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path $env:TEMP ('marker-window-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

`$Script:Config.SessionRoot = '$tmp'
`$Script:Config.TailBytes   = 262144          # 256KB，和线上一样
`$Script:Config.MarkerScanMaxKB = 4096
function Write-Log  { param([string]`$M,[string]`$L='INFO'); if (`$L -eq 'WARN') { Write-Host "     [WARN] `$M" -ForegroundColor DarkYellow } }
function Write-File { param([string]`$M,[string]`$L='INFO') }

`$pass = 0; `$fail = 0
function Check(`$n, `$c, `$d) {
    if (`$c) { `$script:pass++; Write-Host "  [PASS] `$n" -ForegroundColor Green }
    else { `$script:fail++; Write-Host "  [FAIL] `$n  -- `$d" -ForegroundColor Red }
}
function TS([double]`$m) { return (Get-Date).ToUniversalTime().AddMinutes(-`$m).ToString('yyyy-MM-ddTHH:mm:ss.fff') + 'Z' }

# 造一个"标记在很深处"的会话：标记 → 一大堆填充事件 → 再来个事件收尾
function New-DeepSession([string]`$thread, [string]`$markerType, [double]`$markerMinAgo, [int]`$padKB) {
    `$p = Join-Path '$tmp' ("rollout-2026-09-27T00-00-00-" + `$thread + '.jsonl')
    `$sw = New-Object System.IO.StreamWriter(`$p, `$false, (New-Object System.Text.UTF8Encoding(`$false)))
    try {
        `$sw.WriteLine('{"timestamp":"' + (TS `$markerMinAgo) + '","ordinal":1,"type":"event_msg","payload":{"type":"' + `$markerType + '","turn_id":"t1"}}')
        # 填充：每行约 1KB
        `$pad = 'x' * 900
        `$n = `$padKB
        for (`$i = 0; `$i -lt `$n; `$i++) {
            `$sw.WriteLine('{"timestamp":"' + (TS (`$markerMinAgo - 0.01)) + '","ordinal":' + (`$i + 2) + ',"type":"event_msg","payload":{"type":"token_count","pad":"' + `$pad + '"}}')
        }
        # 最后再来一条（让"最后活动时间"靠近现在，标记则远在 pad 之前）
        `$sw.WriteLine('{"timestamp":"' + (TS 1) + '","ordinal":99999,"type":"event_msg","payload":{"type":"token_count","info":{}}}')
    } finally { `$sw.Dispose() }
    return `$p
}

Write-Host ''
Write-Host '=== 1. 标记深埋在 1.5MB 之后（复刻那个 6.8MB 的会话）===' -ForegroundColor Cyan
`$thA = '01a0aaaa-0000-0000-0000-0000000000aa'
`$pA = New-DeepSession `$thA 'task_started' 40 3000      # 约 3MB 填充 → 标记离末尾 ~3MB
`$sizeA = (Get-Item `$pA).Length
Write-Host ("     文件大小 {0:N1} MB，标记在离末尾约 {1:N1} MB 处" -f (`$sizeA/1MB), (`$sizeA/1MB))
`$fa = Get-SessionFact -File (Get-Item `$pA)
Check '能读到回合标记（不再空）' (`$fa.LastMarker -eq 'task_started') "LastMarker=`$(`$fa.LastMarker)"
Check '任务被认成"开着"' (`$fa.TaskOpen) "TaskOpen=`$(`$fa.TaskOpen)"
`$outA = Get-ConversationOutcome -Fact `$fa -Verdict (Get-SessionVerdict -Fact `$fa)
# 这条的关键：**绝不能再被当成"正常结束"**（那正是"换了号没继续"的根因）
Check '不会被误判成"正常结束"' (`$outA -ne 'finished') "outcome=`$outA"
Check '尾部事件很新 → 正确认成"正在跑"' (`$outA -eq 'running') "outcome=`$outA"

# 再来一个：标记同样深埋，但尾部事件已经很久 → 应该被判成"被中断"、要续跑
`$thA2 = '01a0aaaa-0000-0000-0000-0000000000ab'
`$pA2 = New-DeepSession `$thA2 'task_started' 40 3000
# 把最后那行的时间戳改旧（直接从尾部改字符串不方便，重建一个"最后事件也很旧"的）
`$sw = New-Object System.IO.StreamWriter(`$pA2, `$false, (New-Object System.Text.UTF8Encoding(`$false)))
try {
    `$sw.WriteLine('{"timestamp":"' + (TS 40) + '","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}')
    `$pad = 'x' * 900
    for (`$i = 0; `$i -lt 3000; `$i++) {
        `$sw.WriteLine('{"timestamp":"' + (TS 39) + '","ordinal":' + (`$i + 2) + ',"type":"event_msg","payload":{"type":"token_count","pad":"' + `$pad + '"}}')
    }
    `$sw.WriteLine('{"timestamp":"' + (TS 35) + '","ordinal":99999,"type":"event_msg","payload":{"type":"token_count","info":{}}}')
} finally { `$sw.Dispose() }
`$fa2 = Get-SessionFact -File (Get-Item `$pA2)
`$outA2 = Get-ConversationOutcome -Fact `$fa2 -Verdict (Get-SessionVerdict -Fact `$fa2)
Check '深埋标记 + 停了 35 分钟 → 被中断（要续跑）' (`$outA2 -eq 'interrupted') "outcome=`$outA2 marker=`$(`$fa2.LastMarker) TaskOpen=`$(`$fa2.TaskOpen)"

Write-Host ''
Write-Host '=== 2. 小文件不受影响，而且不会白白读大窗口 ===' -ForegroundColor Cyan
`$thB = '01a0bbbb-0000-0000-0000-0000000000bb'
`$pB = Join-Path '$tmp' ("rollout-2026-09-27T00-00-00-" + `$thB + '.jsonl')
[System.IO.File]::WriteAllLines(`$pB, @(
    '{"timestamp":"' + (TS 30) + '","ordinal":1,"type":"event_msg","payload":{"type":"task_completed","turn_id":"t1"}}'
), (New-Object System.Text.UTF8Encoding(`$false)))
`$fb = Get-SessionFact -File (Get-Item `$pB)
Check '小文件照常读出标记' (`$fb.LastMarker -eq 'task_completed') "LastMarker=`$(`$fb.LastMarker)"
Check '小文件的读取窗口仍是最小的 256KB' (`$Script:TailHint[(Get-Item `$pB).FullName] -eq `$Script:Config.TailBytes) "hint=`$(`$Script:TailHint[(Get-Item `$pB).FullName])"

Write-Host ''
Write-Host '=== 3. 记住"这个文件要读多大"，下一轮不重复试 ===' -ForegroundColor Cyan
`$null = Get-SessionFact -File (Get-Item `$pA)
`$hintA = `$Script:TailHint[(Get-Item `$pA).FullName]
Check '深文件的窗口被记下来且大于默认值' (`$hintA -gt `$Script:Config.TailBytes) "hint=`$hintA"
Check '不超过上限' (`$hintA -le (`$Script:Config.MarkerScanMaxKB * 1KB)) "hint=`$hintA"

Write-Host ''
Write-Host '=== 4. 满窗口扫完还是没有标记 → 不崩，且标记为空（日志会告警）===' -ForegroundColor Cyan
`$thC = '01a0cccc-0000-0000-0000-0000000000cc'
`$pC = Join-Path '$tmp' ("rollout-2026-09-27T00-00-00-" + `$thC + '.jsonl')
`$pad = 'y' * 900
`$lines = @()
for (`$i = 0; `$i -lt 400; `$i++) {
    `$lines += '{"timestamp":"' + (TS 5) + '","ordinal":' + `$i + ',"type":"event_msg","payload":{"type":"token_count","pad":"' + `$pad + '"}}'
}
[System.IO.File]::WriteAllLines(`$pC, `$lines, (New-Object System.Text.UTF8Encoding(`$false)))
`$err = `$null; `$fc = `$null
try { `$fc = Get-SessionFact -File (Get-Item `$pC) } catch { `$err = `$_.Exception.Message }
Check '不抛异常' (`$null -eq `$err) "异常：`$err"
Check '标记为空（交给调用方告警，不静默当结束）' (`$null -eq `$fc.LastMarker) "LastMarker=`$(`$fc.LastMarker)"

Write-Host ''
Write-Host '=== 5. 标记在 4MB 之外 → 线上 64MB 上限仍能识别当前回合 ===' -ForegroundColor Cyan
`$Script:Config.MarkerScanMaxKB = 65536
`$thD = '01a0dddd-0000-0000-0000-0000000000dd'
`$pD = New-DeepSession `$thD 'task_started' 10 7000
`$fd = Get-SessionFact -File (Get-Item `$pD)
Check '超过旧 4MB 上限仍找到 task_started' (`$fd.LastMarker -eq 'task_started') "LastMarker=`$(`$fd.LastMarker)"
Check '超长会话仍判为正在运行' ((Get-ConversationOutcome -Fact `$fd -Verdict (Get-SessionVerdict -Fact `$fd)) -eq 'running') '没有判为 running'

Write-Host ''
Write-Host ("  通过 `$pass 项，失败 `$fail 项") -ForegroundColor `$(if (`$fail -eq 0) { 'Green' } else { 'Red' })
Set-Location `$env:TEMP
Remove-Item '$tmp' -Recurse -Force -ErrorAction SilentlyContinue
exit `$(if (`$fail -eq 0) { 0 } else { 1 })
"@

[System.IO.File]::AppendAllText($hf, $test, (New-Object System.Text.UTF8Encoding($true)))
& $hf
exit $LASTEXITCODE
