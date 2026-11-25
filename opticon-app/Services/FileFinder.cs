using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Opticon.Services
{
    public class FileRow : INotifyPropertyChanged
    {
        public string Group { get; set; }
        public string Name { get; set; }
        public string Folder { get; set; }
        public string FullPath { get; set; }
        public long Size { get; set; }
        public DateTime Date { get; set; }
        public string Note { get; set; }
        public string SizeText { get { return Cleanup.Fmt(Size); } }
        public string DateText { get { return Date.ToString("d. MMM yyyy", new System.Globalization.CultureInfo("da-DK")); } }
        bool sel; public bool Selected { get { return sel; } set { sel = value; var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs("Selected")); } }
        public event PropertyChangedEventHandler PropertyChanged;
    }

    /// <summary>Finder dubletter, gamle installere og store filer i dine egne mapper. Sletter kun til papirkurven.</summary>
    public static class FileFinder
    {
        static readonly EnumerationOptions Deep = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint | FileAttributes.Offline };

        static List<string> InstalledPrograms()
        {
            var names = new List<string>();
            foreach (var hive in new[] { Registry.LocalMachine, Registry.CurrentUser })
                foreach (var path in new[] { @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" })
                    try
                    {
                        using (var k = hive.OpenSubKey(path))
                            if (k != null)
                                foreach (var sub in k.GetSubKeyNames())
                                    using (var s = k.OpenSubKey(sub))
                                    {
                                        var n = s == null ? null : s.GetValue("DisplayName") as string;
                                        if (!string.IsNullOrEmpty(n)) names.Add(Regex.Replace(n.ToLowerInvariant(), "[^a-z0-9]", ""));
                                    }
                    }
                    catch { }
            return names;
        }

        public static List<FileRow> Run(Action<string> status)
        {
            var rows = new List<FileRow>();
            string up = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string dl = Path.Combine(up, "Downloads");
            var roots = new[] { dl, Environment.GetFolderPath(Environment.SpecialFolder.Desktop), Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                                Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), Environment.GetFolderPath(Environment.SpecialFolder.MyMusic), Environment.GetFolderPath(Environment.SpecialFolder.MyPictures) }
                        .Where(Directory.Exists).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            status("Gennemgår dine mapper…");
            var all = new List<FileInfo>();
            foreach (var r in roots)
                try
                {
                    foreach (var f in new DirectoryInfo(r).EnumerateFiles("*", Deep))
                        if (!Regex.IsMatch(f.FullName, @"\\(PC-Tjek-rapport|\.git|node_modules)\\", RegexOptions.IgnoreCase) && ((int)f.Attributes & 0x400000) == 0) all.Add(f);
                }
                catch { }
            all = all.GroupBy(f => f.FullName, StringComparer.OrdinalIgnoreCase).Select(g => g.First()).ToList();

            // Dubletter: samme størrelse -> samme SHA-256
            status("Leder efter dubletter…");
            long hashed = 0, budget = 30L << 30;
            foreach (var g in all.Where(f => f.Length >= 50 * 1024).GroupBy(f => f.Length).Where(g => g.Count() > 1).OrderByDescending(g => g.Key))
            {
                if (hashed > budget) break;
                var byHash = new List<Tuple<FileInfo, string>>();
                foreach (var f in g)
                {
                    hashed += f.Length;
                    try { using (var sha = SHA256.Create()) using (var st = f.OpenRead()) byHash.Add(Tuple.Create(f, BitConverter.ToString(sha.ComputeHash(st)).Replace("-", ""))); } catch { }
                }
                foreach (var h in byHash.GroupBy(x => x.Item2).Where(x => x.Count() > 1))
                {
                    // behold den med det pæneste navn (uden "(1)" eller "kopi"), ellers den nyeste
                    var sorted = h.OrderBy(x => Regex.IsMatch(x.Item1.Name, @"\(\d+\)|kopi|copy", RegexOptions.IgnoreCase)).ThenByDescending(x => x.Item1.LastWriteTime).ToList();
                    var keep = sorted[0].Item1;
                    foreach (var x in sorted)
                    {
                        bool isKeep = x.Item1.FullName == keep.FullName;
                        rows.Add(new FileRow { Group = "Dublet", Name = x.Item1.Name, Folder = x.Item1.DirectoryName, FullPath = x.Item1.FullName, Size = x.Item1.Length, Date = x.Item1.LastWriteTime,
                            Selected = !isKeep, Note = isKeep ? "Behold (original) · " + h.Count() + " ens kopier" : "Kopi af " + keep.Name + " i " + keep.DirectoryName });
                    }
                }
            }

            // Gamle installere i Overførsler
            status("Finder gamle installere…");
            var progs = InstalledPrograms();
            if (Directory.Exists(dl))
                foreach (var f in new DirectoryInfo(dl).GetFiles().Where(f => Regex.IsMatch(f.Extension, @"^\.(exe|msi|msix|msixbundle|appx)$", RegexOptions.IgnoreCase)))
                {
                    var bas = Regex.Replace(Regex.Split(Path.GetFileNameWithoutExtension(f.Name), @"[-_ .(]")[0].ToLowerInvariant(), "[^a-z0-9]", "");
                    bool installed = bas.Length >= 4 && progs.Any(p => p.StartsWith(bas));
                    bool old = f.LastWriteTime < DateTime.Now.AddDays(-14);
                    rows.Add(new FileRow { Group = "Installer", Name = f.Name, Folder = f.DirectoryName, FullPath = f.FullName, Size = f.Length, Date = f.LastWriteTime, Selected = installed || old,
                        Note = installed ? "Programmet er installeret, så installeren skal ikke bruges igen" : old ? "Gammel installer (over 14 dage)" : "Ny installer. Behold, hvis du ikke har kørt den endnu" });
                }

            // Store filer
            status("Finder de største filer…");
            foreach (var f in all.Where(f => f.Length >= 300L << 20).OrderByDescending(f => f.Length).Take(30))
            {
                if (rows.Any(r => r.FullPath == f.FullName)) continue;
                string note = Regex.IsMatch(f.Extension, @"^\.iso$", RegexOptions.IgnoreCase) ? "Diskbillede. Kan slettes, hvis programmet er installeret"
                    : Regex.IsMatch(f.Extension, @"^\.(zip|7z|rar)$", RegexOptions.IgnoreCase) ? "Arkiv. Slet, hvis det allerede er pakket ud"
                    : Regex.IsMatch(f.Extension, @"^\.(mp4|mkv|mov)$", RegexOptions.IgnoreCase) ? "Video" : "Stor fil";
                rows.Add(new FileRow { Group = "Stor fil", Name = f.Name, Folder = f.DirectoryName, FullPath = f.FullName, Size = f.Length, Date = f.LastWriteTime, Note = note });
            }
            return rows;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct SHFILEOPSTRUCT { public IntPtr hwnd; public uint wFunc; public string pFrom; public string pTo; public ushort fFlags; public bool fAnyOperationsAborted; public IntPtr hNameMappings; public string lpszProgressTitle; }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

        /// <summary>Lægger filerne i papirkurven (kan fortrydes).</summary>
        public static int ToRecycleBin(IEnumerable<string> files)
        {
            int ok = 0;
            foreach (var f in files)
            {
                var op = new SHFILEOPSTRUCT { wFunc = 3, pFrom = f + "\0\0", fFlags = 0x40 | 0x10 | 0x400 | 0x4 };   // FO_DELETE, FOF_ALLOWUNDO | NOCONFIRMATION | NOERRORUI | SILENT
                if (SHFileOperation(ref op) == 0 && !File.Exists(f)) ok++;
            }
            return ok;
        }
    }
}
