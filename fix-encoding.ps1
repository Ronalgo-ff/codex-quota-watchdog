<#
    修复脚本的 UTF-8 BOM。
    为什么需要：这两个 .ps1 里有中文，Windows PowerShell 读「无 BOM 的 UTF-8」时会按系统
    ANSI 码页解码，中文变乱码并把字符串引号搞坏，报出一堆假的语法错误。
    任何编辑器保存过这两个文件之后，都跑一下这个脚本。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
# 所有含中文的 .ps1 都要在这张表里，漏一个就会在运行时"无法解析"。
# tests 目录下的脚本同样含中文，一并管起来 ——
# 漏掉它们的话，编辑一次就丢 BOM，测试会以"找不到入口标记"这种看不懂的方式失败。
$targets = @(Get-ChildItem -LiteralPath $Here -Recurse -File -Filter '*.ps1' |
    Where-Object { $_.FullName -notmatch '\\(state|logs|backups)\\' } |
    ForEach-Object { $_.FullName.Substring($Here.Length + 1) })
$bom = New-Object System.Text.UTF8Encoding($true)
$fixed = 0
$parseFailures = 0

foreach ($name in $targets) {
    $f = Join-Path $Here $name
    if (-not (Test-Path $f)) { Write-Host "  跳过（不存在）：$name" -ForegroundColor DarkGray; continue }

    $bytes = [System.IO.File]::ReadAllBytes($f)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    # 无论有没有 BOM，都按 UTF-8 读出来再带 BOM 写回，保证内容不被破坏
    $text = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($f, $text, $bom)

    # 验证语法
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs) | Out-Null
    $status = if ($errs) { "语法错误 $($errs.Count) 处" } else { '语法 OK' }
    $color  = if ($errs) { 'Red' } else { 'Green' }
    $note   = if ($hasBom) { 'BOM 本来就有' } else { 'BOM 缺失，已补上' }

    Write-Host ("  {0,-22} {1}  {2}" -f $name, $note, $status) -ForegroundColor $color
    if ($errs) {
        $parseFailures += $errs.Count
        $errs | Select-Object -First 3 | ForEach-Object {
            Write-Host ("      行 {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red
        }
    }
    $fixed++
}

Write-Host ''
if ($fixed -gt 0) { Write-Host '  完成。' -ForegroundColor Cyan } else { Write-Host '  没有可处理的文件。' -ForegroundColor Yellow }
if ($parseFailures -gt 0) { exit 1 }
