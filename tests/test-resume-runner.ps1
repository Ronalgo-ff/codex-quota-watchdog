# End-to-end runner test with fake Codex commands. No account or session is touched.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$tmp = Join-Path $tempRoot ('resume-runner-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$pass = 0; $fail = 0
function Check($Name, $Ok) {
    if ($Ok) { $script:pass++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  [FAIL] $Name" -ForegroundColor Red }
}
try {
    $fake = Join-Path $tmp 'fake native.exe'
    New-TestNative $fake
    foreach ($case in @(@{ Name='ok'; Code=0; Timeout=30 }, @{ Name='error'; Code=7; Timeout=30 },
                        @{ Name='timeout'; Code=124; Timeout=1 })) {
        $mode = if ($case.Name -eq 'timeout') { 'timeout' } else { "runner-$($case.Name)" }
        Set-Content (Join-Path $tmp 'fake-mode.txt') -Value $mode -Encoding UTF8
        $id = [guid]::NewGuid().ToString('N')
        $resultFile = Join-Path $tmp "$id.result.json"
        $jobFile = Join-Path $tmp "$id.job.json"
        $message = "继续，带空格和引号 `"测试`"`n第二行 & $(1+1)"
        @{ jobId=$id; threadId='01a0aaaa-1111-2222-3333-444444444444'; message=$message
           workDir=$tmp; codexExe=$fake; stdout=(Join-Path $tmp "$id.out")
           stderr=(Join-Path $tmp "$id.err"); resultFile=$resultFile; timeoutSec=$case.Timeout } |
            ConvertTo-Json | Set-Content -LiteralPath $jobFile -Encoding UTF8
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'resume-runner.ps1') -JobFile $jobFile | Out-Null
        $code = $LASTEXITCODE
        $result = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Check "$($case.Name): exit code reaches caller" ($code -eq $case.Code)
        Check "$($case.Name): result file has true exit code" ($result.exitCode -eq $case.Code)
        Check "$($case.Name): result belongs to job" ($result.jobId -eq $id)
        Check "$($case.Name): Unicode multiline prompt intact" ([IO.File]::ReadAllText((Join-Path $tmp 'stdin.txt')) -eq $message)
        Check "$($case.Name): stderr captured without false failure" ((Get-Content (Join-Path $tmp "$id.err") -Raw) -match 'diagnostic')
        if ($case.Name -eq 'timeout') {
            Check 'timeout: result records timeout reason' ($result.error -match '超过 1 秒')
        }
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($tmp)
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        $resolved -ne $tempRoot.TrimEnd('\')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "  通过 $pass 项，失败 $fail 项"
exit $(if ($fail -eq 0) { 0 } else { 1 })
