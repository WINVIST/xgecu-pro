// QA-only same-user launcher. No credentials, users, policy, or registry changes.
// https://learn.microsoft.com/windows/win32/api/securitybaseapi/nf-securitybaseapi-createrestrictedtoken
// https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessasuserw
// https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
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
        [StructLayout(LayoutKind.Sequential)]
        struct TokenGroupsLayout { public uint Count; public SidAndAttributes First; }
        [StructLayout(LayoutKind.Sequential)]
        struct GenericMapping { public uint Read, Write, Execute, All; }
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
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool DuplicateTokenEx(NativeHandle token, uint access, IntPtr attributes,
            int level, int type, out NativeHandle duplicate);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool AccessCheck([In] byte[] descriptor, NativeHandle token, uint desired,
            ref GenericMapping mapping, IntPtr privileges, ref uint size, out uint granted,
            [MarshalAs(UnmanagedType.Bool)] out bool allowed);
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
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr GetProcessWindowStation();
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr GetThreadDesktop(uint thread);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetUserObjectInformationW(IntPtr handle, int index, StringBuilder value, uint size, out uint needed);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr OpenWindowStationW(string name, bool inherit, uint access);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr OpenDesktopW(string name, uint flags, bool inherit, uint access);
        [DllImport("user32.dll", SetLastError = true)] static extern bool CloseWindowStation(IntPtr handle);
        [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr handle);
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool GetUserObjectSecurity(IntPtr handle, ref uint information, [Out] byte[] descriptor, uint size, out uint needed);
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool SetUserObjectSecurity(IntPtr handle, ref uint information, [In] byte[] descriptor);

        static Win32Exception Error(string operation) { return new Win32Exception(Marshal.GetLastWin32Error(), operation); }

        static T TokenValue<T>(NativeHandle token, int kind, Func<IntPtr, T> read)
        {
            uint size;
            GetTokenInformation(token, kind, IntPtr.Zero, 0, out size);
            if (size == 0) throw Error("GetTokenInformation(size, " + kind + ")");
            IntPtr buffer = Marshal.AllocHGlobal(checked((int)size));
            try {
                if (!GetTokenInformation(token, kind, buffer, size, out size)) throw Error("GetTokenInformation(" + kind + ")");
                return read(buffer);
            } finally { Marshal.FreeHGlobal(buffer); }
        }

        static string TokenSid(NativeHandle token, int kind)
        {
            return TokenValue(token, kind, p => new SecurityIdentifier(Marshal.ReadIntPtr(p)).Value);
        }

        static RawAcl DefaultDacl(NativeHandle token)
        {
            return TokenValue(token, 6, p => {
                IntPtr acl = Marshal.ReadIntPtr(p);
                if (acl == IntPtr.Zero) return null;
                var bytes = new byte[unchecked((ushort)Marshal.ReadInt16(acl, 2))];
                Marshal.Copy(acl, bytes, 0, bytes.Length);
                return new RawAcl(bytes, 0);
            });
        }

        static string GroupList(NativeHandle token, int kind)
        {
            return TokenValue(token, kind, p => {
                uint count = unchecked((uint)Marshal.ReadInt32(p));
                int offset = Marshal.OffsetOf<TokenGroupsLayout>("First").ToInt32();
                var result = new StringBuilder("count=" + count);
                for (int i = 0; i < Math.Min(count, 32); i++) {
                    var value = Marshal.PtrToStructure<SidAndAttributes>(IntPtr.Add(p, offset + i * Marshal.SizeOf<SidAndAttributes>()));
                    result.Append(' ').Append(new SecurityIdentifier(value.Sid).Value).Append(":0x").Append(value.Attributes.ToString("X8"));
                }
                return result.ToString();
            });
        }

        static void DescribeToken(string name, NativeHandle token)
        {
            // Bounded security metadata only: no environment, credentials, or command line.
            var acl = DefaultDacl(token);
            var descriptor = new RawSecurityDescriptor(ControlFlags.DiscretionaryAclPresent,
                new SecurityIdentifier(TokenSid(token, 4)), null, null, acl);
            Console.WriteLine("[windows-native] Token " + name + ": IL=" + Integrity(token) +
                " elevated=" + TokenValue(token, 20, p => Marshal.ReadInt32(p) != 0) +
                " user=" + TokenSid(token, 1) + " owner=" + TokenSid(token, 4) +
                " default=" + descriptor.GetSddlForm(AccessControlSections.Owner | AccessControlSections.Access));
            Console.WriteLine("[windows-native] Token " + name + " groups: " + GroupList(token, 2));
            Console.WriteLine("[windows-native] Token " + name + " restricting SIDs: " + GroupList(token, 11));
        }

        // A UAC-disabled administrator's default owner/DACL can retain only the
        // Administrators group, which LUA_TOKEN marks deny-only. Repair only the
        // NEW token's defaults so its child can access its own kernel objects.
        // https://learn.microsoft.com/windows/win32/api/securitybaseapi/nf-securitybaseapi-settokeninformation
        static void SetOwnedDefaults(NativeHandle token)
        {
            var user = new SecurityIdentifier(TokenSid(token, 1));
            var sid = new byte[user.BinaryLength]; user.GetBinaryForm(sid, 0);
            IntPtr owner = Marshal.AllocHGlobal(IntPtr.Size + sid.Length);
            try {
                Marshal.WriteIntPtr(owner, IntPtr.Add(owner, IntPtr.Size));
                Marshal.Copy(sid, 0, IntPtr.Add(owner, IntPtr.Size), sid.Length);
                if (!SetTokenInformation(token, 4, owner, checked((uint)(IntPtr.Size + sid.Length)))) throw Error("SetTokenInformation(TokenOwner=current user)");
            } finally { Marshal.FreeHGlobal(owner); }
            var acl = DefaultDacl(token) ?? new RawAcl(2, 2);
            int position = 0;
            while (position < acl.Count && (acl[position].AceFlags & AceFlags.Inherited) == 0) position++;
            acl.InsertAce(position++, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, 0x10000000, user, false, null));
            acl.InsertAce(position, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, 0x10000000,
                new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), false, null));
            var bytes = new byte[acl.BinaryLength]; acl.GetBinaryForm(bytes, 0);
            IntPtr dacl = Marshal.AllocHGlobal(IntPtr.Size + bytes.Length);
            try {
                Marshal.WriteIntPtr(dacl, IntPtr.Add(dacl, IntPtr.Size));
                Marshal.Copy(bytes, 0, IntPtr.Add(dacl, IntPtr.Size), bytes.Length);
                if (!SetTokenInformation(token, 6, dacl, checked((uint)(IntPtr.Size + bytes.Length)))) throw Error("SetTokenInformation(TokenDefaultDacl=current user/System)");
            } finally { Marshal.FreeHGlobal(dacl); }
        }

        static string UserObjectName(IntPtr handle)
        {
            if (handle == IntPtr.Zero) throw Error("Get current USER object");
            uint needed;
            GetUserObjectInformationW(handle, 2, null, 0, out needed); // UOI_NAME
            if (needed == 0) throw Error("GetUserObjectInformationW(name size)");
            var name = new StringBuilder(checked((int)needed / 2));
            if (!GetUserObjectInformationW(handle, 2, name, needed, out needed)) throw Error("GetUserObjectInformationW(name)");
            return name.ToString();
        }

        public static string CurrentDesktop()
        {
            // These two handles are borrowed, and must not be closed here.
            return UserObjectName(GetProcessWindowStation()) + "\\" + UserObjectName(GetThreadDesktop(GetCurrentThreadId()));
        }

        // Restricted LUA tokens deny the Administrators SID. On hosted runners
        // with UAC disabled, WinSta/desktop DACLs may grant only that group GUI
        // access, causing user32 DLL initialization to fail before pwsh starts.
        // https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-setuserobjectsecurity
        // https://learn.microsoft.com/windows/win32/winstation/window-station-security-and-access-rights
        // https://learn.microsoft.com/windows/win32/winstation/desktop-security-and-access-rights
        sealed class DesktopAccess : IDisposable
        {
            sealed class Grant
            {
                public IntPtr Handle;
                public byte[] Original, Applied, Ace;
                public int OriginalMatches;
            }
            IntPtr station, desktop;
            Grant stationGrant, desktopGrant;
            public string Path { get; private set; }

            static byte[] Read(IntPtr handle, uint information = 4)
            {
                uint needed; // Writes below are DACL only; never change owner/SACL.
                GetUserObjectSecurity(handle, ref information, null, 0, out needed);
                if (needed == 0) throw Error("GetUserObjectSecurity(size)");
                var descriptor = new byte[needed];
                if (!GetUserObjectSecurity(handle, ref information, descriptor, needed, out needed)) throw Error("GetUserObjectSecurity(DACL)");
                return descriptor;
            }

            static void DescribeObject(string name, IntPtr handle, NativeHandle token, GenericMapping mapping)
            {
                try {
                    // LABEL_SECURITY_INFORMATION requests just the mandatory label,
                    // not the audit SACL. Fall back explicitly if the OS denies it.
                    byte[] security;
                    try { security = Read(handle, 0x17); }
                    catch (Win32Exception e) {
                        Console.WriteLine("[windows-native] " + name + " label unavailable: Win32=" + e.NativeErrorCode);
                        security = Read(handle, 7);
                    }
                    Console.WriteLine("[windows-native] " + name + " security=" + new RawSecurityDescriptor(security, 0).GetSddlForm(AccessControlSections.All));
                    NativeHandle impersonation;
                    if (!DuplicateTokenEx(token, 0x8, IntPtr.Zero, 2, 2, out impersonation)) throw Error("DuplicateTokenEx(AccessCheck)");
                    using (impersonation) {
                        IntPtr privileges = Marshal.AllocHGlobal(4096);
                        try {
                            uint size = 4096, granted; bool allowed;
                            if (!AccessCheck(Read(handle, 7), impersonation, 0x02000000, ref mapping, privileges, ref size, out granted, out allowed))
                                throw Error("AccessCheck(MAXIMUM_ALLOWED)");
                            Console.WriteLine("[windows-native] " + name + " restricted DACL access: allowed=" + allowed +
                                " maximum=0x" + granted.ToString("X8") + " full=" + ((granted & mapping.All) == mapping.All));
                        } finally { Marshal.FreeHGlobal(privileges); }
                    }
                } catch (Win32Exception e) { Console.WriteLine("[windows-native] " + name + " access diagnostic unavailable: Win32=" + e.NativeErrorCode); }
            }
            static void Write(IntPtr handle, byte[] descriptor)
            {
                uint information = 4;
                if (!SetUserObjectSecurity(handle, ref information, descriptor)) throw Error("SetUserObjectSecurity(DACL)");
            }
            static byte[] Binary(GenericSecurityDescriptor value)
            {
                var bytes = new byte[value.BinaryLength]; value.GetBinaryForm(bytes, 0); return bytes;
            }
            static byte[] AceBinary(GenericAce value)
            {
                var bytes = new byte[value.BinaryLength]; value.GetBinaryForm(bytes, 0); return bytes;
            }
            static bool Equal(byte[] left, byte[] right)
            {
                if (left == null || right == null) return left == right;
                if (left.Length != right.Length) return false;
                for (int i = 0; i < left.Length; i++) if (left[i] != right[i]) return false;
                return true;
            }
            static byte[] AclBinary(byte[] descriptor)
            {
                var acl = new RawSecurityDescriptor(descriptor, 0).DiscretionaryAcl;
                if (acl == null) return null;
                var bytes = new byte[acl.BinaryLength]; acl.GetBinaryForm(bytes, 0); return bytes;
            }
            static int Matches(RawAcl acl, byte[] ace)
            {
                int count = 0;
                if (acl != null) for (int i = 0; i < acl.Count; i++) if (Equal(AceBinary(acl[i]), ace)) count++;
                return count;
            }
            static Grant Add(IntPtr handle, SecurityIdentifier user, int rights)
            {
                var original = Read(handle);
                var descriptor = new RawSecurityDescriptor(original, 0);
                if (descriptor.DiscretionaryAcl == null) return null; // NULL DACL already allows access.
                var ace = new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, rights, user, false, null);
                var added = AceBinary(ace);
                int matches = Matches(descriptor.DiscretionaryAcl, added);
                int position = 0;
                while (position < descriptor.DiscretionaryAcl.Count &&
                    (descriptor.DiscretionaryAcl[position].AceFlags & AceFlags.Inherited) == 0) position++;
                descriptor.DiscretionaryAcl.InsertAce(position, ace);
                var grant = new Grant { Handle = handle, Original = original, Applied = Binary(descriptor), Ace = added, OriginalMatches = matches };
                Write(handle, grant.Applied);
                return grant;
            }
            static void Restore(Grant grant)
            {
                if (grant == null) return;
                var current = Read(grant.Handle);
                if (Equal(AclBinary(current), AclBinary(grant.Applied))) {
                    Write(grant.Handle, grant.Original);
                    if (!Equal(AclBinary(Read(grant.Handle)), AclBinary(grant.Original)))
                        throw new InvalidOperationException("The original GUI-object DACL was not restored.");
                } else {
                    // Preserve unrelated concurrent changes; remove only our
                    // additional matching ACE, never a pre-existing entry.
                    var descriptor = new RawSecurityDescriptor(current, 0);
                    var acl = descriptor.DiscretionaryAcl;
                    if (Matches(acl, grant.Ace) <= grant.OriginalMatches) return;
                    for (int i = acl.Count - 1; i >= 0; i--) if (Equal(AceBinary(acl[i]), grant.Ace)) {
                        acl.RemoveAce(i); Write(grant.Handle, Binary(descriptor)); break;
                    }
                }
            }

            public static DesktopAccess ForElevatedCaller(NativeHandle token)
            {
                if (CurrentIntegrity() < 0x3000 && !CurrentElevated()) return null;
                var scope = new DesktopAccess();
                try
                {
                    string stationName = UserObjectName(GetProcessWindowStation());
                    string desktopName = UserObjectName(GetThreadDesktop(GetCurrentThreadId()));
                    scope.Path = stationName + "\\" + desktopName;
                    // CreateProcessAsUser requires full access to both objects.
                    // Only same-user access is added, and restored in Dispose.
                    scope.station = OpenWindowStationW(stationName, false, 0x00060002);
                    if (scope.station == IntPtr.Zero) throw Error("OpenWindowStationW(READ_CONTROL | WRITE_DAC)");
                    scope.desktop = OpenDesktopW(desktopName, 0, false, 0x00060081);
                    if (scope.desktop == IntPtr.Zero) throw Error("OpenDesktopW(READ_CONTROL | WRITE_DAC)");
                    var stationMapping = new GenericMapping { Read = 0x20303, Write = 0x2001c, Execute = 0x20060, All = 0xf037f };
                    var desktopMapping = new GenericMapping { Read = 0x20041, Write = 0x200be, Execute = 0x20100, All = 0xf01ff };
                    DescribeObject("station before", scope.station, token, stationMapping);
                    DescribeObject("desktop before", scope.desktop, token, desktopMapping);
                    var user = new SecurityIdentifier(CurrentUserSid());
                    scope.stationGrant = Add(scope.station, user, 0x000f037f);
                    scope.desktopGrant = Add(scope.desktop, user, 0x000f01ff);
                    DescribeObject("station after", scope.station, token, stationMapping);
                    DescribeObject("desktop after", scope.desktop, token, desktopMapping);
                    Console.WriteLine("[windows-native] Temporary same-user GUI access: " + scope.Path);
                    return scope;
                }
                catch { scope.Dispose(); throw; }
            }

            public void Dispose()
            {
                Exception failure = null;
                try { Restore(desktopGrant); } catch (Exception e) { failure = e; } finally { desktopGrant = null; }
                try { Restore(stationGrant); } catch (Exception e) { failure = failure == null ? e : new AggregateException(failure, e); } finally { stationGrant = null; }
                if (desktop != IntPtr.Zero) {
                    if (!CloseDesktop(desktop)) failure = failure ?? Error("CloseDesktop");
                    desktop = IntPtr.Zero;
                }
                if (station != IntPtr.Zero) {
                    if (!CloseWindowStation(station)) failure = failure ?? Error("CloseWindowStation");
                    station = IntPtr.Zero;
                }
                if (failure != null) throw failure;
                if (Path != null) Console.WriteLine("[windows-native] Same-user GUI DACL access restored: " + Path);
            }
        }
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
                bool elevatedCaller = Integrity(original) >= 0x3000 || TokenValue(original, 20, p => Marshal.ReadInt32(p) != 0);
                DescribeToken("original", original);
                NativeHandle restricted;
                if (!CreateRestrictedToken(original, DisableMaxPrivilege | LuaToken, 0, IntPtr.Zero, 0,
                    IntPtr.Zero, 0, IntPtr.Zero, out restricted)) throw Error("CreateRestrictedToken(DISABLE_MAX_PRIVILEGE | LUA_TOKEN)");
                using (restricted)
                {
                    SetMedium(restricted);
                    DescribeToken("restricted before defaults", restricted);
                    if (elevatedCaller) SetOwnedDefaults(restricted);
                    DescribeToken("restricted launch", restricted);
                    using (var desktopAccess = DesktopAccess.ForElevatedCaller(restricted))
                    {
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
                                    desktop = desktopAccess == null ? null : desktopAccess.Path,
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
}
