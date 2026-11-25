using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

namespace Opticon.Services
{
    public class GameProfile
    {
        public string Name { get; set; }
        public string Exe { get; set; }            // procesnavn uden .exe
        public string Path { get; set; }           // fuld sti til spillets .exe
        public List<string> Close { get; set; } = new List<string>();
        public bool Mute { get; set; } = true;
        public string CloseText { get { return Close == null || Close.Count == 0 ? "Lukker ingen programmer" : "Lukker: " + string.Join(", ", Close); } }
    }

    public class ClosedApp { public string Name { get; set; } public string Path { get; set; } }

    public class ModeState
    {
        public string Mode { get; set; }           // Spil eller Fokus
        public string Name { get; set; }
        public string Exe { get; set; }
        public DateTime Started { get; set; }
        public DateTime? Until { get; set; }
        public int? PrevToast { get; set; }
        public List<string> Sites { get; set; } = new List<string>();
        public List<ClosedApp> Closed { get; set; } = new List<ClosedApp>();
        public List<string> NotClosed { get; set; } = new List<string>();
        public bool Auto { get; set; }
        public int Misses { get; set; }
    }

    /// <summary>
    /// Tilstande: Spil (lukker valgte programmer og slår beskeder fra, mens du spiller) og Fokus (slår beskeder fra
    /// og blokerer valgte sider i en periode). Alt sættes tilbage, når tilstanden slutter, også efter et nedbrud.
    /// </summary>
    public static class Modes
    {
        static string StateFile { get { return Path.Combine(App.DataDir, "tilstand.json"); } }
        static string GamesFile { get { return Path.Combine(App.DataDir, "spil.json"); } }
        static string Hosts { get { return Path.Combine(Environment.SystemDirectory, @"drivers\etc\hosts"); } }
        const string HostsBegin = "# >>> Opticon Fokus (fjernes automatisk, når fokus slutter)";
        const string HostsEnd = "# <<< Opticon Fokus";
        const string ToastKey = @"Software\Microsoft\Windows\CurrentVersion\PushNotifications";
        static readonly string[] Never = { "explorer", "dwm", "csrss", "winlogon", "opticon", "steam", "steamwebhelper", "svchost", "system", "idle", "searchhost", "startmenuexperiencehost", "textinputhost", "shellexperiencehost", "applicationframehost", "sihost", "taskmgr" };

        public static event Action<string, string> Notice;   // titel, tekst (til popups i Vagten)

        static T Locked<T>(Func<T> body)
        {
            using (var m = new Mutex(false, "Local\\OpticonMode"))
            {
                bool got = false;
                try { got = m.WaitOne(5000); return body(); }
                catch (AbandonedMutexException) { got = true; return body(); }
                finally { if (got) m.ReleaseMutex(); }
            }
        }

        public static ModeState Current()
        {
            try { return File.Exists(StateFile) ? JsonSerializer.Deserialize<ModeState>(File.ReadAllText(StateFile)) : null; } catch { return null; }
        }

        static void Save(ModeState s)
        {
            Directory.CreateDirectory(App.DataDir);
            var tmp = StateFile + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(s));
            File.Copy(tmp, StateFile, true); File.Delete(tmp);
        }

        public static List<GameProfile> Games()
        {
            try { return File.Exists(GamesFile) ? JsonSerializer.Deserialize<List<GameProfile>>(File.ReadAllText(GamesFile)) ?? new List<GameProfile>() : new List<GameProfile>(); } catch { return new List<GameProfile>(); }
        }

        public static void SaveGames(List<GameProfile> g)
        {
            Directory.CreateDirectory(App.DataDir);
            File.WriteAllText(GamesFile, JsonSerializer.Serialize(g));
        }

        /// <summary>Programmer med et vindue lige nu (forslag til, hvad der kan lukkes).</summary>
        public static List<string> RunningApps()
        {
            return Process.GetProcesses().Where(p => { try { return p.MainWindowHandle != IntPtr.Zero && !Never.Contains(p.ProcessName.ToLowerInvariant()); } catch { return false; } })
                .Select(p => p.ProcessName).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(n => n).ToList();
        }

