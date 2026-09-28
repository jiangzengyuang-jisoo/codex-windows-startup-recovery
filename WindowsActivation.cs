using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace CodexStartupRecovery {
    [ComImport, Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IApplicationActivationManager {
        [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string id,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
        [PreserveSig] int ActivateForFile([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr items,
            [MarshalAs(UnmanagedType.LPWStr)] string verb, out uint processId);
        [PreserveSig] int ActivateForProtocol([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr items, out uint processId);
    }

    public static class Native {
        public static uint Activate(string appId) {
            object manager = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")));
            try {
                uint id;
                // AO_NONE: normal packaged activation, with no debug or prelaunch flags.
                int hr = ((IApplicationActivationManager)manager).ActivateApplication(appId, null, 0, out id);
                Marshal.ThrowExceptionForHR(hr);
                if (id == 0) throw new InvalidOperationException("Activation returned no process ID.");
                return id;
            } finally { Marshal.FinalReleaseComObject(manager); }
        }
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindow(string className, string title);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
        public static void FocusProgress(string title) {
            IntPtr window = FindWindow(null, title);
            if (window != IntPtr.Zero) { ShowWindow(window, 9); SetForegroundWindow(window); }
        }
    }

    // Holds an OS handle, so termination never retargets a reused PID.
    public sealed class BoundProcess : IDisposable {
        readonly SafeProcessHandle handle;
        readonly bool canTerminate;
        int terminationAttempted;
        public readonly long StartTicks;
        public readonly string ImagePath;
        [DllImport("kernel32.dll", SetLastError=true)] static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint id);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(SafeProcessHandle h, out long created, out long exited, out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(SafeProcessHandle h, uint flags, StringBuilder path, ref uint size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern int GetPackageFamilyName(SafeProcessHandle h, ref uint size, StringBuilder name);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(SafeProcessHandle h, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(SafeProcessHandle h, uint code);
        public BoundProcess(uint id, string expectedPath, long expectedStartTicks, bool allowTerminate) {
            canTerminate = allowTerminate;
            handle = OpenProcess(0x1000u | 0x100000u | (allowTerminate ? 1u : 0u), false, id);
            if (handle.IsInvalid) { int code=Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(code); }
            try {
                long c, e, k, u;
                if (!GetProcessTimes(handle, out c, out e, out k, out u)) throw new Win32Exception(Marshal.GetLastWin32Error());
                StartTicks=DateTime.FromFileTimeUtc(c).Ticks;
                uint length=32768; var path=new StringBuilder((int)length);
                if (!QueryFullProcessImageName(handle, 0, path, ref length)) throw new Win32Exception(Marshal.GetLastWin32Error());
                ImagePath=path.ToString();
                // CIM timestamps can be rounded to microseconds; allow under 1 ms only.
                if (Math.Abs(StartTicks-expectedStartTicks) >= TimeSpan.TicksPerMillisecond ||
                    !String.Equals(ImagePath, expectedPath, StringComparison.OrdinalIgnoreCase) || !IsAlive)
                    throw new InvalidOperationException("Process identity changed.");
            } catch { handle.Dispose(); throw; }
        }
        public bool IsAlive {
            get {
                uint result=WaitForSingleObject(handle, 0);
                if (result==0xFFFFFFFFu) throw new Win32Exception(Marshal.GetLastWin32Error());
                return result==258;
            }
        }
        public void AssertPackageFamily(string expected) {
            uint size=0; int result=GetPackageFamilyName(handle, ref size, null);
            if (result!=122) throw new Win32Exception(result);
            var name=new StringBuilder((int)size);
            result=GetPackageFamilyName(handle, ref size, name);
            if (result!=0) throw new Win32Exception(result);
            if (!String.Equals(name.ToString(), expected, StringComparison.Ordinal))
                throw new InvalidOperationException("Unexpected package family.");
        }
        public void TerminateOnce() {
            if (!canTerminate) throw new InvalidOperationException("This handle cannot terminate a process.");
            if (Interlocked.Exchange(ref terminationAttempted, 1)!=0)
                throw new InvalidOperationException("A second termination attempt is forbidden.");
            if (!IsAlive) throw new InvalidOperationException("The original process already exited.");
            if (!TerminateProcess(handle, 0xFFFFFFFFu)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        public void Dispose() { handle.Dispose(); }
    }
}
