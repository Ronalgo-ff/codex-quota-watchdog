using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace QuotaWatchdog
{
    public static class DesktopProcess
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int processId);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(SafeProcessHandle process, out long created,
            out long exited, out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool QueryFullProcessImageName(SafeProcessHandle process, uint flags,
            StringBuilder path, ref int length);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(SafeProcessHandle process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(SafeProcessHandle process, uint milliseconds);

        public static string StopExact(int processId, string executable, DateTime startedUtc)
        {
            if (processId <= 0 || processId == Process.GetCurrentProcess().Id ||
                string.IsNullOrEmpty(executable) || !Path.IsPathRooted(executable))
                throw new ArgumentException("Invalid saved desktop process identity");

            // The same kernel handle is used for verification and termination.
            // A PID reused between the snapshot and this call cannot kill a new app.
            using (SafeProcessHandle process = OpenProcess(0x00101001, false, processId))
            {
                if (process.IsInvalid)
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 87) return "already-exited";
                    throw new Win32Exception(error);
                }
                if (WaitForSingleObject(process, 0) == 0) return "already-exited";
                long created, exited, kernel, user;
                if (!GetProcessTimes(process, out created, out exited, out kernel, out user))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                int length = 32768;
                StringBuilder path = new StringBuilder(length);
                if (!QueryFullProcessImageName(process, 0, path, ref length))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                if (!string.Equals(Path.GetFullPath(path.ToString()), Path.GetFullPath(executable),
                        StringComparison.OrdinalIgnoreCase) ||
                    Math.Abs((DateTime.FromFileTimeUtc(created) - startedUtc.ToUniversalTime()).TotalSeconds) > 2)
                    return "identity-mismatch";

                if (!TerminateProcess(process, 1))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (WaitForSingleObject(process, 0) == 0) return "already-exited";
                    throw new Win32Exception(error);
                }
                uint wait = WaitForSingleObject(process, 5000);
                if (wait == 0) return "terminated";
                if (wait == 258) return "termination-pending";
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }
}
