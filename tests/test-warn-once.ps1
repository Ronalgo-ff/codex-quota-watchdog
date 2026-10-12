# "快到墙了"只提醒一次 —— 测试
#
# 用户原话："每次额度低于 15% 之后，它就会一直报 warning'马上撞墙了'。
#            不需要这样，只需要出来一次就行了，后面不要每过 10 秒就来一次。"
# 以及同一类毛病："当前号 5 小时已经归零 → 主动切号" 那条原来也是每轮都喊。

$ap = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path $env:TEMP ('warn-once-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
`$Script:Config.WarnPercent = 15.0
`$Script:Config.ResumeGapSec = 0
`$Script:Config.ResumeSettleSec = 0
`$Script:Config.ConsumeGapSec = 0
`$Live = `$true
function Write-File { param([string]`$M,[string]`$L='INFO') }
`$script:Said = @()
function Write-Event { param([string]`$M,[string]`$L='INFO') `$script:Said += `$M }
function Save-State { param(`$State) }
function Get-QuotaSnapshot { return `$null }
function Invoke-SwitchAccount { param(`$Account) return `$true }
function Invoke-ResumeConversation { param([string]`$ThreadId,[string]`$Label,[string]`$WorkDir) return `$true }

`$pass = 0; `$fail = 0
function Check(`$n, `$c, `$d) {
    if (`$c) { `$script:pass++; Write-Host "  [PASS] `$n" -ForegroundColor Green }
    else { `$script:fail++; Write-Host "  [FAIL] `$n  -- `$d" -ForegroundColor Red }
}
function Warns { return @(`$script:Said | Where-Object { `$_ -match '快到墙了' }) }

`$script:Five = 10
function Get-Accounts {
    return @(
        [pscustomobject]@{ Email='active@x.com'; Id='id-a'; Active=`$true; Switchable=`$true
                           FiveHour=`$script:Five; Weekly=50; FiveHourReset=0; WeeklyReset=0; UsageError=`$null },
        [pscustomobject]@{ Email='other@x.com'; Id='id-b'; Active=`$false; Switchable=`$true
                           FiveHour=100; Weekly=60; FiveHourReset=0; WeeklyReset=0; UsageError=`$null }
    )
}

Write-Host ''
Write-Host '=== 1. 低于 15%：第一轮提醒一次，第二轮不再重复 ===' -ForegroundColor Cyan
`$script:Five = 10
`$Script:WarnedDryAccount = `$null
`$state = [pscustomobject]@{ handled = [pscustomobject]@{} }
`$script:Said = @()
`$null = Invoke-Round -State `$state
Check '第一轮提醒了' (@(Warns).Count -eq 1) "说了 `$(@(Warns).Count) 次"
`$script:Said = @()
`$null = Invoke-Round -State `$state
Check '第二轮**没有**再提醒' (@(Warns).Count -eq 0) "说了 `$(@(Warns).Count) 次"
`$script:Said = @()
`$null = Invoke-Round -State `$state
Check '第三轮也没再提醒' (@(Warns).Count -eq 0) "说了 `$(@(Warns).Count) 次"

Write-Host ''
Write-Host '=== 2. 额度回到警戒线以上，再跌破 → 重新提醒一次 ===' -ForegroundColor Cyan
`$script:Five = 80
`$null = Invoke-Round -State `$state        # 这一轮回到 80%，记忆被清掉
`$script:Five = 12
`$script:Said = @()
`$null = Invoke-Round -State `$state
Check '重新跌破后又能提醒一次' (@(Warns).Count -eq 1) "说了 `$(@(Warns).Count) 次"
`$script:Said = @()
`$null = Invoke-Round -State `$state
Check '然后还是不重复' (@(Warns).Count -eq 0) "说了 `$(@(Warns).Count) 次"

Write-Host ''
Write-Host '=== 3. 同一轮里"归零→主动切号"也只说一次 ===' -ForegroundColor Cyan
`$script:Five = 0
`$Script:WarnedDryAccount = `$null
`$state = [pscustomobject]@{ handled = [pscustomobject]@{} }
`$script:Said = @()
`$null = Invoke-Round -State `$state
`$n1 = @(`$script:Said | Where-Object { `$_ -match '主动切号' }).Count
Check '第一轮说了"主动切号"' (`$n1 -eq 1) "说了 `$n1 次"
`$script:Said = @()
`$null = Invoke-Round -State `$state
`$n2 = @(`$script:Said | Where-Object { `$_ -match '主动切号' }).Count
Check '第二轮不再重复（已切过就别再喊）' (`$n2 -eq 0) "说了 `$n2 次"

Write-Host ''
Write-Host ("  通过 `$pass 项，失败 `$fail 项") -ForegroundColor `$(if (`$fail -eq 0) { 'Green' } else { 'Red' })
Set-Location `$env:TEMP
Remove-Item '$tmp' -Recurse -Force -ErrorAction SilentlyContinue
exit `$(if (`$fail -eq 0) { 0 } else { 1 })
"@

[System.IO.File]::AppendAllText($hf, $test, (New-Object System.Text.UTF8Encoding($true)))
& $hf
exit $LASTEXITCODE
