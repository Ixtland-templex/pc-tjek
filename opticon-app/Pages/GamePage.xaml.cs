using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Opticon.Services;
using Opticon.Views;

namespace Opticon.Pages
{
    public partial class GamePage : UserControl
    {
        bool loaded, running;

        public GamePage()
        {
            InitializeComponent();
            var last = BenchRunner.History().LastOrDefault();
            if (last != null) Show(last, null, "Sidste måling " + last.Date.ToString("d. MMM 'kl.' HH:mm", new CultureInfo("da-DK")));
        }

        public void OnShown() { if (!loaded) { loaded = true; LoadSettings(); } }

        async void LoadSettings()
        {
            try { SetList.ItemsSource = await Task.Run(() => GameSettings.Check()); }
            catch (Exception e) { App.Log("Spilindstillinger: " + e); }
        }

        void Refresh_Click(object sender, RoutedEventArgs e) { LoadSettings(); }

        void Fix_Click(object sender, RoutedEventArgs e)
        {
            var it = (SecItem)((Button)sender).Tag;
            try { MessageBox.Show(GameSettings.Fix(it.Fix), "Opticon", MessageBoxButton.OK, MessageBoxImage.Information); }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Opticon", MessageBoxButton.OK, MessageBoxImage.Warning); }
            LoadSettings();
        }

        void Open_Click(object sender, RoutedEventArgs e)
        {
            var it = (SecItem)((Button)sender).Tag;
            try { Process.Start(new ProcessStartInfo(it.Uri) { UseShellExecute = true }); } catch { }
        }

        static List<GpuStep> GpuSteps()
        {
            var list = new List<GpuStep> { new GpuStep { Res = "1920x1080", Label = "1080p" } };
            string nat = "";
            try { nat = BenchRunner.NativeRes(); } catch { }
            if (nat.Length > 0 && nat != "1920x1080" && nat != "3840x2160") list.Add(new GpuStep { Res = nat, Label = "din skærm (" + nat.Replace("x", "×") + ")" });
            list.Add(new GpuStep { Res = "3840x2160", Label = "4K" });
            return list;
        }

        async void Bench_Click(object sender, RoutedEventArgs e) { await RunBench(true); }
        async void GpuOnly_Click(object sender, RoutedEventArgs e) { await RunBench(false); }

