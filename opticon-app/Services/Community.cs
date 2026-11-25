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
            var rows = new List<CompareRow>(); double? cpuDiff = null, gpuDiff = null;
            foreach (var d in defs)
            {
                var m = Median(d.Item4.Select(e => score(e, d.Item3)));
                if (m == null || d.Item2 <= 0) continue;
                double diff = 100 * (d.Item2 - m.Value) / Math.Max(0.001, m.Value);
                if (d.Item3 == "cpuN") cpuDiff = diff; if (d.Item3 == "gpu") gpuDiff = diff;
                int cnt = d.Item4.Count(e => score(e, d.Item3) > 0);
                rows.Add(new CompareRow { Name = d.Item1, Mine = d.Item2.ToString("N0", da) + d.Item6, Median = m.Value.ToString("N0", da) + d.Item6,
                    Diff = diff.ToString("+0;-0;0", da) + " %" + (diff <= -10 ? " ⚠" : diff >= 5 ? " 👍" : ""), Who = (cnt == 1 ? "Ét delt resultat" : cnt + " delte resultater") + " · " + kind + " med " + d.Item5 });
            }
            var txt = new List<string>();
            if (rows.Count == 0) txt.Add("Ingen har delt resultater med din processor eller dit grafikkort endnu (Opticon har " + valid.Count + " resultater i alt). Del dit, så er du den første. Indtil da kan du se, hvad andre med samme processor får i Geekbench.");
            else
            {
                if (cpuDiff.HasValue) txt.Add(cpuDiff <= -10 ? "⚠ Din processor er " + Math.Round(-cpuDiff.Value) + " % langsommere end andre med samme model. Tjek strømtilstand, køling og programmer i baggrunden." : cpuDiff >= 5 ? "👍 Din processor er " + Math.Round(cpuDiff.Value) + " % hurtigere end medianen for samme model." : "✓ Din processor yder som forventet for modellen.");
                if (gpuDiff.HasValue) txt.Add(gpuDiff <= -10 ? "⚠ Dit grafikkort er " + Math.Round(-gpuDiff.Value) + " % langsommere end andre med samme kort. Tjek driver, strømtilstand og temperatur." : gpuDiff >= 5 ? "👍 Dit grafikkort er " + Math.Round(gpuDiff.Value) + " % hurtigere end medianen for samme kort." : "✓ Dit grafikkort yder som forventet for modellen.");
                txt.Add("Kun resultater fra samme testmetode og samme type pc (" + kind + ", tilsluttet strøm) tæller med.");
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
