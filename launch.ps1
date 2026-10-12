<# 双击入口：验证脚本及本机配置后打开托盘。失败时显示可读错误。 #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'fix-encoding.ps1') *> $null
    if ($LASTEXITCODE -ne 0) { throw '脚本语法检查失败，请运行 fix-encoding.ps1 查看详情。' }
    $null = & (Join-Path $PSScriptRoot 'setup.ps1') -NoShortcut
    $trayPath = Join-Path $PSScriptRoot 'tray.ps1'
    . (Join-Path $PSScriptRoot 'lib\host.ps1')
    $null = Start-QuotaIndependentHost $PSScriptRoot $trayPath
} catch {
    $logDir = Join-Path $PSScriptRoot 'logs'
    $null = New-Item -ItemType Directory -Path $logDir -Force
    Add-Content -LiteralPath (Join-Path $logDir 'startup.log') -Encoding UTF8 -Value ("$(Get-Date -Format o) $($_.Exception.Message)")
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message + "`n`n程序目录：$PSScriptRoot",'Codex 额度看护：启动检查未通过','OK','Warning')
    exit 1
}
