using System;
using System.Collections.Generic;
using System.Linq;
using System.Management;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows;

namespace Opticon.Services
{
    /// <summary>Et kort på Optimering-siden.</summary>
    public class TweakCard
    {
        public string Icon { get; set; }
        public string Title { get; set; }
        public string State { get; set; }      // good, tip, info
        public string Badge { get; set; }
        public string Now { get; set; }
        public string Can { get; set; }
        public string Text { get; set; }
        public string Steps { get; set; }
        public string Action { get; set; }     // knaptekst
        public string ActionId { get; set; }
        public string Action2 { get; set; }
        public string Action2Id { get; set; }
        public System.Windows.Media.Brush BadgeBrush { get { return DotBrushes.For(State == "good" ? "#4ADE80" : State == "tip" ? "#F6C344" : "#8AB4FF"); } }
        public System.Windows.Media.Brush BadgeBack { get { return DotBrushes.For(State == "good" ? "#173325" : State == "tip" ? "#3A2E12" : "#1D2433"); } }
        public Visibility CanVis { get { return string.IsNullOrEmpty(Can) ? Visibility.Collapsed : Visibility.Visible; } }
        public Visibility ActionVis { get { return string.IsNullOrEmpty(Action) ? Visibility.Collapsed : Visibility.Visible; } }
        public Visibility Action2Vis { get { return string.IsNullOrEmpty(Action2) ? Visibility.Collapsed : Visibility.Visible; } }
        public Visibility StepsVis { get { return string.IsNullOrEmpty(Steps) ? Visibility.Collapsed : Visibility.Visible; } }
    }

    /// <summary>"Gratis ydelse, der ofte bliver glemt": RAM-hastighed (XMP/EXPO), skærmens Hz, driver- og BIOS-alder.</summary>
    public static class Tweaks
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DEVMODE
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
            public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
            public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
            public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DISPLAY_DEVICE
        {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);

        class Screen { public string Name; public int W, H, Cur, Max; }

