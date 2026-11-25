using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Opticon.Services
{
    public class SpaceRow
    {
        public string Label { get; set; }
        public string Path { get; set; }
        public long Size { get; set; }
        public long? Change { get; set; }
        public double Share { get; set; }   // 0..1 i forhold til den største
        public string SizeText { get { return Cleanup.Fmt(Size); } }
        public string ChangeText
        {
            get
            {
                if (Change == null) return "";
                long c = Change.Value;
                if (Math.Abs(c) < 100L * 1048576) return "uændret";
                return (c > 0 ? "+" : "−") + Cleanup.Fmt(Math.Abs(c)) + " siden sidst";
            }
        }
        public double BarWidth { get { return Math.Max(4, 260 * Share); } }
    }

    public class SpaceResult
    {
        public DateTime Date;
        public DateTime? PrevDate;
        public List<SpaceRow> Rows = new List<SpaceRow>();
        public string Drive = "";
        public bool Partial;
    }

    public static class SpaceScan
    {
        static string HistFile { get { return System.IO.Path.Combine(App.DataDir, "plads-historik.json"); } }
        static readonly EnumerationOptions Deep = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint };

        class Hist { public DateTime Date { get; set; } public Dictionary<string, long> Sizes { get; set; } }

        static long DirSize(string path, Stopwatch sw, int budgetSec, ref bool partial)
        {
            long size = 0;
            try
            {
                foreach (var f in new DirectoryInfo(path).EnumerateFiles("*", Deep))
                {
                    try { if (((int)f.Attributes & 0x400000) == 0) size += f.Length; } catch { }   // 0x400000 = kun i skyen
                    if (sw.Elapsed.TotalSeconds > budgetSec) { partial = true; break; }
                }
            }
            catch { }
            return size;
        }

        static IEnumerable<KeyValuePair<string, string>> Roots()
        {
            string up = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            yield return new KeyValuePair<string, string>("Overførsler", System.IO.Path.Combine(up, "Downloads"));
            yield return new KeyValuePair<string, string>("Videoer", Environment.GetFolderPath(Environment.SpecialFolder.MyVideos));
            yield return new KeyValuePair<string, string>("Billeder", Environment.GetFolderPath(Environment.SpecialFolder.MyPictures));
            yield return new KeyValuePair<string, string>("Dokumenter", Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments));
            yield return new KeyValuePair<string, string>("Skrivebord", Environment.GetFolderPath(Environment.SpecialFolder.Desktop));
            yield return new KeyValuePair<string, string>("Musik", Environment.GetFolderPath(Environment.SpecialFolder.MyMusic));
            yield return new KeyValuePair<string, string>("Midlertidige filer", System.IO.Path.GetTempPath().TrimEnd('\\'));
            // Spilbiblioteker
            var libs = new List<string>();
            try
            {
                var steam = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) as string;
                if (!string.IsNullOrEmpty(steam))
                {
                    steam = steam.Replace('/', '\\');
                    libs.Add(System.IO.Path.Combine(steam, @"steamapps\common"));
                    var vdf = System.IO.Path.Combine(steam, @"steamapps\libraryfolders.vdf");
                    if (File.Exists(vdf))
                        foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                            libs.Add(System.IO.Path.Combine(m.Groups[1].Value.Replace(@"\\", @"\"), @"steamapps\common"));
                }
            }
            catch { }
            string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            libs.Add(System.IO.Path.Combine(pf, "Epic Games"));
            libs.Add(System.IO.Path.GetPathRoot(pf) + "XboxGames");
            libs.Add(System.IO.Path.Combine(pf, "EA Games"));
            libs.Add(System.IO.Path.Combine(pf86, @"Ubisoft\Ubisoft Game Launcher\games"));
            libs.Add(System.IO.Path.Combine(pf86, "Battle.net"));
            foreach (var l in libs.Distinct(StringComparer.OrdinalIgnoreCase))
                yield return new KeyValuePair<string, string>("Spil (" + new DirectoryInfo(l).Parent?.Name + ")", l);
        }

        public static SpaceResult Run(Action<string> status)
        {
            var res = new SpaceResult { Date = DateTime.Now };
            var sw = Stopwatch.StartNew(); const int budget = 150;
            bool partial = false;
            var rows = new List<SpaceRow>();
            foreach (var r in Roots())
            {
                if (string.IsNullOrEmpty(r.Value) || !Directory.Exists(r.Value)) continue;
                status("Måler " + r.Key + "…");
                long total = 0;
                // Undermapper over 200 MB vises for sig
                try
                {
                    foreach (var d in new DirectoryInfo(r.Value).EnumerateDirectories("*", new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint }))
                    {
                        long s = DirSize(d.FullName, sw, budget, ref partial);
                        total += s;
                        if (s >= 200L * 1048576) rows.Add(new SpaceRow { Label = r.Key + " › " + d.Name, Path = d.FullName, Size = s });
                    }
                    foreach (var f in new DirectoryInfo(r.Value).EnumerateFiles()) { try { if (((int)f.Attributes & 0x400000) == 0) total += f.Length; } catch { } }
                }
                catch { }
                if (total > 0) rows.Add(new SpaceRow { Label = r.Key, Path = r.Value, Size = total });
            }
            res.Partial = partial;

            // Sammenlign med sidste måling
            Hist prev = null;
            try { if (File.Exists(HistFile)) prev = JsonSerializer.Deserialize<Hist>(File.ReadAllText(HistFile)); } catch { }
            if (prev != null && prev.Sizes != null)
            {
                res.PrevDate = prev.Date;
                foreach (var row in rows) { long old; if (prev.Sizes.TryGetValue(row.Path, out old)) row.Change = row.Size - old; }
            }
            try
            {
                Directory.CreateDirectory(App.DataDir);
                File.WriteAllText(HistFile, JsonSerializer.Serialize(new Hist { Date = res.Date, Sizes = rows.GroupBy(x => x.Path, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First().Size) }));
            }
            catch (Exception e) { App.Log("Plads-historik: " + e.Message); }

            res.Rows = rows.OrderByDescending(x => x.Size).Take(25).ToList();
            long max = res.Rows.Count > 0 ? res.Rows[0].Size : 1;
            foreach (var row in res.Rows) row.Share = (double)row.Size / Math.Max(1, max);
            try { var c = new DriveInfo("C"); res.Drive = "C: " + Cleanup.Fmt(c.AvailableFreeSpace) + " ledig af " + Cleanup.Fmt(c.TotalSize); } catch { }
            return res;
        }
    }
}
