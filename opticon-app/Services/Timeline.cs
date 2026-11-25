using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace Opticon.Services
{
    public class TimeEvent
    {
        public DateTime Time { get; set; }
        public string Type { get; set; }
        public string Title { get; set; }
        public string Detail { get; set; }
        public int Level { get; set; }   // 0 alvorlig, 1 bemærk, 2 normal
        public string TimeText { get { return Time.ToString("ddd d. MMM HH:mm", new CultureInfo("da-DK")); } }
        public System.Windows.Media.Brush DotBrush { get { return DotBrushes.For(Level == 0 ? "#F05252" : Level == 1 ? "#F5B83D" : "#4B5263"); } }
    }

    /// <summary>Hændelsesforløb: hvad er der sket på pc'en de seneste 14 dage (fra Windows' egne logfiler).</summary>
    public static class Timeline
    {
        public static List<TimeEvent> Read(int days = 14)
        {
            var list = new List<TimeEvent>();
            Action<DateTime?, string, string, string, int> add = (t, type, title, detail, lvl) => { if (t.HasValue) list.Add(new TimeEvent { Time = t.Value, Type = type, Title = title, Detail = detail ?? "", Level = lvl }); };

            // Defender
            foreach (var e in Events.Read("Microsoft-Windows-Windows Defender/Operational", "1116,1117,5001,5007", days, 300))
            {
                var lines = Events.Msg(e).Split('\n').Where(l => Regex.IsMatch(l, "(Navn|Name|Sti|Path|Ny værdi|New value)")).Take(2).Select(l => l.Trim());
                string d = string.Join(" · ", lines);
                if (e.Id == 1116) add(e.TimeCreated, "Defender", "Trussel opdaget", d, 0);
                else if (e.Id == 1117) add(e.TimeCreated, "Defender", "Defender fjernede eller blokerede en trussel", d, 1);
                else if (e.Id == 5001) add(e.TimeCreated, "Defender", "Realtidsbeskyttelse blev slået FRA", "", 0);
                else if (e.Id == 5007) add(e.TimeCreated, "Defender", Regex.IsMatch(d, "Exclusion", RegexOptions.IgnoreCase) ? "En Defender-undtagelse blev ændret" : "En Defender-indstilling blev ændret", d, Regex.IsMatch(d, "Exclusion", RegexOptions.IgnoreCase) ? 1 : 2);
            }
            // Installationer og opdateringer
            foreach (var e in Events.Read("Application", "1033", days, 300, "MsiInstaller")) add(e.TimeCreated, "Program", "Installeret: " + Events.Prop(e, 0), Events.Prop(e, 5), 2);
            foreach (var e in Events.Read("Application", "1034", days, 300, "MsiInstaller")) add(e.TimeCreated, "Program", "Afinstalleret: " + Events.Prop(e, 0), "", 2);
            foreach (var e in Events.Read("System", "19", days, 300, "Microsoft-Windows-WindowsUpdateClient")) add(e.TimeCreated, "Windows Update", "Opdatering installeret", Events.Prop(e, 0), 2);
            foreach (var e in Events.Read("System", "7045", days, 200)) add(e.TimeCreated, "Tjeneste", "Ny tjeneste installeret: " + Events.Prop(e, 0), Events.Prop(e, 1), 1);
            foreach (var e in Events.Read("Microsoft-Windows-TaskScheduler/Operational", "106", days, 200)) add(e.TimeCreated, "Opgave", "Planlagt opgave oprettet: " + Events.Prop(e, 0), "af " + Events.Prop(e, 1), 1);
            // Nedbrud, genstarter, opstart
            foreach (var e in Events.Read("Application", "1000,1002", days, 500))
                if (e.ProviderName == "Application Error" || e.ProviderName == "Application Hang")
                    add(e.TimeCreated, "Nedbrud", Events.Prop(e, 0) + (e.Id == 1000 ? " lukkede uventet" : " holdt op med at svare"), "", 1);
            foreach (var e in Events.Read("System", "41,6008,1001,12,13,1074", days, 500))
            {
                string p = e.ProviderName ?? "";
                if (e.Id == 41 && p.Contains("Kernel-Power")) add(e.TimeCreated, "System", "Uventet genstart eller strømtab", "", 1);
                else if (e.Id == 6008) add(e.TimeCreated, "System", "Pc'en lukkede ned uventet", "", 1);
                else if (e.Id == 1001 && p.Contains("WER-SystemErrorReporting")) add(e.TimeCreated, "System", "Blå skærm (systemnedbrud)", Events.Prop(e, 0), 0);
                else if (e.Id == 12 && p.Contains("Kernel-General")) add(e.TimeCreated, "System", "Pc'en startede", "", 2);
                else if (e.Id == 13 && p.Contains("Kernel-General")) add(e.TimeCreated, "System", "Pc'en lukkede ned", "", 2);
                else if (e.Id == 1074) add(e.TimeCreated, "System", "Genstart eller nedlukning startet af " + Path.GetFileName(Events.Prop(e, 0)), Events.Prop(e, 2), 2);
            }
            // Nye filer i Startup-mappen
            foreach (var sf in new[] { Environment.GetFolderPath(Environment.SpecialFolder.Startup), Environment.GetFolderPath(Environment.SpecialFolder.CommonStartup) })
                try { foreach (var f in new DirectoryInfo(sf).GetFiles().Where(f => f.CreationTime > DateTime.Now.AddDays(-days) && f.Name != "desktop.ini")) add(f.CreationTime, "Autostart", "Ny fil i startmappen: " + f.Name, f.FullName, 1); } catch { }
            // Opticons egen log (rettelser, oprydning, Vagt)
            try
            {
                var log = Path.Combine(App.DataDir, "opticon.log");
                if (File.Exists(log))
                    foreach (var l in File.ReadLines(log).Reverse().Take(3000))
                    {
                        var m = Regex.Match(l, @"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)  (Retter: .+|Oprydning: .+|Download-vagt: .+|Vagthund: nyt .+|Markeret som OK: .+|Opstart .+ -> .+|Opdatering .+ hentet.+|Vagten slået .+|Filer i papirkurven: .+)$");
                        DateTime t;
                        if (m.Success && DateTime.TryParseExact(m.Groups[1].Value, "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out t) && t > DateTime.Now.AddDays(-days))
                            add(t, "Opticon", m.Groups[2].Value, "", 2);
                    }
            }
            catch { }
            return list.OrderByDescending(e => e.Time).ToList();
        }
    }
}
