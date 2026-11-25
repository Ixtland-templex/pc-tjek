using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Management;
using System.Text.RegularExpressions;

namespace Opticon.Services
{
    public class CrashRow
    {
        public int Level { get; set; }
        public string Title { get; set; }
        public string Count { get; set; }
        public string Last { get; set; }
        public string Note { get; set; }
        public string Advice { get; set; }
        public int Sort { get; set; }
        public System.Windows.Visibility AdviceVis { get { return string.IsNullOrEmpty(Advice) ? System.Windows.Visibility.Collapsed : System.Windows.Visibility.Visible; } }
        public System.Windows.Media.Brush DotBrush { get { return DotBrushes.For(Level == 0 ? "#F05252" : Level == 1 ? "#F5B83D" : "#6B7488"); } }
    }

    public class CrashResult { public List<CrashRow> Rows = new List<CrashRow>(); public int Total; public string Summary; }

    public class GpuLive { public string Name; public double Power, Limit, Temp, Fan, Clock, Util, MemUsed, MemTotal; }

    /// <summary>Ydelse og helbred: diske, plads, genstart, RAM, strømplan, opstartstid, nedbrud og grafikkortet live.</summary>
    public static class Health
    {
        public static List<SecItem> Check()
        {
            var r = new List<SecItem>();
            Action<int, string, string, string> add = (l, n, v, note) => r.Add(new SecItem { Level = l, Name = n, Value = v, Note = note });
            var da = new CultureInfo("da-DK");

            // Diske
            try
            {
                var counters = Wmi.Query(@"root\Microsoft\Windows\Storage", "SELECT DeviceId, Temperature, TemperatureMax, Wear, ReadErrorsUncorrected, WriteErrorsUncorrected, PowerOnHours FROM MSFT_StorageReliabilityCounter");
                foreach (var d in Wmi.Query(@"root\Microsoft\Windows\Storage", "SELECT DeviceId, FriendlyName, MediaType, Size, HealthStatus FROM MSFT_PhysicalDisk"))
                {
                    int hs = Convert.ToInt32(Wmi.Prop(d, "HealthStatus") ?? 0);
                    int lvl = hs == 0 ? 2 : hs == 1 ? 1 : 0;
                    int mt = Convert.ToInt32(Wmi.Prop(d, "MediaType") ?? 0);
                    string media = mt == 4 ? "SSD" : mt == 3 ? "HDD" : "Disk";
                    string name = Convert.ToString(Wmi.Prop(d, "FriendlyName"));
                    add(lvl, "Disk: " + name, media + " · " + Math.Round(Convert.ToDouble(Wmi.Prop(d, "Size") ?? 0) / 1e9) + " GB · " + (lvl == 2 ? "sund" : lvl == 1 ? "advarsel" : "FEJL"), lvl == 2 ? "Disken melder sund" : "Tag backup snarest, og overvej at udskifte disken");
                    var rc = counters.FirstOrDefault(c => Convert.ToString(Wmi.Prop(c, "DeviceId")) == Convert.ToString(Wmi.Prop(d, "DeviceId")));
                    if (rc == null) continue;
                    int t = Convert.ToInt32(Wmi.Prop(rc, "Temperature") ?? 0), tm = Convert.ToInt32(Wmi.Prop(rc, "TemperatureMax") ?? 0);
                    if (t > 0) { int hot = tm > 40 ? tm - 8 : 70; add(t < 55 ? 2 : t < hot ? 1 : 0, "   Temperatur", t + " °C" + (tm > 40 ? " (maks. " + tm + " °C)" : ""), t < 55 ? "Fin" : t < hot ? "Varm. Tjek, at der kommer luft til disken" : "For varm! Disken kan sætte farten ned eller tage skade"); }
                    var wear = Wmi.Prop(rc, "Wear");
                    if (wear != null) { int w = Convert.ToInt32(wear); add(w < 50 ? 2 : w < 80 ? 1 : 0, "   Slid (SSD)", w + " % brugt", w < 50 ? "Masser af levetid tilbage" : w < 80 ? "Over halvvejs. Hold øje, og tag backup" : "Næsten slidt op. Planlæg at udskifte den"); }
                    long ue = Convert.ToInt64(Wmi.Prop(rc, "ReadErrorsUncorrected") ?? 0) + Convert.ToInt64(Wmi.Prop(rc, "WriteErrorsUncorrected") ?? 0);
                    add(ue == 0 ? 2 : 0, "   Fejl der ikke kunne rettes", ue.ToString(), ue == 0 ? "Ingen. Godt" : "Tidligt tegn på, at disken er ved at gå i stykker. Tag backup");
                    long h = Convert.ToInt64(Wmi.Prop(rc, "PowerOnHours") ?? 0);
                    if (h > 0) add(3, "   Tændt i alt", h.ToString("N0", da) + " timer", h >= 8760 ? "Ca. " + (h / 8760.0).ToString("0.#", da) + " år i drift" : "Ca. " + Math.Round(h / 730.0) + " måneder i drift");
                }
                if (counters.Count == 0 && !Admin.IsElevated) add(3, "Diskens temperatur og slid", "Kræver administrator", "Kør Opticon som administrator for at se temperatur, slid og fejl");
            }
            catch (Exception e) { App.Log("Helbred disk: " + e.Message); }

            try
            {
                var c = new DriveInfo("C");
                int pct = (int)Math.Round(100.0 * c.AvailableFreeSpace / c.TotalSize);
                add(pct >= 20 ? 2 : pct >= 10 ? 1 : 0, "Ledig plads på C:", Math.Round(c.AvailableFreeSpace / 1e9) + " GB (" + pct + " %)", pct >= 20 ? "Fint" : "Under 20 % ledig gør Windows langsommere. Brug Oprydning");
            }
            catch { }

            try
            {
                var os = Wmi.First(@"root\cimv2", "SELECT LastBootUpTime, FreePhysicalMemory, TotalVisibleMemorySize FROM Win32_OperatingSystem");
                var boot = ManagementDateTimeConverter.ToDateTime(Convert.ToString(Wmi.Prop(os, "LastBootUpTime")));
                double days = Math.Round((DateTime.Now - boot).TotalDays, 1);
                add(days < 7 ? 2 : 1, "Tid siden genstart", days.ToString("0.#", da) + " dage", days < 7 ? "Fint" : "Genstart pc'en. Med Hurtig start rydder \"Luk computeren\" ikke hukommelsen");
                double tot = Convert.ToDouble(Wmi.Prop(os, "TotalVisibleMemorySize")), free = Convert.ToDouble(Wmi.Prop(os, "FreePhysicalMemory"));
                int ram = (int)Math.Round(100 - free / tot * 100);
                add(ram < 75 ? 2 : ram < 90 ? 1 : 0, "RAM i brug", ram + " % af " + Math.Round(tot / 1048576) + " GB", ram < 75 ? "Fint" : "Luk tunge programmer, eller slå opstartsprogrammer fra under Optimering");
            }
            catch { }

            try
            {
                var plan = Run(Path.Combine(Environment.SystemDirectory, "powercfg.exe"), "/getactivescheme");
                var m = Regex.Match(plan, @"\((.+)\)");
                bool high = Regex.IsMatch(plan, "8c5e7fda|e9a42b02", RegexOptions.IgnoreCase);
                bool laptop = PowerMode.OnBattery() || Convert.ToInt32(Wmi.Prop(Wmi.First(@"root\cimv2", "SELECT PCSystemType FROM Win32_ComputerSystem"), "PCSystemType") ?? 0) == 2;
                add(high || laptop ? 2 : 3, "Strømplan", m.Success ? m.Groups[1].Value : plan.Trim(), high ? "Maks. ydelse" : laptop ? "Fint på en bærbar. Brug strømtilstanden i Windows til at vælge ydelse" : "På en stationær gaming-pc giver \"Høj ydelse\" lidt hurtigere respons (lidt mere strøm)");
            }
            catch { }

            try
            {
                var ev = Events.Read("Microsoft-Windows-Diagnostics-Performance/Operational", "100", 60, 1);
                if (ev.Count > 0)
                {
                    var xml = ev[0].ToXml();
                    var m = Regex.Match(xml, "<Data Name='BootTime'>(\\d+)</Data>");
                    if (m.Success)
                    {
                        int bs = (int)Math.Round(int.Parse(m.Groups[1].Value) / 1000.0);
                        add(bs < 40 ? 2 : bs < 90 ? 1 : 0, "Seneste opstartstid", bs + " sek.", bs < 40 ? "Hurtig" : "Langsom: slå opstartsprogrammer fra under Optimering");
                    }
                }
            }
            catch { }
            return r;
        }