        static int? GetToast() { try { using (var k = Registry.CurrentUser.OpenSubKey(ToastKey)) return k == null ? 1 : Convert.ToInt32(k.GetValue("ToastEnabled", 1)); } catch { return null; } }
        static void SetToast(int on) { try { using (var k = Registry.CurrentUser.CreateSubKey(ToastKey, true)) k.SetValue("ToastEnabled", on, RegistryValueKind.DWord); } catch (Exception e) { App.Log("Beskeder: " + e.Message); } }

        public static string CleanSite(string s)
        {
            s = (s ?? "").Trim().ToLowerInvariant();
            s = Regex.Replace(s, "^https?://", ""); s = Regex.Replace(s, "/.*$", ""); s = Regex.Replace(s, "^(www|m)\\.", "");
            return Regex.IsMatch(s, @"^[a-z0-9-]+(\.[a-z0-9-]+)+$") ? s : null;
        }

        static void RemoveHostsBlock()
        {
            var lines = File.ReadAllLines(Hosts).ToList();
            int a = lines.IndexOf(HostsBegin), b = lines.IndexOf(HostsEnd);
            if (a < 0) return;
            if (b < a) b = lines.Count - 1;
            lines.RemoveRange(a, b - a + 1);
            File.WriteAllLines(Hosts, lines);
            Flush();
        }

        static void SetHostsBlock(List<string> sites)
        {
            RemoveHostsBlock();
            var lines = File.ReadAllLines(Hosts).ToList();
            lines.Add(HostsBegin);
            foreach (var s in sites) { lines.Add("0.0.0.0 " + s); lines.Add("0.0.0.0 www." + s); }
            lines.Add(HostsEnd);
            File.WriteAllLines(Hosts, lines);
            Flush();
        }

