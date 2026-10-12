function New-TestNative {
    param([string]$Path)
    $source = @'
using System;
using System.IO;
using System.Threading;
public class FakeNative {
    public static int Main(string[] args) {
        Console.InputEncoding = new System.Text.UTF8Encoding(false);
        Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        string mode = File.ReadAllText("fake-mode.txt").Trim().Trim('\uFEFF');
        string input = Console.In.ReadToEnd();
        File.WriteAllText("stdin.txt", input);
        File.WriteAllLines("argv.txt", args);
        File.AppendAllText("calls.txt", mode + "\n");
        Console.Error.WriteLine("diagnostic on stderr (not a failure)");
        if (mode == "timeout") { Thread.Sleep(10000); return 0; }
        if (mode == "runner-error") return 7;
        if (mode == "runner-ok") { Console.WriteLine("finished"); return 0; }
        if (mode == "invalid") { Console.WriteLine("not JSON"); return 0; }
        return 0;
    }
}
'@
    # Compiler in Windows PowerShell produces a .NET Framework executable usable on this machine.
    $sourceFile = "$Path.cs"
    [IO.File]::WriteAllText($sourceFile, $source, (New-Object Text.UTF8Encoding($true)))
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $compiler)) { $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    & $compiler /nologo /target:exe "/out:$Path" $sourceFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot compile test fixture' }
}

function Remove-TestDirectory {
    param([string]$Path)
    $base = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or
        $resolved -eq $base.TrimEnd('\')) { throw "Unsafe test cleanup: $resolved" }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
