using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Opticon.Services
{
    /// <summary>Ekstra dele af "Scan pc'en": nye programfiler, netværksforbindelser, browserudvidelser og MalwareBazaar.</summary>
    public static class ScanExtra
    {
        static void Safe(string what, Action a) { try { a(); } catch (Exception e) { App.Log("Scan " + what + ": " + e.Message); } }

        static ScanFind Add(ScanResult r, int lvl, string cat, string title, string detail, string why, string path, string advice, string file = null)
        {
            var f = new ScanFind { Level = lvl, Category = cat, Title = title, Detail = detail, Why = why, Path = path, Advice = advice, FilePath = file != null && File.Exists(file) ? file : null };
            lock (r.Finds) r.Finds.Add(f);
            return f;
        }

        // ---------- Nye programfiler i typiske gemmesteder ----------
        static readonly HashSet<string> Ext = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".exe", ".dll", ".ps1", ".vbs", ".js", ".bat", ".cmd", ".msi", ".scr", ".jar", ".hta" };
        static readonly Regex SkipPath = new Regex(@"\\(Packages|WinGet|Microsoft\\Edge|Microsoft\\Teams|Google\\Chrome\\Application|Google\\Chrome\\User Data\\[^\\]+\\(Cache|Code Cache|Extensions)|npm-cache|pip\\cache|Discord\\app-|Spotify|NVIDIA|Steam|squirrel|Opticon|\\Programs\\(Microsoft VS Code|Obsidian|GitHub Desktop|claude|chatgpt|Opticon))\\", RegexOptions.IgnoreCase);
        static readonly Regex SkipDir = new Regex(@"^(node_modules|\.git|Packages|WindowsApps|WinGet|Package Cache|Cache|Code Cache|GPUCache|cache2|CacheStorage|Service Worker|IndexedDB|INetCache|npm-cache|\.cache|DXCache|GLCache|D3DSCache|Crashpad)$", RegexOptions.IgnoreCase);

        public static void NewFiles(ScanResult r, Action<double, string> progress, string mbKey)
        {
            var since = DateTime.Now.AddDays(-45);
            var roots = new[] { Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), Path.GetTempPath().TrimEnd('\\'), Environment.GetEnvironmentVariable("PUBLIC") ?? "",
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Temp") }.Where(Directory.Exists).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            var found = new List<FileInfo>();
            int seen = 0;
            foreach (var root in roots)
            {
                var stack = new Stack<DirectoryInfo>(); stack.Push(new DirectoryInfo(root));
                while (stack.Count > 0)
                {
                    var d = stack.Pop();
                    try
                    {
                        foreach (var e in d.EnumerateFileSystemInfos())
                        {
                            if (e is DirectoryInfo)
                            {
                                if ((e.Attributes & FileAttributes.ReparsePoint) != 0 || SkipDir.IsMatch(e.Name)) continue;
                                stack.Push((DirectoryInfo)e);
                            }
                            else
                            {
                                seen++;
                                if (seen % 2000 == 0) progress(-1, string.Format("Leder efter nye programfiler · {0:N0} filer gennemgået", seen));
                                if (Ext.Contains(e.Extension) && e.CreationTime > since && !SkipPath.IsMatch(e.FullName)) found.Add((FileInfo)e);
                            }
                        }
                    }
                    catch { }
                }
            }
            var files = found.OrderByDescending(f => f.CreationTime).Take(1500).ToList();
            int n = 0;
            var flagged = new List<ScanFind>();
            foreach (var f in files)
            {
                n++; if (n % 20 == 0) progress(-1, "Tjekker signaturer på nye filer (" + n + " af " + files.Count + ")…");
                string ext = f.Extension.ToLowerInvariant();
                bool bin = ext == ".exe" || ext == ".dll" || ext == ".msi" || ext == ".scr";
                string sig = bin ? Signature.Check(f.FullName) : "script";
                if (Signature.IsSigned(sig)) continue;
                string p = f.FullName;
                bool hideout = Regex.IsMatch(p, @"\\(Temp|Users\\Public|Start Menu\\Programs\\Startup)\\", RegexOptions.IgnoreCase) || Regex.IsMatch(p, @"\\AppData\\(Roaming|Local)\\[^\\]+$", RegexOptions.IgnoreCase) || Regex.IsMatch(p, @"^C:\\ProgramData\\[^\\]+$", RegexOptions.IgnoreCase);
                bool risky = ext == ".hta" || ext == ".scr" || (new[] { ".vbs", ".js", ".jar", ".ps1", ".bat", ".cmd" }.Contains(ext) && hideout) || Regex.IsMatch(p, @"\\Users\\Public\\", RegexOptions.IgnoreCase)
                    || Regex.IsMatch(p, @"\\AppData\\(Roaming|Local)\\[^\\]+\.(exe|dll|scr)$", RegexOptions.IgnoreCase) || Regex.IsMatch(p, @"^C:\\ProgramData\\[^\\]+\.(exe|dll|scr)$", RegexOptions.IgnoreCase);
                string sha = null;
                if (f.Length < 100L << 20) try { using (var s = SHA256.Create()) using (var st = f.OpenRead()) sha = BitConverter.ToString(s.ComputeHash(st)).Replace("-", "").ToLowerInvariant(); } catch { }
                var x = Add(r, risky ? 2 : 1, "Ny fil", f.Name, Math.Round(f.Length / 1024.0) + " KB · oprettet " + f.CreationTime.ToString("d. MMM yyyy") + " · " + sig,
                    "Usigneret programfil oprettet for nylig et sted, hvor malware ofte lægger sig. Mange er ufarlige (spil, værktøjer). Brug VirusTotal ved tvivl.", f.FullName, "", f.FullName);
                x.Sha = sha;
                r.Checked++;
                if (risky) flagged.Add(x);
            }

            // Defender tjekker de markerede filer (kun læsning: -DisableRemediation)
            var mp = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Windows Defender", "MpCmdRun.exe");
            if (File.Exists(mp))
            {
                int ci = 0;
                foreach (var x in flagged.Take(40))
                {
                    ci++; progress(-1, "Defender tjekker markerede filer (" + ci + " af " + Math.Min(40, flagged.Count) + ")…");
                    if (!File.Exists(x.Path)) continue;
                    try
                    {
                        var psi = new ProcessStartInfo(mp, "-Scan -ScanType 3 -File \"" + x.Path + "\" -DisableRemediation") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
                        using (var p = Process.Start(psi))
                        {
                            var o = p.StandardOutput.ReadToEnd();
                            if (!p.WaitForExit(120000)) { try { p.Kill(); } catch { } continue; }
                            var m = Regex.Match(o, @"found (\d+) threat", RegexOptions.IgnoreCase);
                            if (m.Success && int.Parse(m.Groups[1].Value) > 0)
                            {
                                x.Level = 4; x.Category = "Trussel"; x.Title = "Defender fandt malware: " + Path.GetFileName(x.Path);
                                x.Why = "Fundet af Defender under tjekket. Scanningen har ikke ændret noget, så filen ligger der stadig.";
                                x.Advice = "Åbn Windows Sikkerhed → Virus- og trusselsbeskyttelse, og lad Defender fjerne den. Eller kør en Defender Offline-scanning.";
                            }
                            else if (p.ExitCode == 0 && Regex.IsMatch(o, "found no threats", RegexOptions.IgnoreCase))
                            {
                                x.Level = 1; x.Detail = "✓ Tjekket af Defender: intet fundet · " + x.Detail;
                            }
                        }
                    }
                    catch { }
                }
            }

            // MalwareBazaar (valgfrit): kun fingeraftrykket sendes, aldrig filen
            if (!string.IsNullOrEmpty(mbKey)) MalwareBazaar(r, mbKey, progress);
        }

        static void MalwareBazaar(ScanResult r, string key, Action<double, string> progress)
        {
            var list = r.Finds.Where(f => f.Category == "Ny fil" && !string.IsNullOrEmpty(f.Sha)).Take(60).ToList();
            if (list.Count == 0) return;
            int hits = 0, fails = 0, i = 0;
            using (var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) })
            {
                http.DefaultRequestHeaders.Add("Auth-Key", key);
                foreach (var x in list)
                {
                    i++; progress(-1, "MalwareBazaar tjekker usignerede filer (" + i + " af " + list.Count + ")…");
                    try
                    {
                        var resp = http.PostAsync("https://mb-api.abuse.ch/api/v1/", new FormUrlEncodedContent(new Dictionary<string, string> { { "query", "get_info" }, { "hash", x.Sha } })).Result;
                        using (var doc = JsonDocument.Parse(resp.Content.ReadAsStringAsync().Result))
                        {
                            var st = doc.RootElement.TryGetProperty("query_status", out var q) ? q.GetString() : "";
                            if (st == "ok" && doc.RootElement.TryGetProperty("data", out var data) && data.GetArrayLength() > 0)
                            {
                                hits++;
                                var d0 = data[0];
                                string fam = d0.TryGetProperty("signature", out var sg) && sg.ValueKind == JsonValueKind.String ? sg.GetString() : "";
                                x.Level = 4; x.Category = "Trussel";
                                x.Title = "Kendt malware: " + Path.GetFileName(x.Path) + (string.IsNullOrEmpty(fam) ? "" : " (" + fam + ")");
                                x.Why = "Filens fingeraftryk findes i MalwareBazaar, en database med over 1 million bekræftede malware-filer." + (string.IsNullOrEmpty(fam) ? "" : " Familie: " + fam + ".");
                                x.Advice = "Lad Defender fjerne den, eller kør en Defender Offline-scanning. Har filen kørt, så skift dine vigtigste adgangskoder fra en anden enhed.";
                            }
                            else if (st == "hash_not_found") x.Detail = "✓ Ukendt for MalwareBazaar · " + x.Detail;
                            else fails++;
                        }
                    }
                    catch { fails++; }
                    if (fails >= 3 && hits == 0 && i <= 3) break;
                    System.Threading.Thread.Sleep(150);
                }
            }
            App.Log("MalwareBazaar: " + i + " tjekket, " + hits + " kendt malware, " + fails + " fejl");
        }

        // ---------- Netværksforbindelser ----------
        [StructLayout(LayoutKind.Sequential)] struct MIB_TCPROW_OWNER_PID { public uint state, localAddr, localPort, remoteAddr, remotePort, owningPid; }
        [DllImport("iphlpapi.dll", SetLastError = true)] static extern uint GetExtendedTcpTable(IntPtr pTcpTable, ref int size, bool order, int af, int tableClass, uint reserved);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder name, ref int size);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

        static string ProcPath(int pid)
        {
            IntPtr h = OpenProcess(0x1000, false, pid);   // PROCESS_QUERY_LIMITED_INFORMATION
            if (h == IntPtr.Zero) return null;
            try { var sb = new StringBuilder(1024); int sz = sb.Capacity; return QueryFullProcessImageName(h, 0, sb, ref sz) ? sb.ToString() : null; }
            finally { CloseHandle(h); }
        }

        static bool IsLan(IPAddress a)
        {
            var b = a.GetAddressBytes();
            return b[0] == 10 || b[0] == 127 || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
        }

        public static void Network(ScanResult r)
        {
            int size = 0;
            GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2, 5, 0);
            IntPtr buf = Marshal.AllocHGlobal(size + 1024); size += 1024;
            var conns = new List<MIB_TCPROW_OWNER_PID>();
            try
            {
                if (GetExtendedTcpTable(buf, ref size, false, 2, 5, 0) != 0) return;
                int count = Marshal.ReadInt32(buf);
                int rowSize = Marshal.SizeOf(typeof(MIB_TCPROW_OWNER_PID));
                for (int i = 0; i < count; i++)
                    conns.Add((MIB_TCPROW_OWNER_PID)Marshal.PtrToStructure(new IntPtr(buf.ToInt64() + 4 + i * rowSize), typeof(MIB_TCPROW_OWNER_PID)));
            }
            finally { Marshal.FreeHGlobal(buf); }
            foreach (var g in conns.Where(c => c.state == 5 && c.owningPid > 4).GroupBy(c => (int)c.owningPid))
            {
                var remotes = g.Select(c => new IPAddress(c.remoteAddr)).Where(a => !IPAddress.IsLoopback(a) && !a.Equals(IPAddress.Any)).ToList();
                if (remotes.Count == 0) continue;
                var path = ProcPath(g.Key);
                if (string.IsNullOrEmpty(path)) continue;
                var sig = Signature.Check(path);
                r.Checked++;
                if (Signature.IsSigned(sig)) continue;
                string list = string.Join(", ", g.Take(5).Select(c => new IPAddress(c.remoteAddr) + ":" + (((c.remotePort & 0xFF) << 8) | ((c.remotePort >> 8) & 0xFF))));
                var name = Path.GetFileName(path);
                if (remotes.All(IsLan))
                    Add(r, 1, "Netværk", "Program på dit eget netværk: " + name, g.Count() + " forbindelser → " + list, "Forbindelsen går kun til enheder på dit eget netværk (fx en server, NAS eller printer).", path, "Normalt ufarligt.", path);
                else
                    Add(r, Regex.IsMatch(path, @"\\(AppData|Temp|ProgramData|Users\\Public|Downloads)\\", RegexOptions.IgnoreCase) ? 4 : 3, "Netværk", "Usigneret program på nettet: " + name, g.Count() + " forbindelser → " + list,
                        "Et program uden verificeret udgiver har forbindelse til internettet. Det er tit helt normale programmer, men en bagdør ville også se sådan ud.", path,
                        "Tryk på VirusTotal. Kender du ikke programmet, så tryk Vis fil og se, hvilket program mappen hører til.", path);
            }
        }

        // ---------- Browserudvidelser ----------
        public static void Browsers(ScanResult r)
        {
            string L = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var browsers = new Dictionary<string, string> { { "Chrome", Path.Combine(L, @"Google\Chrome\User Data") }, { "Edge", Path.Combine(L, @"Microsoft\Edge\User Data") }, { "Brave", Path.Combine(L, @"BraveSoftware\Brave-Browser\User Data") } };
            foreach (var b in browsers)
            {
                if (!Directory.Exists(b.Value)) continue;
                foreach (var prof in new DirectoryInfo(b.Value).GetDirectories().Where(d => Regex.IsMatch(d.Name, @"^(Default|Profile \d+)$")))
                {
                    var ext = Path.Combine(prof.FullName, "Extensions");
                    if (!Directory.Exists(ext)) continue;
                    foreach (var e in new DirectoryInfo(ext).GetDirectories())
                        Safe("udvidelse", () =>
                        {
                            var m = e.EnumerateFiles("manifest.json", SearchOption.AllDirectories).FirstOrDefault();
                            if (m == null) return;
                            using (var doc = JsonDocument.Parse(File.ReadAllText(m.FullName), new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip }))
                            {
                                var j = doc.RootElement;
                                string name = j.TryGetProperty("name", out var nm) ? nm.GetString() : e.Name;
                                if (name == null || name.StartsWith("__MSG_")) name = "(id " + e.Name + ")";
                                var perms = new List<string>();
                                foreach (var key in new[] { "permissions", "host_permissions" })
                                    if (j.TryGetProperty(key, out var arr) && arr.ValueKind == JsonValueKind.Array)
                                        foreach (var p in arr.EnumerateArray()) if (p.ValueKind == JsonValueKind.String) perms.Add(p.GetString());
                                var all = string.Join(" ", perms);
                                bool broad = Regex.IsMatch(all, @"<all_urls>|\*://\*/\*|http://\*/\*|https://\*/\*");
                                int risk = broad && Regex.IsMatch(all, "webRequest|cookies|scripting|tabs") ? 2 : broad ? 1 : 0;
                                r.Checked++;
                                Add(r, risk, "Browser", b.Key + "-udvidelse: " + name, prof.Name + " · v" + (j.TryGetProperty("version", out var v) ? v.GetString() : "?") + " · installeret " + m.Directory.CreationTime.ToString("d. MMM yyyy"),
                                    risk >= 2 ? "Udvidelsen kan læse og ændre alle sider, du besøger (også cookies). Kender du den ikke, så fjern den." : "Browserudvidelse.", m.Directory.FullName, risk >= 2 ? "Fjern den under " + b.Key.ToLower() + "://extensions, hvis du ikke selv har installeret den." : "");
                            }
                        });
                }
            }
            foreach (var pk in new[] { @"HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist", @"HKEY_CURRENT_USER\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist", @"HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist" })
                Safe("forcelist", () =>
                {
                    var hive = pk.StartsWith("HKEY_LOCAL_MACHINE") ? Registry.LocalMachine : Registry.CurrentUser;
                    using (var k = hive.OpenSubKey(pk.Substring(pk.IndexOf('\\') + 1)))
                        if (k != null && k.ValueCount > 0)
                            Add(r, 4, "Browser", "Tvangsinstallerede browserudvidelser (politik)", string.Join(" | ", k.GetValueNames().Select(n => Convert.ToString(k.GetValue(n)))),
                                "En politik tvinger udvidelser ind i browseren, så du ikke kan fjerne dem. Det er klassisk adware-adfærd på en privat pc.", pk, "");
                });
        }
    }
}
