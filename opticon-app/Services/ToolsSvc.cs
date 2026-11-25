using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Management;
using System.Net.NetworkInformation;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Microsoft.Win32;

namespace Opticon.Services
{
    public class PickRow : INotifyPropertyChanged
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Note { get; set; }
        public bool Installed { get; set; }
        bool sel; public bool Selected { get { return sel; } set { sel = value; On("Selected"); } }
        string status = ""; public string Status { get { return status; } set { status = value; On("Status"); } }
        public string State { get; set; }
        public event PropertyChangedEventHandler PropertyChanged;
        void On(string n) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    }

    // ---------------- 1. Gendannelsespunkt ----------------
    public static class RestorePoint
    {
        public static string Last()
        {
            try
            {
                var pts = Wmi.Query(@"root\default", "SELECT Description, CreationTime FROM SystemRestore");
                if (pts.Count == 0) return "Ingen gendannelsespunkter endnu.";
                var last = pts.Select(p => new { D = Convert.ToString(Wmi.Prop(p, "Description")), T = ManagementDateTimeConverter.ToDateTime(Convert.ToString(Wmi.Prop(p, "CreationTime"))) }).OrderByDescending(x => x.T).First();
                return "Seneste: \"" + last.D + "\" " + last.T.ToString("d. MMM yyyy 'kl.' HH:mm", new CultureInfo("da-DK")) + " (" + pts.Count + " i alt).";
            }
            catch { return Admin.IsElevated ? "Systembeskyttelse ser ud til at være slået fra." : "Kør som administrator for at se gendannelsespunkter."; }
        }

        /// <summary>Kræver administrator. Slår systembeskyttelse til på C:, hvis den er slået fra.</summary>
        public static string Create(string desc)
        {
            using (var cls = new ManagementClass(new ManagementScope(@"root\default"), new ManagementPath("SystemRestore"), null))
            {
                try { var en = cls.GetMethodParameters("Enable"); en["Drive"] = Path.GetPathRoot(Environment.SystemDirectory); cls.InvokeMethod("Enable", en, null); } catch { }
                // Windows tillader normalt kun ét punkt pr. døgn. Slå grænsen fra et øjeblik.
                object prev = null;
                const string K = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore";
                try { using (var k = Registry.LocalMachine.CreateSubKey(K, true)) { prev = k.GetValue("SystemRestorePointCreationFrequency"); k.SetValue("SystemRestorePointCreationFrequency", 0, RegistryValueKind.DWord); } } catch { }
                try
                {
                    var p = cls.GetMethodParameters("CreateRestorePoint");
                    p["Description"] = desc; p["RestorePointType"] = 12; p["EventType"] = 100;
                    var o = cls.InvokeMethod("CreateRestorePoint", p, null);
                    int rv = Convert.ToInt32(o["ReturnValue"]);
                    if (rv != 0) throw new Exception("Windows kunne ikke lave gendannelsespunktet (kode " + rv + "). Er Systembeskyttelse slået til?");
                }
                finally
                {
                    try { using (var k = Registry.LocalMachine.CreateSubKey(K, true)) { if (prev == null) k.DeleteValue("SystemRestorePointCreationFrequency", false); else k.SetValue("SystemRestorePointCreationFrequency", prev, RegistryValueKind.DWord); } } catch { }
                }
            }
            App.Log("Gendannelsespunkt oprettet: " + desc);
            return "✓ Gendannelsespunktet \"" + desc + "\" er lavet. Går noget galt, kan du gå tilbage hertil med \"Åbn Systemgendannelse\".";
        }
    }

    // ---------------- 2. Forudinstallerede apps ----------------
    public static class Bloat
    {
        // (pakkenavn-mønster, visningsnavn, forvalgt, note)
        static readonly Tuple<string, string, bool, string>[] List =
        {
            Tuple.Create("king.com.", "Candy Crush og andre King-spil", true, "Reklamespil installeret af Windows"),
            Tuple.Create("BytedancePte.Ltd.TikTok", "TikTok", true, "Forudinstalleret genvej"),
            Tuple.Create("Disney.", "Disney+", true, "Forudinstalleret genvej"),
            Tuple.Create("Facebook.", "Facebook / Instagram", true, "Forudinstalleret genvej"),
            Tuple.Create("AmazonVideo.PrimeVideo", "Prime Video", true, "Forudinstalleret genvej"),
            Tuple.Create("Microsoft.MicrosoftSolitaireCollection", "Microsoft Solitaire", true, "Spil med reklamer"),
            Tuple.Create("Microsoft.BingNews", "Nyheder (Microsoft News)", true, "Nyhedsapp med reklamer"),
            Tuple.Create("Microsoft.BingWeather", "Vejret (MSN Vejr)", false, "Fjern, hvis du ikke bruger den"),
            Tuple.Create("Microsoft.GetHelp", "Få hjælp", true, "Microsofts hjælpe-app"),
            Tuple.Create("Microsoft.Getstarted", "Tips", true, "Windows-tips"),
            Tuple.Create("Microsoft.WindowsFeedbackHub", "Feedbackhub", true, "Til at sende feedback til Microsoft"),
            Tuple.Create("Microsoft.PowerAutomateDesktop", "Power Automate", true, "Automatisering, mest til firmaer"),
            Tuple.Create("Clipchamp.Clipchamp", "Clipchamp", true, "Videoredigering (online)"),
            Tuple.Create("Microsoft.MicrosoftOfficeHub", "Microsoft 365 (Office)-app", false, "Genvej til Office. Fjern, hvis du ikke bruger Office"),
            Tuple.Create("MicrosoftTeams", "Teams (privat)", false, "Fjern, hvis du ikke bruger Teams privat"),
            Tuple.Create("Microsoft.Todos", "Microsoft To Do", false, "Opgaveliste"),
            Tuple.Create("Microsoft.People", "Personer", true, "Gammel kontakt-app"),
            Tuple.Create("Microsoft.ZuneVideo", "Film og tv", true, "Gammel video-app (Medieafspiller kan det samme)"),
            Tuple.Create("Microsoft.YourPhone", "Phone Link", false, "Forbinder din telefon. Behold, hvis du bruger den"),
            Tuple.Create("Microsoft.OutlookForWindows", "Outlook (ny)", false, "Fjern, hvis du bruger Gmail eller anden mail"),
            Tuple.Create("Microsoft.Copilot", "Copilot", false, "Microsofts AI-assistent"),
            Tuple.Create("Microsoft.MicrosoftJournal", "Journal", true, "Notesapp til pen"),
            Tuple.Create("Microsoft.549981C3F5F10", "Cortana", true, "Afløst af Copilot"),
            Tuple.Create("Microsoft.MixedReality.Portal", "Mixed Reality-portal", true, "Til VR-briller fra Windows Mixed Reality"),
        };

        public static List<PickRow> Installed()
        {
            var pm = new Windows.Management.Deployment.PackageManager();
            var pkgs = pm.FindPackagesForUser("").ToList();
            var rows = new List<PickRow>();
            foreach (var b in List)
            {
                var hits = pkgs.Where(p => { try { return p.Id.Name.StartsWith(b.Item1, StringComparison.OrdinalIgnoreCase) && !p.IsFramework; } catch { return false; } }).ToList();
                if (hits.Count == 0) continue;
                rows.Add(new PickRow { Id = string.Join("|", hits.Select(h => h.Id.FullName)), Name = b.Item2, Note = b.Item4, Selected = b.Item3, Installed = true });
            }
            return rows;
        }

        public static string Remove(PickRow r)
        {
            var pm = new Windows.Management.Deployment.PackageManager();
            int ok = 0; string err = null;
            foreach (var full in r.Id.Split('|'))
                try
                {
                    var res = pm.RemovePackageAsync(full).AsTask().Result;
                    if (res.IsRegistered) err = res.ErrorText; else ok++;
                }
                catch (Exception e) { err = (e.InnerException ?? e).Message; }
            App.Log("Fjern app " + r.Name + ": " + (err ?? "ok"));
            return err == null ? "✓ Fjernet" : ok > 0 ? "Delvist fjernet" : "Kunne ikke fjernes: " + err;
        }
    }

    // ---------------- 3. Populære programmer ----------------
    public static class Installs
    {
        static readonly Tuple<string, string, string, string>[] List =
        {
            Tuple.Create("Valve.Steam", "Steam", "steam", "Spil"),
            Tuple.Create("EpicGames.EpicGamesLauncher", "Epic Games Launcher", "epic games launcher", "Spil"),
            Tuple.Create("ElectronicArts.EADesktop", "EA app", "ea app", "Spil"),
            Tuple.Create("Ubisoft.Connect", "Ubisoft Connect", "ubisoft connect", "Spil"),
            Tuple.Create("Blizzard.BattleNet", "Battle.net", "battle.net", "Spil"),
            Tuple.Create("Discord.Discord", "Discord", "discord", "Snak"),
            Tuple.Create("Google.Chrome", "Google Chrome", "google chrome", "Browser"),
            Tuple.Create("Mozilla.Firefox", "Firefox", "mozilla firefox", "Browser"),
            Tuple.Create("Brave.Brave", "Brave", "brave", "Browser"),
            Tuple.Create("7zip.7zip", "7-Zip", "7-zip", "Værktøj · pakker zip, rar og 7z ud"),
            Tuple.Create("VideoLAN.VLC", "VLC", "vlc media player", "Medie · afspiller alt"),
            Tuple.Create("Spotify.Spotify", "Spotify", "spotify", "Medie"),
            Tuple.Create("OBSProject.OBSStudio", "OBS Studio", "obs studio", "Optag og stream"),
            Tuple.Create("Microsoft.PowerToys", "PowerToys", "powertoys", "Værktøj · Microsofts ekstra funktioner"),
            Tuple.Create("Notepad++.Notepad++", "Notepad++", "notepad++", "Værktøj · teksteditor"),
            Tuple.Create("Microsoft.VisualStudioCode", "Visual Studio Code", "microsoft visual studio code", "Programmering"),
            Tuple.Create("REALiX.HWiNFO", "HWiNFO", "hwinfo", "Værktøj · temperaturer og sensorer"),
            Tuple.Create("Bitwarden.Bitwarden", "Bitwarden", "bitwarden", "Sikkerhed · gratis adgangskode-manager"),
        };

        public static List<PickRow> Rows()
        {
            var names = new List<string>();
            foreach (var hive in new[] { Registry.LocalMachine, Registry.CurrentUser })
                foreach (var path in new[] { @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" })
                    try { using (var k = hive.OpenSubKey(path)) if (k != null) foreach (var sub in k.GetSubKeyNames()) using (var s = k.OpenSubKey(sub)) { var n = s?.GetValue("DisplayName") as string; if (!string.IsNullOrEmpty(n)) names.Add(n.ToLowerInvariant()); } } catch { }
            return List.Select(x => { bool inst = names.Any(n => n.StartsWith(x.Item3)); return new PickRow { Id = x.Item1, Name = x.Item2, Note = x.Item4, Installed = inst, State = inst ? "✓ Installeret" : "" }; }).ToList();
        }

        public static string Install(string id)
        {
            var exe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\winget.exe");
            var psi = new ProcessStartInfo(File.Exists(exe) ? exe : "winget.exe", "install --id " + id + " -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity") { UseShellExecute = false, CreateNoWindow = true };
            using (var p = Process.Start(psi))
            {
                if (!p.WaitForExit(30 * 60 * 1000)) { try { p.Kill(); } catch { } return "Tog for lang tid"; }
                App.Log("winget install " + id + ": kode " + p.ExitCode);
                return p.ExitCode == 0 ? "✓ Installeret" : p.ExitCode == unchecked((int)0x8A15002B) ? "✓ Allerede installeret" : "Fejl (kode 0x" + p.ExitCode.ToString("X8") + ")";
            }
        }
    }

    // ---------------- 4. Reklamer og forslag ----------------
    public static class Ads
    {
        const string CDM = @"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";
        const string ADV = @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";
        // (id, navn, nøgle, værdi, "slået fra"-værdi, standard når den mangler)
        static readonly Tuple<string, string, string, string, int, int>[] Items =
        {
            Tuple.Create("apps", "Windows installerer selv \"foreslåede\" apps (fx spil)", CDM, "SilentInstalledAppsEnabled", 0, 1),
            Tuple.Create("start", "Forslag og reklamer i Start-menuen", CDM, "SubscribedContent-338388Enabled", 0, 1),
            Tuple.Create("startrec", "Anbefalinger af tips og nye apps i Start", ADV, "Start_IrisRecommendations", 0, 1),
            Tuple.Create("tips", "\"Tips og forslag\", når du bruger Windows", CDM, "SubscribedContent-338389Enabled", 0, 1),
            Tuple.Create("settings", "Forslag i Indstillinger-appen", CDM, "SubscribedContent-338393Enabled", 0, 1),
            Tuple.Create("welcome", "\"Velkommen til Windows\" efter opdateringer", CDM, "SubscribedContent-310093Enabled", 0, 1),
            Tuple.Create("lock", "Sjove fakta og reklamer på låseskærmen", CDM, "RotatingLockScreenOverlayEnabled", 0, 1),
            Tuple.Create("explorer", "Reklamer for OneDrive/Microsoft 365 i Stifinder", ADV, "ShowSyncProviderNotifications", 0, 1),
            Tuple.Create("scoobe", "\"Få endnu mere ud af Windows\"-skærmen", @"Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement", "ScoobeSystemSettingEnabled", 0, 1),
            Tuple.Create("adid", "Reklame-id (personlige annoncer i apps)", @"Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo", "Enabled", 0, 1),
            Tuple.Create("tailored", "Tilpassede oplevelser ud fra dine diagnosedata", @"Software\Microsoft\Windows\CurrentVersion\Privacy", "TailoredExperiencesWithDiagnosticDataEnabled", 0, 1),
        };
        static string Backup { get { return Path.Combine(App.DataDir, "reklamer-backup.json"); } }

        public static List<PickRow> Rows()
        {
            var r = new List<PickRow>();
            foreach (var i in Items)
            {
                int v; using (var k = Registry.CurrentUser.OpenSubKey(i.Item3)) v = k == null ? i.Item6 : Convert.ToInt32(k.GetValue(i.Item4, i.Item6));
                bool on = v != i.Item5;
                r.Add(new PickRow { Id = i.Item1, Name = i.Item2, Installed = on, Selected = on, State = on ? "Til" : "Fra ✓" });
            }
            return r;
        }

        public static bool HasBackup { get { return File.Exists(Backup); } }

        public static void TurnOff(IEnumerable<string> ids)
        {
            var bak = new Dictionary<string, int?>();
            try { if (File.Exists(Backup)) bak = JsonSerializer.Deserialize<Dictionary<string, int?>>(File.ReadAllText(Backup)); } catch { }
            foreach (var i in Items.Where(x => ids.Contains(x.Item1)))
                using (var k = Registry.CurrentUser.CreateSubKey(i.Item3, true))
                {
                    if (!bak.ContainsKey(i.Item1)) { var cur = k.GetValue(i.Item4); bak[i.Item1] = cur == null ? (int?)null : Convert.ToInt32(cur); }
                    k.SetValue(i.Item4, i.Item5, RegistryValueKind.DWord);
                }
            Directory.CreateDirectory(App.DataDir);
            File.WriteAllText(Backup, JsonSerializer.Serialize(bak));
            App.Log("Retter: reklamer og forslag slået fra (" + string.Join(", ", ids) + ")");
        }

        public static void Restore()
        {
            var bak = JsonSerializer.Deserialize<Dictionary<string, int?>>(File.ReadAllText(Backup));
            foreach (var i in Items.Where(x => bak.ContainsKey(x.Item1)))
                using (var k = Registry.CurrentUser.CreateSubKey(i.Item3, true))
                {
                    var v = bak[i.Item1];
                    if (v == null) k.DeleteValue(i.Item4, false); else k.SetValue(i.Item4, v.Value, RegistryValueKind.DWord);
                }
            File.Delete(Backup);
            App.Log("Reklamer og forslag sat tilbage");
        }
    }

    // ---------------- 5. Batteri ----------------
    public class BatteryInfo { public string Name; public double Design, Full; public int Cycles; public double Health { get { return Design > 0 ? 100.0 * Full / Design : 0; } } }

    public static class Battery
    {
        public static string ReportHtml { get { return Path.Combine(App.DataDir, "batteri-rapport.html"); } }

        public static List<BatteryInfo> Read()
        {
            var list = new List<BatteryInfo>();
            var xml = Path.Combine(Path.GetTempPath(), "opticon-batteri.xml");
            Health.Run(Path.Combine(Environment.SystemDirectory, "powercfg.exe"), "/batteryreport /xml /output \"" + xml + "\"");
            if (!File.Exists(xml)) return list;
            try
            {
                var doc = XDocument.Load(xml);
                foreach (var b in doc.Descendants().Where(e => e.Name.LocalName == "Battery"))
                {
                    Func<string, string> v = n => b.Elements().FirstOrDefault(e => e.Name.LocalName == n)?.Value ?? "";
                    double d, f; int c;
                    double.TryParse(v("DesignCapacity"), NumberStyles.Any, CultureInfo.InvariantCulture, out d);
                    double.TryParse(v("FullChargeCapacity"), NumberStyles.Any, CultureInfo.InvariantCulture, out f);
                    int.TryParse(v("CycleCount"), out c);
                    if (d > 0) list.Add(new BatteryInfo { Name = (v("Manufacturer") + " " + v("Id")).Trim(), Design = d, Full = f, Cycles = c });
                }
            }
            finally { try { File.Delete(xml); } catch { } }
            return list;
        }

        public static void OpenReport()
        {
            Directory.CreateDirectory(App.DataDir);
            Health.Run(Path.Combine(Environment.SystemDirectory, "powercfg.exe"), "/batteryreport /output \"" + ReportHtml + "\"");
            if (File.Exists(ReportHtml)) Process.Start(new ProcessStartInfo(ReportHtml) { UseShellExecute = true });
        }
    }

    // ---------------- 6. Netværk ----------------
    public class PingRow { public string Target { get; set; } public string Result { get; set; } public string Note { get; set; } public System.Windows.Media.Brush DotBrush { get; set; } }

    public static class NetTest
    {
        public static Tuple<string, List<PingRow>, List<string>> Run(Action<string> status)
        {
            var advice = new List<string>();
            string kind = "Ukendt", wifi = "";
            string gateway = null;
            var nic = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback && n.GetIPProperties().GatewayAddresses.Any(g => g.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && !g.Address.ToString().StartsWith("0.")))
                .OrderBy(n => n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ? 1 : 0).FirstOrDefault();
            if (nic != null)
            {
                gateway = nic.GetIPProperties().GatewayAddresses.First(g => g.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork).Address.ToString();
                if (nic.NetworkInterfaceType == NetworkInterfaceType.Wireless80211)
                {
                    kind = "Wi-Fi";
                    var o = Health.Run(Path.Combine(Environment.SystemDirectory, "netsh.exe"), "wlan show interfaces");
                    var sig = Regex.Match(o, @"Signal\s*:\s*(\d+)\s*%"); var band = Regex.Match(o, @"(Band|Bånd)\s*:\s*([\d.,]+ ?GHz)"); var ssid = Regex.Match(o, @"^\s*SSID\s*:\s*(.+)$", RegexOptions.Multiline);
                    wifi = (ssid.Success ? ssid.Groups[1].Value.Trim() + " · " : "") + (sig.Success ? "signal " + sig.Groups[1].Value + " %" : "") + (band.Success ? " · " + band.Groups[2].Value : "");
                    advice.Add("Du er på Wi-Fi. Et netværkskabel giver næsten altid lavere og mere stabil ping i spil.");
                    if (sig.Success && int.Parse(sig.Groups[1].Value) < 60) advice.Add("Signalet er svagt (" + sig.Groups[1].Value + " %). Flyt routeren tættere på, eller brug kabel eller en mesh-enhed.");
                    if (band.Success && band.Groups[2].Value.StartsWith("2")) advice.Add("Du er på 2,4 GHz. Vælg routerens 5 GHz- eller 6 GHz-netværk, hvis du kan. Det er hurtigere og mindre forstyrret.");
                }
                else kind = "Kabel (" + (nic.Speed >= 1_000_000_000 ? (nic.Speed / 1_000_000_000) + " Gbit/s" : (nic.Speed / 1_000_000) + " Mbit/s") + ")";
                if (nic.NetworkInterfaceType != NetworkInterfaceType.Wireless80211 && nic.Speed > 0 && nic.Speed < 1_000_000_000) advice.Add("Netværkskortet kører kun " + nic.Speed / 1_000_000 + " Mbit/s. Et gammelt eller beskadiget kabel (Cat5) kan være skyld. Prøv et Cat6-kabel.");
            }
            var targets = new List<Tuple<string, string>>();
            if (gateway != null) targets.Add(Tuple.Create("Din router (" + gateway + ")", gateway));
            targets.Add(Tuple.Create("Cloudflare (1.1.1.1)", "1.1.1.1"));
            targets.Add(Tuple.Create("Google (8.8.8.8)", "8.8.8.8"));
            var rows = new List<PingRow>();
            using (var p = new Ping())
                foreach (var t in targets)
                {
                    status("Måler ping til " + t.Item1 + "…");
                    var times = new List<long>(); int lost = 0;
                    for (int i = 0; i < 30; i++)
                    {
                        try { var r = p.Send(t.Item2, 1000); if (r.Status == IPStatus.Success) times.Add(r.RoundtripTime); else lost++; } catch { lost++; }
                        System.Threading.Thread.Sleep(100);
                    }
                    if (times.Count == 0) { rows.Add(new PingRow { Target = t.Item1, Result = "Intet svar", Note = "Kan være blokeret af en firewall", DotBrush = DotBrushes.For("#6B7488") }); continue; }
                    double avg = times.Average(); double jit = times.Count > 1 ? times.Zip(times.Skip(1), (a, b) => (double)Math.Abs(a - b)).Average() : 0; double loss = 100.0 * lost / 30;
                    bool local = t.Item2 == gateway;
                    int lvl = loss > 2 || (local ? avg > 10 : avg > 60) || jit > (local ? 5 : 15) ? 0 : loss > 0 || (local ? avg > 4 : avg > 35) || jit > (local ? 2 : 8) ? 1 : 2;
                    rows.Add(new PingRow { Target = t.Item1, Result = Math.Round(avg) + " ms · udsving " + Math.Round(jit, 1) + " ms · tab " + Math.Round(loss) + " %", Note = lvl == 2 ? "Fint" : lvl == 1 ? "Okay" : "Dårligt", DotBrush = DotBrushes.For(lvl == 2 ? "#4ADE80" : lvl == 1 ? "#F5B83D" : "#F05252") });
                    if (local && (avg > 10 || loss > 0)) advice.Add("Allerede forbindelsen til din egen router er langsom eller ustabil. Det er dit hjemmenetværk (Wi-Fi eller kabel), ikke internettet.");
                    if (!local && loss > 2) advice.Add("Der forsvinder pakker på vej ud på internettet. Genstart routeren. Fortsætter det, så kontakt din internetudbyder.");
                }
            if (advice.Count == 0) advice.Add("✓ Din forbindelse ser god ud til spil.");
            return Tuple.Create(kind + (wifi.Length > 0 ? " · " + wifi : ""), rows, advice);
        }
    }
}
