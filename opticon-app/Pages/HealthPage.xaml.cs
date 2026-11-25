using System;
using System.Globalization;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Opticon.Services;

namespace Opticon.Pages
{
    public partial class HealthPage : UserControl
    {
        bool loaded, gpuBusy, noGpu;
        readonly DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };

        public HealthPage()
        {
            InitializeComponent();
            timer.Tick += async (s, e) => await UpdateGpu();
            IsVisibleChanged += (s, e) => { if (IsVisible && !noGpu) timer.Start(); else timer.Stop(); };
        }

        public void OnShown() { if (!loaded) { loaded = true; Load(); } }

        void Refresh_Click(object sender, RoutedEventArgs e) { Load(); }

        async void Load()
        {
            await UpdateGpu();
            try { List.ItemsSource = await Task.Run(() => Health.Check()); } catch (Exception ex) { App.Log("Helbred: " + ex); }
            CrashSub.Text = "Læser hændelsesloggen…";
            try
            {
                var c = await Task.Run(() => Health.Crashes());
                CrashList.ItemsSource = c.Rows;
                CrashBig.Text = c.Total.ToString();
                CrashBig.Foreground = DotBrushes.For(c.Total >= 5 ? "#FF5D6C" : c.Total >= 1 ? "#F6C344" : "#4ADE80");
                CrashSub.Text = c.Summary;
            }
            catch (Exception ex) { App.Log("Nedbrud: " + ex); CrashSub.Text = "Kunne ikke læse hændelsesloggen."; }
        }

        async Task UpdateGpu()
        {
            if (gpuBusy || noGpu) return;
            gpuBusy = true;
            try
            {
                var g = await Task.Run(() => Health.Gpu());
                if (g == null) { noGpu = true; timer.Stop(); GpuCard.Visibility = Visibility.Collapsed; return; }
                GpuCard.Visibility = Visibility.Visible;
                GpuTitle.Text = "🎮  " + g.Name + " lige nu";
                GPower.Text = Math.Round(g.Power) + " / " + Math.Round(g.Limit) + " W";
                GTemp.Text = Math.Round(g.Temp) + " °C";
                GFan.Text = Math.Round(g.Fan) + " %";
                GClock.Text = Math.Round(g.Clock) + " MHz";
                GUtil.Text = Math.Round(g.Util) + " %";
            }
            catch { }
            finally { gpuBusy = false; }
        }

        void High_Click(object sender, RoutedEventArgs e) { try { Health.SetPlan(true); App.Log("Strømplan: Høj ydelse"); } catch (Exception ex) { MessageBox.Show(ex.Message); } Load(); }
        void Bal_Click(object sender, RoutedEventArgs e) { try { Health.SetPlan(false); App.Log("Strømplan: Balanceret"); } catch (Exception ex) { MessageBox.Show(ex.Message); } Load(); }

        async void Copy_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                var t = await Task.Run(() => Health.SupportInfo());
                Clipboard.SetText(t);
                MessageBox.Show("Pc-info er kopieret. Sæt den ind (Ctrl+V) i en besked til den, der hjælper dig.\n\n" + t, "Kopieret", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex) { MessageBox.Show("Kunne ikke kopiere: " + ex.Message); }
        }
    }
}
