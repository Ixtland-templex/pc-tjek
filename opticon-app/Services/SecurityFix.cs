using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management;
using System.Reflection;
using Microsoft.Win32;

namespace Opticon.Services
{
    /// <summary>Rettelser fra sikkerhedstjekket. Kræver administrator. Bruger kun Windows' egne værktøjer og indstillinger.</summary>
    public static class SecurityFix
    {
        const string Def = @"root\Microsoft\Windows\Defender";

        public static string Apply(string id)
        {
            App.Log("Retter: " + id);
            switch (id)
            {
                case "sigs":
                    {
                        var mp = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Windows Defender", "MpCmdRun.exe");
                        int code = Run(mp, "-SignatureUpdate", 300);
                        if (code != 0) throw new Exception("Defender kunne ikke hente nye definitioner (kode " + code + "). Prøv igen, når du er på nettet.");
                        return "Virusdefinitioner opdateret.";
                    }
                case "pua":
                    MpInvoke("Set", m => m["PUAProtection"] = (byte)1);
                    return "Blokering af uønskede programmer er slået til.";
                case "asr":
                    MpInvoke("Add", m =>
                    {
                        m["AttackSurfaceReductionRules_Ids"] = SecurityCheck.AsrStandard;
                        m["AttackSurfaceReductionRules_Actions"] = SecurityCheck.AsrStandard.Select(x => (byte)1).ToArray();
                    });
                    return "De 3 ekstra Defender-regler er slået til.";
                case "fw":
                    {
                        var fw = FwPolicy();
                        foreach (int profile in new[] { 1, 2, 4 })   // domæne, privat, offentlig
                            fw.GetType().InvokeMember("FirewallEnabled", BindingFlags.SetProperty, null, fw, new object[] { profile, true });
                        return "Firewall er slået til på alle netværk.";
                    }
                case "uac":
                    {
                        const string K = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System";
                        using (var k = Registry.LocalMachine.CreateSubKey(K, true))
                        {
                            bool wasOff = Convert.ToInt32(k.GetValue("EnableLUA", 1)) == 0;
                            k.SetValue("EnableLUA", 1, RegistryValueKind.DWord);
                            k.SetValue("ConsentPromptBehaviorAdmin", 5, RegistryValueKind.DWord);
                            k.SetValue("PromptOnSecureDesktop", 1, RegistryValueKind.DWord);
                            return wasOff ? "Brugerkontokontrol er slået til. Genstart pc'en, så den træder i kraft." : "Brugerkontokontrol er sat til Windows-standard.";
                        }
                    }
                case "blocklist":
                    using (var k = Registry.LocalMachine.CreateSubKey(@"SYSTEM\CurrentControlSet\Control\CI\Config", true))
                        k.SetValue("VulnerableDriverBlocklistEnable", 1, RegistryValueKind.DWord);
                    return "Blokering af sårbare drivere er slået til. Træder i kraft efter genstart.";
                case "smb1":
                    using (var k = Registry.LocalMachine.CreateSubKey(@"SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters", true))
                        k.SetValue("SMB1", 0, RegistryValueKind.DWord);
                    Run(Path.Combine(Environment.SystemDirectory, "dism.exe"), "/online /disable-feature /featurename:SMB1Protocol /norestart /quiet", 600);
                    return "SMBv1 er slået fra. Genstart for at fjerne den helt.";
                case "rdp":
                    using (var k = Registry.LocalMachine.CreateSubKey(@"SYSTEM\CurrentControlSet\Control\Terminal Server", true))
                        k.SetValue("fDenyTSConnections", 1, RegistryValueKind.DWord);
                    try
                    {
                        var fw = FwPolicy();   // luk også firewall-reglerne for fjernskrivebord
                        fw.GetType().InvokeMember("EnableRuleGroup", BindingFlags.InvokeMethod, null, fw, new object[] { 0x7FFFFFFF, "@FirewallAPI.dll,-28752", false });
                    }
                    catch (Exception e) { App.Log("Firewall-regler for fjernskrivebord: " + e.Message); }
                    return "Fjernskrivebord er lukket.";
                case "guest":
                    {
                        var g = Wmi.Query(@"root\cimv2", "SELECT * FROM Win32_UserAccount WHERE LocalAccount=True")
                            .FirstOrDefault(u => (Convert.ToString(Wmi.Prop(u, "SID")) ?? "").EndsWith("-501"));
                        if (g == null) return "Der er ingen gæstekonto.";
                        g["Disabled"] = true;
                        g.Put();
                        return "Gæstekontoen er slået fra.";
                    }
                case "autologon":
                    using (var k = Registry.LocalMachine.CreateSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon", true))
                    {
                        k.DeleteValue("DefaultPassword", false);
                        k.SetValue("AutoAdminLogon", "0", RegistryValueKind.String);
                    }
                    return "Den gemte adgangskode er fjernet, og automatisk login er slået fra.";
                default:
                    throw new Exception("Ukendt rettelse: " + id);
            }
        }

        static object FwPolicy()
        {
            var t = Type.GetTypeFromProgID("HNetCfg.FwPolicy2");
            if (t == null) throw new Exception("Windows Firewall kunne ikke åbnes.");
            return Activator.CreateInstance(t);
        }

        static void MpInvoke(string method, Action<ManagementBaseObject> fill)
        {
            using (var mc = new ManagementClass(new ManagementScope(Def), new ManagementPath("MSFT_MpPreference"), null))
            {
                var inParams = mc.GetMethodParameters(method);
                fill(inParams);
                var outParams = mc.InvokeMethod(method, inParams, null);
                int rv = outParams == null ? 0 : Convert.ToInt32(outParams["ReturnValue"] ?? 0);
                if (rv != 0) throw new Exception("Defender afviste ændringen (kode " + rv + "). Er Manipulationsbeskyttelse eller en anden antivirus i vejen?");
            }
        }

        static int Run(string exe, string args, int timeoutSec)
        {
            var psi = new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true };
            using (var p = Process.Start(psi))
            {
                if (!p.WaitForExit(timeoutSec * 1000)) { try { p.Kill(); } catch { } throw new Exception(Path.GetFileName(exe) + " svarede ikke."); }
                return p.ExitCode;
            }
        }
    }
}
