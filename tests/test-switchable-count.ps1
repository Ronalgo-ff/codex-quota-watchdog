# "可切号 N 个"计数测试
#
# 用户 2026-09-27 看出来的两个问题（原话）：
#   "1. 我一共是 5 个号，现在用了一个，那剩下的肯定只有 4 个了呀。"
#   "2. 我刚刚还出现了一种情况，就是只剩最后一个号了，这里显示的是'可切号 1 个'。
#       那我都在用最后一个号了，肯定是没有可切的号呀。"
#
# 根因：算"可切号"时把 **当前正在用的那个号** 也算进去了。
# 选号逻辑本身没错（Select-BestAccount 一直有排除 active），错的是这个计数。
# 这个测试把"排除 active"钉死，防止以后再退回去。

$ap = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path $env:TEMP ('switchable-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
function Write-Log  { param([string]`$M,[string]`$L='INFO') }
function Write-File { param([string]`$M,[string]`$L='INFO') }
function Write-Event{ param([string]`$M,[string]`$L='INFO') }

`$pass = 0; `$fail = 0
function Check(`$n, `$c, `$d) {
    if (`$c) { `$script:pass++; Write-Host "  [PASS] `$n" -ForegroundColor Green }
    else { `$script:fail++; Write-Host "  [FAIL] `$n  -- `$d" -ForegroundColor Red }
}
function A([string]`$email, [bool]`$active, `$five, `$week, [bool]`$switchable=`$true) {
    return [pscustomobject]@{
        Email=`$email; Id=`$email; Active=`$active; Switchable=`$switchable
        FiveHour=`$five; Weekly=`$week; FiveHourReset=0; WeeklyReset=0; UsageError=`$null
    }
}

Write-Host ''
Write-Host '=== 1. 用户说的第一种情况：5 个号全有额度，正在用 1 个 ===' -ForegroundColor Cyan
`$accs = @(
    (A 'in-use@x.com' `$true  50 50),
    (A 'a@x.com'      `$false 100 60),
    (A 'b@x.com'      `$false 100 70),
    (A 'c@x.com'      `$false 100 80),
    (A 'd@x.com'      `$false 100 90)
)
`$u = @(Get-UsableAccounts -Accounts `$accs)
Check '可切号是 4 个，不是 5 个' (`$u.Count -eq 4) "count=`$(`$u.Count)"
Check '当前正在用的那个号不在里面' (-not (`$u.Email -contains 'in-use@x.com')) "emails=`$(`$u.Email -join ',')"

Write-Host ''
Write-Host '=== 2. 用户说的第二种情况：只剩正在用的那个号还有余量 ===' -ForegroundColor Cyan
`$accs = @(
    (A 'in-use@x.com' `$true  8  40),
    (A 'a@x.com'      `$false 0  50),
    (A 'b@x.com'      `$false 0  60),
    (A 'c@x.com'      `$false 0  70),
    (A 'd@x.com'      `$false 0  80)
)
`$u = @(Get-UsableAccounts -Accounts `$accs)
Check '可切号是 0 个（那个 1 就是它自己）' (`$u.Count -eq 0) "count=`$(`$u.Count)"

Write-Host ''
Write-Host '=== 3. 排除规则：周额度空 / 不支持直连切换 ===' -ForegroundColor Cyan
`$accs = @(
    (A 'in-use@x.com' `$true  50 50),
    (A 'weekly0@x.com' `$false 100 0),          # 周额度空 → 不算
    (A 'noswitch@x.com' `$false 100 60 `$false), # 不支持直连 → 不算
    (A 'ok@x.com'      `$false 100 70)
)
`$u = @(Get-UsableAccounts -Accounts `$accs)
Check '只剩那 1 个真正能切的' (`$u.Count -eq 1 -and `$u.Email -contains 'ok@x.com') "emails=`$(`$u.Email -join ',')"

Write-Host ''
Write-Host '=== 4. csw 没有标记 active 时，按"全都能切"算（不能凭空少算）===' -ForegroundColor Cyan
`$accs = @(
    (A 'a@x.com' `$false 100 60),
    (A 'b@x.com' `$false 100 70)
)
`$u = @(Get-UsableAccounts -Accounts `$accs)
Check '两个都算可切' (`$u.Count -eq 2) "count=`$(`$u.Count)"

Write-Host ''
Write-Host '=== 5. 端到端：状态行里那个数字也要对 ===' -ForegroundColor Cyan
function Get-Accounts {
    return @(
        (A 'in-use@x.com' `$true  50 50),
        (A 'a@x.com'      `$false 100 60),
        (A 'b@x.com'      `$false 100 70),
        (A 'c@x.com'      `$false 100 80),
        (A 'd@x.com'      `$false 100 90)
    )
}
`$state = [pscustomobject]@{ handled = [pscustomobject]@{} }
`$r = Invoke-Round -State `$state
Check '本轮结果是正常' (`$r.Kind -eq 'ok') "Kind=`$(`$r.Kind)"
Check 'Summary 里写的是 4 个' (`$r.Summary -match '可切号\s*4\s*个') "Summary=`$(`$r.Summary)"

Write-Host ''
Write-Host ("  通过 `$pass 项，失败 `$fail 项") -ForegroundColor `$(if (`$fail -eq 0) { 'Green' } else { 'Red' })
Set-Location `$env:TEMP
Remove-Item '$tmp' -Recurse -Force -ErrorAction SilentlyContinue
exit `$(if (`$fail -eq 0) { 0 } else { 1 })
"@

[System.IO.File]::AppendAllText($hf, $test, (New-Object System.Text.UTF8Encoding($true)))
& $hf
exit $LASTEXITCODE
