// QA-only same-user launcher. No credentials, users, policy, or registry changes.
// https://learn.microsoft.com/windows/win32/api/securitybaseapi/nf-securitybaseapi-createrestrictedtoken
// https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessasuserw
// https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Xgecu.Qa
{
    public static class MediumLaunch
    {
        const uint TokenAccess = 0x0001 | 0x0002 | 0x0008 | 0x0080; // assign, duplicate, query, adjust-default
        const int TokenIntegrityLevel = 25;
        const uint MediumIntegrity = 0x2000;
        const uint DisableMaxPrivilege = 0x1, LuaToken = 0x4;
        const uint ExtendedStartupInfo = 0x00080000, CreateNoWindow = 0x08000000;
        const uint WaitTimeout = 258;

        sealed class NativeHandle : SafeHandleZeroOrMinusOneIsInvalid
        {
            public NativeHandle() : base(true) { }
            public NativeHandle(IntPtr value) : base(true) { SetHandle(value); }
            protected override bool ReleaseHandle() { return CloseHandle(handle); }
        }

        [StructLayout(LayoutKind.Sequential)]
        struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct StartupInfo
        {
            public uint cb;
            public string reserved, desktop, title;
            public uint x, y, xSize, ySize, xChars, yChars, fill, flags;
            public ushort showWindow, reservedSize;
            public IntPtr reservedBytes, stdin, stdout, stderr;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct StartupInfoEx { public StartupInfo startup; public IntPtr attributes; }
        [StructLayout(LayoutKind.Sequential)]
        struct ProcessInformation { public IntPtr process, thread; public uint processId, threadId; }
        [StructLayout(LayoutKind.Sequential)]
        struct SecurityAttributes
        {
            public uint length;
            public IntPtr descriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool inherit;
        }

        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool OpenProcessToken(IntPtr process, uint access, out NativeHandle token);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool GetTokenInformation(NativeHandle token, int kind, IntPtr buffer, uint size, out uint required);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool SetTokenInformation(NativeHandle token, int kind, IntPtr buffer, uint size);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool CreateRestrictedToken(NativeHandle original, uint flags, uint disabledCount,
            IntPtr disabled, uint deletedCount, IntPtr deleted, uint restrictedCount, IntPtr restricted, out NativeHandle token);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern NativeHandle CreateFileW(string name, uint access, uint share, ref SecurityAttributes security,
            uint disposition, uint attributes, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool InitializeProcThreadAttributeList(IntPtr list, uint count, uint flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value,
            IntPtr size, IntPtr previous, IntPtr returnedSize);
        [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcessAsUserW(NativeHandle token, string application, StringBuilder commandLine,
            IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment,
            string directory, ref StartupInfoEx startup, out ProcessInformation process);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(NativeHandle handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(NativeHandle handle, out uint code);

        static Win32Exception Error(string operation) { return new Win32Exception(Marshal.GetLastWin32Error(), operation); }
        static NativeHandle CurrentToken(uint access)
        {
            NativeHandle token;
            if (!OpenProcessToken(GetCurrentProcess(), access, out token)) throw Error("OpenProcessToken");
            return token;
        }

        static uint Integrity(NativeHandle token)
        {
            uint size;
            GetTokenInformation(token, TokenIntegrityLevel, IntPtr.Zero, 0, out size);
            if (size == 0) throw Error("GetTokenInformation(TokenIntegrityLevel size)");
            IntPtr buffer = Marshal.AllocHGlobal(checked((int)size));
            try
            {
                if (!GetTokenInformation(token, TokenIntegrityLevel, buffer, size, out size)) throw Error("GetTokenInformation(TokenIntegrityLevel)");
                var label = Marshal.PtrToStructure<SidAndAttributes>(buffer);
                string sid = new SecurityIdentifier(label.Sid).Value;
                return uint.Parse(sid.Substring(sid.LastIndexOf('-') + 1), System.Globalization.CultureInfo.InvariantCulture);
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        public static uint CurrentIntegrity()
        {
            using (var token = CurrentToken(0x0008)) return Integrity(token);
        }

        public static bool CurrentElevated()
        {
            using (var token = CurrentToken(0x0008))
            {
                IntPtr value = Marshal.AllocHGlobal(sizeof(uint));
                try
                {
                    uint size;
                    if (!GetTokenInformation(token, 20, value, sizeof(uint), out size)) throw Error("GetTokenInformation(TokenElevation)");
                    return Marshal.ReadInt32(value) != 0;
                }
                finally { Marshal.FreeHGlobal(value); }
            }
        }

        public static string CurrentUserSid()
        {
            using (var identity = WindowsIdentity.GetCurrent()) return identity.User.Value;
        }

        static void SetMedium(NativeHandle token)
        {
            var sid = new SecurityIdentifier("S-1-16-8192");
            var bytes = new byte[sid.BinaryLength];
            sid.GetBinaryForm(bytes, 0);
            int labelSize = Marshal.SizeOf<SidAndAttributes>();
            IntPtr buffer = Marshal.AllocHGlobal(labelSize + bytes.Length);
            try
            {
                IntPtr sidPointer = IntPtr.Add(buffer, labelSize);
                Marshal.Copy(bytes, 0, sidPointer, bytes.Length);
                Marshal.StructureToPtr(new SidAndAttributes { Sid = sidPointer, Attributes = 0x20 }, buffer, false);
                if (!SetTokenInformation(token, TokenIntegrityLevel, buffer, checked((uint)(labelSize + bytes.Length))))
                    throw Error("SetTokenInformation(Medium Integrity)");
            }
            finally { Marshal.FreeHGlobal(buffer); }
            if (Integrity(token) != MediumIntegrity) throw new InvalidOperationException("Restricted token did not acquire Medium Integrity.");
        }

        static string Quote(string value)
        {
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes);
                result.Append(c);
                slashes = 0;
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }

        static NativeHandle Output(string path, ref SecurityAttributes security)
        {
            var handle = CreateFileW(path, 0x40000000, 3, ref security, 1, 0x80, IntPtr.Zero); // CREATE_NEW, inheritable
            if (handle.IsInvalid) { handle.Dispose(); throw Error("CreateFileW(QA output)"); }
            return handle;
        }

        static void Forward(StreamReader reader, TextWriter destination)
        {
            try
            {
                string text = reader.ReadToEnd();
                if (text.Length != 0) { destination.Write(text); destination.Flush(); }
            }
            catch (IOException) { /* Raw output remains in the evidence files. */ }
        }

        public static int Run(string executable, string[] arguments, string directory, string stdout, string stderr)
        {
            // Restricted versions of our own token are exempt from the
            // SeAssignPrimaryToken requirement. CreateProcessAsUser temporarily
            // enables SeIncreaseQuota if held; missing rights fail explicitly.
            using (var original = CurrentToken(TokenAccess))
            {
                NativeHandle restricted;
                if (!CreateRestrictedToken(original, DisableMaxPrivilege | LuaToken, 0, IntPtr.Zero, 0,
                    IntPtr.Zero, 0, IntPtr.Zero, out restricted)) throw Error("CreateRestrictedToken(DISABLE_MAX_PRIVILEGE | LUA_TOKEN)");
                using (restricted)
                {
                    SetMedium(restricted);
                    var security = new SecurityAttributes { length = (uint)Marshal.SizeOf<SecurityAttributes>(), inherit = true };
                    using (var output = Output(stdout, ref security))
                    using (var error = Output(stderr, ref security))
                    using (var input = CreateFileW("NUL", 0x80000000, 3, ref security, 3, 0x80, IntPtr.Zero))
                    {
                        if (input.IsInvalid) throw Error("CreateFileW(NUL)");
                        IntPtr attributeSize = IntPtr.Zero, attributes = IntPtr.Zero, handles = IntPtr.Zero;
                        bool initialized = false;
                        try
                        {
                            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeSize);
                            if (attributeSize == IntPtr.Zero) throw Error("InitializeProcThreadAttributeList(size)");
                            attributes = Marshal.AllocHGlobal(attributeSize);
                            if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref attributeSize)) throw Error("InitializeProcThreadAttributeList");
                            initialized = true;
                            handles = Marshal.AllocHGlobal(IntPtr.Size * 3);
                            Marshal.WriteIntPtr(handles, 0, input.DangerousGetHandle());
                            Marshal.WriteIntPtr(handles, IntPtr.Size, output.DangerousGetHandle());
                            Marshal.WriteIntPtr(handles, IntPtr.Size * 2, error.DangerousGetHandle());
                            // Inherit exactly our three streams, not arbitrary PowerShell handles.
                            if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x20002), handles,
                                new IntPtr(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero)) throw Error("UpdateProcThreadAttribute(HANDLE_LIST)");
                            var startup = new StartupInfoEx {
                                attributes = attributes,
                                startup = new StartupInfo {
                                    cb = (uint)Marshal.SizeOf<StartupInfoEx>(), flags = 0x100 | 0x1, showWindow = 0,
                                    stdin = input.DangerousGetHandle(), stdout = output.DangerousGetHandle(), stderr = error.DangerousGetHandle()
                                }
                            };
                            var command = new StringBuilder(Quote(executable));
                            foreach (string argument in arguments) command.Append(' ').Append(Quote(argument));
                            ProcessInformation child;
                            if (!CreateProcessAsUserW(restricted, executable, command, IntPtr.Zero, IntPtr.Zero, true,
                                ExtendedStartupInfo | CreateNoWindow, IntPtr.Zero, directory, ref startup, out child))
                                throw Error("CreateProcessAsUserW(same-user restricted QA process; SeIncreaseQuota may be required)");
                            using (var process = new NativeHandle(child.process))
                            using (var thread = new NativeHandle(child.thread))
                            using (var outReader = new StreamReader(new FileStream(stdout, FileMode.Open, FileAccess.Read, FileShare.ReadWrite), Encoding.UTF8))
                            using (var errReader = new StreamReader(new FileStream(stderr, FileMode.Open, FileAccess.Read, FileShare.ReadWrite), Encoding.UTF8))
                            {
                                uint wait;
                                do {
                                    wait = WaitForSingleObject(process, 1000);
                                    Forward(outReader, Console.Out);
                                    Forward(errReader, Console.Error);
                                } while (wait == WaitTimeout);
                                if (wait != 0) throw Error("WaitForSingleObject(QA process)");
                                uint code;
                                if (!GetExitCodeProcess(process, out code)) throw Error("GetExitCodeProcess(QA process)");
                                return unchecked((int)code);
                            }
                        }
                        finally
                        {
                            if (initialized) DeleteProcThreadAttributeList(attributes);
                            if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                            if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
                        }
                    }
                }
            }
        }
    }
}
