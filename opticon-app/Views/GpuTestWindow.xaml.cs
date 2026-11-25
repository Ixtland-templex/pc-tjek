using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace Opticon.Views
{
    public class GpuStep { public string Res; public string Label; public double Fps; public double P99; public string PowerMode; public double? Watts; public bool SwitchFailed; }

    public class GpuTestResult
    {
        public List<GpuStep> Steps = new List<GpuStep>();
        public string Renderer = "";
        public string Error;
        public bool Aborted;
    }

    /// <summary>Fuldskærms grafiktest i en indbygget browser (WebView2 + WebGL2). Ingen PowerShell, ingen lokal webserver.</summary>
    public partial class GpuTestWindow : Window
    {
        const double StepSec = 12, StepTimeout = 35;
        readonly List<GpuStep> steps;
        readonly GpuTestResult result = new GpuTestResult();
        readonly TaskCompletionSource<GpuTestResult> tcs = new TaskCompletionSource<GpuTestResult>();
        readonly DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        int cur = -1;
        DateTime stepStart, firstData, lastMsg = DateTime.Now;
        double sumF, sumMs; readonly List<double> p99s = new List<double>();
        bool ready, finished, switching;
        readonly List<double> watts = new List<double>();
        readonly bool battery = Opticon.Services.PowerMode.OnBattery();

        public GpuTestWindow(IEnumerable<GpuStep> steps)
        {
            InitializeComponent();
            this.steps = steps.ToList();
            Loaded += async (s, e) => await Start();
            Closing += (s, e) => { if (!finished) { result.Aborted = true; Finish(); } };
            PreviewKeyDown += (s, e) => { if (e.Key == Key.Escape) { result.Aborted = true; Finish(); } };
            timer.Tick += Tick;
        }

        public Task<GpuTestResult> Result { get { return tcs.Task; } }

        async Task Start()
        {
            try
            {
                var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(App.DataDir, "webview2"),
                    new CoreWebView2EnvironmentOptions("--disable-gpu-vsync --disable-frame-rate-limit"));
                await Web.EnsureCoreWebView2Async(env);
                Web.CoreWebView2.Settings.AreDevToolsEnabled = false;
                Web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
                Web.CoreWebView2.WebMessageReceived += OnMessage;
                string html;
                using (var st = typeof(GpuTestWindow).Assembly.GetManifestResourceStream("gpu-test.html"))
                using (var rd = new StreamReader(st)) html = rd.ReadToEnd();
                Web.NavigateToString(html);
                lastMsg = DateTime.Now;
                timer.Start();
            }
            catch (Exception e)
            {
                App.Log("Grafiktest: kunne ikke starte WebView2: " + e);
                result.Error = "Den indbyggede browser (WebView2) kunne ikke starte: " + e.Message;
                Finish();
            }
        }

        void OnMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            lastMsg = DateTime.Now;
            JsonElement m;
            try { m = JsonDocument.Parse(e.WebMessageAsJson).RootElement; } catch { return; }
            string t = m.TryGetProperty("t", out var tt) ? tt.GetString() : "";
            switch (t)
            {
                case "ready": ready = true; Info.Visibility = Visibility.Collapsed; NextStep(); break;
                case "renderer": result.Renderer = m.GetProperty("r").GetString(); App.Log("Grafiktest: renderer " + result.Renderer); break;
                case "abort": result.Aborted = true; Finish(); break;
                case "lost": result.Error = "Grafikdriveren gik ned eller genstartede under testen."; Finish(); break;
                case "error": result.Error = "Grafiktesten kunne ikke køre: " + m.GetProperty("e").GetString(); Finish(); break;
                case "jserr": App.Log("Grafiktest JS-fejl: " + m.GetProperty("e").GetString()); break;
                case "fps":
                    if (cur < 0 || cur >= steps.Count) break;
                    var res = m.GetProperty("w").GetInt32() + "x" + m.GetProperty("h").GetInt32();
                    if (res != steps[cur].Res) break;   // gammel måling fra forrige opløsning
                    if (switching || (steps[cur].PowerMode != null && (DateTime.Now - stepStart).TotalSeconds < 3)) break;   // lige efter skift af strømtilstand
                    if (firstData == default(DateTime)) firstData = DateTime.Now;
                    sumF += m.GetProperty("f").GetDouble(); sumMs += m.GetProperty("ms").GetDouble();
                    p99s.Add(m.GetProperty("p99").GetDouble());
                    break;
            }
        }

        void NextStep()
        {
            if (cur >= 0 && cur < steps.Count && sumMs > 0)
            {
                steps[cur].Fps = Math.Round(1000 * sumF / sumMs);
                var s = p99s.OrderBy(x => x).ToList();
                steps[cur].P99 = s.Count > 0 ? s[s.Count / 2] : 0;
                if (watts.Count > 0) steps[cur].Watts = Math.Round(watts.Average(), 1);
                result.Steps.Add(steps[cur]);
                App.Log("Grafiktest " + steps[cur].Res + ": " + steps[cur].Fps + " fps");
            }
            cur++;
            sumF = 0; sumMs = 0; p99s.Clear(); lock (watts) watts.Clear(); firstData = default(DateTime); stepStart = DateTime.Now;
            if (cur >= steps.Count) { Finish(); return; }
            var pm = steps[cur].PowerMode;
            if (pm != null)
            {
                switching = true;
                var step = steps[cur];
                Task.Run(() => Opticon.Services.PowerMode.Set(pm)).ContinueWith(t =>
                {
                    step.SwitchFailed = !t.Result;
                    App.Log("Strømtest: " + Opticon.Services.PowerMode.Name(pm) + (t.Result ? " slået til" : " kunne ikke slås til"));
                    switching = false; stepStart = DateTime.Now; lastMsg = DateTime.Now;
                    Send();
                }, TaskScheduler.FromCurrentSynchronizationContext());
            }
            Send();
        }

        void Send()
        {
            if (Web.CoreWebView2 == null) return;
            double remain = 0;
            for (int i = Math.Max(0, cur); i < steps.Count; i++) remain += StepSec + 3;
            if (cur >= 0 && cur < steps.Count) remain -= Math.Min(StepSec + 3, (DateTime.Now - stepStart).TotalSeconds);
            var st = cur >= 0 && cur < steps.Count
                ? new Dictionary<string, object> { { "Res", steps[cur].Res }, { "Label", "Trin " + (cur + 1) + " af " + steps.Count + " · " + (switching ? "skifter strømtilstand…" : steps[cur].Label) }, { "Remain", (int)Math.Max(0, remain) } }
                : new Dictionary<string, object> { { "Done", true } };
            try { Web.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(st)); } catch { }
        }

        void Tick(object sender, EventArgs e)
        {
            if (finished) return;
            if ((DateTime.Now - lastMsg).TotalSeconds > 20) { result.Error = "Grafiktesten holdt op med at svare."; Finish(); return; }
            if (!ready || switching) return;
            Send();
            SampleWatts();
            bool enough = firstData != default(DateTime) && (DateTime.Now - firstData).TotalSeconds >= StepSec;
            bool timeout = (DateTime.Now - stepStart).TotalSeconds > StepTimeout;
            if (enough || timeout) { if (timeout && !enough) App.Log("Grafiktest: trin " + (cur >= 0 && cur < steps.Count ? steps[cur].Res : "?") + " nåede ikke at måle færdigt"); NextStep(); }
        }

        bool sampling;
        void SampleWatts()
        {
            if (sampling || cur < 0 || cur >= steps.Count || (DateTime.Now - stepStart).TotalSeconds < 3) return;
            sampling = true;
            Task.Run(() => Opticon.Services.PowerMode.Watts(battery)).ContinueWith(t =>
            {
                sampling = false;
                if (t.Status == TaskStatus.RanToCompletion && t.Result.HasValue && !switching) lock (watts) watts.Add(t.Result.Value);
            });
        }

        void Finish()
        {
            if (finished) return;
            finished = true;
            timer.Stop();
            try { Web.CoreWebView2?.PostWebMessageAsJson("{\"Done\":true}"); } catch { }
            tcs.TrySetResult(result);
            Dispatcher.BeginInvoke(new Action(() => { try { Close(); } catch { } }), DispatcherPriority.Background);
        }
    }
}