        public static CrashResult Crashes()
        {
            var res = new CrashResult();
            var apps = new Dictionary<string, Tuple<string, int, int, DateTime, DateTime>>(StringComparer.OrdinalIgnoreCase);
            foreach (var e in Events.Read("Application", "1000,1002", 14, 2000))
            {
                if (e.ProviderName != "Application Error" && e.ProviderName != "Application Hang") continue;
                var name = Events.Prop(e, 0); if (string.IsNullOrEmpty(name)) continue;
                var t = e.TimeCreated ?? DateTime.Now;
                Tuple<string, int, int, DateTime, DateTime> a;
                if (!apps.TryGetValue(name, out a)) a = Tuple.Create(name, 0, 0, t, t);
                apps[name] = Tuple.Create(a.Item1, a.Item2 + (e.Id == 1000 ? 1 : 0), a.Item3 + (e.Id == 1002 ? 1 : 0), t < a.Item4 ? t : a.Item4, t > a.Item5 ? t : a.Item5);
            }
            var installs = new List<Tuple<DateTime, string>>();
            foreach (var e in Events.Read("Application", "1033", 17, 300, "MsiInstaller")) installs.Add(Tuple.Create(e.TimeCreated ?? DateTime.Now, Events.Prop(e, 0)));
            foreach (var e in Events.Read("System", "19", 17, 300, "Microsoft-Windows-WindowsUpdateClient")) installs.Add(Tuple.Create(e.TimeCreated ?? DateTime.Now, "Windows Update: " + Events.Prop(e, 0)));
            var sys = new List<Tuple<string, DateTime>>();
            foreach (var e in Events.Read("System", "41,6008,1001", 14, 500))
            {
                var t = e.TimeCreated ?? DateTime.Now;
                if (e.Id == 41 && (e.ProviderName ?? "").Contains("Kernel-Power")) sys.Add(Tuple.Create("restart", t));
                else if (e.Id == 6008) sys.Add(Tuple.Create("shutdown", t));
                else if (e.Id == 1001 && (e.ProviderName ?? "").Contains("WER-SystemErrorReporting")) sys.Add(Tuple.Create("bsod", t));
            }
            var advice = new Dictionary<string, string>
            {
                { "bsod", "Hvad gør jeg? Én enkelt blå skærm er sjældent farlig. Sker det igen: 1) opdatér grafikdriveren og BIOS (se Optimering), 2) har du slået XMP/EXPO til, så prøv uden, 3) test RAM: tryk Start, og søg på \"Windows Hukommelsesdiagnosticering\", 4) se under Hændelsesforløb, hvad der skete lige før." },
                { "restart", "Hvad gør jeg? Holdt du tænd/sluk-knappen inde, eller gik strømmen? Så er det ikke en fejl. Sker det af sig selv, især under spil: hold øje med temperaturen (grafikkortet live herover) og overvej strømforsyningen." },
                { "shutdown", "Hvad gør jeg? Det sker, når Windows ikke nåede at lukke ordentligt ned, fx efter en blå skærm eller strømtab. Se de andre linjer herover." },
            };
            foreach (var k in new[] { Tuple.Create("bsod", "Blå skærm (systemnedbrud)", 0, "Ofte driver, RAM (fx ustabil XMP) eller overophedning"), Tuple.Create("restart", "Uventet genstart eller strømtab", 1, "Strømafbrydelse, holdt tænd/sluk inde, eller ustabil hardware"), Tuple.Create("shutdown", "Pc'en lukkede ned uventet", 1, "") })
            {
                var ev = sys.Where(s => s.Item1 == k.Item1).ToList();
                if (ev.Count > 0) res.Rows.Add(new CrashRow { Level = k.Item3, Title = k.Item2, Count = ev.Count + (ev.Count == 1 ? " gang" : " gange"), Last = ev.Max(x => x.Item2).ToString("dd-MM HH:mm"), Note = k.Item4, Sort = 0, Advice = advice[k.Item1] });
            }
            // Blå skærm, genstart og nedlukning inden for få minutter er én og samme hændelse
            var bs = sys.Where(x => x.Item1 == "bsod").Select(x => x.Item2).ToList();
            if (bs.Count > 0 && sys.Any(x => x.Item1 != "bsod" && bs.Any(b => Math.Abs((x.Item2 - b).TotalMinutes) < 10)))
                foreach (var row in res.Rows.Where(r => r.Sort == 0 && r.Title != "Blå skærm (systemnedbrud)")) { row.Note = "Skete samtidig med den blå skærm, så det er samme hændelse."; row.Advice = ""; }
            foreach (var a in apps.Values.OrderByDescending(a => a.Item2 + a.Item3))
            {
                int n = a.Item2 + a.Item3;
                // Defenders daglige definitioner og Microsoft Store-apps er næsten aldrig årsagen: dem nævner vi ikke
                var near = installs.Where(i => i.Item1 <= a.Item4 && i.Item1 >= a.Item4.AddHours(-48) && !Regex.IsMatch(i.Item2, "Defender|sikkerhedsefterretning|Security Intelligence|KB2267602|9[A-Z0-9]{11}", RegexOptions.IgnoreCase)).OrderByDescending(i => i.Item1).FirstOrDefault();
                string nice = Regex.Replace(a.Item1, @"\.exe$", "", RegexOptions.IgnoreCase);
                bool installer = Regex.IsMatch(nice, "^(msiexec|setup|install|unins\\d*|.*installer.*)$", RegexOptions.IgnoreCase);
                string adv = installer ? "Hvad gør jeg? En installation gik ned. Ingen grund til bekymring, medmindre et program ikke virker. Så installér det igen."
                    : n == 1 ? "Hvad gør jeg? Sket én gang. Gør ingenting, medmindre det sker igen."
                    : near != null ? "Hvad gør jeg? Det begyndte kort efter " + near.Item2 + ". Opdatér " + nice + " (se Opdateringer), eller prøv at afinstallere det, der blev installeret lige før."
                    : "Hvad gør jeg? 1) Opdatér " + nice + " (se Opdateringer). 2) Er det et spil eller en emulator: opdatér grafikdriveren, og slå overlays fra (Discord, MSI Afterburner/RTSS, NVIDIA-overlay). 3) Hjælper det ikke, så geninstallér det.";
                res.Rows.Add(new CrashRow
                {
                    Level = n >= 3 ? 0 : n >= 2 ? 1 : 2, Sort = 1,
                    Title = nice + (a.Item2 > 0 && a.Item3 > 0 ? " lukkede uventet / hang" : a.Item2 > 0 ? " lukkede uventet" : " holdt op med at svare"),
                    Count = n + (n == 1 ? " gang" : " gange"), Last = a.Item5.ToString("dd-MM HH:mm"),
                    Note = near != null ? "Begyndte " + a.Item4.ToString("dd-MM") + ", kort efter: " + near.Item2 + " (" + near.Item1.ToString("dd-MM HH:mm") + ")" : n >= 2 ? "Første gang " + a.Item4.ToString("dd-MM HH:mm") : "",
                    Advice = adv
                });
            }
            res.Total = apps.Values.Sum(a => a.Item2 + a.Item3) + sys.Count;
            var top = apps.Values.OrderByDescending(a => a.Item2 + a.Item3).FirstOrDefault();
            res.Summary = res.Rows.Count == 0 ? "Ingen nedbrud eller uventede genstarter de seneste 14 dage. 🎉"
                : top != null && top.Item2 + top.Item3 >= 2 ? Regex.Replace(top.Item1, @"\.exe$", "", RegexOptions.IgnoreCase) + " har haft problemer " + (top.Item2 + top.Item3) + " gange de seneste 14 dage. Start dér."
                : "Enkelte nedbrud de seneste 14 dage. Intet gentager sig.";
            return res;
        }

