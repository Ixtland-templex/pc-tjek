using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;

namespace Opticon.Services
{
    public class GameResult
    {
        public DateTime Date { get; set; }
        public string Game { get; set; }
        public double Seconds { get; set; }
        public int Frames { get; set; }
        public double Fps { get; set; }
        public double Low1 { get; set; }
        public double Low01 { get; set; }
        public int Hak { get; set; }
        public double HakMin { get; set; }
        public string Limit { get; set; }      // gpu, cpu, cap, mixed, ukendt
        public double? GpuShare { get; set; }
        public double? CpuShare { get; set; }
        public double VSync { get; set; }
        public List<double> Seg { get; set; }
        public double? Watts { get; set; }
        public double? TempMax { get; set; }
    }

    /// <summary>"Mål i mit spil": måler et kørende spil med Intels PresentMon (gratis, open source, signeret af Intel).</summary>
    public static class GameMeasure
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool MessageBeep(uint type);
        static void Beep(uint t) { try { MessageBeep(t); } catch { } }
        static string Tools { get { return Path.Combine(App.DataDir, "tools"); } }
        static string Pm { get { return Path.Combine(Tools, "PresentMon.exe"); } }

        static bool IntelSigned(string p)
        {
            var s = Signature.Check(p);
            return Signature.IsSigned(s) && s.IndexOf("Intel", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        static void EnsurePresentMon(Action<string> status)
        {
            Directory.CreateDirectory(Tools);
            if (File.Exists(Pm) && IntelSigned(Pm)) return;
            status("Henter Intel PresentMon (kun første gang)…");
            using (var http = new HttpClient { Timeout = TimeSpan.FromSeconds(120) })
            {
                http.DefaultRequestHeaders.UserAgent.ParseAdd("Opticon");
                string url = null;
                try
                {
                    using (var doc = JsonDocument.Parse(http.GetStringAsync("https://api.github.com/repos/GameTechDev/PresentMon/releases?per_page=15").Result))
                        foreach (var r in doc.RootElement.EnumerateArray())
                        {
                            if (r.GetProperty("prerelease").GetBoolean() || r.GetProperty("draft").GetBoolean()) continue;
                            foreach (var a in r.GetProperty("assets").EnumerateArray())
                                if (Regex.IsMatch(a.GetProperty("name").GetString() ?? "", @"^PresentMon-[\d.]+-x64\.exe$")) { url = a.GetProperty("browser_download_url").GetString(); break; }
                            if (url != null) break;
                        }
                }
                catch (Exception e) { App.Log("PresentMon-udgivelser: " + e.Message); }
                if (url == null) url = "https://github.com/GameTechDev/PresentMon/releases/download/v2.3.1/PresentMon-2.3.1-x64.exe";
                var tmp = Path.Combine(Tools, "PresentMon-ny.exe");
                File.WriteAllBytes(tmp, http.GetByteArrayAsync(url).Result);
                if (!IntelSigned(tmp)) { try { File.Delete(tmp); } catch { } throw new Exception("PresentMon-filen var ikke gyldigt signeret af Intel, så Opticon brugte den ikke."); }
                if (File.Exists(Pm)) File.Delete(Pm);
                File.Move(tmp, Pm);
            }
        }

        static readonly Regex Skip = new Regex(@"^(dwm|explorer|powershell|pwsh|conhost|msedge|msedgewebview2|chrome|firefox|opera|brave|discord|steamwebhelper|steam|epicgameslauncher|eadesktop|battle\.net|overwolf|nvcontainer|nvidia overlay|nvidia app|applicationframehost|searchhost|searchapp|startmenuexperiencehost|textinputhost|shellexperiencehost|ms-teams|teams|spotify|obs64|code|windowsterminal|gamebar|xboxgamebar|xboxpcapp|presentmon.*|lghub|rtss|widgets|photos|mspaint|notepad|claude|chatgpt|codex|opticon)(\.exe)?$", RegexOptions.IgnoreCase);

        /// <summary>Måler i 'seconds' sekunder. status(tekst, andel 0..1 eller -1).</summary>
        public static GameResult Run(int seconds, Action<string, double> status)
        {
            EnsurePresentMon(t => status(t, -1));
            for (int i = 10; i > 0; i--) { status("Skift til dit spil nu. Målingen starter om " + i + " sek…", -1); Thread.Sleep(1000); }
            foreach (var old in new DirectoryInfo(Tools).GetFiles("capture-*.csv").OrderByDescending(f => f.LastWriteTime).Skip(2)) try { old.Delete(); } catch { }
            var csv = Path.Combine(Tools, "capture-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".csv");
            Beep(0x40);
            var args = "--output_file \"" + csv + "\" --timed " + seconds + " --terminate_after_timed --stop_existing_session --session_name Opticon --no_console_stats --no_track_input";
            var watts = new List<double>(); var temps = new List<double>();
            var smi = Path.Combine(Environment.SystemDirectory, "nvidia-smi.exe");
            bool hasSmi = File.Exists(smi);
            var p = Process.Start(new ProcessStartInfo(Pm, args) { UseShellExecute = false, CreateNoWindow = true });
            var sw = Stopwatch.StartNew(); var nextS = 0.0;
            while (!p.HasExited)
            {
                double el = sw.Elapsed.TotalSeconds;
                if (hasSmi && el >= nextS)
                {
                    nextS = el + 1;
                    try
                    {
                        using (var q = Process.Start(new ProcessStartInfo(smi, "--query-gpu=power.draw,temperature.gpu --format=csv,noheader,nounits") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true }))
                        {
                            var parts = q.StandardOutput.ReadToEnd().Split('\n')[0].Split(',');
                            q.WaitForExit(2000);
                            double w, t;
                            if (parts.Length > 1 && double.TryParse(parts[0].Trim(), NumberStyles.Float, Inv, out w)) watts.Add(w);
                            if (parts.Length > 1 && double.TryParse(parts[1].Trim(), NumberStyles.Float, Inv, out t)) temps.Add(t);
                        }
                    }
                    catch { }
                }
                status("Måler dit spil… " + Math.Max(0, (int)(seconds - el)) + " sek. tilbage", Math.Min(1, el / seconds));
                if (el > seconds + 30) { try { p.Kill(); } catch { } break; }
                Thread.Sleep(500);
            }
            Beep(0x30);
            Thread.Sleep(500);
            if (!File.Exists(csv)) throw new Exception("PresentMon gemte ingen måling (kode " + (p.HasExited ? p.ExitCode : -1) + "). Kører Opticon som administrator?");

            status("Regner resultatet ud…", -1);
            var lines = File.ReadAllLines(csv);
            if (lines.Length < 30) throw new Exception("Fandt næsten ingen billeder. Var spillet i gang og i forgrunden, mens den målte?");
            var hdr = lines[0].Split(',');
            Func<string[], int> col = names => { foreach (var n in names) { int ix = Array.IndexOf(hdr, n); if (ix >= 0) return ix; } return -1; };
            int iApp = col(new[] { "Application", "ProcessName" }), iFt = col(new[] { "MsBetweenPresents", "FrameTime", "MsBetweenAppStart" });
            int iGpu = col(new[] { "MsGPUBusy", "GPUBusy" }), iCpu = col(new[] { "MsCPUBusy", "CPUBusy" }), iSync = col(new[] { "SyncInterval" });
            if (iApp < 0 || iFt < 0) throw new Exception("Kunne ikke læse PresentMons resultat (ukendte kolonner).");

            var count = new Dictionary<string, int>();
            for (int i = 1; i < lines.Length; i++)
            {
                var c = lines[i].Split(',');
                if (c.Length <= iFt || Skip.IsMatch(c[iApp])) continue;
                int n; count.TryGetValue(c[iApp], out n); count[c[iApp]] = n + 1;
            }
            if (count.Count == 0) throw new Exception("Fandt intet spil i målingen. Var spillet i forgrunden, mens den målte?");
            var game = count.OrderByDescending(x => x.Value).First().Key;

            var ft = new List<double>(); double gb = 0, cb = 0; int ng = 0, nc = 0, vs = 0;
            for (int i = 1; i < lines.Length; i++)
            {
                var c = lines[i].Split(',');
                if (c.Length <= iFt || c[iApp] != game) continue;
                double v, w;
                if (!double.TryParse(c[iFt], NumberStyles.Float, Inv, out v) || v <= 0 || v > 2000) continue;
                ft.Add(v);
                if (iGpu >= 0 && c.Length > iGpu && double.TryParse(c[iGpu], NumberStyles.Float, Inv, out w)) { gb += w; ng++; }
                if (iCpu >= 0 && c.Length > iCpu && double.TryParse(c[iCpu], NumberStyles.Float, Inv, out w)) { cb += w; nc++; }
                if (iSync >= 0 && c.Length > iSync && Regex.IsMatch(c[iSync], "^[1-9]")) vs++;
            }
            if (ft.Count < 30) throw new Exception("For få billeder fra " + game + " til en måling. Prøv igen, og bliv inde i spillet hele tiden.");

            // FPS pr. 10 sekunder: viser, hvor meget FPS svinger af sig selv
            var seg = new List<double>(); double acc = 0; int cnt = 0;
            foreach (var v in ft) { acc += v; cnt++; if (acc >= 10000) { seg.Add(Math.Round(1000.0 * cnt / acc, 1)); acc = 0; cnt = 0; } }
            var arr = ft.OrderBy(x => x).ToArray();
            double total = arr.Sum(), avg = total / arr.Length;
            double med = arr[(int)Math.Floor(0.5 * (arr.Length - 1))], p99 = arr[(int)Math.Floor(0.99 * (arr.Length - 1))], p999 = arr[(int)Math.Floor(0.999 * (arr.Length - 1))];
            double hakLim = Math.Max(2.5 * med, med + 12);
            int hak = arr.Count(v => v >= hakLim);
            double secs = total / 1000;
            double? gpuShare = ng > 0 ? (gb / ng) / avg : (double?)null, cpuShare = nc > 0 ? (cb / nc) / avg : (double?)null;
            string limit = gpuShare == null ? "ukendt" : gpuShare >= 0.9 ? "gpu" : (cpuShare != null && cpuShare >= 0.85) ? "cpu" : gpuShare < 0.8 ? "cap" : "mixed";
            var r = new GameResult
            {
                Date = DateTime.Now, Game = Regex.Replace(game, @"\.exe$", "", RegexOptions.IgnoreCase), Seconds = Math.Round(secs, 1), Frames = arr.Length,
                Fps = Math.Round(1000 / avg, 1), Low1 = Math.Round(1000 / p99, 1), Low01 = Math.Round(1000 / p999, 1),
                Hak = hak, HakMin = Math.Round(hak / Math.Max(0.1, secs / 60), 1), Limit = limit,
                GpuShare = gpuShare.HasValue ? Math.Round(gpuShare.Value * 100) : (double?)null, CpuShare = cpuShare.HasValue ? Math.Round(cpuShare.Value * 100) : (double?)null,
                VSync = Math.Round(100.0 * vs / ft.Count), Seg = seg,
                Watts = watts.Count > 0 ? Math.Round(watts.Average(), 1) : (double?)null, TempMax = temps.Count > 0 ? temps.Max() : (double?)null
            };
            App.Log("Mål i mit spil: " + r.Game + " " + r.Fps + " fps, 1% low " + r.Low1 + ", hak/min " + r.HakMin + ", begrænset af " + r.Limit);
            return r;
        }

        public static string Describe(GameResult r)
        {
            var da = new CultureInfo("da-DK");
            var t = string.Format(da, "{0}: {1:0} FPS i gennemsnit · 1 % low {2:0} FPS · {3:0.#} hak pr. minut", r.Game, r.Fps, r.Low1, r.HakMin);
            if (r.Watts.HasValue) t += string.Format(da, " · grafikkort {0:0} W{1}", r.Watts, r.TempMax.HasValue ? string.Format(da, ", maks. {0:0} °C", r.TempMax) : "");
            t += "\n\n";
            switch (r.Limit)
            {
                case "gpu": t += "🎮 Grafikkortet arbejder for fuld kraft og er det, der sætter grænsen. Vil du have flere FPS: sænk opløsningen eller de tunge grafikindstillinger (skygger, strålesporing), eller slå DLSS/FSR til."; break;
                case "cpu": t += "🧠 Processoren er flaskehalsen: grafikkortet venter på den. Sænk processortunge indstillinger (sigtbarhed, antal personer, fysik), og luk programmer i baggrunden. Højere grafik koster her næsten ingen FPS."; break;
                case "cap": t += "🔒 FPS ser ud til at være låst af V-Sync, et FPS-loft i spillet eller skærmens Hz. Grafikkortet har kræfter til overs. Det er helt fint, hvis det kører jævnt."; break;
                case "mixed": t += "⚖ Grafikkort og processor er nogenlunde lige belastede. Der er ikke én tydelig flaskehals."; break;
                default: t += "Kunne ikke se, hvad der begrænser FPS (PresentMon gav ikke belastningen)."; break;
            }
            if (r.HakMin >= 6) t += "\n\n⚠ Mange hak. Typiske årsager: shader-kompilering første gang, for lidt RAM eller VRAM, eller noget i baggrunden. Prøv igen, efter spillet har kørt et par minutter.";
            else if (r.Low1 < r.Fps * 0.5) t += "\n\n⚠ 1 % low er meget lavere end gennemsnittet, så spillet kan føles ujævnt.";
            return t;
        }

        /// <summary>Hvor meget FPS svinger af sig selv (variationskoefficient af 10-sekunders segmenter).</summary>
        public static double Noise(GameResult r)
        {
            if (r.Seg == null || r.Seg.Count < 2) return 0.03;
            double m = r.Seg.Average(), sd = Math.Sqrt(r.Seg.Sum(x => (x - m) * (x - m)) / (r.Seg.Count - 1));
            return Math.Max(0.01, sd / Math.Max(1, m));
        }
    }
}