        static List<Screen> Screens()
        {
            var list = new List<Screen>();
            for (uint i = 0; i < 16; i++)
            {
                var d = new DISPLAY_DEVICE { cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE)) };
                if (!EnumDisplayDevices(null, i, ref d, 0)) break;
                if ((d.StateFlags & 1) == 0) continue;
                var cur = new DEVMODE { dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)) };
                if (!EnumDisplaySettings(d.DeviceName, -1, ref cur)) continue;
                int max = cur.dmDisplayFrequency;
                var m = new DEVMODE { dmSize = cur.dmSize };
                for (int k = 0; k < 5000 && EnumDisplaySettings(d.DeviceName, k, ref m); k++)
                    if (m.dmPelsWidth == cur.dmPelsWidth && m.dmPelsHeight == cur.dmPelsHeight && m.dmDisplayFrequency > max) max = m.dmDisplayFrequency;
                var mon = new DISPLAY_DEVICE { cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE)) };
                string name = EnumDisplayDevices(d.DeviceName, 0, ref mon, 0) ? mon.DeviceString : d.DeviceName;
                list.Add(new Screen { Name = name, W = cur.dmPelsWidth, H = cur.dmPelsHeight, Cur = cur.dmDisplayFrequency, Max = max });
            }
            // Rigtige skærmnavne fra skærmen selv (EDID), hvis Windows kun siger "Generisk skærm"
            try
            {
                var friendly = Wmi.Query(@"root\wmi", "SELECT UserFriendlyName FROM WmiMonitorID")
                    .Select(o => (Wmi.Prop(o, "UserFriendlyName") as ushort[]) ?? new ushort[0])
                    .Select(a => new string(a.Where(c => c != 0).Select(c => (char)c).ToArray()).Trim()).ToList();
                for (int i = 0; i < list.Count && i < friendly.Count; i++)
                    if (Regex.IsMatch(list[i].Name, "generic|generisk|pnp|^$", RegexOptions.IgnoreCase) && friendly[i].Length > 0) list[i].Name = friendly[i];
            }
            catch { }
            return list;
        }

        static int? RamRated(string pn)
        {
            pn = (pn ?? "").Trim().ToUpperInvariant();
            int? v = null; Match m;
            if ((m = Regex.Match(pn, @"F[45]-(\d{4})[A-Z]")).Success) v = int.Parse(m.Groups[1].Value);          // G.Skill
            else if ((m = Regex.Match(pn, @"^KF\d(\d{2})C\d")).Success) v = int.Parse(m.Groups[1].Value) * 100;   // Kingston Fury
            else if ((m = Regex.Match(pn, @"^C[TP]\d+G(\d{2})C\d")).Success) v = int.Parse(m.Groups[1].Value) * 100;  // Crucial
            else if ((m = Regex.Match(pn, @"(\d{4})H?C\d{2}")).Success) v = int.Parse(m.Groups[1].Value);         // Corsair/TeamGroup
            if (v < 1600 || v > 9600) v = null;
            return v;
        }

        static string Age(int? days)
        {
            if (days == null) return "ukendt";
            if (days < 31) return days + " dage";
            if (days < 365) return Math.Round(days.Value / 30.4) + " mdr.";
            return (days.Value / 365.0).ToString("0.#") + " år";
        }

        public static List<TweakCard> Check()
        {
            var cards = new List<TweakCard>();

            // ---- RAM ----
            try
            {
                var mods = Wmi.Query(@"root\cimv2", "SELECT ConfiguredClockSpeed, Speed, PartNumber, SMBIOSMemoryType FROM Win32_PhysicalMemory");
                int cfg = mods.Select(m => Convert.ToInt32(Wmi.Prop(m, "ConfiguredClockSpeed") ?? 0)).DefaultIfEmpty(0).Max();
                int spd = mods.Select(m => Convert.ToInt32(Wmi.Prop(m, "Speed") ?? 0)).DefaultIfEmpty(0).Max();
                string pn = mods.Count > 0 ? (Convert.ToString(Wmi.Prop(mods[0], "PartNumber")) ?? "").Trim() : "";
                int t = mods.Count > 0 ? Convert.ToInt32(Wmi.Prop(mods[0], "SMBIOSMemoryType") ?? 0) : 0;
                string type = t == 26 ? "DDR4" : t == 34 ? "DDR5" : "";
                int rated = RamRated(pn) ?? 0; if (rated < spd) rated = spd;
                string board = Convert.ToString(Wmi.Prop(Wmi.First(@"root\cimv2", "SELECT Manufacturer FROM Win32_BaseBoard"), "Manufacturer")) ?? "";
                bool amd = (Convert.ToString(Wmi.Prop(Wmi.First(@"root\cimv2", "SELECT Manufacturer FROM Win32_Processor"), "Manufacturer")) ?? "").IndexOf("AMD", StringComparison.OrdinalIgnoreCase) >= 0;
                string prof = amd && type == "DDR5" ? "EXPO" : "XMP";
                var c = new TweakCard { Icon = "🧠", Title = "Hukommelse (RAM)" };
                if (cfg <= 0) { c.State = "info"; c.Badge = "Kunne ikke måles"; c.Text = "Windows oplyser ikke RAM-hastigheden på denne pc, så den kan ikke vurderes."; }
                else
                {
                    c.Now = cfg + " MT/s i brug";
                    bool gain = rated > cfg + 150;
                    if (gain)
                    {
                        c.State = "tip"; c.Badge = "💡 Mulig forbedring · avanceret"; c.Can = rated + " MT/s mærket";
                        c.Text = "Din " + type + " RAM kører med " + cfg + " MT/s. Ud fra modelnummeret (" + pn + ") er modulet mærket " + rated + " MT/s. Den hastighed får man normalt ved at slå " + prof + " til i BIOS.\n\n" + prof + " er en profil, som RAM-producenten har testet, men teknisk set er det overclocking. Om det kører stabilt, afhænger af bundkort og processor. Hvor meget hurtigere spil bliver, varierer fra spil til spil.";
                        string bios = Regex.IsMatch(board, "gigabyte", RegexOptions.IgnoreCase) ? "I GIGABYTE-BIOS: Tweaker (eller Easy Mode) → Extreme Memory Profile (X.M.P.) → Profile 1."
                            : Regex.IsMatch(board, "asus", RegexOptions.IgnoreCase) ? "I ASUS-BIOS: Ai Tweaker (tryk F7 for Advanced) → Ai Overclock Tuner → " + prof + " I."
                            : Regex.IsMatch(board, "micro-star|msi", RegexOptions.IgnoreCase) ? "I MSI-BIOS: øverst til venstre er en " + prof + "-knap. Slå den til (Profile 1)."
                            : Regex.IsMatch(board, "asrock", RegexOptions.IgnoreCase) ? "I ASRock-BIOS: OC Tweaker → DRAM Configuration → Load " + prof + " Setting → Profile 1."
                            : "Find indstillingen " + prof + " (eller \"Memory Profile\") i BIOS, og vælg Profile 1.";
                        c.Steps = "Gør det kun, hvis du er tryg ved at ændre i BIOS.\n1.  Tryk \"Genstart til BIOS\" (eller genstart, og tryk gentagne gange på Del, mens pc'en starter).\n2.  " + bios + "\n3.  Tryk F10 for at gemme og genstarte.\n4.  Åbn Opticon igen, og tryk \"Tjek igen\". Nu bør der stå " + rated + " MT/s.\nStarter pc'en ikke bagefter, venter den typisk lidt og nulstiller selv. Ellers så slå " + prof + " fra igen.";
                        c.Action = "🔁  Genstart til BIOS"; c.ActionId = "bios";
                    }
                    else { c.State = "good"; c.Badge = "✓ Alt godt"; c.Text = "Din " + type + " RAM kører med sin fulde hastighed (" + cfg + " MT/s, " + mods.Count + (mods.Count == 1 ? " modul" : " moduler") + ")."; }
                    if (mods.Count == 1) c.Text += "\n\n💡 Du har kun ét RAM-modul. Med to moduler (dual channel) får processoren næsten dobbelt så hurtig adgang til hukommelsen. Det kan mærkes i spil.";
                }
                cards.Add(c);
            }
            catch (Exception e) { App.Log("Optimering RAM: " + e.Message); }

            // ---- Skærme ----
            try
            {
                var sc = Screens();
                var c = new TweakCard { Icon = "🖥", Title = "Skærmens opdateringshastighed", Action = "🖥  Åbn skærmindstillinger", ActionId = "display" };
                if (sc.Count == 0) { c.State = "info"; c.Badge = "Kunne ikke læses"; c.Text = "Kunne ikke læse skærmens indstillinger."; }
                else
                {
                    var low = sc.Where(s => s.Max > s.Cur + 1).ToList();
                    var first = low.Count > 0 ? low[0] : sc[0];
                    c.Now = first.Cur + " Hz nu";
                    var lines = string.Join("\n", sc.Select(s => "•  " + s.Name + ": " + s.W + "×" + s.H + " på " + s.Cur + " Hz" + (s.Max > s.Cur + 1 ? "  →  kan køre " + s.Max + " Hz" : "  ✓")));
                    if (low.Count > 0)
                    {
                        c.State = "tip"; c.Badge = "💡 Gratis ydelse"; c.Can = first.Max + " Hz muligt";
                        c.Text = "Din skærm kan vise " + first.Max + " billeder i sekundet, men Windows bruger kun " + first.Cur + ". Alt føles mere flydende ved fuld hastighed, også musen og scrolling.\n\n" + lines;
                        c.Steps = "1.  Tryk \"Åbn skærmindstillinger\".\n2.  Vælg skærmen øverst (hvis du har flere), og tryk \"Avanceret skærm\".\n3.  Under \"Vælg en opdateringshastighed\" vælger du " + first.Max + " Hz.\n4.  Tryk \"Behold ændringer\".\nTip: brug DisplayPort til skærme over 144 Hz. Gamle HDMI-kabler kan begrænse hastigheden.";
                    }
                    else { c.State = "good"; c.Badge = "✓ Alt godt"; c.Text = "Dine skærme kører allerede med den højeste hastighed, de kan.\n\n" + lines; }
                }
                cards.Add(c);
            }
            catch (Exception e) { App.Log("Optimering skærm: " + e.Message); }

            // ---- Driver og BIOS ----
            try
            {
                var g = Wmi.Query(@"root\cimv2", "SELECT Name, DriverDate, DriverVersion FROM Win32_VideoController")
                    .FirstOrDefault(v => !Regex.IsMatch(Convert.ToString(Wmi.Prop(v, "Name")) ?? "", "basic|virtual|remote|parsec|meta|mirage", RegexOptions.IgnoreCase));
                var bios = Wmi.First(@"root\cimv2", "SELECT SMBIOSBIOSVersion, ReleaseDate FROM Win32_BIOS");
                var mb = Wmi.First(@"root\cimv2", "SELECT Manufacturer, Product FROM Win32_BaseBoard");
                Func<object, DateTime?> dt = o => { try { return o == null ? (DateTime?)null : ManagementDateTimeConverter.ToDateTime(o.ToString()); } catch { return null; } };
                string gpu = Convert.ToString(Wmi.Prop(g, "Name")) ?? "";
                var dd = dt(Wmi.Prop(g, "DriverDate")); var bd = dt(Wmi.Prop(bios, "ReleaseDate"));
                int? drvDays = dd.HasValue ? (int)(DateTime.Now - dd.Value).TotalDays : (int?)null, biosDays = bd.HasValue ? (int)(DateTime.Now - bd.Value).TotalDays : (int?)null;
                string ver = Convert.ToString(Wmi.Prop(g, "DriverVersion")) ?? "";
                var nv = Regex.Match(ver, @"\d+\.\d+\.\d(\d)\.(\d{2})(\d{2})$");
                if (gpu.IndexOf("nvidia", StringComparison.OrdinalIgnoreCase) >= 0 && nv.Success) ver = nv.Groups[1].Value + nv.Groups[2].Value + "." + nv.Groups[3].Value;
                string board = ((Convert.ToString(Wmi.Prop(mb, "Manufacturer")) ?? "") + " " + (Convert.ToString(Wmi.Prop(mb, "Product")) ?? "")).Trim();
                string biosVer = Convert.ToString(Wmi.Prop(bios, "SMBIOSBIOSVersion")) ?? "";
                bool oldDrv = drvDays > 120, oldBios = biosDays > 730;
                var c = new TweakCard { Icon = "🔧", Title = "Drivere og BIOS", Now = "Driver " + ver, Can = "BIOS " + biosVer };
                c.Text = "Grafikdriver til " + gpu + ": version " + ver + " fra " + (dd.HasValue ? dd.Value.ToString("dd-MM-yyyy") : "?") + " (" + Age(drvDays) + " gammel).\n\nBIOS på " + board + ": " + biosVer + " fra " + (bd.HasValue ? bd.Value.ToString("dd-MM-yyyy") : "?") + " (" + Age(biosDays) + " gammel).\n\nDatoen alene siger ikke, om der findes en relevant opdatering. Det kan kun producenten svare på.";
                if (oldDrv) { c.State = "tip"; c.Badge = "💡 Grafikdriveren er over 4 måneder gammel"; c.Text += " Nye grafikdrivere giver ofte flere FPS i nye spil og retter fejl."; }
                else if (oldBios) { c.State = "info"; c.Badge = "BIOS er over 2 år gammel"; c.Text += " En BIOS-opdatering kan rette sikkerhedshuller og stabilitet, men er ikke noget, man behøver for ydelsens skyld."; }
                else { c.State = "good"; c.Badge = "✓ Ser opdateret ud"; }
                c.Steps = "Grafikdriver: tryk \"Opdatér grafikdriver\". Det åbner NVIDIA App / AMD Software / Snapdragon Control Panel (eller Windows Update).\nBIOS (kun hvis du vil): tryk \"Find BIOS-opdatering\", og følg producentens vejledning. Sluk ALDRIG pc'en under en BIOS-opdatering. Bagefter skal XMP/EXPO ofte slås til igen.";
                c.Action = "⬇  Opdatér grafikdriver"; c.ActionId = "gpudriver:" + gpu;
                c.Action2 = "🔎  Find BIOS-opdatering"; c.Action2Id = "biossearch:" + board;
                cards.Add(c);
            }
            catch (Exception e) { App.Log("Optimering driver: " + e.Message); }
            TweaksMore.Add(cards);
            return cards;
        }
    }
}