        public static GpuLive Gpu()
        {
            var smi = Path.Combine(Environment.SystemDirectory, "nvidia-smi.exe");
            if (!File.Exists(smi)) return null;
            var o = Run(smi, "--query-gpu=name,power.draw,power.limit,temperature.gpu,fan.speed,clocks.gr,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits");
            var c = o.Split('\n')[0].Split(',');
            if (c.Length < 9) return null;
            Func<string, double> d = s => { double v; return double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : 0; };
            return new GpuLive { Name = c[0].Trim(), Power = d(c[1]), Limit = d(c[2]), Temp = d(c[3]), Fan = d(c[4]), Clock = d(c[5]), Util = d(c[6]), MemUsed = d(c[7]), MemTotal = d(c[8]) };
        }

        public static string Run(string exe, string args)
        {
            var psi = new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
            using (var p = Process.Start(psi))
            {
                var o = p.StandardOutput.ReadToEnd();
                p.WaitForExit(5000);
                return o;
            }
        }

        public static void SetPlan(bool high)
        {
            var pc = Path.Combine(Environment.SystemDirectory, "powercfg.exe");
            if (!high) { Run(pc, "/setactive SCHEME_BALANCED"); return; }
            var psi = new ProcessStartInfo(pc, "/setactive SCHEME_MIN") { UseShellExecute = false, CreateNoWindow = true };
            using (var p = Process.Start(psi)) { p.WaitForExit(5000); if (p.ExitCode == 0) return; }
            // "Høj ydelse" er skjult på nogle pc'er: lav en kopi af den
            var o = Run(pc, "/duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c");
            var m = Regex.Match(o, "([0-9a-f]{8}-[0-9a-f-]{27})", RegexOptions.IgnoreCase);
            if (m.Success) Run(pc, "/setactive " + m.Groups[1].Value);
        }

        public static string SupportInfo()
        {
            var i = SystemInfo.Read();
            return "Opticon " + Updater.Current.ToString(3) + "\n" + i.Windows + " · " + i.Build + " · " + i.Arch + "\nBundkort: " + i.Board + "\nProcessor: " + i.Cpu + " (" + i.CpuDetail + ")\nGrafikkort: " + string.Join("; ", i.Gpus) + "\nRAM: " + i.Ram + " (" + i.RamUsedPct + " % i brug)\nDisk: C: " + i.Disk;
        }
    }
}
