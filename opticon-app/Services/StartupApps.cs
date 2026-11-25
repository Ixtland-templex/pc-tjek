using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Opticon.Services
{
    public class StartupItem
    {
        public string Name { get; set; }
        public string Tip { get; set; }
        public string Publisher { get; set; }
        public string Source { get; set; }
        public bool On { get; set; }
        public string Kind;          // reg, appx
        public RegistryKey Hive;
        public string ApprKey;       // under Hive
        public string ValueName;
        public string State { get { return On ? "Til" : "Fra"; } }
        public string ToggleText { get { return On ? "Slå fra" : "Slå til"; } }
        public System.Windows.Media.Brush DotBrush { get { return DotBrushes.For(On ? "#4ADE80" : "#4B5263"); } }
        public bool CanDisable { get { return Tip.StartsWith("Kan slås fra"); } }
    }

    /// <summary>Programmer, der starter med Windows. Til/fra virker som i Jobliste (StartupApproved): intet slettes.</summary>
    public static class StartupApps
    {
        const string Approved = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved";
        static readonly Tuple<string, string>[] Tips =
        {
            Tuple.Create("security|defender|securityhealth", "Behold: Windows Sikkerhed"),
            Tuple.Create("opticon", "Behold: Opticon-vagten"),
            Tuple.Create("realtek|audio|nvidia|amd|intel|touchpad|synaptics|qualcomm|snapdragon", "Behold: driver eller hardware"),
            Tuple.Create("tailscale|synology", "Behold, hvis du bruger synkronisering eller fjernadgang"),
            Tuple.Create("nzxt", "Valgfri: tung, men styrer måske blæsere og køling"),
            Tuple.Create("poweriso", "Kan slås fra: Windows kan selv åbne ISO-filer"),
            Tuple.Create("spotify", "Kan slås fra: åbn den, når du vil høre musik"),
            Tuple.Create("discord", "Kan slås fra: åbn den, når du skal bruge den"),
            Tuple.Create("chatgpt|claude|copilot", "Kan slås fra: åbn den, når du skal bruge den"),
            Tuple.Create("steam|battle\\.net|epic|xbox|ea desktop|ubisoft", "Kan slås fra: spil-launchere behøver ikke starte med Windows"),
            Tuple.Create("onedrive", "Valgfri: behold, hvis du synkroniserer filer med OneDrive"),
            Tuple.Create("teams|skype", "Valgfri: slå fra, hvis du ikke bruger den dagligt"),
            Tuple.Create("gigabyte|gcc|rgb|corsair|icue|armoury|lghub|razer", "Valgfri: behold, hvis den styrer blæsere eller RGB"),
            Tuple.Create("cisco|anyconnect|vpn", "Valgfri: behold, hvis du bruger VPN (fx skolens)"),
            Tuple.Create("adobe|acrobat|updater|update", "Kan slås fra: opdaterer også, når programmet åbnes"),
        };

        static string Tip(string name, string cmd, string sig)
        {
            foreach (var t in Tips) if (Regex.IsMatch(name + " " + cmd, t.Item1, RegexOptions.IgnoreCase)) return t.Item2;
            if (sig == "USIGNERET") return "⚠ Usigneret. Kender du den ikke, så slå den fra, og tjek den med Scan pc'en";
            return "Valgfri";
        }

        static bool IsOn(RegistryKey hive, string apprKey, string name)
        {
            using (var k = hive.OpenSubKey(apprKey))
            {
                var b = k == null ? null : k.GetValue(name) as byte[];
                return !(b != null && b.Length > 0 && (b[0] & 1) == 1);
            }
        }

        static string ShortSig(string path)
        {
            var s = Signature.Check(path);
            return s.StartsWith("Signeret: ") ? s.Substring(10) : s == "Ikke fundet" ? "(fil ikke fundet)" : s;
        }

        public static List<StartupItem> List()
        {
            var items = new List<StartupItem>();
            var srcs = new[]
            {
                Tuple.Create(Registry.CurrentUser, @"Software\Microsoft\Windows\CurrentVersion\Run", "Run", "Din bruger"),
                Tuple.Create(Registry.LocalMachine, @"Software\Microsoft\Windows\CurrentVersion\Run", "Run", "Alle brugere"),
                Tuple.Create(Registry.LocalMachine, @"Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run", "Run32", "Alle (32-bit)"),
            };
            foreach (var s in srcs)
                try
                {
                    using (var k = s.Item1.OpenSubKey(s.Item2))
                        if (k != null)
                            foreach (var n in k.GetValueNames())
                            {
                                var cmd = Convert.ToString(k.GetValue(n));
                                var sig = ShortSig(Signature.ExePath(cmd));
                                var appr = Approved + "\\" + s.Item3;
                                items.Add(new StartupItem { Name = n, Publisher = sig, Source = s.Item4, Kind = "reg", Hive = s.Item1, ApprKey = appr, ValueName = n, On = IsOn(s.Item1, appr, n), Tip = Tip(n, cmd, sig) });
                            }
                }
                catch { }
            foreach (var sf in new[] { Tuple.Create(Environment.GetFolderPath(Environment.SpecialFolder.Startup), Registry.CurrentUser, "Startmappe"), Tuple.Create(Environment.GetFolderPath(Environment.SpecialFolder.CommonStartup), Registry.LocalMachine, "Startmappe (alle)") })
                try
                {
                    if (!Directory.Exists(sf.Item1)) continue;
                    foreach (var f in new DirectoryInfo(sf.Item1).GetFiles().Where(f => !f.Name.Equals("desktop.ini", StringComparison.OrdinalIgnoreCase)))
                    {
                        var appr = Approved + "\\StartupFolder";
                        items.Add(new StartupItem { Name = Path.GetFileNameWithoutExtension(f.Name), Publisher = f.Extension.Equals(".lnk", StringComparison.OrdinalIgnoreCase) ? "Genvej" : ShortSig(f.FullName), Source = sf.Item3, Kind = "reg", Hive = sf.Item2, ApprKey = appr, ValueName = f.Name, On = IsOn(sf.Item2, appr, f.Name), Tip = Tip(f.Name, f.FullName, "") });
                    }
                }
                catch { }
            // Store-apps (Spotify, ChatGPT …): StartupTask State. 2 = til, 1 = slået fra af dig, 4 = tvunget til af en politik
            try
            {
                const string AppData = @"Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData";
                using (var root = Registry.CurrentUser.OpenSubKey(AppData))
                    if (root != null)
                        foreach (var pkg in root.GetSubKeyNames())
                            using (var pk = root.OpenSubKey(pkg))
                                foreach (var task in pk.GetSubKeyNames())
                                    using (var tk = pk.OpenSubKey(task))
                                    {
                                        var st = tk == null ? null : tk.GetValue("State");
                                        if (st == null) continue;
                                        int state = Convert.ToInt32(st);
                                        var nice = Regex.Replace(pkg.Split('_')[0], @"^[^.]+\.", "");
                                        items.Add(new StartupItem { Name = nice, Publisher = "Microsoft Store-app", Source = "Store-app", Kind = "appx", Hive = Registry.CurrentUser, ApprKey = AppData + "\\" + pkg + "\\" + task, ValueName = "State", On = state == 2 || state == 4, Tip = Tip(nice, pkg, "Store") });
                                    }
            }
            catch { }
            return items.OrderBy(i => !i.On).ThenBy(i => i.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        }

        /// <summary>Alle brugere (HKLM) kræver administrator.</summary>
        public static void Set(StartupItem it, bool enable)
        {
            if (it.Kind == "appx")
            {
                using (var k = it.Hive.OpenSubKey(it.ApprKey, true))
                {
                    if (!enable && Convert.ToInt32(k.GetValue("State")) == 4) throw new Exception("Appen er låst til at starte af en politik.");
                    k.SetValue("State", enable ? 2 : 1, RegistryValueKind.DWord);
                }
                return;
            }
            using (var k = it.Hive.CreateSubKey(it.ApprKey, true))
            {
                var b = new byte[12];
                if (enable) b[0] = 2; else { b[0] = 3; BitConverter.GetBytes(DateTime.Now.ToFileTime()).CopyTo(b, 4); }
                k.SetValue(it.ValueName, b, RegistryValueKind.Binary);
            }
        }
    }
}