        static void Flush() { try { using (var p = Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "ipconfig.exe"), "/flushdns") { UseShellExecute = false, CreateNoWindow = true })) p.WaitForExit(5000); } catch { } }

        public static bool HostsBlocked { get { try { return File.ReadAllText(Hosts).Contains(HostsBegin); } catch { return false; } } }

        public static ModeState StartGame(GameProfile g, bool auto)
        {
            return Locked(() =>
            {
                if (Current() != null) return null;
                var s = new ModeState { Mode = "Spil", Name = g.Name, Exe = g.Exe, Started = DateTime.Now, Auto = auto };
                if (g.Mute) { s.PrevToast = GetToast(); Save(s); SetToast(0); }
                Save(s);
                // Kun en almindelig lukning, som når du selv trykker på krydset. Intet tvangsstop, så du aldrig mister noget, der ikke er gemt.
                var asked = new List<ClosedApp>();
                foreach (var n in g.Close ?? new List<string>())
                {
                    if (Never.Contains(n.ToLowerInvariant())) continue;
                    var ps = Process.GetProcessesByName(n);
                    if (ps.Length == 0) continue;
                    string path = null; foreach (var p in ps) { try { path = path ?? p.MainModule.FileName; } catch { } }
                    asked.Add(new ClosedApp { Name = n, Path = path });
                    foreach (var p in ps) { try { p.CloseMainWindow(); } catch { } }
                }
                var until = DateTime.Now.AddSeconds(8);
                while (DateTime.Now < until && asked.Any(a => Process.GetProcessesByName(a.Name).Length > 0)) Thread.Sleep(400);
                s.Closed = asked.Where(a => Process.GetProcessesByName(a.Name).Length == 0).ToList();
                s.NotClosed = asked.Where(a => Process.GetProcessesByName(a.Name).Length > 0).Select(a => a.Name).ToList();
                Save(s);
                App.Log("Spil-tilstand startet: " + g.Name + " (lukket: " + string.Join(", ", s.Closed.Select(c => c.Name)) + ")");
                return s;
            });
        }

        /// <summary>Sideblokering kræver administrator (hosts-filen).</summary>
        public static ModeState StartFocus(int minutes, bool mute, List<string> sites)
        {
            return Locked(() =>
            {
                if (Current() != null) throw new Exception("En anden tilstand er allerede aktiv. Afslut den først.");
                var clean = (sites ?? new List<string>()).Select(CleanSite).Where(x => x != null).Distinct().ToList();
                if (clean.Count > 0 && !Admin.IsElevated) throw new UnauthorizedAccessException("Blokering af sider kræver administrator.");
                var s = new ModeState { Mode = "Fokus", Name = minutes + " min", Started = DateTime.Now, Until = DateTime.Now.AddMinutes(minutes), Sites = clean };
                if (mute) s.PrevToast = GetToast();
                Save(s);
                if (mute) SetToast(0);
                if (clean.Count > 0) SetHostsBlock(clean);
                App.Log("Fokus startet: " + minutes + " min" + (clean.Count > 0 ? " · blokerer " + string.Join(", ", clean) : ""));
                return s;
            });
        }

        /// <summary>Sætter alt tilbage. Returnerer en tekst om, hvad der skete.</summary>
        public static string Stop(string reason)
        {
            return Locked(() =>
            {
                var s = Current();
                if (s == null) return "";
                var notes = new List<string>();
                if (s.PrevToast.HasValue) SetToast(s.PrevToast.Value);
                bool hostsLeft = false;
                if (s.Sites != null && s.Sites.Count > 0 && HostsBlocked)
                {
                    try { RemoveHostsBlock(); }
                    catch { hostsLeft = true; notes.Add("Sideblokeringen kunne ikke fjernes uden administrator. Åbn Opticon som administrator for at fjerne den."); }
                }
                foreach (var c in s.Closed ?? new List<ClosedApp>())
                    if (!string.IsNullOrEmpty(c.Path) && File.Exists(c.Path) && Process.GetProcessesByName(c.Name).Length == 0)
                        try { Process.Start(new ProcessStartInfo(c.Path) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(c.Path) }); } catch { }
                if (!hostsLeft) { try { File.Delete(StateFile); } catch { } }
                else { s.Closed = new List<ClosedApp>(); s.PrevToast = null; s.Until = DateTime.Now; Save(s); }
                App.Log(s.Mode + "-tilstand afsluttet (" + reason + ")");
                var msg = s.Mode + "-tilstand er slut (" + reason + "). " + (s.Closed != null && s.Closed.Count > 0 ? "Lukkede programmer er startet igen. " : "") + string.Join(" ", notes);
                return msg.Trim();
            });
        }

        /// <summary>Kaldes jævnligt (hvert 5. sek.) af appen og Vagten: starter og stopper tilstande automatisk.</summary>
        public static void Tick(bool autoStartGames)
        {
            try
            {
                var s = Current();
                if (s != null)
                {
                    if (s.Mode == "Fokus" && s.Until.HasValue && DateTime.Now > s.Until.Value)
                    {
                        if (s.Sites != null && s.Sites.Count > 0 && HostsBlocked && !Admin.IsElevated) return;   // venter på, at appen åbnes som administrator
                        var m = Stop("tiden var gået"); var h = Notice; if (h != null) h("Fokus er slut", m);
                    }
                    else if (s.Mode == "Spil" && !string.IsNullOrEmpty(s.Exe))
                    {
                        if (Process.GetProcessesByName(s.Exe).Length == 0)
                        {
                            s.Misses++;
                            if (s.Misses >= 3) { var m = Stop("spillet blev lukket"); var h = Notice; if (h != null) h("Spil-tilstand er slut", m); }
                            else Locked(() => { Save(s); return 0; });
                        }
                        else if (s.Misses > 0) { s.Misses = 0; Locked(() => { Save(s); return 0; }); }
                    }
                    return;
                }
                if (!autoStartGames) return;
                foreach (var g in Games())
                    if (!string.IsNullOrEmpty(g.Exe) && Process.GetProcessesByName(g.Exe).Length > 0)
                    {
                        var st = StartGame(g, true);
                        if (st != null) { var h = Notice; if (h != null) h("Spil-tilstand: " + g.Name, (st.Closed.Count > 0 ? "Lukkede " + string.Join(", ", st.Closed.Select(c => c.Name)) + ". " : "") + (g.Mute ? "Beskeder er slået fra. " : "") + "Alt sættes tilbage, når du lukker spillet."); }
                        break;
                    }
            }
            catch (Exception e) { App.Log("Tilstande: " + e.Message); }
        }
    }
}
