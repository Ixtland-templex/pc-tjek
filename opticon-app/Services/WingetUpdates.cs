using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Opticon.Services
{
    public class AppUpdate : INotifyPropertyChanged
    {
        public string Name { get; set; }
        public string Id { get; set; }
        public string Version { get; set; }
        public string Available { get; set; }
        bool sel = true; public bool Selected { get { return sel; } set { sel = value; On("Selected"); } }
        string status = ""; public string Status { get { return status; } set { status = value; On("Status"); } }
        public event PropertyChangedEventHandler PropertyChanged;
        void On(string n) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    }

    /// <summary>Opdaterer programmer med Microsofts egen pakkehåndtering (winget).</summary>
    public static class WingetUpdates
    {
        static string Exe
        {
            get
            {
                var alias = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\winget.exe");
                return File.Exists(alias) ? alias : "winget.exe";
            }
        }

        static Tuple<int, List<string>> Run(string args, int timeoutSec)
        {
            var psi = new ProcessStartInfo(Exe, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8 };
            var lines = new List<string>();
            using (var p = new Process { StartInfo = psi })
            {
                p.OutputDataReceived += (s, e) => { if (e.Data != null) lock (lines) lines.Add(e.Data.Split('\r').Last()); };
                p.ErrorDataReceived += (s, e) => { };
                try { p.Start(); }
                catch (Exception e) { throw new Exception("winget blev ikke fundet. Installér \"App Installer\" fra Microsoft Store. (" + e.Message + ")"); }
                p.BeginOutputReadLine(); p.BeginErrorReadLine();
                if (!p.WaitForExit(timeoutSec * 1000)) { try { p.Kill(); } catch { } throw new Exception("winget svarede ikke."); }
                p.WaitForExit();
                return Tuple.Create(p.ExitCode, lines);
            }
        }

        public static List<AppUpdate> List()
        {
            var r = Run("upgrade --accept-source-agreements --disable-interactivity", 180);
            var lines = r.Item2;
            int sep = lines.FindIndex(l => Regex.IsMatch(l, "^-{10,}"));
            if (sep < 1)
            {
                if (Regex.IsMatch(string.Join(" ", lines), "no installed package|no applicable|ingen installerede|ingen tilgængelige|no available upgrade", RegexOptions.IgnoreCase)) return new List<AppUpdate>();
                App.Log("winget svar: " + string.Join(" | ", lines.Take(8)));
                throw new Exception("Kunne ikke læse svaret fra winget. Prøv igen senere.");
            }
            var starts = Regex.Matches(lines[sep - 1], @"\S+").Cast<Match>().Select(m => m.Index).ToList();
            if (starts.Count < 4) return new List<AppUpdate>();
            var outp = new List<AppUpdate>();
            Func<string, int, int, string> cut = (l, a, b) => l.Length <= a ? "" : (b < 0 || b > l.Length ? l.Substring(a).Trim() : l.Substring(a, b - a).Trim());
            for (int i = sep + 1; i < lines.Count; i++)
            {
                var l = lines[i];
                if (string.IsNullOrWhiteSpace(l) || Regex.IsMatch(l, "^-{5,}")) { if (outp.Count > 0) break; else continue; }
                if (l.Length < starts[3] || Regex.IsMatch(l, @"^\d+ (opgraderinger|upgrades|pakke|package)")) continue;
                var name = cut(l, starts[0], starts[1]); var id = cut(l, starts[1], starts[2]); var ver = cut(l, starts[2], starts[3]);
                var avail = cut(l, starts[3], starts.Count > 4 ? starts[4] : -1);
                if (id.Length > 0 && !id.Contains(" ") && avail.Length > 0) outp.Add(new AppUpdate { Name = name, Id = id, Version = ver, Available = avail });
            }
            return outp;
        }

        public static string Upgrade(string id)
        {
            var r = Run("upgrade --id " + id + " -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity", 1800);
            App.Log("winget upgrade " + id + ": kode " + r.Item1);
            if (r.Item1 == 0) return "✓ Opdateret";
            if (r.Item1 == unchecked((int)0x8A15002B)) return "Allerede nyeste version";
            if (r.Item1 == unchecked((int)0x8A150056)) return "Luk programmet først, og prøv igen";
            return "Fejl (kode 0x" + r.Item1.ToString("X8") + ")";
        }
    }
}
