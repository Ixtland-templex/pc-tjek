using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

namespace Opticon.Services
{
    public class CleanRow : INotifyPropertyChanged
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Note { get; set; }
        public string[] Paths { get; set; }
        public double MinAgeHours { get; set; }
        public string Special { get; set; }
        public bool NeedsAdmin { get; set; }

        bool sel; public bool Selected { get { return sel; } set { sel = value; On("Selected"); } }
        long bytes = -1; public long Bytes { get { return bytes; } set { bytes = value; On("Bytes"); On("SizeText"); } }
        string status = ""; public string Status { get { return status; } set { status = value; On("Status"); } }
        public string SizeText { get { return bytes < 0 ? "–" : Cleanup.Fmt(bytes); } }
        public string AdminText { get { return NeedsAdmin && !Admin.IsElevated ? "Kræver administrator for at rydde det hele" : ""; } }

        public event PropertyChangedEventHandler PropertyChanged;
        void On(string n) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    }

    public static class Cleanup
    {
        public static string Fmt(long b)
        {
            if (b >= 1L << 30) return (b / 1073741824.0).ToString("0.0") + " GB";
            if (b >= 1L << 20) return (b / 1048576.0).ToString("0") + " MB";
            if (b > 0) return Math.Max(1, b / 1024) + " KB";
            return "0 MB";
        }

        public static List<CleanRow> Categories()
        {
            string L = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string W = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string PD = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            string T = Path.GetTempPath().TrimEnd('\\');
            return new List<CleanRow>
            {
                new CleanRow { Id = "utemp", Name = "Midlertidige filer (din bruger)", Paths = new[] { T }, MinAgeHours = 24, Note = "Rester fra programmer og installere", Selected = true },
                new CleanRow { Id = "wtemp", Name = "Midlertidige filer (Windows)", Paths = new[] { W + @"\Temp" }, MinAgeHours = 24, Note = "Systemets midlertidige filer", Selected = true, NeedsAdmin = true },
                new CleanRow { Id = "wu", Name = "Windows Update-downloads", Paths = new[] { W + @"\SoftwareDistribution\Download" }, MinAgeHours = 72, Note = "Allerede installerede opdateringer. Windows rydder normalt selv op", NeedsAdmin = true },
                new CleanRow { Id = "do", Name = "Leveringsoptimering (cache)", Paths = new[] { W + @"\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" }, MinAgeHours = 0, Note = "Opdateringsfiler delt med andre pc'er. Windows rydder normalt selv op", NeedsAdmin = true },
                new CleanRow { Id = "dumps", Name = "Crash dumps og fejlrapporter", Paths = new[] { L + @"\CrashDumps", W + @"\Minidump", W + @"\MEMORY.DMP", PD + @"\Microsoft\Windows\WER\ReportArchive", PD + @"\Microsoft\Windows\WER\ReportQueue" }, MinAgeHours = 24, Note = "Bruges kun til fejlsøgning af gamle nedbrud", Selected = true, NeedsAdmin = true },
                new CleanRow { Id = "shader", Name = "Shader-cache (DirectX, NVIDIA, AMD)", Paths = new[] { L + @"\D3DSCache", L + @"\NVIDIA\DXCache", L + @"\NVIDIA\GLCache", L + @"\AMD\DxCache" }, MinAgeHours = 24, Note = "Genopbygges automatisk. Spil kan hakke lidt første gang efter" },
                new CleanRow { Id = "thumbs", Name = "Miniaturebilleder", Paths = new[] { L + @"\Microsoft\Windows\Explorer\thumbcache_*.db" }, MinAgeHours = 0, Note = "Genopbygges, når du åbner mapper" },
                new CleanRow { Id = "browser", Name = "Browsercache (Chrome og Edge)", Paths = new[] { L + @"\Google\Chrome\User Data\*\Cache", L + @"\Google\Chrome\User Data\*\Code Cache", L + @"\Google\Chrome\User Data\*\GPUCache", L + @"\Microsoft\Edge\User Data\*\Cache", L + @"\Microsoft\Edge\User Data\*\Code Cache", L + @"\Microsoft\Edge\User Data\*\GPUCache" }, MinAgeHours = 0, Note = "Luk browseren først. Logins og historik bevares" },
                new CleanRow { Id = "recycle", Name = "Papirkurv", Paths = new string[0], Special = "recycle", Note = "Tømmes permanent. Tjek den først" },
            };
        }

        /// <summary>Udvider stier med * (fx "User Data\*\Cache") til de mapper/filer, der findes.</summary>
        public static IEnumerable<string> Expand(string pattern)
        {
            if (pattern.IndexOf('*') < 0) { if (Directory.Exists(pattern) || File.Exists(pattern)) yield return pattern; yield break; }
            var parts = pattern.Split('\\');
            var cur = new List<string> { parts[0] + "\\" };
            for (int i = 1; i < parts.Length; i++)
            {
                var next = new List<string>();
                bool last = i == parts.Length - 1;
                foreach (var c in cur)
                {
                    try
                    {
                        if (parts[i].IndexOf('*') < 0) { var p = Path.Combine(c, parts[i]); if (Directory.Exists(p) || (last && File.Exists(p))) next.Add(p); }
                        else
                        {
                            next.AddRange(Directory.GetDirectories(c, parts[i]));
                            if (last) next.AddRange(Directory.GetFiles(c, parts[i]));
                        }
                    }
                    catch { }
                }
                cur = next;
            }
            foreach (var c in cur) yield return c;
        }

        static readonly EnumerationOptions Deep = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint };

        static IEnumerable<FileInfo> Files(CleanRow c)
        {
            var cut = DateTime.Now.AddHours(-c.MinAgeHours);
            foreach (var pat in c.Paths)
                foreach (var p in Expand(pat))
                {
                    if (File.Exists(p)) { var f = new FileInfo(p); if (f.LastWriteTime < cut) yield return f; continue; }
                    IEnumerable<FileInfo> e;
                    try { e = new DirectoryInfo(p).EnumerateFiles("*", Deep); } catch { continue; }
                    foreach (var f in e) { bool old; try { old = f.LastWriteTime < cut; } catch { continue; } if (old) yield return f; }
                }
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        struct SHQUERYRBINFO { public int cbSize; public long i64Size; public long i64NumItems; }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHQueryRecycleBin(string root, ref SHQUERYRBINFO info);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHEmptyRecycleBin(IntPtr hwnd, string root, uint flags);

        public static long Measure(CleanRow c)
        {
            if (c.Special == "recycle")
            {
                var i = new SHQUERYRBINFO { cbSize = Marshal.SizeOf(typeof(SHQUERYRBINFO)) };
                return SHQueryRecycleBin(null, ref i) == 0 ? i.i64Size : 0;
            }
            long sum = 0;
            foreach (var f in Files(c)) { try { sum += f.Length; } catch { } }
            return sum;
        }

        /// <summary>Sletter filerne i kategorien. Filer i brug springes over. Returnerer (frigjort, sprunget over).</summary>
        public static Tuple<long, int> Clean(CleanRow c)
        {
            if (c.Special == "recycle")
            {
                long before = Measure(c);
                SHEmptyRecycleBin(IntPtr.Zero, null, 0x1 | 0x2 | 0x4);   // ingen bekræftelse, ingen fremgang, ingen lyd
                return Tuple.Create(Math.Max(0, before - Measure(c)), 0);
            }
            long freed = 0; int skipped = 0;
            foreach (var f in Files(c).ToList())
            {
                try { long len = f.Length; f.Attributes = FileAttributes.Normal; f.Delete(); freed += len; }
                catch { skipped++; }
            }
            // tomme undermapper (selve rodmappen bliver)
            foreach (var pat in c.Paths)
                foreach (var p in Expand(pat))
                {
                    if (!Directory.Exists(p)) continue;
                    try
                    {
                        foreach (var d in Directory.EnumerateDirectories(p, "*", Deep).OrderByDescending(x => x.Length).ToList())
                            try { if (!Directory.EnumerateFileSystemEntries(d).Any()) Directory.Delete(d); } catch { }
                    }
                    catch { }
                }
            return Tuple.Create(freed, skipped);
        }

        public static bool BrowserRunning()
        {
            return Process.GetProcessesByName("chrome").Length > 0 || Process.GetProcessesByName("msedge").Length > 0;
        }
    }
}
