using System;
using System.Runtime.InteropServices;

namespace QuotaWatchdog
{
    // Activate packaged desktop apps through Windows, preserving their identity
    // and launch arguments instead of executing a protected WindowsApps binary.
    public static class DesktopActivation
    {
        [ComImport]
        [Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IApplicationActivationManager
        {
            [PreserveSig]
            int ActivateApplication(
                [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
                [MarshalAs(UnmanagedType.LPWStr)] string arguments,
                uint options, out uint processId);
        }

        public static uint Activate(string appUserModelId, string arguments)
        {
            object manager = Activator.CreateInstance(Type.GetTypeFromCLSID(
                new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")));
            try
            {
                uint processId;
                int result = ((IApplicationActivationManager)manager).ActivateApplication(
                    appUserModelId, arguments ?? "", 2 /* AO_NOERRORUI */, out processId);
                if (result < 0)
                    throw new COMException("Windows app activation failed (0x" +
                        unchecked((uint)result).ToString("X8") + ")", result);
                if (processId == 0)
                    throw new InvalidOperationException("Windows app activation returned no process ID");
                return processId;
            }
            finally
            {
                if (manager != null) Marshal.FinalReleaseComObject(manager);
            }
        }
    }
}
