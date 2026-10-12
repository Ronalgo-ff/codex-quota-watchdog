# 选号三态单元测试
# 从主脚本抽出 Select-BestAccount / Format-ResetAt，构造场景验证

$src = Join-Path (Split-Path $PSScriptRoot -Parent) 'codex-autopilot.ps1'
$code = Get-Content $src -Raw -Encoding UTF8
$lines = $code -split "`r?`n"

$sb = New-Object System.Text.StringBuilder
$capture = $false; $depth = 0
foreach ($l in $lines) {
    if ($l -match '^function (Select-BestAccount|Format-ResetAt)') { $capture = $true; $depth = 0 }
    if ($capture) {
        [void]$sb.AppendLine($l)
        $depth += ([regex]::Matches($l, '\{')).Count - ([regex]::Matches($l, '\}')).Count
        if ($depth -le 0 -and $l -match '^\}') { $capture = $false }
    }
}

$Script:Config = @{ LogDir = $env:TEMP }
$Script:LogFile = $null
function Write-Log { param([string]$Message, [string]$Level = 'INFO'); Write-Host "     [$Level] $Message" }
# 主脚本里 Select-BestAccount 会调 Write-Event / Write-File，测试环境给个桩
function Write-Event { param([string]$Message, [string]$Level = 'INFO'); Write-Host "     [$Level] $Message" }
function Write-File  { param([string]$Message, [string]$Level = 'INFO') }

. ([scriptblock]::Create($sb.ToString()))

function New-Acc {
    param($Email, $Five, $Week, $Active = $false, $Switchable = $true)
    [pscustomobject]@{
        Id = "id-$Email"; Email = $Email; Plan = 'team'; Active = $Active
        Switchable = $Switchable; FiveHour = $Five; Weekly = $Week
        FiveHourReset = 1790508341; WeeklyReset = 1791012784; UsageError = $null
    }
}

$pass = 0; $fail = 0
function Check($name, $cond, $detail) {
    if ($cond) { $script:pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  [FAIL] $name  -- $detail" -ForegroundColor Red }
}

Write-Host ''
Write-Host '=== 场景 1：当前号 5h 用尽，另有号 5h 有额度 ===' -ForegroundColor Cyan
$r1 = Select-BestAccount -Accounts @(
    (New-Acc 'active@x.com' 0 58 $true),
    (New-Acc 'good@x.com' 100 60),
    (New-Acc 'cooling@x.com' 0 43)
)
Check '选中 good@x.com' ($r1.Best.Email -eq 'good@x.com') "实际 $($r1.Best.Email)"
Check 'AllDry 为 false' (-not $r1.AllDry) "实际 $($r1.AllDry)"

Write-Host ''
Write-Host '=== 场景 2：全部 5h 冷却，周额度仍有（manual pause 抓到的 bug 场景）===' -ForegroundColor Cyan
$r2 = Select-BestAccount -Accounts @(
    (New-Acc 'active@x.com' 0 58 $true),
    (New-Acc 'a@x.com' 0 43),
    (New-Acc 'b@x.com' 0 51),
    (New-Acc 'c@x.com' 0 70)
)
Check 'Best 为空（选不出号）' ($null -eq $r2.Best) "实际 $($r2.Best)"
Check 'AllDry 为 false（关键！不能误报全空）' (-not $r2.AllDry) "实际 AllDry=$($r2.AllDry)"
Check 'Cooling 收集到 3 个号' ($r2.Cooling.Count -eq 3) "实际 $($r2.Cooling.Count)"
Check '能给出恢复时间' ((Format-ResetAt $r2.Cooling[0].FiveHourReset) -ne '未知') '恢复时间读不出'

Write-Host ''
Write-Host '=== 场景 3：周额度也全空（真·全空）===' -ForegroundColor Cyan
$r3 = Select-BestAccount -Accounts @(
    (New-Acc 'active@x.com' 0 0 $true),
    (New-Acc 'a@x.com' 0 0),
    (New-Acc 'b@x.com' 100 0)
)
Check 'Best 为空' ($null -eq $r3.Best) "实际 $($r3.Best)"
Check 'AllDry 为 true（这才该收摊）' ($r3.AllDry) "实际 AllDry=$($r3.AllDry)"

Write-Host ''
Write-Host '=== 场景 4：多个可切，按周额度最大选（用户规则）===' -ForegroundColor Cyan
$r4 = Select-BestAccount -Accounts @(
    (New-Acc 'active@x.com' 0 58 $true),
    (New-Acc 'low-week@x.com' 100 43),
    (New-Acc 'high-week@x.com' 100 70),
    (New-Acc 'mid-week@x.com' 100 51)
)
Check '选中 high-week@x.com' ($r4.Best.Email -eq 'high-week@x.com') "实际 $($r4.Best.Email)"

Write-Host ''
Write-Host '=== 场景 5：不可切换的号要被排除 ===' -ForegroundColor Cyan
$r5 = Select-BestAccount -Accounts @(
    (New-Acc 'active@x.com' 0 58 $true),
    (New-Acc 'blocked@x.com' 100 90 $false $false),
    (New-Acc 'ok@x.com' 100 50)
)
Check '跳过不可切换的号' ($r5.Best.Email -eq 'ok@x.com') "实际 $($r5.Best.Email)"

Write-Host ''
Write-Host ("  通过 $pass 项，失败 $fail 项") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
exit $(if ($fail -eq 0) { 0 } else { 1 })
