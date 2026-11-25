using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Opticon.Services
{
    public class CompareRow
    {
        public string Name { get; set; }
        public string Mine { get; set; }
        public string Median { get; set; }
        public string Diff { get; set; }
        public string Who { get; set; }
    }

    /// <summary>Sammenligner dit benchmark med andre, der har delt resultater med samme processor eller grafikkort.</summary>
    public static class Community
    {
        const string Repo = "Ixtland-templex/pc-tjek";
        const int TestVersion = 3;   // samme målemetode som den gamle app (grafik uden skærmlås)

        public static string Norm(string n)
        {
            var s = (n ?? "").ToLowerInvariant();
            s = Regex.Replace(s, @"\((r|tm)\)", "");
            s = Regex.Replace(s, @"\b(processor|cpu|with radeon graphics|w/ radeon.*|graphics|gpu)\b", "");
            return Regex.Replace(s, "[^a-z0-9]+", " ").Trim();
        }

        static double? Median(IEnumerable<double> xs)
        {
            var a = xs.Where(x => x > 0).OrderBy(x => x).ToArray();
            if (a.Length == 0) return null;
            return a.Length % 2 == 1 ? a[a.Length / 2] : (a[a.Length / 2 - 1] + a[a.Length / 2]) / 2;
        }

        static bool NewGpuMethod(string app)
        {
            Version v;
            if (!Version.TryParse(app ?? "", out v)) return false;
            return v.Major == 0 || v >= new Version(2, 45);   // ny app (0.x) eller gammel app fra 2.45
        }

        static string url;
        static readonly HttpClient http = MakeClient();
        static HttpClient MakeClient() { var h = new HttpClient { Timeout = TimeSpan.FromSeconds(20) }; h.DefaultRequestHeaders.UserAgent.ParseAdd("Opticon"); return h; }

        /// <summary>Adressen på fælles-databasen (står i opticon-app/community.json i repoet, så den kan ændres uden ny app-version).</summary>
        public static string Url
        {
            get
            {
                if (url != null) return url;
                try
                {
                    var j = http.GetStringAsync("https://raw.githubusercontent.com/" + Repo + "/main/opticon-app/community.json?t=" + DateTime.UtcNow.Ticks).Result;
                    using (var d = JsonDocument.Parse(j)) url = d.RootElement.TryGetProperty("url", out var u) ? (u.GetString() ?? "") : "";
                }
                catch { url = ""; }
                return url;
            }
        }

        // ---------- Anslåede tal (community-estimates.json) ----------
        class Est { public Dictionary<string, double[]> Cpu = new Dictionary<string, double[]>(); public Dictionary<string, double> Gpu = new Dictionary<string, double>(); public int MinReal = 3; public string CpuSrc = "", GpuSrc = ""; }
        static Est est;

        /// <summary>Nøgle for en processor, fx "i13600k" for både i5-13600K og i5-13600KF.</summary>
        public static string CpuKey(string name)
        {
            var n = Norm(name);
            bool amd = n.Contains("ryzen") || n.Contains("amd");
            var m = Regex.Match(n, @"\b(\d{4,5}x3d|\d{4,5}[a-z]{0,2})\b");
            if (!m.Success) return null;
            var model = m.Groups[1].Value;
            if (!amd) model = Regex.Replace(model, "(kf|f)$", m2 => m2.Value == "kf" ? "k" : "");
            return (amd ? "r" : "i") + model;
        }

        /// <summary>Nøgle for et grafikkort, fx "rtx 3070 ti". Bærbare kort (Laptop GPU) får ingen nøgle.</summary>
        public static string GpuKey(string name)
        {
            var n = (name ?? "").ToLowerInvariant();
            if (n.Contains("laptop") || n.Contains("mobile") || n.Contains("max-q")) return null;
            n = Norm(n);
            n = Regex.Replace(n, @"\b(nvidia|amd|intel|geforce|radeon|arc|\d+ ?gb)\b", " ");
            n = Regex.Replace(n, @"\s+", " ").Trim();
            return n.Length == 0 ? null : n;
        }

        static Est LoadEst()
        {
            if (est != null) return est;
            var e = new Est();
            try
            {
                var j = http.GetStringAsync("https://raw.githubusercontent.com/" + Repo + "/main/opticon-app/community-estimates.json?t=" + DateTime.UtcNow.Ticks).Result;
                using (var d = JsonDocument.Parse(j))
                {
                    var r = d.RootElement;
                    if (r.TryGetProperty("minReal", out var mr)) e.MinReal = mr.GetInt32();
                    if (r.TryGetProperty("sources", out var src)) { if (src.TryGetProperty("cpu", out var c)) e.CpuSrc = c.GetString(); if (src.TryGetProperty("gpu", out var g)) e.GpuSrc = g.GetString(); }
                    if (r.TryGetProperty("cpu", out var cpu)) foreach (var p in cpu.EnumerateObject()) { var k = CpuKey(p.Name); if (k != null && !e.Cpu.ContainsKey(k)) e.Cpu[k] = new[] { p.Value[0].GetDouble(), p.Value[1].GetDouble() }; }
                    if (r.TryGetProperty("gpu", out var gpu)) foreach (var p in gpu.EnumerateObject()) { var k = GpuKey(p.Name); if (k != null && !e.Gpu.ContainsKey(k)) e.Gpu[k] = p.Value.GetDouble(); }
                }
            }
            catch (Exception x) { App.Log("Anslåede tal: " + x.Message); }
            return est = e;
        }

        static IEnumerable<JsonElement> Parse(string json)
        {
            using (var doc = JsonDocument.Parse(json))
                return doc.RootElement.ValueKind == JsonValueKind.Array ? doc.RootElement.EnumerateArray().Select(e => e.Clone()).ToList() : new List<JsonElement>();
        }

        /// <summary>Alle delte resultater: den nye fælles-database plus de gamle fra GitHub.</summary>
        static JsonElement[] LoadAll()
        {
            var list = new List<JsonElement>();
            try
            {
                var resp = http.GetAsync("https://raw.githubusercontent.com/" + Repo + "/results/results.json?t=" + DateTime.UtcNow.Ticks).Result;
                if (resp.IsSuccessStatusCode) list.AddRange(Parse(resp.Content.ReadAsStringAsync().Result));
            }
            catch (Exception e) { App.Log("GitHub-resultater: " + e.Message); }
            if (!string.IsNullOrEmpty(Url))
                try { list.AddRange(Parse(http.GetStringAsync(Url).Result)); }
                catch (Exception e) { App.Log("Fælles resultater: " + e.Message); }
            return list.ToArray();
        }

        static Dictionary<string, object> Payload(BenchResult me)
        {
            return new Dictionary<string, object>
            {
                { "v", TestVersion }, { "app", Updater.Current.ToString(3) }, { "cpu", me.CpuName }, { "gpu", me.GpuName }, { "cores", me.Cores }, { "threads", me.Threads },
                { "ramGB", me.RamGB }, { "ramMHz", me.RamMHz }, { "disk", me.DiskName ?? "" }, { "laptop", me.Laptop }, { "battery", me.OnBattery }, { "power", PowerMode.Name(PowerMode.Current()) },
                { "scores", new Dictionary<string, object> { { "cpu1", me.Cpu1 }, { "cpuN", me.CpuN }, { "sustain", me.Sustain }, { "ram", me.Ram }, { "diskR", me.DiskR }, { "diskW", me.DiskW }, { "iops", me.Iops }, { "gpu", me.Gpu }, { "total", me.Score } } }
            };
        }

        /// <summary>Deler resultatet med ét klik (ingen login). Returnerer null ved succes, ellers en fejltekst.</summary>
        public static string Submit(BenchResult me)
        {
            if (string.IsNullOrEmpty(Url)) return "nourl";
            try
            {
                var body = new StringContent(JsonSerializer.Serialize(Payload(me)), System.Text.Encoding.UTF8, "text/plain");
                var resp = http.PostAsync(Url, body).Result;
                var txt = resp.Content.ReadAsStringAsync().Result;
                using (var d = JsonDocument.Parse(txt))
                {
                    if (d.RootElement.TryGetProperty("ok", out var ok) && ok.GetBoolean()) { App.Log("Benchmark delt"); return null; }
                    return d.RootElement.TryGetProperty("error", out var er) ? er.GetString() : "ukendt svar";
                }
            }
            catch (Exception e) { App.Log("Del resultat: " + e.Message); return (e.InnerException ?? e).Message; }
        }

        /// <summary>Returnerer (rækker, tekst). Kaster ved netværksfejl.</summary>
        public static Tuple<List<CompareRow>, string> Compare(BenchResult me)
        {
            var all = LoadAll();
            Func<JsonElement, string, string> str = (e, k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : "";
            Func<JsonElement, string, bool> boo = (e, k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
            Func<JsonElement, string, double> score = (e, k) => e.TryGetProperty("scores", out var s) && s.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : 0;
            var valid = all.Where(e => e.TryGetProperty("v", out var v) && v.ValueKind == JsonValueKind.Number && v.GetInt32() == TestVersion && !boo(e, "battery")).ToList();
            string myCpu = Norm(me.CpuName), myGpu = Norm(me.GpuName);
            var sameCpu = valid.Where(e => Norm(str(e, "cpu")) == myCpu && boo(e, "laptop") == me.Laptop).ToList();
            var sameGpu = valid.Where(e => Norm(str(e, "gpu")) == myGpu && boo(e, "laptop") == me.Laptop && NewGpuMethod(str(e, "app"))).ToList();
            string kind = me.Laptop ? "bærbare" : "stationære";
            var da = new CultureInfo("da-DK");
            var defs = new[]
            {
                Tuple.Create("Processor · én kerne", me.Cpu1, "cpu1", sameCpu, me.CpuName, ""),
                Tuple.Create("Processor · alle kerner", me.CpuN, "cpuN", sameCpu, me.CpuName, ""),
                Tuple.Create("Holder farten", (double)me.Sustain, "sustain", sameCpu, me.CpuName, " %"),
                Tuple.Create("Hukommelse", me.Ram, "ram", sameCpu, me.CpuName, " GB/s"),
                Tuple.Create("Grafik (1080p)", me.Gpu, "gpu", sameGpu, me.GpuName, " fps"),
            };
            var es = LoadEst();
            string myCk = me.Laptop ? null : CpuKey(me.CpuName), myGk = me.Laptop ? null : GpuKey(me.GpuName);
            double[] myCref = myCk != null && es.Cpu.ContainsKey(myCk) ? es.Cpu[myCk] : null;
            double myGref = myGk != null && es.Gpu.ContainsKey(myGk) ? es.Gpu[myGk] : 0;
            // Anslået værdi = median over rigtige stationære resultater med kendt referencetal, skaleret med forholdet mellem referencetallene.
            Func<string, double?> estimate = k =>
            {
                var vals = new List<double>();
                foreach (var e in valid)
                {
                    if (boo(e, "laptop")) continue;
                    double v = score(e, k); if (v <= 0) continue;
                    if (k == "gpu")
                    {
                        if (myGref <= 0 || !NewGpuMethod(str(e, "app"))) continue;
                        var gk = GpuKey(str(e, "gpu")); if (gk == null || !es.Gpu.ContainsKey(gk)) continue;
                        vals.Add(v * myGref / es.Gpu[gk]);
                    }
                    else
                    {
                        if (myCref == null) continue;
                        var ck = CpuKey(str(e, "cpu")); if (ck == null || !es.Cpu.ContainsKey(ck)) continue;
                        int i = k == "cpu1" ? 0 : 1;
                        vals.Add(v * myCref[i] / es.Cpu[ck][i]);
                    }
                }
                return Median(vals);
            };
            var rows = new List<CompareRow>(); double? cpuDiff = null, gpuDiff = null; bool cpuEst = false, gpuEst = false;
            foreach (var d in defs)
            {
                if (d.Item2 <= 0) continue;
                var real = d.Item4.Select(e => score(e, d.Item3)).Where(x => x > 0).ToList();
                double? guess = (d.Item3 == "cpu1" || d.Item3 == "cpuN" || d.Item3 == "gpu") && real.Count < es.MinReal ? estimate(d.Item3) : null;
                var m = Median(guess.HasValue ? real.Concat(new[] { guess.Value }) : real);
                if (m == null) continue;
                double diff = 100 * (d.Item2 - m.Value) / Math.Max(0.001, m.Value);
                if (d.Item3 == "cpuN") { cpuDiff = diff; cpuEst = guess.HasValue; }
                if (d.Item3 == "gpu") { gpuDiff = diff; gpuEst = guess.HasValue; }
                int cnt = real.Count;
                string who = guess.HasValue
                    ? (cnt == 0 ? "Anslået" : (cnt == 1 ? "Ét delt resultat" : cnt + " delte resultater") + " + anslået") + " ud fra " + (d.Item3 == "gpu" ? "spiltests" : "Cinebench") + " · " + d.Item5
                    : (cnt == 1 ? "Ét delt resultat" : cnt + " delte resultater") + " · " + kind + " med " + d.Item5;
                rows.Add(new CompareRow { Name = d.Item1, Mine = d.Item2.ToString("N0", da) + d.Item6, Median = (guess.HasValue ? "≈ " : "") + m.Value.ToString("N0", da) + d.Item6,
                    Diff = (guess.HasValue ? "≈ " : "") + diff.ToString("+0;-0;0", da) + " %" + (diff <= (guess.HasValue ? -20 : -10) ? " ⚠" : diff >= 5 ? " 👍" : ""), Who = who });
            }
            var txt = new List<string>();
            if (rows.Count == 0) txt.Add("Ingen har delt resultater med din processor eller dit grafikkort endnu (Opticon har " + valid.Count + " resultater i alt). Del dit, så er du den første. Indtil da kan du se, hvad andre med samme processor får i Geekbench.");
            else
            {
                if (cpuDiff.HasValue && cpuEst) txt.Add(cpuDiff <= -20 ? "⚠ Din processor ser ud til at være ca. " + Math.Round(-cpuDiff.Value) + " % langsommere end forventet for modellen (anslået). Tjek strømtilstand, køling og programmer i baggrunden." : "✓ Din processor ser ud til at yde som forventet (anslået).");
                else if (cpuDiff.HasValue) txt.Add(cpuDiff <= -10 ? "⚠ Din processor er " + Math.Round(-cpuDiff.Value) + " % langsommere end andre med samme model. Tjek strømtilstand, køling og programmer i baggrunden." : cpuDiff >= 5 ? "👍 Din processor er " + Math.Round(cpuDiff.Value) + " % hurtigere end medianen for samme model." : "✓ Din processor yder som forventet for modellen.");
                if (gpuDiff.HasValue && gpuEst) txt.Add(gpuDiff <= -20 ? "⚠ Dit grafikkort ser ud til at være ca. " + Math.Round(-gpuDiff.Value) + " % langsommere end forventet for kortet (anslået). Tjek driver, strømtilstand og temperatur." : "✓ Dit grafikkort ser ud til at yde som forventet (anslået).");
                else if (gpuDiff.HasValue) txt.Add(gpuDiff <= -10 ? "⚠ Dit grafikkort er " + Math.Round(-gpuDiff.Value) + " % langsommere end andre med samme kort. Tjek driver, strømtilstand og temperatur." : gpuDiff >= 5 ? "👍 Dit grafikkort er " + Math.Round(gpuDiff.Value) + " % hurtigere end medianen for samme kort." : "✓ Dit grafikkort yder som forventet for modellen.");
                txt.Add("Kun resultater fra samme testmetode og samme type pc (" + kind + ", tilsluttet strøm) tæller med.");
                if (cpuEst || gpuEst) txt.Add("≈ Anslået: der er endnu for få delte resultater for din hardware, så Opticon regner et forventet tal ud fra rigtige Opticon-målinger på anden hardware og offentlige tests (Cinebench R23, spiltests). Det er kun vejledende og forsvinder, når der er " + es.MinReal + " rigtige resultater.");
            }
            return Tuple.Create(rows, string.Join("\n", txt));
        }

        /// <summary>Åbner GitHub med et færdigt opslag. Resultatet tilføjes automatisk af projektets GitHub-robot.</summary>
        public static void Share(BenchResult me)
        {
            var data = Payload(me);
            var json = JsonSerializer.Serialize(data);
            var title = "[Opticon-resultat] " + me.CpuName + " / " + me.GpuName;
            var body = "Opticon-resultat. Det bliver tilføjet automatisk, og opslaget lukkes af sig selv.\n\n```json\n" + json + "\n```";
            Process.Start(new ProcessStartInfo("https://github.com/" + Repo + "/issues/new?title=" + Uri.EscapeDataString(title) + "&body=" + Uri.EscapeDataString(body)) { UseShellExecute = true });
            App.Log("Benchmark-resultat sendt til deling");
        }
    }
}
