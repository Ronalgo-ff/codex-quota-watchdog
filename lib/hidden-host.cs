// GUI-subsystem bridge: no console is allocated, even with Windows Terminal as default.
using System;
using System.Diagnostics;
using System.IO;
public static class QuotaHiddenHost {
    [STAThread]
    public static int Main(string[] args) {
        if (args.Length != 2) return 2;
        try {
            var info = new ProcessStartInfo();
            info.FileName = args[0];
            info.Arguments = "-NoProfile -STA -NonInteractive -ExecutionPolicy Bypass -File \"" + args[1] + "\"";
            info.WorkingDirectory = Path.GetDirectoryName(args[1]);
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            using (var process = Process.Start(info)) {
                process.WaitForExit();
                return process.ExitCode;
            }
        } catch { return 1; }
    }
}
