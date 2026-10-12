[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scripts = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter 'test-*.ps1' | Sort-Object Name)
$shellExe = (Get-Process -Id $PID).Path
$failed = @()
foreach ($test in $scripts) {
    Write-Host "`n--- $($test.Name) ---" -ForegroundColor Cyan
    & $shellExe -NoProfile -ExecutionPolicy Bypass -File $test.FullName
    if ($LASTEXITCODE -ne 0) { $failed += $test.Name }
}
Write-Host "`n测试脚本 $($scripts.Count) 个；失败 $($failed.Count) 个。" -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
if ($failed.Count) { Write-Host "失败：$($failed -join ', ')" -ForegroundColor Red; exit 1 }
exit 0
