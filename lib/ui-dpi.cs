// PowerShell hosts have no application-specific DPI manifest. Configure the UI
// before loading WinForms or creating any handles; do not modify powershell.exe.
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class QuotaUiDpi {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CharFormat {
        public uint Size, Mask, Effects;
        public int Height, Offset, TextColor;
        public byte FontCharSet, PitchAndFamily;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr flags, ref CharFormat format);

    public static void ResetLogFont(IntPtr window) {
        // RichEdit sizes are in twips (1/20 pt), independent of GDI+'s system
        // DPI font conversion. Reset existing text and the default for refresh.
        CharFormat format = new CharFormat();
        format.Size = (uint)Marshal.SizeOf(typeof(CharFormat));
        format.Mask = 0x80000000;
        format.Height = 180;
        SendMessage(window, 0x0444, IntPtr.Zero, ref format);
        SendMessage(window, 0x0444, new IntPtr(4), ref format);
    }

    public static int GetLogFontTwips(IntPtr window) {
        CharFormat format = new CharFormat();
        format.Size = (uint)Marshal.SizeOf(typeof(CharFormat));
        SendMessage(window, 0x043A, IntPtr.Zero, ref format);
        return format.Height;
    }
    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    private static extern bool IsProcessDPIAware();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    public static void Initialize() {
        try {
            // Also set the STA thread if the PowerShell host already fixed the
            // process default. WinForms must separately opt into DPI changes.
            SetProcessDpiAwarenessContext(new IntPtr(-4));
            if (SetThreadDpiAwarenessContext(new IntPtr(-4)) == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error());
        } catch (EntryPointNotFoundException) {
            SetProcessDPIAware();
            if (!IsProcessDPIAware())
                throw new InvalidOperationException("Unable to enable high DPI rendering.");
        }
    }
}
