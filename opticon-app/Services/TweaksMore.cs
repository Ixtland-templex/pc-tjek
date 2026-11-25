using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Opticon.Services
{
    /// <summary>Flere optimeringer: hardwarefejl, spil-indstillinger i Windows, overlays og disk.</summary>
    public static class TweaksMore
    {
        static string Smi { get { var p = Path.Combine(Environment.SystemDirectory, "nvidia-smi.exe"); return File.Exists(p) ? p : null; } }

        static bool IsLaptop()
        {
            try { return Convert.ToInt32(Wmi.Prop(Wmi.First(@"root\cimv2", "SELECT PCSystemType FROM Win32_ComputerSystem"), "PCSystemType") ?? 0) == 2; } catch { return false; }
        }

        public static void Add(List<TweakCard> cards)
        {
            bool laptop = IsLaptop();
            Safe(() => cards.Add(Hardware(laptop)));
            Safe(() => cards.Add(GameSettingsCard(laptop)));
            Safe(() => cards.Add(Overlays()));
            Safe(() => cards.Add(DiskCard()));
        }

        static void Safe(Action a) { try { a(); } catch (Exception e) { App.Log("Optimering: " + e.Message); } }

        // ---------- Hardwarefejl ----------
        static TweakCard Hardware(bool laptop)
        {
            var c = new TweakCard { Icon = "🔌", Title = "Grafikkortet er sat rigtigt op" };
            var issues = new List<string>(); var ok = new List<string>(); var steps = new List<string>();
            var vids = Wmi.Query(@"root\cimv2", "SELECT Name, CurrentHorizontalResolution FROM Win32_VideoController")
                .Select(v => new { Name = Convert.ToString(Wmi.Prop(v, "Name")) ?? "", Active = Wmi.Prop(v, "CurrentHorizontalResolution") != null })
                .Where(v => !Regex.IsMatch(v.Name, "basic|virtual|remote|parsec|meta|mirage|displaylink", RegexOptions.IgnoreCase)).ToList();
            var dgpu = vids.FirstOrDefault(v => Regex.IsMatch(v.Name, "nvidia|radeon rx|radeon pro|arc a|arc b", RegexOptions.IgnoreCase));
            var igpu = vids.FirstOrDefault(v => v != dgpu && Regex.IsMatch(v.Name, "intel|radeon\\(tm\\) graphics|radeon graphics|uhd|iris", RegexOptions.IgnoreCase));

            // Skærmen sat i bundkortet (kun stationære: bærbare viser altid billedet via processorens grafik)
            if (!laptop && dgpu != null && igpu != null && igpu.Active && !dgpu.Active)
            {
                issues.Add("⚠ Skærmen ser ud til at sidde i bundkortets stik i stedet for grafikkortets. Så bruger spil processorens langsomme grafik, eller billedet sendes en omvej. Det kan koste over halvdelen af dine FPS.");
                steps.Add("Flyt skærmkablet fra stikket ved USB-portene (bundkortet) til et af stikkene længere nede på bagsiden (grafikkortet).");
            }
            else if (dgpu != null && !laptop) ok.Add("Skærmen sidder i grafikkortet ✓");

            var smi = Smi;
            if (smi != null)
            {
                var o = Health.Run(smi, "--query-gpu=pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv,noheader,nounits").Split('\n')[0].Split(',');
                int gen, wcur, wmax;
                if (o.Length >= 3 && int.TryParse(o[0].Trim(), out gen) && int.TryParse(o[1].Trim(), out wcur) && int.TryParse(o[2].Trim(), out wmax))
                {
                    if (wcur < wmax && !laptop)
                    {
                        issues.Add("⚠ Grafikkortet kører kun med " + wcur + " PCIe-baner af " + wmax + " mulige (x" + wcur + " i stedet for x" + wmax + "). Det sker typisk, når kortet sidder i den nederste plads, eller når en NVMe-disk deler baner med det.");
                        steps.Add("Sæt grafikkortet i den øverste lange PCIe-plads (tættest på processoren). Står der stadig x" + wcur + " bagefter, så se i bundkortets manual, om en M.2-plads deler baner med grafikkortet.");
                    }
                    else ok.Add("PCIe x" + wcur + " (Gen " + gen + ") ✓");
                }
                var mem = Health.Run(smi, "-q -d MEMORY");
                var fb = Regex.Match(mem, @"FB Memory Usage\s+Total\s+:\s+(\d+)\s+MiB");
                var bar = Regex.Match(mem, @"BAR1 Memory Usage\s+Total\s+:\s+(\d+)\s+MiB");
                if (fb.Success && bar.Success)
                {
                    double f = double.Parse(fb.Groups[1].Value), b = double.Parse(bar.Groups[1].Value);
                    if (b < f * 0.5)
                    {
                        issues.Add("💡 Resizable BAR er slået fra. Med den kan processoren tilgå hele grafikkortets hukommelse på én gang, hvilket giver op til ca. 10 % flere FPS i nogle spil (for det meste lidt eller intet).");
                        string board = Convert.ToString(Wmi.Prop(Wmi.First(@"root\cimv2", "SELECT Manufacturer FROM Win32_BaseBoard"), "Manufacturer")) ?? "";
                        steps.Add("Resizable BAR (avanceret, i BIOS): slå \"Above 4G Decoding\" og \"Re-Size BAR Support\" til" + (Regex.IsMatch(board, "asrock", RegexOptions.IgnoreCase) ? " (ASRock: Advanced → Chipset Configuration)" : Regex.IsMatch(board, "asus", RegexOptions.IgnoreCase) ? " (ASUS: Advanced → PCI Subsystem Settings)" : Regex.IsMatch(board, "msi|micro-star", RegexOptions.IgnoreCase) ? " (MSI: Settings → Advanced → PCI Subsystem Settings)" : Regex.IsMatch(board, "gigabyte", RegexOptions.IgnoreCase) ? " (GIGABYTE: Settings → IO Ports)" : "") + ". Det kræver, at CSM er slået fra (Windows installeret i UEFI-tilstand). Tryk F10 for at gemme.");
                    }
                    else ok.Add("Resizable BAR er til ✓");
                }
            }
            else if (dgpu == null) ok.Add("Intet separat grafikkort fundet");

            c.State = issues.Any(i => i.StartsWith("⚠")) ? "tip" : issues.Count > 0 ? "tip" : "good";
            c.Badge = issues.Any(i => i.StartsWith("⚠")) ? "⚠ Koster sandsynligvis FPS" : issues.Count > 0 ? "💡 Mulig forbedring" : "✓ Alt godt";
            c.Text = string.Join("\n\n", issues.Concat(ok.Count > 0 ? new[] { string.Join(" · ", ok) } : new string[0]));
            if (string.IsNullOrEmpty(c.Text)) c.Text = "Kunne ikke læse grafikkortets forbindelse.";
            if (steps.Count > 0) { c.Steps = string.Join("\n\n", steps); if (issues.Any(i => i.Contains("Resizable"))) { c.Action = "🔁  Genstart til BIOS"; c.ActionId = "bios"; } }
            return c;
        }

        // ---------- Spil-indstillinger i Windows ----------
        const string GpuPref = @"Software\Microsoft\DirectX\UserGpuPreferences";

        static TweakCard GameSettingsCard(bool laptop)
        {
            var c = new TweakCard { Icon = "🎮", Title = "Spil-indstillinger i Windows" };
            var tips = new List<string>(); var ok = new List<string>(); var fixes = new List<string>();
            string global;
            using (var k = Registry.CurrentUser.OpenSubKey(GpuPref)) global = k == null ? "" : Convert.ToString(k.GetValue("DirectXUserGlobalSettings")) ?? "";
            if (global.Contains("SwapEffectUpgradeEnable=0")) { tips.Add("💡 \"Optimeringer af spil i vinduer\" er slået fra. Den giver lavere forsinkelse i spil, der kører i vindue eller kantløst vindue, og gør det muligt at bruge Auto HDR og VRR i dem."); fixes.Add("windowed"); }
            else ok.Add("Optimeringer af spil i vinduer ✓");

            string ms; using (var k = Registry.CurrentUser.OpenSubKey(@"Control Panel\Mouse")) ms = k == null ? "0" : Convert.ToString(k.GetValue("MouseSpeed")) ?? "0";
            if (ms != "0") { tips.Add("💡 \"Forbedret markørpræcision\" (musacceleration) er slået til. Så flytter musen sig længere, jo hurtigere du bevæger den. Det gør det svært at ramme præcist i skydespil, fordi samme bevægelse ikke altid giver samme resultat."); fixes.Add("mouse"); }
            else ok.Add("Ingen musacceleration ✓");

            if (laptop)
            {
                var vids = Wmi.Query(@"root\cimv2", "SELECT Name FROM Win32_VideoController").Select(v => Convert.ToString(Wmi.Prop(v, "Name")) ?? "").ToList();
                if (vids.Any(n => Regex.IsMatch(n, "nvidia|radeon rx", RegexOptions.IgnoreCase)) && vids.Count > 1)
                {
                    var games = Modes.Games().Where(g => !string.IsNullOrEmpty(g.Path)).ToList();
                    var missing = new List<GameProfile>();
                    using (var k = Registry.CurrentUser.OpenSubKey(GpuPref))
                        foreach (var g in games) if (!(Convert.ToString(k == null ? null : k.GetValue(g.Path)) ?? "").Contains("GpuPreference=2")) missing.Add(g);
                    if (games.Count == 0) tips.Add("💡 Din bærbare har to grafikkort. Sørg for, at spil bruger det kraftige: tilføj dine spil under Tilstande, så kan Opticon sætte det for dig.");
                    else if (missing.Count > 0) { tips.Add("💡 Din bærbare har to grafikkort. " + string.Join(", ", missing.Select(g => g.Name)) + " er ikke sat til at bruge det kraftige grafikkort, så Windows kan vælge det svage for at spare strøm."); fixes.Add("gpupref"); }
                    else ok.Add("Dine spil bruger det kraftige grafikkort ✓");
                }
            }
            c.State = tips.Count > 0 ? "tip" : "good";
            c.Badge = tips.Count > 0 ? "💡 " + tips.Count + (tips.Count == 1 ? " forslag" : " forslag") : "✓ Alt godt";
            c.Text = string.Join("\n\n", tips.Concat(ok.Count > 0 ? new[] { string.Join(" · ", ok) } : new string[0]));
            if (fixes.Count > 0) { c.Action = "✓  Ret det"; c.ActionId = "fix:" + string.Join(",", fixes); }
            c.Action2 = "⚙  Grafikindstillinger"; c.Action2Id = "ms-settings:display-advancedgraphics";
            return c;
        }

        // ---------- Overlays og baggrund ----------
        static readonly Tuple<string, string, string>[] Known =
        {
            Tuple.Create("Discord", "discord", "Discord: slå \"In-game overlay\" fra under Brugerindstillinger → Spil-overlay, hvis du ikke bruger den. Slå også \"Hardwareacceleration\" fra under Avanceret, hvis spillet hakker, mens Discord er åben."),
            Tuple.Create("Steam", "steam", "Steam-overlay: Steam → Indstillinger → I spillet → slå Steam-overlay fra, hvis du ikke bruger det."),
            Tuple.Create("MSI Afterburner / RivaTuner", "rtss|msiafterburner", "RivaTuner (RTSS) tegner FPS-tælleren oven på spillet. Den er normalt let, men kan give hak med nogle spil og anti-cheat. Luk den, hvis du ikke kigger på tallene."),
            Tuple.Create("NVIDIA-overlay", "nvidia overlay", "NVIDIA App-overlay (Alt+Z): slå det fra i NVIDIA App → Indstillinger, hvis du ikke optager eller bruger filtre."),
            Tuple.Create("Overwolf", "overwolf", "Overwolf: lægger apps oven på spil og er tung. Luk den, når du ikke bruger den."),
            Tuple.Create("Medal", "medal", "Medal optager hele tiden i baggrunden. Slå baggrundsoptagelse fra, hvis du ikke bruger den."),
            Tuple.Create("Wallpaper Engine", "wallpaper32|wallpaper64", "Wallpaper Engine: sæt den til at pause, når et program er i fuld skærm (Indstillinger → Ydelse)."),
            Tuple.Create("Razer Cortex", "razercortex", "Razer Cortex lukker selv programmer og ændrer indstillinger. Brug én af Opticon og Cortex, ikke begge."),
            Tuple.Create("Armoury Crate / iCUE / G HUB", "armourycrate|icue|lghub", "RGB- og blæserprogrammer bruger ofte lidt processor hele tiden. Behold dem, hvis de styrer blæsere."),
        };

        static TweakCard Overlays()
        {
            var c = new TweakCard { Icon = "🪟", Title = "Overlays og tunge programmer i baggrunden" };
            var procs = Process.GetProcesses();
            var names = new HashSet<string>(procs.Select(p => { try { return p.ProcessName.ToLowerInvariant(); } catch { return ""; } }));
            var found = Known.Where(k => names.Any(n => Regex.IsMatch(n, "^(" + k.Item2 + ")$"))).ToList();
            bool gameBar;
            using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\GameBar")) gameBar = k == null || Convert.ToInt32(k.GetValue("UseNexusForGameBarEnabled", 1)) != 0;
            var heavy = procs.Select(p => { try { return new { Name = p.ProcessName, Mb = p.WorkingSet64 / 1048576 }; } catch { return null; } })
                .Where(x => x != null && x.Mb > 1200 && !Regex.IsMatch(x.Name, "^(memory compression|system|vmmem.*|opticon|dwm|msmpeng)$", RegexOptions.IgnoreCase))
                .GroupBy(x => x.Name).Select(g => new { Name = g.Key, Mb = g.Sum(x => x.Mb) }).OrderByDescending(x => x.Mb).Take(3).ToList();
            var lines = new List<string>();
            foreach (var f in found) lines.Add("•  " + f.Item3);
            if (gameBar) lines.Add("•  Xbox Game Bar (Win+G) er slået til. Den er let, men bruger du den aldrig, kan den slås fra under Indstillinger → Spil → Game Bar.");
            if (heavy.Count > 0) lines.Add("Bruger meget hukommelse lige nu: " + string.Join(", ", heavy.Select(h => h.Name + " (" + (h.Mb / 1024.0).ToString("0.0", CultureInfo.GetCultureInfo("da-DK")) + " GB)")) + ". Luk dem, før du spiller, eller lad Spil-tilstanden under Tilstande gøre det.");
            c.State = found.Count >= 2 || heavy.Count > 0 ? "tip" : found.Count > 0 ? "info" : "good";
            c.Badge = found.Count == 0 && heavy.Count == 0 ? "✓ Intet tungt kører" : found.Count + " overlay" + (found.Count == 1 ? "" : "s") + " fundet";
            c.Now = found.Count + (found.Count == 1 ? " overlay kører" : " overlays kører");
            c.Text = lines.Count == 0 ? "Ingen kendte overlays eller tunge programmer kører lige nu." : "Overlays tegner oven på spillet og kan give hak eller lavere FPS. Ét eller to er normalt fint. Behold dem, du bruger.\n\n" + string.Join("\n", lines);
            c.Action = "🎯  Spil-tilstand"; c.ActionId = "page:modes";
            c.Action2 = "⚙  Game Bar"; c.Action2Id = "ms-settings:gaming-gamebar";
            return c;
        }

        // ---------- Disk og lager ----------
        static TweakCard DiskCard()
        {
            var c = new TweakCard { Icon = "💾", Title = "Disk og lager" };
            var tips = new List<string>(); var ok = new List<string>(); var fixes = new List<string>();
            foreach (var d in DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.Fixed && d.IsReady))
            {
                int pct = (int)Math.Round(100.0 * d.AvailableFreeSpace / d.TotalSize);
                if (pct < (d.Name.StartsWith("C") ? 15 : 10)) tips.Add("⚠ " + d.Name.TrimEnd('\\') + " er næsten fuld (" + pct + " % ledig). En SSD bliver langsommere, når den er over ca. 85-90 % fuld, og Windows har brug for plads til opdateringer. Brug Oprydning og \"Hvad fylder?\".");
            }
            if (tips.Count == 0) ok.Add("God plads på alle diske ✓");
            int? policy;
            using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy")) policy = k == null ? (int?)null : Convert.ToInt32(k.GetValue("01", 0));
            if (policy != 1) { tips.Add("💡 Lagerfornuft er slået fra. Den rydder selv midlertidige filer og papirkurven op, så disken ikke langsomt fyldes."); fixes.Add("storagesense"); }
            else ok.Add("Lagerfornuft ✓");
            // TRIM og den planlagte optimering af drev
            try
            {
                var t = Type.GetTypeFromProgID("Schedule.Service");
                dynamic svc = Activator.CreateInstance(t); svc.Connect();
                dynamic task = svc.GetFolder("\\Microsoft\\Windows\\Defrag").GetTask("ScheduledDefrag");
                if (!(bool)task.Enabled) { tips.Add("⚠ Windows' ugentlige optimering af drev er slået fra. På en SSD er det den, der kører TRIM, så disken holder farten. Slå den til under \"Optimer drev\"."); }
                else ok.Add("Ugentlig optimering af drev (TRIM) ✓");
            }
            catch { }
            if (Admin.IsElevated)
                try { var o = Health.Run(Path.Combine(Environment.SystemDirectory, "fsutil.exe"), "behavior query DisableDeleteNotify"); if (Regex.IsMatch(o, @"NTFS DisableDeleteNotify = 1")) tips.Add("⚠ TRIM er slået fra for NTFS. Uden TRIM bliver en SSD langsommere med tiden."); } catch { }
            c.State = tips.Any(x => x.StartsWith("⚠")) ? "tip" : tips.Count > 0 ? "tip" : "good";
            c.Badge = tips.Count > 0 ? "💡 " + tips.Count + " forslag" : "✓ Alt godt";
            c.Text = string.Join("\n\n", tips.Concat(ok.Count > 0 ? new[] { string.Join(" · ", ok) } : new string[0]));
            if (fixes.Count > 0) { c.Action = "✓  Slå Lagerfornuft til"; c.ActionId = "fix:" + string.Join(",", fixes); }
            c.Action2 = "⚙  Optimer drev"; c.Action2Id = "run:dfrgui.exe";
            return c;
        }

        // ---------- Rettelser ----------
        [DllImport("user32.dll", SetLastError = true)] static extern bool SystemParametersInfo(uint action, uint param, int[] vparam, uint winIni);

        public static string Fix(string ids)
        {
            var done = new List<string>();
            foreach (var id in ids.Split(','))
                switch (id)
                {
                    case "windowed":
                        using (var k = Registry.CurrentUser.CreateSubKey(GpuPref, true))
                        {
                            var g = Convert.ToString(k.GetValue("DirectXUserGlobalSettings")) ?? "";
                            g = Regex.Replace(g, "SwapEffectUpgradeEnable=\\d;?", "");
                            k.SetValue("DirectXUserGlobalSettings", g + "SwapEffectUpgradeEnable=1;", RegistryValueKind.String);
                        }
                        done.Add("Optimeringer af spil i vinduer er slået til (virker fra næste gang spillet startes)");
                        break;
                    case "mouse":
                        SystemParametersInfo(0x0004, 0, new[] { 0, 0, 0 }, 0x01 | 0x02);   // SPI_SETMOUSE, gem og giv besked
                        done.Add("Musacceleration er slået fra");
                        break;
                    case "gpupref":
                        using (var k = Registry.CurrentUser.CreateSubKey(GpuPref, true))
                            foreach (var g in Modes.Games().Where(x => !string.IsNullOrEmpty(x.Path))) k.SetValue(g.Path, "GpuPreference=2;", RegistryValueKind.String);
                        done.Add("Dine spil bruger nu det kraftige grafikkort");
                        break;
                    case "storagesense":
                        using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy", true)) k.SetValue("01", 1, RegistryValueKind.DWord);
                        done.Add("Lagerfornuft er slået til");
                        break;
                }
            App.Log("Retter: " + ids);
            return string.Join(".\n", done) + ".";
        }
    }
}
