using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Opticon.Services
{
    /// <summary>Spørger grafikdriveren direkte, om hardware-accelereret GPU-planlægning er slået til (samme kilde som Windows' egen indstilling).</summary>
    public static class Hags
    {
        [StructLayout(LayoutKind.Sequential)] struct AdapterInfo { public uint hAdapter; public uint LuidLow; public int LuidHigh; public uint NumOfSources; public int Precise; }
        [StructLayout(LayoutKind.Sequential)] struct EnumAdapters2 { public uint NumAdapters; public IntPtr pAdapters; }
        [StructLayout(LayoutKind.Sequential)] struct QueryInfo { public uint hAdapter; public int Type; public IntPtr pData; public uint DataSize; }
        [StructLayout(LayoutKind.Sequential)] struct CloseAdapter { public uint hAdapter; }
        [DllImport("gdi32.dll")] static extern int D3DKMTEnumAdapters2(ref EnumAdapters2 e);
        [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref QueryInfo q);
        [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref CloseAdapter c);

        /// <summary>-1 = ukendt, 0 = understøttes ikke, 1 = understøttet men slået fra, 2 = slået til</summary>
        public static int State()
        {
            int best = -1;
            var e = new EnumAdapters2();
            if (D3DKMTEnumAdapters2(ref e) != 0 || e.NumAdapters == 0) return -1;
            int sz = Marshal.SizeOf(typeof(AdapterInfo));
            IntPtr buf = Marshal.AllocHGlobal(sz * (int)e.NumAdapters);
            IntPtr caps = Marshal.AllocHGlobal(4);
            try
            {
                e.pAdapters = buf;
                if (D3DKMTEnumAdapters2(ref e) != 0) return -1;
                for (int i = 0; i < e.NumAdapters; i++)
                {
                    var a = (AdapterInfo)Marshal.PtrToStructure(new IntPtr(buf.ToInt64() + i * sz), typeof(AdapterInfo));
                    Marshal.WriteInt32(caps, 0);
                    var q = new QueryInfo { hAdapter = a.hAdapter, Type = 70, pData = caps, DataSize = 4 };   // 70 = WDDM 2.7-egenskaber
                    if (D3DKMTQueryAdapterInfo(ref q) == 0)
                    {
                        int v = Marshal.ReadInt32(caps);
                        int st = (v & 1) == 0 ? 0 : ((v & 2) != 0 ? 2 : 1);
                        if (st > best) best = st;
                    }
                    var c = new CloseAdapter { hAdapter = a.hAdapter }; D3DKMTCloseAdapter(ref c);
                }
            }
            finally { Marshal.FreeHGlobal(buf); Marshal.FreeHGlobal(caps); }
            return best;
        }
    }

    public static class PowerMode
    {
        [DllImport("powrprof.dll")] static extern uint PowerGetEffectiveOverlayScheme(out Guid g);
        public static readonly Dictionary<string, string> Names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "961cc777-2547-4f9d-8174-7d86181b8a7a", "Bedste energieffektivitet" },
            { "00000000-0000-0000-0000-000000000000", "Balanceret" },
            { "3af9b8d9-7c97-431d-ad78-34a8bfea439f", "Bedre ydeevne" },
            { "ded574b5-45a0-4f42-8737-46345c09c238", "Bedste ydeevne" },
        };

        [StructLayout(LayoutKind.Sequential)] struct SYSTEM_POWER_STATUS { public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag; public int BatteryLifeTime, BatteryFullLifeTime; }
        [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS s);
        public static bool OnBattery() { SYSTEM_POWER_STATUS s; return GetSystemPowerStatus(out s) && s.ACLineStatus == 0; }

        /// <summary>Kun læsning (det er skift af strømtilstand, der gav problemer på Snapdragon).</summary>
        public static string Current()
        {
            try { Guid g; if (PowerGetEffectiveOverlayScheme(out g) == 0) return g.ToString(); } catch { }
            return null;
        }

        /// <summary>
        /// Skifter strømtilstand med Windows' eget powercfg i en separat proces (det direkte Windows-kald fik
        /// den gamle app til at gå ned på en Snapdragon-pc). Returnerer true, hvis skiftet blev bekræftet.
        /// </summary>
        public static bool Set(string guid)
        {
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo(System.IO.Path.Combine(Environment.SystemDirectory, "powercfg.exe"), "/overlaysetactive " + guid) { UseShellExecute = false, CreateNoWindow = true };
                using (var p = System.Diagnostics.Process.Start(psi)) { if (!p.WaitForExit(6000)) { try { p.Kill(); } catch { } } }
                for (int i = 0; i < 6; i++) { System.Threading.Thread.Sleep(200); if (string.Equals(Current(), guid, StringComparison.OrdinalIgnoreCase)) return true; }
            }
            catch (Exception e) { App.Log("Skift strømtilstand: " + e.Message); }
            return false;
        }

        /// <summary>Strømforbrug lige nu i watt: batteriets afladning (bærbar uden oplader) eller NVIDIA-kortets forbrug. Null, hvis det ikke kan måles.</summary>
        public static double? Watts(bool battery)
        {
            try
            {
                if (battery)
                {
                    var b = Wmi.First(@"root\wmi", "SELECT DischargeRate, PowerOnline FROM BatteryStatus");
                    if (b != null && !Convert.ToBoolean(Wmi.Prop(b, "PowerOnline") ?? true)) { var mw = Convert.ToDouble(Wmi.Prop(b, "DischargeRate") ?? 0); if (mw > 0) return Math.Round(mw / 1000, 1); }
                    return null;
                }
                var smi = System.IO.Path.Combine(Environment.SystemDirectory, "nvidia-smi.exe");
                if (!System.IO.File.Exists(smi)) return null;
                var psi = new System.Diagnostics.ProcessStartInfo(smi, "--query-gpu=power.draw --format=csv,noheader,nounits") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
                using (var p = System.Diagnostics.Process.Start(psi))
                {
                    var o = p.StandardOutput.ReadToEnd();
                    if (!p.WaitForExit(3000)) { try { p.Kill(); } catch { } return null; }
                    double w; if (double.TryParse(o.Split('\n')[0].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out w)) return Math.Round(w, 1);
                }
            }
            catch { }
            return null;
        }

        public static string Name(string g)
        {
            string n; return g != null && Names.TryGetValue(g, out n) ? n : "Ukendt";
        }
    }

    public static class GameSettings
    {
        const string HKCU = "HKEY_CURRENT_USER\\";

        public static List<SecItem> Check()
        {
            var r = new List<SecItem>();
            // Spiltilstand (mangler værdien, er den til)
            var gm = Wmi.RegInt(HKCU + @"Software\Microsoft\GameBar", "AutoGameModeEnabled");
            r.Add(gm == 0
                ? new SecItem { Id = "gamemode", Level = 1, Name = "Spiltilstand", Value = "Fra", Note = "Spiltilstand giver spillet forrang og udskyder Windows Update-genstarter, mens du spiller.", How = "Opticon kan slå den til.", Fix = "gamemode", Uri = "ms-settings:gaming-gamemode" }
                : new SecItem { Id = "gamemode", Level = 2, Name = "Spiltilstand", Value = "Til", Note = "Windows giver spil forrang" });

            // Baggrundsoptagelse
            var dvr = Wmi.RegInt(HKCU + @"System\GameConfigStore", "GameDVR_Enabled");
            var cap = Wmi.RegInt(HKCU + @"Software\Microsoft\Windows\CurrentVersion\GameDVR", "AppCaptureEnabled");
            var hist = Wmi.RegInt(HKCU + @"Software\Microsoft\Windows\CurrentVersion\GameDVR", "HistoricalCaptureEnabled");
            bool recording = hist == 1 && cap != 0 && dvr != 0;
            r.Add(recording
                ? new SecItem { Id = "dvr", Level = 1, Name = "Optag i baggrunden", Value = "Til", Note = "Windows optager hele tiden de sidste minutter af dit spil. Det koster lidt FPS og skriver til disken.", How = "Opticon kan slå baggrundsoptagelsen fra. Du kan stadig optage med Win+Alt+R.", Fix = "dvr", Uri = "ms-settings:gaming-gamedvr" }
                : new SecItem { Id = "dvr", Level = 2, Name = "Optag i baggrunden", Value = "Fra", Note = "Windows optager ikke dit spil i baggrunden" });

            // Hardware-accelereret GPU-planlægning
            int hs = -1; try { hs = Hags.State(); } catch (Exception e) { App.Log("GPU-planlægning: " + e.Message); }
            var reg = Wmi.RegInt(@"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\GraphicsDrivers", "HwSchMode");
            const string tip = "Indstillinger → System → Skærm → Grafik → Hardware-accelereret GPU-planlægning (kræver genstart).";
            string uri = "ms-settings:display-advancedgraphics";
            SecItem h;
            if (hs == 2) h = reg == 1 ? new SecItem { Level = 3, Value = "Til (slås fra ved genstart)", Note = "Du har slået den fra. Det sker, når pc'en genstarter" } : new SecItem { Level = 2, Value = "Til", Note = "Lavere latens i spil, der kan bruge det" };
            else if (hs == 1) h = reg == 2 ? new SecItem { Level = 3, Value = "Til efter genstart", Note = "Den er slået til, men virker først, når pc'en har været genstartet" } : new SecItem { Level = 1, Value = "Fra", Note = "Giver lavere latens i nogle spil og er nødvendig for DLSS Frame Generation.", How = tip, Uri = uri };
            else if (hs == 0) h = new SecItem { Level = 3, Value = "Understøttes ikke", Note = "Grafikkortet eller driveren kan ikke bruge funktionen. Det er helt fint" };
            else h = reg == 2 ? new SecItem { Level = 2, Value = "Til", Note = "Lavere latens i spil, der kan bruge det" } : new SecItem { Level = 3, Value = "Ukendt", Note = "Se status i Windows' indstillinger", How = tip, Uri = uri };
            h.Id = "hags"; h.Name = "Hardware-accelereret GPU-planlægning";
            r.Add(h);

            // Strømtilstand
            var pm = PowerMode.Current();
            bool battery = false;
            try { battery = PowerMode.OnBattery(); } catch { }
            if (pm == null) r.Add(new SecItem { Id = "power", Level = 3, Name = "Strømtilstand", Value = "Ukendt", Note = "Kunne ikke læses", Uri = "ms-settings:powersleep" });
            else if (pm.StartsWith("961cc777", StringComparison.OrdinalIgnoreCase)) r.Add(new SecItem { Id = "power", Level = 1, Name = "Strømtilstand", Value = PowerMode.Name(pm), Note = "Sparer strøm, men gør spil langsommere.", How = "Indstillinger → System → Strøm og batteri → Strømtilstand → Balanceret eller Bedste ydeevne" + (battery ? ", helst med opladeren i." : "."), Uri = "ms-settings:powersleep" });
            else r.Add(new SecItem { Id = "power", Level = 2, Name = "Strømtilstand", Value = PowerMode.Name(pm), Note = battery ? "Kører på batteri: spil er hurtigst med opladeren i" : "Fint til spil" });
            return r;
        }

        public static string Fix(string id)
        {
            switch (id)
            {
                case "gamemode":
                    using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\GameBar", true)) k.SetValue("AutoGameModeEnabled", 1, RegistryValueKind.DWord);
                    return "Spiltilstand er slået til.";
                case "dvr":
                    using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\GameDVR", true)) k.SetValue("HistoricalCaptureEnabled", 0, RegistryValueKind.DWord);
                    return "Baggrundsoptagelse er slået fra.";
                default: throw new Exception("Ukendt rettelse: " + id);
            }
        }
    }
}
