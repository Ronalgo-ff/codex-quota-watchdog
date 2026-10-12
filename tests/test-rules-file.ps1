# 外部规则文件 rules.json 的测试
#
# 目的：确认"换个场景只改 rules.json、不动脚本"这条路是通的，而且**改坏了也不会把看护搞崩**。
#   1. 正常覆盖：写哪个键就覆盖哪个键
#   2. 下划线开头的键只当注释，不覆盖配置
#   3. 不认识的键要能被看见（免得以为写错了还在生效）
#   4. 文件写坏了 → 退回默认值继续跑，不抛异常
#   5. 文件不存在 → 什么都不做，不抛异常
#   6. 仓库里那份真 rules.json 必须能解析，且关键值和脚本默认值一致（防两份配置漂移）

$ap = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path $env:TEMP ('rules-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# 只取脚本的"函数部分"（跳过入口），这样不会真的跑起来
$code = Get-Content (Join-Path $ap 'codex-autopilot.ps1') -Raw -Encoding UTF8
$cut = $code.IndexOf('#  入口')
if ($cut -lt 0) { Write-Host '找不到入口标记' -ForegroundColor Red; exit 1 }
$body = $code.Substring(0, $cut)
$body = [regex]::Replace($body, '(?s)^\s*<#.*?#>\s*\[CmdletBinding\(\)\]\s*param\(.*?\)\s*', '')
# 入口之前那两行顶层初始化也拿掉（它会去读真实的 rules.json，测试里不需要）
$body = [regex]::Replace($body, '(?ms)^\$Script:RulesFile\s*=.*?^\$Script:RulesApplied\s*=.*?$', '')

$hf = Join-Path $tmp 'harness.ps1'
[System.IO.File]::WriteAllText($hf, $body, (New-Object System.Text.UTF8Encoding($true)))

$test = @"

`$pass = 0; `$fail = 0
function Check(`$n, `$c, `$d) {
    if (`$c) { `$script:pass++; Write-Host "  [PASS] `$n" -ForegroundColor Green }
    else { `$script:fail++; Write-Host "  [FAIL] `$n  -- `$d" -ForegroundColor Red }
}
function New-Config { return @{ A = 1; B = '默认' } }

Write-Host ''
Write-Host '=== 1. 正常覆盖 ===' -ForegroundColor Cyan
`$f1 = Join-Path '$tmp' 'ok.json'
[System.IO.File]::WriteAllText(`$f1, '{"A": 99, "B": "改过了", "_注释": "别管我"}', (New-Object System.Text.UTF8Encoding(`$false)))
`$c1 = New-Config
`$ap1 = @(Import-Rules -Path `$f1 -Config `$c1)
Check 'A 被覆盖成 99' (`$c1.A -eq 99) "A=`$(`$c1.A)"
Check 'B 被覆盖' (`$c1.B -eq '改过了') "B=`$(`$c1.B)"
Check '下划线键不覆盖配置' (-not `$c1.ContainsKey('_注释')) "keys=`$(`$c1.Keys -join ',')"
Check '报告里只说改了两个键' (`$ap1.Count -eq 2) "applied=`$(`$ap1 -join ',')"

Write-Host ''
Write-Host '=== 2. 不认识的键要能看见 ===' -ForegroundColor Cyan
`$f2 = Join-Path '$tmp' 'unknown.json'
[System.IO.File]::WriteAllText(`$f2, '{"A": 5, "没有这个键": 1}', (New-Object System.Text.UTF8Encoding(`$false)))
`$c2 = New-Config
`$ap2 = @(Import-Rules -Path `$f2 -Config `$c2)
Check '未知键被标注出来' ((`$ap2 -join ',') -match '未知键') "applied=`$(`$ap2 -join ',')"

Write-Host ''
Write-Host '=== 3. 文件写坏了 → 退回默认值，不抛异常 ===' -ForegroundColor Cyan
`$f3 = Join-Path '$tmp' 'broken.json'
[System.IO.File]::WriteAllText(`$f3, '{ 这不是 JSON ,,', (New-Object System.Text.UTF8Encoding(`$false)))
`$c3 = New-Config
`$err = `$null; `$ap3 = @()
try { `$ap3 = @(Import-Rules -Path `$f3 -Config `$c3) } catch { `$err = `$_.Exception.Message }
Check '不抛异常' (`$null -eq `$err) "异常：`$err"
Check '配置保持默认值' (`$c3.A -eq 1 -and `$c3.B -eq '默认') "A=`$(`$c3.A) B=`$(`$c3.B)"
Check '日志里说明了解析失败' ((`$ap3 -join '') -match '解析失败') "applied=`$(`$ap3 -join ',')"

Write-Host ''
Write-Host '=== 4. 文件不存在 → 什么都不做 ===' -ForegroundColor Cyan
`$c4 = New-Config
`$err = `$null; `$ap4 = @()
try { `$ap4 = @(Import-Rules -Path (Join-Path '$tmp' 'nope.json') -Config `$c4) } catch { `$err = `$_.Exception.Message }
Check '不抛异常' (`$null -eq `$err) "异常：`$err"
Check '返回空、配置不动' (`$ap4.Count -eq 0 -and `$c4.A -eq 1) "applied=`$(`$ap4.Count)"

Write-Host ''
Write-Host '=== 5. 仓库里那份真 rules.json 能解析、且和脚本默认值不漂移 ===' -ForegroundColor Cyan
`$real = Join-Path '$ap' 'rules.json'
Check 'rules.json 存在' (Test-Path `$real) "路径：`$real"
`$c5 = New-Config
`$err = `$null; `$ap5 = @()
try { `$ap5 = @(Import-Rules -Path `$real -Config `$c5) } catch { `$err = `$_.Exception.Message }
Check '能正常解析' (`$null -eq `$err` -and (`$ap5 -join '') -notmatch '解析失败') "applied=`$(`$ap5 -join ',')"

# 关键值必须和脚本默认值一致 —— 防止"改了脚本忘了改 rules.json"或反过来
`$defaults = @{ ResumeScanThreads = 5; ResumeMaxThreads = 5; ResumeQuietMin = 2; ResumeMaxRounds = 4 }
`$rulesObj = Get-Content `$real -Raw -Encoding UTF8 | ConvertFrom-Json
foreach (`$k in `$defaults.Keys) {
    `$rv = `$rulesObj.`$k
    `$dv = `$defaults[`$k]
    Check "`$k 两边一致（rules=`$rv / 脚本默认=`$dv）" (`$rv -eq `$dv) "rules=`$rv default=`$dv"
}
Check 'UnfinishedMarkers 是非空数组' (@(`$rulesObj.UnfinishedMarkers).Count -ge 5) "count=`$(@(`$rulesObj.UnfinishedMarkers).Count)"

Write-Host ''
Write-Host ("  通过 `$pass 项，失败 `$fail 项") -ForegroundColor `$(if (`$fail -eq 0) { 'Green' } else { 'Red' })
Set-Location `$env:TEMP
Remove-Item '$tmp' -Recurse -Force -ErrorAction SilentlyContinue
exit `$(if (`$fail -eq 0) { 0 } else { 1 })
"@

[System.IO.File]::AppendAllText($hf, $test, (New-Object System.Text.UTF8Encoding($true)))
& $hf
exit $LASTEXITCODE
