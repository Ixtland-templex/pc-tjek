using System;
using System.Collections.Concurrent;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;

namespace Opticon.Services
{
    /// <summary>Tjekker en fils digitale signatur med Windows' eget WinVerifyTrust (uden net-opslag).</summary>
    public static class Signature
    {
        [StructLayout(LayoutKind.Sequential)]
        struct WINTRUST_FILE_INFO { public uint cbStruct; [MarshalAs(UnmanagedType.LPWStr)] public string pcwszFilePath; public IntPtr hFile; public IntPtr pgKnownSubject; }

        [StructLayout(LayoutKind.Sequential)]
        struct WINTRUST_DATA
        {
            public uint cbStruct; public IntPtr pPolicyCallbackData; public IntPtr pSIPClientData;
            public uint dwUIChoice; public uint fdwRevocationChecks; public uint dwUnionChoice; public IntPtr pFile;
            public uint dwStateAction; public IntPtr hWVTStateData; public IntPtr pwszURLReference;
            public uint dwProvFlags; public uint dwUIContext; public IntPtr pSignatureSettings;
        }

        [DllImport("wintrust.dll", CharSet = CharSet.Unicode)]
        static extern int WinVerifyTrust(IntPtr hwnd, ref Guid action, ref WINTRUST_DATA data);

        static readonly ConcurrentDictionary<string, string> cache = new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        static readonly string WinDir = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        static readonly string Apps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsApps");

        public static bool IsSigned(string s) { return s != null && s.StartsWith("Signeret", StringComparison.Ordinal); }

        /// <summary>"Signeret: Udgiver", "USIGNERET", "Ikke fundet" eller "Kunne ikke læses".</summary>
        public static string Check(string path)
        {
            if (string.IsNullOrEmpty(path)) return "Ikke fundet";
            return cache.GetOrAdd(path, p =>
            {
                if (!File.Exists(p)) return "Ikke fundet";
                if (p.StartsWith(Apps, StringComparison.OrdinalIgnoreCase)) return "Signeret: Microsoft Store-pakke";
                int rc = Verify(p);
                if (rc == 0)
                {
                    string who = "ukendt udgiver";
                    try
                    {
#pragma warning disable SYSLIB0057
                        var c = X509Certificate.CreateFromSignedFile(p);
#pragma warning restore SYSLIB0057
                        var m = Regex.Match(c.Subject, "CN=\"?([^,\"]+)");
                        if (m.Success) who = m.Groups[1].Value;
                    }
                    catch { }
                    return "Signeret: " + who;
                }
                // Windows' egne filer er ofte signeret via et katalog i stedet for i selve filen. Mappen kan kun ændres af Windows.
                if (p.StartsWith(WinDir + "\\System32\\", StringComparison.OrdinalIgnoreCase) || p.StartsWith(WinDir + "\\SysWOW64\\", StringComparison.OrdinalIgnoreCase) || OwnedByWindows(p))
                    return "Signeret: Microsoft Windows (katalog)";
                return "USIGNERET";
            });
        }

        /// <summary>Filer ejet af TrustedInstaller er en del af Windows selv (fx Windows Media Player) og kan kun ændres af Windows Update.</summary>
        static bool OwnedByWindows(string path)
        {
            try
            {
                var owner = new FileInfo(path).GetAccessControl().GetOwner(typeof(System.Security.Principal.SecurityIdentifier));
                return owner != null && owner.Value == "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";
            }
            catch { return false; }
        }

        static int Verify(string path)
        {
            var fi = new WINTRUST_FILE_INFO { cbStruct = (uint)Marshal.SizeOf(typeof(WINTRUST_FILE_INFO)), pcwszFilePath = path };
            IntPtr pFi = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WINTRUST_FILE_INFO)));
            try
            {
                Marshal.StructureToPtr(fi, pFi, false);
                var d = new WINTRUST_DATA
                {
                    cbStruct = (uint)Marshal.SizeOf(typeof(WINTRUST_DATA)),
                    dwUIChoice = 2,            // ingen dialoger
                    fdwRevocationChecks = 0,
                    dwUnionChoice = 1,         // fil
                    pFile = pFi,
                    dwProvFlags = 0x1000 | 0x80 // kun cache, ingen tilbagekaldelses-opslag på nettet
                };
                var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");   // WINTRUST_ACTION_GENERIC_VERIFY_V2
                return WinVerifyTrust(new IntPtr(-1), ref action, ref d);
            }
            catch { return -1; }
            finally { Marshal.DestroyStructure(pFi, typeof(WINTRUST_FILE_INFO)); Marshal.FreeHGlobal(pFi); }
        }

        /// <summary>Finder programfilen i en kommandolinje (fx '"C:\x\y.exe" -arg' eller 'C:\x\y.exe -arg').</summary>
        public static string ExePath(string cmd)
        {
            if (string.IsNullOrWhiteSpace(cmd)) return null;
            var c = Environment.ExpandEnvironmentVariables(cmd).Trim();
            var m = Regex.Match(c, "^\"([^\"]+)\"");
            if (m.Success) return m.Groups[1].Value;
            m = Regex.Match(c, @"^(.+?\.(exe|dll|bat|cmd|ps1|vbs|js|com|scr))(\s|,|$)", RegexOptions.IgnoreCase);
            if (m.Success) return m.Groups[1].Value;
            var first = c.Split(' ')[0];
            if (!first.Contains("\\"))
            {
                var sys = Path.Combine(Environment.SystemDirectory, first.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? first : first + ".exe");
                if (File.Exists(sys)) return sys;
            }
            return first;
        }
    }
}
