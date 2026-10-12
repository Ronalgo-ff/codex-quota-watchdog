# Windows PowerShell 5.1 and PowerShell 7 compatible native process runner.
# Uses .NET directly: stderr is diagnostic data, never a PowerShell exception.
function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    '"' + ([regex]::Replace($Value, '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Stop-OwnedProcessTree {
    param([System.Diagnostics.Process]$Process)
    if ($null -eq $Process -or $Process.HasExited) { return }
    $kill = New-Object System.Diagnostics.ProcessStartInfo
    $kill.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    $kill.Arguments = '/PID {0} /T /F' -f $Process.Id
    $kill.UseShellExecute = $false
    $kill.CreateNoWindow = $true
    $kill.RedirectStandardOutput = $true
    $kill.RedirectStandardError = $true
    $kp = [System.Diagnostics.Process]::Start($kill)
    $null = $kp.StandardOutput.ReadToEndAsync()
    $null = $kp.StandardError.ReadToEndAsync()
    $null = $kp.WaitForExit(5000)
    $kp.Dispose()
    if (-not $Process.HasExited) { $Process.Kill() }
}

function Invoke-ManagedProcess {
    param(
        [string]$FilePath, [string[]]$Arguments, [string]$WorkDir,
        [string]$Stdout, [string]$Stderr, [string]$InputText,
        [int]$TimeoutSec = 0
    )
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = $FilePath
    $si.Arguments = (@($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $si.WorkingDirectory = $WorkDir
    $si.UseShellExecute = $false
    $si.CreateNoWindow = $true
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    $si.RedirectStandardInput = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $si
    $outStream = $null; $errStream = $null; $started = $false
    try {
        $outStream = [IO.File]::Open($Stdout, 'Create', 'Write', 'ReadWrite')
        $errStream = [IO.File]::Open($Stderr, 'Create', 'Write', 'ReadWrite')
        $started = $p.Start()
        $outCopy = $p.StandardOutput.BaseStream.CopyToAsync($outStream)
        $errCopy = $p.StandardError.BaseStream.CopyToAsync($errStream)
        if ($InputText) {
            $bytes = [Text.Encoding]::UTF8.GetBytes($InputText)
            $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $p.StandardInput.BaseStream.Flush()
        }
        $p.StandardInput.Close()
        $timedOut = $false
        if ($TimeoutSec -gt 0) {
            $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
            if ($timedOut) { Stop-OwnedProcessTree $p }
        } else { $p.WaitForExit() }
        $p.WaitForExit()
        $null = $outCopy.GetAwaiter().GetResult()
        $null = $errCopy.GetAwaiter().GetResult()
        return [pscustomobject]@{ ExitCode = $p.ExitCode; TimedOut = $timedOut }
    } finally {
        if ($started -and -not $p.HasExited) { Stop-OwnedProcessTree $p }
        if ($outStream) { $outStream.Dispose() }
        if ($errStream) { $errStream.Dispose() }
        $p.Dispose()
    }
}
