<# Runs one Codex resume job and records its exit status for the watcher. #>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$JobFile)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\process.ps1')
$job = Get-Content -LiteralPath $JobFile -Raw -Encoding UTF8 | ConvertFrom-Json
$exitCode = 1
$failure = $null
try {
    $run = Invoke-ManagedProcess -FilePath $job.codexExe `
        -Arguments @('exec', 'resume', '--skip-git-repo-check', $job.threadId, '-') `
        -WorkDir $job.workDir -InputText $job.message -Stdout $job.stdout -Stderr $job.stderr `
        -TimeoutSec ([int]$job.timeoutSec)
    if ($run.TimedOut) {
        $exitCode = 124
        $failure = "无人值守续跑超过 $($job.timeoutSec) 秒，已终止"
        Add-Content -LiteralPath $job.stderr -Value $failure -Encoding UTF8
    } else { $exitCode = $run.ExitCode }
} catch {
    $failure = $_.Exception.Message
    try { Add-Content -LiteralPath $job.stderr -Value $failure -Encoding UTF8 } catch { }
} finally {
    $result = @{
        jobId = $job.jobId
        threadId = $job.threadId
        exitCode = $exitCode
        error = $failure
        finishedAt = (Get-Date).ToString('o')
    }
    $tmp = "$($job.resultFile).tmp"
    $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $job.resultFile -Force
}
exit $exitCode