        async Task RunBench(bool full)
        {
            if (running) return;
            running = true;
            BtnBench.IsEnabled = false; BtnGpuOnly.IsEnabled = false;
            BenchBar.Visibility = Visibility.Visible; BenchBar.Value = 0;
            var prev = BenchRunner.History().LastOrDefault(x => x.Score > 0);
            BenchResult r;
            try
            {
                if (full)
                {
                    var prog = new Progress<Tuple<double, string>>(p => { BenchBar.Value = p.Item1; BenchSub.Text = p.Item2; });
                    IProgress<Tuple<double, string>> ip = prog;
                    r = await Task.Run(() => BenchRunner.RunCpuRamDisk((pc, txt) => ip.Report(Tuple.Create(pc, txt))));
                }
                else
                {
                    var last = BenchRunner.History().LastOrDefault();
                    r = new BenchResult { Date = DateTime.Now, OnBattery = PowerMode.OnBattery() };
                    if (last != null) { r.Cpu1 = last.Cpu1; r.CpuN = last.CpuN; r.Sustain = last.Sustain; r.Ram = last.Ram; r.DiskR = last.DiskR; r.DiskW = last.DiskW; r.Iops = last.Iops; }
                }

                BenchSub.Text = "Grafik · fuldskærmstest (Esc stopper den)…"; BenchBar.Value = 90;
                var w = new GpuTestWindow(GpuSteps());
                w.Show();
                var g = await w.Result;
                Activate();
                var s1080 = g.Steps.FirstOrDefault(x => x.Res == "1920x1080");
                var s4k = g.Steps.FirstOrDefault(x => x.Res == "3840x2160");
                var sNat = g.Steps.FirstOrDefault(x => x.Res != "1920x1080" && x.Res != "3840x2160");
                r.Gpu = s1080 != null ? s1080.Fps : 0;
                r.Gpu4K = s4k != null ? s4k.Fps : 0;
                if (sNat != null) { r.GpuNative = sNat.Fps; r.GpuNativeRes = sNat.Res; }
                r.Renderer = g.Renderer;
                r.GpuNote = g.Error ?? (g.Aborted ? "Grafiktesten blev stoppet" : null);
                if (!string.IsNullOrEmpty(g.Renderer) && System.Text.RegularExpressions.Regex.IsMatch(g.Renderer, "SwiftShader|Basic Render|llvmpipe", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                    r.GpuNote = "Testen kørte på processoren i stedet for grafikkortet (" + g.Renderer + "). Opdatér grafikdriveren.";
                r.Version = typeof(App).Assembly.GetName().Version.ToString(3);
                r.Score = BenchRunner.Total(r);
                if (full || r.Gpu > 0) BenchRunner.Save(r);
                App.Log("Benchmark: " + (r.Score > 0 ? r.Score + " point" : "delvis") + (r.GpuNote != null ? " · " + r.GpuNote : ""));
                Show(r, prev, null);
            }
            catch (Exception ex)
            {
                App.Log("Benchmark fejlede: " + ex);
                BenchSub.Text = "Benchmark fejlede: " + ex.Message;
            }
            finally
            {
                running = false; BtnBench.IsEnabled = true; BtnGpuOnly.IsEnabled = true; BenchBar.Visibility = Visibility.Collapsed;
            }
        }

        void Activate() { var w = Window.GetWindow(this); if (w != null) w.Activate(); }

        void Show(BenchResult r, BenchResult prev, string header)
        {
            Tiles.Visibility = Visibility.Visible;
            var da = new CultureInfo("da-DK");
            TScore.Text = r.Score > 0 ? r.Score.ToString("N0", da) : "–";
            TScoreSub.Text = r.Score > 0 ? (prev != null && prev.Score > 0 ? string.Format("sidst {0:N0} ({1:+0;-0;0} %)", prev.Score, 100.0 * (r.Score - prev.Score) / prev.Score) : "1.000 = referencepc") : "ikke alle dele blev målt";
            TCpu.Text = r.Cpu1 > 0 ? string.Format(da, "{0:N0} / {1:N0}", r.Cpu1, r.CpuN) : "–";
            TCpuSub.Text = r.Cpu1 > 0 ? "én kerne / alle · holder " + r.Sustain + " % varm" : "";
            TRam.Text = r.Ram > 0 ? r.Ram.ToString("0.0", da) + " GB/s" : "–";
            TDisk.Text = r.DiskR > 0 ? string.Format(da, "{0:N0} MB/s", r.DiskR) : "–";
            TDiskSub.Text = r.DiskR > 0 ? string.Format(da, "læs · skriv {0:N0} MB/s · {1:N0} små læsninger/s", r.DiskW, r.Iops) : "";
            var parts = new List<string>();
            if (r.Gpu > 0) parts.Add(string.Format(da, "1080p: {0:N0}", r.Gpu));
            if (r.GpuNative > 0) parts.Add(string.Format(da, "{0}: {1:N0}", (r.GpuNativeRes ?? "").Replace("x", "×"), r.GpuNative));
            if (r.Gpu4K > 0) parts.Add(string.Format(da, "4K: {0:N0}", r.Gpu4K));
            TGpu.Text = parts.Count > 0 ? string.Join("   ·   ", parts) : "–";
            TGpuSub.Text = r.GpuNote ?? (string.IsNullOrEmpty(r.Renderer) ? "" : r.Renderer);
            BenchSub.Text = header ?? ("✓ Færdig" + (r.OnBattery ? " · målt på batteri, så tallene er lavere end med oplader" : ""));
        }

        // ---------- Strømtest ----------
        async void Power_Click(object sender, RoutedEventArgs e)
        {
            if (running) return;
            var orig = PowerMode.Current();
            if (orig == null) { PowerSub.Text = "Windows' strømtilstand kunne ikke læses på denne pc, så strømtesten kan ikke køre."; return; }
            running = true; BtnPower.IsEnabled = false; BtnBench.IsEnabled = false;
            bool battery = PowerMode.OnBattery();
            var modes = new[] { "961cc777-2547-4f9d-8174-7d86181b8a7a", "00000000-0000-0000-0000-000000000000", "3af9b8d9-7c97-431d-ad78-34a8bfea439f", "ded574b5-45a0-4f42-8737-46345c09c238" };
            var steps = modes.Select(m => new GpuStep { Res = "1920x1080", Label = PowerMode.Name(m), PowerMode = m }).ToList();
            PowerSub.Text = "Strømtesten kører i fuld skærm (Esc stopper den)…";
            GpuTestResult g = null;
            try
            {
                var w = new GpuTestWindow(steps);
                w.Show();
                g = await w.Result;
            }
            catch (Exception ex) { App.Log("Strømtest: " + ex); }
            finally
            {
                // Sæt altid strømtilstanden tilbage
                bool back = await Task.Run(() => PowerMode.Set(orig));
                App.Log("Strømtest: tilbage til " + PowerMode.Name(orig) + (back ? "" : " (kunne ikke bekræftes)"));
                Activate();
                running = false; BtnPower.IsEnabled = true; BtnBench.IsEnabled = true;
            }
            if (g == null) { PowerSub.Text = "Strømtesten fejlede."; return; }
            var da = new CultureInfo("da-DK");
            var rows = new List<Tuple<string, string, string, string>> { Tuple.Create("Strømtilstand", "FPS", battery ? "Batteri" : "Grafikkort", "FPS pr. watt") };
            foreach (var st in g.Steps)
                rows.Add(Tuple.Create(st.Label + (st.SwitchFailed ? " (kunne ikke slås til)" : ""), st.Fps.ToString("N0", da),
                    st.Watts.HasValue ? st.Watts.Value.ToString("0.0", da) + " W" : "–",
                    st.Watts.HasValue && st.Watts > 0 ? (st.Fps / st.Watts.Value).ToString("0.0", da) : "–"));
            PowerList.ItemsSource = rows;
            var ok = g.Steps.Where(x => !x.SwitchFailed && x.Fps > 0).ToList();
            string verdict = "";
            if (ok.Count >= 2)
            {
                var best = ok.OrderByDescending(x => x.Fps).First(); var low = ok.OrderBy(x => x.Fps).First();
                double gain = 100.0 * (best.Fps - low.Fps) / Math.Max(1, low.Fps);
                verdict = gain < 5 ? "Strømtilstanden gør næsten ingen forskel for grafikken på denne pc (under 5 %). Vælg gerne Balanceret." :
                    string.Format(da, "{0} er {1:0} % hurtigere end {2}.", best.Label, gain, low.Label);
                var eff = ok.Where(x => x.Watts > 0).OrderByDescending(x => x.Fps / x.Watts.Value).FirstOrDefault();
                if (eff != null) verdict += " Mest effektiv: " + eff.Label + ".";
            }
            PowerSub.Text = (g.Error ?? (g.Aborted ? "Strømtesten blev stoppet. " : "✓ Færdig. ")) + verdict + " Strømtilstanden er sat tilbage til " + PowerMode.Name(orig) + "." + (battery ? "" : " (Strømforbrug måles på batteri eller med et NVIDIA-kort.)");
        }

        // ---------- Mål i mit spil og "Hjalp det?" ----------
        GameResult abBefore;

        int Seconds() { return GameDur.SelectedIndex == 0 ? 30 : GameDur.SelectedIndex == 2 ? 120 : 60; }

        bool NeedAdmin()
        {
            if (Admin.IsElevated) return false;
            if (MessageBox.Show("\"Mål i mit spil\" bruger Windows' målesystem, som kræver administrator.\n\nGenstarte Opticon som administrator nu?", "Opticon", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                Admin.RestartElevated("--page game");
            return true;
        }

        async Task<GameResult> Measure(string phase)
        {
            int secs = Seconds();
            BtnGame.IsEnabled = false; BtnAb.IsEnabled = false; GameDur.IsEnabled = false;
            try
            {
                var prog = new Progress<string>(t => GameSub.Text = (phase != null ? phase + " · " : "") + t);
                IProgress<string> ip = prog;
                return await Task.Run(() => GameMeasure.Run(secs, (t, f) => ip.Report(t)));
            }
            catch (Exception ex)
            {
                var msg = ex is AggregateException && ex.InnerException != null ? ex.InnerException.Message : ex.Message;
                App.Log("Mål i mit spil: " + ex);
                GameSub.Text = "Målingen fejlede: " + msg;
                return null;
            }
            finally { BtnGame.IsEnabled = true; BtnAb.IsEnabled = true; GameDur.IsEnabled = true; }
        }

        async void Game_Click(object sender, RoutedEventArgs e)
        {
            if (NeedAdmin()) return;
            var r = await Measure(null);
            if (r == null) return;
            GameSub.Text = "✓ Målt " + r.Seconds.ToString("0") + " sek. (" + r.Frames + " billeder)";
            GameText.Text = GameMeasure.Describe(r);
        }

        async void Ab_Click(object sender, RoutedEventArgs e)
        {
            if (NeedAdmin()) return;
            if (abBefore == null)
            {
                MessageBox.Show("\"Hjalp det i mit spil?\" måler to gange: før og efter en ændring (fx en grafikindstilling, en ny driver eller en Opticon-rettelse).\n\n1. Start spillet, og stil dig et sted, hvor du kan gøre det samme begge gange.\n2. Tryk OK, og skift til spillet. Første måling starter om 10 sek.", "Hjalp det?", MessageBoxButton.OK, MessageBoxImage.Information);
                abBefore = await Measure("Før");
                if (abBefore == null) return;
                BtnAb.Content = "Mål efter";
                GameSub.Text = "✓ Før-målingen er gemt. Lav din ændring, gå tilbage til samme sted i spillet, og tryk \"Mål efter\".";
                GameText.Text = "Før: " + GameMeasure.Describe(abBefore);
                return;
            }
            var after = await Measure("Efter");
            var before = abBefore;
            abBefore = null; BtnAb.Content = "Hjalp det?";
            if (after == null) return;
            var da = new CultureInfo("da-DK");
            double dFps = 100.0 * (after.Fps - before.Fps) / Math.Max(1, before.Fps);
            double dLow = 100.0 * (after.Low1 - before.Low1) / Math.Max(1, before.Low1);
            double noise = 100.0 * 2 * Math.Max(GameMeasure.Noise(before), GameMeasure.Noise(after));
            string verdict = Math.Abs(dFps) <= noise ? "Ingen sikker forskel: ændringen ligger inden for, hvad FPS svinger af sig selv (±" + noise.ToString("0", da) + " %)."
                : dFps > 0 ? "✓ Det hjalp: " + dFps.ToString("+0;-0", da) + " % FPS." : "✗ Det blev langsommere: " + dFps.ToString("+0;-0", da) + " % FPS.";
            GameSub.Text = "✓ Før og efter er målt";
            GameText.Text = verdict + "\n\n" +
                string.Format(da, "FPS: {0:0} → {1:0} ({2:+0;-0;0} %)\n1 % low: {3:0} → {4:0} ({5:+0;-0;0} %)\nHak pr. minut: {6:0.#} → {7:0.#}", before.Fps, after.Fps, dFps, before.Low1, after.Low1, dLow, before.HakMin, after.HakMin) +
                (before.Game != after.Game ? "\n\n⚠ De to målinger er fra forskellige spil (" + before.Game + " og " + after.Game + ")." : "");
            App.Log("Hjalp det: " + dFps.ToString("0.0", CultureInfo.InvariantCulture) + " % FPS, støj " + noise.ToString("0.0", CultureInfo.InvariantCulture) + " %");
        }
    }
}
