using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;

namespace Opticon.Services
{
    /// <summary>Ét punkt i sikkerhedstjekket. Level: 0 = vigtigt, 1 = forslag, 2 = i orden, 3 = info.</summary>
    public class SecItem
    {
        public string Id { get; set; }
        public int Level { get; set; }
        public string Name { get; set; }
        public string Value { get; set; }
        public string Note { get; set; }
        public string How { get; set; }
        public string Fix { get; set; }
        public string Uri { get; set; }

        public string Dot { get { return Level == 0 ? "🔴" : Level == 1 ? "🟡" : Level == 2 ? "🟢" : "ℹ"; } }
        public System.Windows.Media.Brush DotBrush { get { return DotBrushes.For(Level == 0 ? "#F05252" : Level == 1 ? "#F5B83D" : Level == 2 ? "#4ADE80" : "#6B8AFD"); } }
        public Visibility HowVis { get { return string.IsNullOrEmpty(How) || Level == 2 ? Visibility.Collapsed : Visibility.Visible; } }
        public Visibility FixVis { get { return string.IsNullOrEmpty(Fix) || Level == 2 ? Visibility.Collapsed : Visibility.Visible; } }
        public Visibility UriVis { get { return string.IsNullOrEmpty(Uri) || Level == 2 ? Visibility.Collapsed : Visibility.Visible; } }
        public int Sort { get { return Level == 0 ? 0 : Level == 1 ? 1 : Level == 3 ? 2 : 3; } }
    }

