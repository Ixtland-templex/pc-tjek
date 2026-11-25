using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using Opticon.Views;

namespace Opticon.Services
{
    /// <summary>
    /// Vagten kører stille i baggrunden (startes ved login, hvis den er slået til):
    /// * Download-vagt: tjekker nye programfiler i Overførsler (signatur, hvor de kommer fra, Defender)
    /// * Vagthund: giver besked, når noget nyt sætter sig i autostart, planlagte opgaver, tjenester eller Defender-undtagelser
    /// </summary>
    public static class Vagt
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunName = "Opticon Vagt";
        static string BaseFile { get { return Path.Combine(App.DataDir, "vagt-baseline.json"); } }
        static Mutex mutex;
        static FileSystemWatcher watcher;
        static DispatcherTimer timer;
        static readonly HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        static readonly Regex Risky = new Regex(@"\.(exe|msi|msix|appx|bat|cmd|ps1|vbs|js|jse|wsf|hta|scr|com|lnk|zip|7z|rar|iso|img)$", RegexOptions.IgnoreCase);

        // ---------- Til/fra (fra appen) ----------
        public static bool Enabled
        {
            get { using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) return k != null && k.GetValue(RunName) != null; }
        }

        public static void SetEnabled(bool on)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(RunKey, true))
            {
                if (on) k.SetValue(RunName, "\"" + Environment.ProcessPath + "\" --vagt");
                else k.DeleteValue(RunName, false);
            }
            if (on && !IsRunning) try { Process.Start(new ProcessStartInfo(Environment.ProcessPath, "--vagt") { UseShellExecute = true }); } catch { }
            if (!on) StopRunning();
        }

        public static bool IsRunning
        {
            get { try { using (var m = Mutex.OpenExisting("Local\\OpticonVagt")) return true; } catch { return false; } }
        }

        static void StopRunning()
        {
            try { using (var ev = EventWaitHandle.OpenExisting("Local\\OpticonVagtStop")) ev.Set(); } catch { }
        }

        // ---------- Selve vagten (Opticon.exe --vagt) ----------
        public static void Start()
        {
            bool created;
            mutex = new Mutex(true, "Local\\OpticonVagt", out created);
            if (!created) { Application.Current.Shutdown(); return; }   // kører allerede
            App.Log("Vagten startet");
            var stop = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\OpticonVagtStop");
            new Thread(() => { stop.WaitOne(); Application.Current.Dispatcher.BeginInvoke(new Action(() => { App.Log("Vagten stoppet"); Application.Current.Shutdown(); })); }) { IsBackground = true }.Start();

            // Download-vagt
            var dl = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
            if (Directory.Exists(dl))
            {
                watcher = new FileSystemWatcher(dl) { IncludeSubdirectories = false, NotifyFilter = NotifyFilters.FileName | NotifyFilters.Size };
                FileSystemEventHandler h = (s, e) => OnFile(e.FullPath);
                watcher.Created += h;
                watcher.Renamed += (s, e) => OnFile(e.FullPath);
                watcher.EnableRaisingEvents = true;
            }

            // Tilstande: spil-tilstand starter og slutter af sig selv, fokus slutter, når tiden er gået
            Modes.Notice += (t, b) => Popup(1, t, b);
            var modeTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
            bool modeBusy = false;
            modeTimer.Tick += async (s, e) => { if (modeBusy) return; modeBusy = true; try { await Task.Run(() => Modes.Tick(true)); } finally { modeBusy = false; } };
            modeTimer.Start();

            // Vagthund: første gang efter 2 min, derefter hvert 10. minut
            timer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
            timer.Tick += async (s, e) => { timer.Interval = TimeSpan.FromMinutes(10); await Watchdog(); };
            timer.Start();
        }

        static void Popup(int level, string title, string body, string file = null)
        {
            Application.Current.Dispatcher.BeginInvoke(new Action(() =>
            {
                try { new Popup(level >= 3 ? "⛔" : level == 2 ? "⚠" : "🛡", title, body, file, level >= 3 ? 0 : 20).Show(); }
                catch (Exception e) { App.Log("Vagt-popup: " + e.Message); }
            }));
        }

        static void OnFile(string path)
        {
            if (!Risky.IsMatch(path) || path.EndsWith(".crdownload", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".part", StringComparison.OrdinalIgnoreCase)) return;
            lock (seen) { if (!seen.Add(path)) return; }
            Task.Run(() =>
            {
                try
                {
                    // vent til browseren er færdig med at skrive filen
                    long last = -1;
                    for (int i = 0; i < 60; i++)
                    {
                        Thread.Sleep(1000);
                        if (!File.Exists(path)) return;
                        long len = new FileInfo(path).Length;
                        if (len == last && len > 0) { try { using (File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read)) { } break; } catch { } }
                        last = len;
                    }
                    CheckDownload(path);
                }
                catch (Exception e) { App.Log("Download-vagt " + path + ": " + e.Message); }
            });
        }

        static void CheckDownload(string path)
        {
            var name = Path.GetFileName(path);
            string from = "";
            try
            {
                var zone = File.ReadAllText(path + ":Zone.Identifier");
                var m = Regex.Match(zone, @"HostUrl=(\S+)");
                if (m.Success) { Uri u; if (Uri.TryCreate(m.Groups[1].Value, UriKind.Absolute, out u)) from = u.Host; }
            }
            catch { }
            bool exe = Regex.IsMatch(path, @"\.(exe|msi|scr|com)$", RegexOptions.IgnoreCase);
            bool script = Regex.IsMatch(path, @"\.(bat|cmd|ps1|vbs|js|jse|wsf|hta|lnk)$", RegexOptions.IgnoreCase);
            string sig = exe ? Signature.Check(path) : "";

            // Defender tjekker filen (kun læsning)
            int defender = -1;
            try
            {
                var mp = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Windows Defender", "MpCmdRun.exe");
                if (File.Exists(mp))
                    using (var p = Process.Start(new ProcessStartInfo(mp, "-Scan -ScanType 3 -File \"" + path + "\" -DisableRemediation") { UseShellExecute = false, CreateNoWindow = true }))
                        if (p.WaitForExit(120000)) defender = p.ExitCode;
            }
            catch { }
            if (!File.Exists(path)) { Popup(3, "Defender fjernede en fil", name + " blev fjernet af Microsoft Defender, fordi den var farlig." + (from.Length > 0 ? " Hentet fra " + from + "." : ""), null); return; }

            string where = from.Length > 0 ? "Hentet fra " + from + ". " : "";
            App.Log("Download-vagt: " + name + " · " + (sig.Length > 0 ? sig + " · " : "") + "Defender " + defender + (from.Length > 0 ? " · " + from : ""));
            if (defender == 2) Popup(4, "Farlig fil: " + name, where + "Microsoft Defender fandt en trussel i filen. Åbn den ikke. Slet den, eller lad Windows Sikkerhed fjerne den.", path);
            else if (script) Popup(3, "Script hentet: " + name, where + "Scripts kan gøre alt på din pc. Åbn det kun, hvis du ved præcis, hvad det er.", path);
            else if (exe && !Signature.IsSigned(sig)) Popup(2, "Usigneret program: " + name, where + "Programmet har ingen gyldig signatur, så ingen udgiver står inde for det. Defender fandt intet, men vær forsigtig, hvis du ikke kender det.", path);
            else if (exe) Popup(1, "Nyt program: " + name, where + sig.Replace("Signeret: ", "Signeret af ") + ". Defender fandt intet.", path);
        }

        // ---------- Vagthund ----------
        static string Key(ScanFind f) { return f.Category + "|" + f.Title + "|" + Regex.Replace(f.Path ?? "", @"\d+(\.\d+){1,3}", "#"); }

        static async Task Watchdog()
        {
            try
            {
                var r = await Task.Run(() => MalwareScan.Run((p, t) => { }, false));
                var now = r.Finds.Where(f => f.Category != "Proces" && f.Category != "Trussel (fjernet)" && f.Category != "Netværk" && f.Category != "Ny fil").ToList();
                var keys = now.Select(Key).Distinct().ToList();
                List<string> baseline = null;
                try { if (File.Exists(BaseFile)) baseline = JsonSerializer.Deserialize<List<string>>(File.ReadAllText(BaseFile)); } catch { }
                Directory.CreateDirectory(App.DataDir);
                File.WriteAllText(BaseFile, JsonSerializer.Serialize(keys));
                if (baseline == null) { App.Log("Vagthund: første liste gemt (" + keys.Count + " ting)"); return; }
                var old = new HashSet<string>(baseline);
                var fresh = now.Where(f => !old.Contains(Key(f))).GroupBy(Key).Select(g => g.First()).ToList();
                if (fresh.Count == 0) return;
                // Rigtig mange "nye" på én gang er en stor Windows-opdatering, ikke et angreb: husk stille
                if (fresh.Count > 15) { App.Log("Vagthund: " + fresh.Count + " nye ting på én gang, gemt stille"); return; }
                foreach (var f in fresh.OrderByDescending(x => x.Level).Take(3))
                {
                    App.Log("Vagthund: nyt " + f.Category + ": " + f.Title + " (" + f.Risk + ")");
                    Popup(f.Level >= 3 ? 3 : f.Level >= 2 ? 2 : 1, "Nyt: " + f.Category.ToLower() + " · " + f.Title, (f.Detail ?? "") + ". " + f.Why + (f.Level >= 3 ? " Åbn Opticon → Sikkerhed → Scan pc'en for at se mere." : ""), f.FilePath);
                }
            }
            catch (Exception e) { App.Log("Vagthund: " + e.Message); }
        }
    }
}