    public static class DotBrushes
    {
        static readonly Dictionary<string, System.Windows.Media.SolidColorBrush> cache = new Dictionary<string, System.Windows.Media.SolidColorBrush>();
        public static System.Windows.Media.Brush For(string hex)
        {
            lock (cache)
            {
                System.Windows.Media.SolidColorBrush b;
                if (!cache.TryGetValue(hex, out b)) { b = new System.Windows.Media.SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex)); b.Freeze(); cache[hex] = b; }
                return b;
            }
        }
    }

    public class SecResult
    {
        public List<SecItem> Items = new List<SecItem>();
        public bool Elevated;
        public bool Laptop;
    }

    public static class SecurityCheck
    {
        const string Def = @"root\Microsoft\Windows\Defender";
        const string HKLM = "HKEY_LOCAL_MACHINE\\";
        public static readonly string[] AsrStandard = { "56a863a9-875e-4185-98a7-b882c64b5ce5", "9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2", "e6db77e5-3df2-4cf1-b95a-636979351e5b" };

        static void Add(SecResult r, string id, int lvl, string name, string val, string note, string how = "", string fix = "", string uri = "")
        {
            r.Items.Add(new SecItem { Id = id, Level = lvl, Name = name, Value = val, Note = note, How = how, Fix = fix, Uri = uri });
        }

        static void Safe(string what, Action a)
        {
            try { a(); } catch (Exception e) { App.Log("Sikkerhedstjek " + what + ": " + e.Message); }
        }

        public static SecResult Run()
        {
            var r = new SecResult { Elevated = Admin.IsElevated };
            const string CV = HKLM + @"SOFTWARE\Microsoft\Windows NT\CurrentVersion";
            int build = 0; int.TryParse(Wmi.RegStr(CV, "CurrentBuild") ?? "0", out build);
            string disp = Wmi.RegStr(CV, "DisplayVersion") ?? "";
            string ed = Wmi.RegStr(CV, "EditionID") ?? "";
            Safe("pc-type", () => { var cs = Wmi.First(@"root\cimv2", "SELECT PCSystemType FROM Win32_ComputerSystem"); r.Laptop = cs != null && Convert.ToInt32(Wmi.Prop(cs, "PCSystemType")) == 2; });
            string needAdmin = "Kræver administrator";
            string adminHow = "Tryk på \"Tjek som administrator\" øverst for at se det.";

            // 1. Windows-version
            Safe("winver", () =>
            {
                bool special = System.Text.RegularExpressions.Regex.IsMatch(ed, "Enterprise|Education|IoT|Server");
                if (build > 0 && build < 22000)
                    Add(r, "winver", 0, "Windows-version", "Windows 10 " + disp, "Windows 10 fik sin sidste almindelige sikkerhedsopdatering i oktober 2025. Nye huller bliver kun lukket, hvis pc'en er tilmeldt ESU.", "Opgradér til Windows 11, hvis pc'en kan. Ellers: Windows Update → tilmeld \"Udvidede sikkerhedsopdateringer\" (ESU).", "", "ms-settings:windowsupdate");
                else if (build > 0 && build < 26200 && !special)
                    Add(r, "winver", 0, "Windows-version", "Windows 11 " + disp, "Version " + disp + " af Home/Pro får ikke længere sikkerhedsopdateringer.", "Windows Update → installér den nyeste version af Windows 11 (25H2 eller nyere). Det er gratis og beholder dine filer og programmer.", "", "ms-settings:windowsupdate");
                else
                    Add(r, "winver", 2, "Windows-version", (build >= 22000 ? "Windows 11 " : "Windows ") + disp, "Får stadig sikkerhedsopdateringer");
            });

            // 2. Windows Update på pause?
            Safe("wupause", () =>
            {
                var pz = Wmi.RegStr(HKLM + @"SOFTWARE\Microsoft\WindowsUpdate\UX\Settings", "PauseUpdatesExpiryTime");
                DateTime pd;
                if (!string.IsNullOrEmpty(pz) && DateTime.TryParse(pz, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out pd) && pd.ToLocalTime() > DateTime.Now)
                    Add(r, "wupause", 1, "Windows Update", "På pause til " + pd.ToLocalTime().ToString("d. MMM", new CultureInfo("da-DK")), "Mens opdateringer er sat på pause, bliver nye sikkerhedshuller ikke lukket.", "Windows Update → \"Genoptag opdateringer\".", "", "ms-settings:windowsupdate");
                else
                    Add(r, "wupause", 2, "Windows Update", "Kører", "Ikke sat på pause");
            });

            // 3. Antivirus og Defender
            bool defActive = true;
            Safe("defender", () =>
            {
                var st = Wmi.First(Def, "SELECT RealTimeProtectionEnabled, AntivirusSignatureAge, IsTamperProtected FROM MSFT_MpComputerStatus");
                var others = Wmi.Query(@"root\SecurityCenter2", "SELECT displayName, productState FROM AntiVirusProduct")
                    .Where(p => { var n = Convert.ToString(Wmi.Prop(p, "displayName")) ?? ""; int s = Convert.ToInt32(Wmi.Prop(p, "productState") ?? 0); return n.IndexOf("Defender", StringComparison.OrdinalIgnoreCase) < 0 && ((s >> 12) & 0xF) == 1; })
                    .Select(p => Convert.ToString(Wmi.Prop(p, "displayName"))).ToList();
                bool rtp = st != null && Convert.ToBoolean(Wmi.Prop(st, "RealTimeProtectionEnabled") ?? false);
                if (others.Count > 0 && !rtp) { defActive = false; Add(r, "av", 2, "Antivirus", others[0], "Et andet antivirusprogram passer på pc'en"); }
                else if (st == null) { defActive = false; Add(r, "av", 3, "Antivirus", "Kunne ikke læses", "Windows svarede ikke på, hvilken beskyttelse der kører.", "", "", "windowsdefender://threat"); }
                else if (!rtp) Add(r, "av", 0, "Antivirus", "Realtidsbeskyttelse er FRA", "Pc'en er ubeskyttet mod nye virus. Malware slår den ofte selv fra.", "Windows Sikkerhed → Virus- og trusselsbeskyttelse → slå Realtidsbeskyttelse til. Kør derefter en fuld scanning.", "", "windowsdefender://threatsettings");
                else
                {
                    int age = Convert.ToInt32(Wmi.Prop(st, "AntivirusSignatureAge") ?? 0);
                    if (age > 3) Add(r, "av", 1, "Antivirus", "Defender · virusdefinitioner " + age + " dage gamle", "Defender kender ikke de nyeste virus.", "Opticon kan hente de nyeste definitioner nu.", "sigs", "windowsdefender://threat");
                    else Add(r, "av", 2, "Antivirus", "Microsoft Defender · opdateret", "Realtidsbeskyttelse er til");
                }
                if (!defActive || st == null) return;
                if (Convert.ToBoolean(Wmi.Prop(st, "IsTamperProtected") ?? false)) Add(r, "tamper", 2, "Manipulationsbeskyttelse", "Til", "Programmer kan ikke slå Defender fra bag din ryg");
                else Add(r, "tamper", 1, "Manipulationsbeskyttelse", "Fra", "Uden den kan malware slå Defender fra.", "Windows Sikkerhed → Virus- og trusselsbeskyttelse → Administrer indstillinger → Manipulationsbeskyttelse: Til. (Kun du selv kan slå den til, så malware ikke kan gøre det.)", "", "windowsdefender://threatsettings");

                var mp = Wmi.First(Def, "SELECT PUAProtection, AttackSurfaceReductionRules_Ids, AttackSurfaceReductionRules_Actions FROM MSFT_MpPreference");
                int pua = Convert.ToInt32(Wmi.Prop(mp, "PUAProtection") ?? 0);
                if (pua == 1) Add(r, "pua", 2, "Bloker uønskede programmer", "Til", "Stopper adware og skjulte cryptominere i installere");
                else Add(r, "pua", 1, "Bloker uønskede programmer", "Fra", "Gratis programmer har ofte adware, værktøjslinjer eller cryptominere med i installeren. Defender kan stoppe dem.", "Opticon kan slå det til for dig. Det ændrer ikke dine programmer.", "pua", "windowsdefender://appbrowser");

                var ids = (Wmi.Prop(mp, "AttackSurfaceReductionRules_Ids") as string[]) ?? new string[0];
                var acts = (Wmi.Prop(mp, "AttackSurfaceReductionRules_Actions") as byte[]) ?? new byte[0];
                bool hidden = ids.Length == 1 && ids[0].StartsWith("N/A", StringComparison.OrdinalIgnoreCase);
                if (!r.Elevated && (ids.Length == 0 || hidden))
                {
                    Add(r, "asr", 3, "Ekstra Defender-regler (ASR)", needAdmin, "Windows viser kun disse regler til en administrator.", adminHow);
                    return;
                }
                int on = 0;
                foreach (var g in AsrStandard)
                {
                    int ix = Array.FindIndex(ids, x => string.Equals(x, g, StringComparison.OrdinalIgnoreCase));
                    if (ix >= 0 && ix < acts.Length && (acts[ix] == 1 || acts[ix] == 6)) on++;
                }
                if (on == AsrStandard.Length) Add(r, "asr", 2, "Ekstra Defender-regler (ASR)", "Til (3 af 3)", "Stopper misbrug af sårbare drivere, tyveri af adgangskoder fra hukommelsen og skjult autostart via WMI");
                else Add(r, "asr", 1, "Ekstra Defender-regler (ASR)", on + " af 3 slået til", "Tre regler, som Microsoft anbefaler alle at slå til: de stopper misbrug af sårbare drivere, tyveri af adgangskoder fra hukommelsen og skjult autostart via WMI. De mærkes normalt ikke i hverdagen.", "Opticon kan slå de tre regler til. Et meget gammelt RGB-, blæser- eller overclock-værktøj kan blive blokeret, indtil du opdaterer det. Bliver noget blokeret, viser Windows Sikkerhed en besked om det.", "asr");
            });

            // 4. Firewall
            Safe("firewall", () =>
            {
                var names = new[] { new[] { "DomainProfile", "DomainProfile", "domæne" }, new[] { "StandardProfile", "PrivateProfile", "privat" }, new[] { "PublicProfile", "PublicProfile", "offentlig" } };
                var off = new List<string>();
                foreach (var n in names)
                {
                    int? pol = Wmi.RegInt(HKLM + @"SOFTWARE\Policies\Microsoft\WindowsFirewall\" + n[1], "EnableFirewall");
                    int? loc = Wmi.RegInt(HKLM + @"SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\" + n[0], "EnableFirewall");
                    int v = pol ?? loc ?? 1;
                    if (v == 0) off.Add(n[2]);
                }
                var fwOther = Wmi.Query(@"root\SecurityCenter2", "SELECT displayName, productState FROM FirewallProduct")
                    .Where(p => ((Convert.ToInt32(Wmi.Prop(p, "productState") ?? 0) >> 12) & 0xF) == 1).Select(p => Convert.ToString(Wmi.Prop(p, "displayName"))).ToList();
                if (off.Count == 0) Add(r, "fw", 2, "Firewall", "Til på alle netværk", "Blokerer ubudne forbindelser udefra");
                else if (fwOther.Count > 0) Add(r, "fw", 2, "Firewall", fwOther[0], "Et andet program styrer firewallen");
                else Add(r, "fw", 0, "Firewall", "Fra på " + string.Join(", ", off) + " netværk", "Andre på samme netværk (fx på en café eller skole) kan nå tjenester på din pc.", "Opticon kan slå Windows Firewall til igen på alle netværk.", "fw", "windowsdefender://network");
            });

            // 5. SmartScreen
            Safe("smartscreen", () =>
            {
                var ss = Wmi.RegStr(HKLM + @"SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer", "SmartScreenEnabled");
                var pol = Wmi.RegInt(HKLM + @"SOFTWARE\Policies\Microsoft\Windows\System", "EnableSmartScreen");
                if (string.Equals(ss, "Off", StringComparison.OrdinalIgnoreCase) || pol == 0)
                    Add(r, "smartscreen", 1, "SmartScreen", "Fra", "SmartScreen advarer, før du åbner kendte falske installere og phishing-sider.", "Windows Sikkerhed → App- og browserkontrol → Omdømmebaseret beskyttelse → slå det hele til.", "", "windowsdefender://appbrowser");
                else Add(r, "smartscreen", 2, "SmartScreen", "Til", "Advarer mod kendte falske programmer og sider");
            });

            // 6. Brugerkontokontrol
            Safe("uac", () =>
            {
                const string K = HKLM + @"SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System";
                var lua = Wmi.RegInt(K, "EnableLUA"); var cp = Wmi.RegInt(K, "ConsentPromptBehaviorAdmin"); var sd = Wmi.RegInt(K, "PromptOnSecureDesktop");
                if (lua == 0) Add(r, "uac", 0, "Brugerkontokontrol (UAC)", "Slået helt fra", "Alle programmer får fuld adgang til pc'en uden at spørge. Det gør det meget let for malware.", "Opticon kan slå den til igen. Kræver genstart.", "uac");
                else if (cp == 0 || sd == 0) Add(r, "uac", 1, "Brugerkontokontrol (UAC)", "Til, men spørger ikke ordentligt", "Programmer kan få administrator-rettigheder uden at du bliver spurgt, eller uden den mørke sikre skærm.", "Opticon kan sætte den tilbage til Windows-standard.", "uac");
                else Add(r, "uac", 2, "Brugerkontokontrol (UAC)", "Til", "Programmer skal spørge, før de ændrer pc'en");
            });

            // 7. Hukommelsesintegritet
            bool hvciOn = false;
            Safe("hvci", () =>
            {
                var dg = Wmi.First(@"root\Microsoft\Windows\DeviceGuard", "SELECT SecurityServicesRunning FROM Win32_DeviceGuard");
                var running = Wmi.Prop(dg, "SecurityServicesRunning") as int[];
                if (running == null) { var u = Wmi.Prop(dg, "SecurityServicesRunning") as uint[]; if (u != null) running = u.Select(x => (int)x).ToArray(); }
                hvciOn = running != null && running.Contains(2);
                var reg = Wmi.RegInt(HKLM + @"SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity", "Enabled");
                if (hvciOn) Add(r, "hvci", 2, "Hukommelsesintegritet", "Til", "Forhindrer, at ondsindede drivere får adgang til Windows' kerne");
                else if (reg == 1) Add(r, "hvci", 1, "Hukommelsesintegritet", "Slået til, venter på genstart", "Træder i kraft efter næste genstart", "Genstart pc'en.", "", "windowsdefender://coreisolation");
                else Add(r, "hvci", 1, "Hukommelsesintegritet", "Fra", "Stopper drivere med kendte huller og malware i kernen. Koster typisk 0-5 % FPS i nogle spil.", "Windows Sikkerhed → Enhedssikkerhed → Kerneisolering → Hukommelsesintegritet: Til. Kræver genstart. Står der \"inkompatible drivere\", så opdatér eller fjern de programmer først.", "", "windowsdefender://coreisolation");
            });

            // 8. Blokér sårbare drivere
            Safe("blocklist", () =>
            {
                var bl = Wmi.RegInt(HKLM + @"SYSTEM\CurrentControlSet\Control\CI\Config", "VulnerableDriverBlocklistEnable");
                bool on = hvciOn || bl == 1 || (bl == null && build >= 22621);
                if (on) Add(r, "blocklist", 2, "Blokér sårbare drivere", "Til", "Windows nægter at indlæse drivere med kendte huller");
                else Add(r, "blocklist", 1, "Blokér sårbare drivere", "Fra", "Angribere bruger gamle drivere med kendte huller til at slå antivirus fra. Windows har en liste, den kan blokere.", "Opticon kan slå den til. Kræver genstart. Et meget gammelt RGB-, blæser- eller overclock-værktøj kan holde op med at virke, indtil du opdaterer det.", "blocklist", "windowsdefender://coreisolation");
            });

            // 9. Secure Boot
            Safe("secureboot", () =>
            {
                var sb = Wmi.RegInt(HKLM + @"SYSTEM\CurrentControlSet\Control\SecureBoot\State", "UEFISecureBootEnabled");
                if (sb == 1) Add(r, "secureboot", 2, "Secure Boot", "Til", "Stopper skadelig kode, der vil starte før Windows");
                else if (sb == 0) Add(r, "secureboot", 1, "Secure Boot", "Fra", "Uden Secure Boot kan \"bootkits\" starte før Windows og gemme sig for antivirus. Nogle spil med anti-cheat kræver det også.", "Slås til i BIOS/UEFI: genstart, tryk Del/F2, find Boot → Secure Boot → Enabled. Rør ikke ved andet, hvis du er i tvivl.");
                else Add(r, "secureboot", 3, "Secure Boot", "Ikke tilgængelig", "Pc'en starter i gammel BIOS-tilstand", "Kræver at Windows er installeret i UEFI-tilstand. Ikke noget, du skal ændre uden hjælp.");
            });

            // 10. TPM
            Safe("tpm", () =>
            {
                if (!r.Elevated) { Add(r, "tpm", 3, "TPM-sikkerhedschip", needAdmin, "Windows viser kun TPM-status til en administrator.", adminHow); return; }
                var t = Wmi.First(@"root\cimv2\Security\MicrosoftTpm", "SELECT IsEnabled_InitialValue, IsActivated_InitialValue, SpecVersion FROM Win32_Tpm");
                if (t == null) { Add(r, "tpm", 1, "TPM-sikkerhedschip", "Ikke fundet", "Uden TPM kan disken ikke krypteres automatisk", "Slå fTPM (AMD) eller PTT (Intel) til i BIOS/UEFI under Security eller Advanced."); return; }
                string tv = (Convert.ToString(Wmi.Prop(t, "SpecVersion")) ?? "").Split(',')[0].Trim();
                bool ready = Convert.ToBoolean(Wmi.Prop(t, "IsEnabled_InitialValue") ?? false) && Convert.ToBoolean(Wmi.Prop(t, "IsActivated_InitialValue") ?? false);
                if (ready) Add(r, "tpm", 2, "TPM-sikkerhedschip", "Klar" + (tv.Length > 0 ? " (version " + tv + ")" : ""), "Beskytter krypteringsnøgler og Windows Hello");
                else Add(r, "tpm", 1, "TPM-sikkerhedschip", "Fundet, men ikke klar", "Kryptering og Windows Hello virker ikke optimalt", "Åbn tpm.msc og vælg \"Forbered TPM\", eller nulstil den i BIOS.");
            });

            // 11. Diskkryptering
            Safe("crypt", () =>
            {
                if (!r.Elevated) { Add(r, "crypt", 3, "Diskkryptering (C:)", needAdmin, "Windows viser kun krypteringsstatus til en administrator.", adminHow); return; }
                var ev = Wmi.First(@"root\cimv2\Security\MicrosoftVolumeEncryption", "SELECT ProtectionStatus FROM Win32_EncryptableVolume WHERE DriveLetter='C:'");
                if (ev == null) { Add(r, "crypt", 3, "Diskkryptering (C:)", "Ikke tilgængelig", "Denne udgave af Windows har ikke kryptering"); return; }
                if (Convert.ToInt32(Wmi.Prop(ev, "ProtectionStatus") ?? 0) == 1) Add(r, "crypt", 2, "Diskkryptering (C:)", "Til", "Hvis pc'en bliver stjålet, kan ingen læse dine filer");
                else Add(r, "crypt", r.Laptop ? 1 : 3, "Diskkryptering (C:)", "Fra", r.Laptop ? "En stjålen bærbar kan læses af hvem som helst, også uden din adgangskode." : "Mindre vigtigt på en stationær, men beskytter dine filer ved tyveri.", "Indstillinger → Beskyttelse af personlige oplysninger og sikkerhed → Enhedskryptering (eller BitLocker på Pro). Gem gendannelsesnøglen på din Microsoft-konto.", "", "ms-settings:deviceencryption");
            });

            // 12. SMBv1
            Safe("smb1", () =>
            {
                var f = Wmi.First(@"root\cimv2", "SELECT InstallState FROM Win32_OptionalFeature WHERE Name='SMB1Protocol'");
                bool feat = f != null && Convert.ToInt32(Wmi.Prop(f, "InstallState") ?? 2) == 1;
                var srv = Wmi.RegInt(HKLM + @"SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters", "SMB1");
                bool on = feat && srv != 0;
                if (on) Add(r, "smb1", 0, "Gammel fildeling (SMBv1)", "Til", "En 30 år gammel protokol med kendte huller. Det var den, WannaCry spredte sig med.", "Opticon kan slå den fra. Kun meget gamle NAS-drev og printere bruger den.", "smb1");
                else Add(r, "smb1", 2, "Gammel fildeling (SMBv1)", "Fra", "Godt: den gamle, usikre protokol er slået fra");
            });

            // 13. Fjernskrivebord
            Safe("rdp", () =>
            {
                var deny = Wmi.RegInt(HKLM + @"SYSTEM\CurrentControlSet\Control\Terminal Server", "fDenyTSConnections");
                if (deny == 0)
                {
                    var nla = Wmi.RegInt(HKLM + @"SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp", "UserAuthentication");
                    if (nla == 0) Add(r, "rdp", 0, "Fjernskrivebord", "Åben uden ekstra login-tjek", "Andre kan forsøge at logge på din pc over netværket, og det tjek, der skulle bremse dem, er slået fra.", "Bruger du det ikke selv, så lad Opticon lukke det.", "rdp", "ms-settings:remotedesktop");
                    else Add(r, "rdp", 1, "Fjernskrivebord", "Åben", "Andre kan forsøge at logge på din pc over netværket. Et yndet mål for angreb.", "Bruger du det ikke selv, så lad Opticon lukke det.", "rdp", "ms-settings:remotedesktop");
                }
                else Add(r, "rdp", 2, "Fjernskrivebord", "Lukket", "Ingen kan logge på pc'en udefra");
            });

            // 14. Gæstekonto
            Safe("guest", () =>
            {
                var g = Wmi.Query(@"root\cimv2", "SELECT SID, Disabled FROM Win32_UserAccount WHERE LocalAccount=True")
                    .FirstOrDefault(u => (Convert.ToString(Wmi.Prop(u, "SID")) ?? "").EndsWith("-501"));
                if (g != null && !Convert.ToBoolean(Wmi.Prop(g, "Disabled") ?? true)) Add(r, "guest", 1, "Gæstekonto", "Til", "Alle kan logge på pc'en uden adgangskode", "Opticon kan slå gæstekontoen fra.", "guest");
                else Add(r, "guest", 2, "Gæstekonto", "Fra", "Man skal have en konto for at logge på");
            });

            // 15. Automatisk login
            Safe("autologon", () =>
            {
                const string K = HKLM + @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon";
                var al = Wmi.RegStr(K, "AutoAdminLogon"); var pw = Wmi.RegStr(K, "DefaultPassword");
                if (al == "1" && !string.IsNullOrEmpty(pw)) Add(r, "autologon", 0, "Automatisk login", "Adgangskode gemt i klartekst", "Din Windows-adgangskode ligger ukrypteret i registreringsdatabasen, hvor ethvert program kan læse den.", "Opticon kan fjerne den gemte adgangskode og slå automatisk login fra. Skift derefter adgangskoden, hvis den også bruges andre steder.", "autologon");
                else if (al == "1") Add(r, "autologon", 1, "Automatisk login", "Til", "Pc'en logger selv på, så alle med adgang til den kan bruge den", "Tryk Windows-tasten, skriv netplwiz, og sæt flueben i \"Brugerne skal angive brugernavn og adgangskode\".");
            });

            // 16. Diskenes helbred (Windows' egen vurdering fra disken)
            Safe("disk", () =>
            {
                var disks = Wmi.Query(@"root\Microsoft\Windows\Storage", "SELECT FriendlyName, HealthStatus FROM MSFT_PhysicalDisk");
                if (disks.Count == 0) return;
                var bad = disks.Where(d => Convert.ToInt32(Wmi.Prop(d, "HealthStatus") ?? 0) == 2).Select(d => Convert.ToString(Wmi.Prop(d, "FriendlyName"))).ToList();
                var warn = disks.Where(d => Convert.ToInt32(Wmi.Prop(d, "HealthStatus") ?? 0) == 1).Select(d => Convert.ToString(Wmi.Prop(d, "FriendlyName"))).ToList();
                if (bad.Count > 0) Add(r, "disk", 0, "Diskens helbred", "Fejl: " + string.Join(", ", bad), "Disken selv melder, at den har problemer. Den kan gå i stykker når som helst.", "Tag backup af dine vigtige filer NU (fx til OneDrive eller et USB-drev), og udskift disken.");
                else if (warn.Count > 0) Add(r, "disk", 1, "Diskens helbred", "Advarsel: " + string.Join(", ", warn), "Disken melder en advarsel, fx at den er ved at være slidt.", "Tag backup, og hold øje med den. Se detaljer i Indstillinger → System → Lager → Diske og drev.", "", "ms-settings:disksandvolumes");
                else Add(r, "disk", 2, "Diskens helbred", disks.Count == 1 ? "Sund" : "Alle " + disks.Count + " diske er sunde", "Diskene melder ingen problemer");
            });

            r.Items = r.Items.OrderBy(i => i.Sort).ToList();
            return r;
        }
    }
}
