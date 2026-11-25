using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Opticon.Services;

namespace Opticon.Pages
{
    public partial class ToolsPage : UserControl
    {
        bool loaded;
        List<PickRow> ads, bloat, installs;

        public ToolsPage() { InitializeComponent(); }

        public void OnShown() { if (!loaded) { loaded = true; Load(); } }

        async void Load()
        {
            RestoreSub.Text += " " + await Task.Run(() => RestorePoint.Last());
            LoadAds();
            try { bloat = await Task.Run(() => Bloat.Installed()); BloatList.ItemsSource = bloat; if (bloat.Count == 0) { BloatSub.Text = "✓ Ingen af de typiske forudinstallerede apps er på pc'en."; BtnBloat.IsEnabled = false; } }
            catch (Exception ex) { App.Log("Forudinstallerede apps: " + ex); BloatSub.Text = "Kunne ikke læse apps: " + ex.Message; }
            try { installs = await Task.Run(() => Installs.Rows()); InstallList.ItemsSource = installs; } catch (Exception ex) { App.Log("Programmer: " + ex); }
            try
            {
                var bats = await Task.Run(() => Battery.Read());
                if (bats.Count > 0)
                {
                    var b = bats[0]; var da = new CultureInfo("da-DK");
                    BatCard.Visibility = Visibility.Visible;
                    BatBig.Text = Math.Round(b.Health) + " % af den oprindelige kapacitet";
                    BatBig.Foreground = DotBrushes.For(b.Health >= 80 ? "#4ADE80" : b.Health >= 60 ? "#F6C344" : "#FF5D6C");
                    BatText.Text = string.Format(da, "{0}: kan nu holde {1:N0} mWh af de oprindelige {2:N0} mWh{3}. ", b.Name, b.Full, b.Design, b.Cycles > 0 ? " · " + b.Cycles + " opladninger" : "") +
                        (b.Health >= 80 ? "Batteriet er sundt." : b.Health >= 60 ? "Batteriet er slidt og holder mærkbart kortere end som nyt. Helt normalt efter et par år." : "Batteriet er meget slidt. Overvej at få det skiftet, især hvis pc'en slukker uventet.") +
                        " Tip: lader du altid op til 100 % og har den i stik hele dagen, så slå \"Smart opladning\" eller \"Batteribeskyttelse\" (80 %) til i producentens app (fx Lenovo Vantage).";
                }
            }
            catch (Exception ex) { App.Log("Batteri: " + ex.Message); }
        }

        async void LoadAds()
        {
            ads = await Task.Run(() => Ads.Rows());
            AdsList.ItemsSource = ads;
            int on = ads.Count(a => a.Installed);
            AdsSub.Text = on == 0 ? "✓ Alle reklamer og forslag er slået fra." : on + " af " + ads.Count + " er slået til. Slå dem fra med ét klik. Kan altid sættes tilbage.";
            BtnAdsUndo.Visibility = Ads.HasBackup ? Visibility.Visible : Visibility.Collapsed;
        }

        void Ads_Click(object sender, RoutedEventArgs e)
        {
            var sel = ads.Where(a => a.Selected && a.Installed).Select(a => a.Id).ToList();
            if (sel.Count == 0) return;
            try { Ads.TurnOff(sel); MessageBox.Show("✓ " + sel.Count + " ting er slået fra. Nogle træder først i kraft, når du logger ud og ind igen.", "Opticon", MessageBoxButton.OK, MessageBoxImage.Information); }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Opticon"); }
            LoadAds();
        }

        void AdsUndo_Click(object sender, RoutedEventArgs e)
        {
            try { Ads.Restore(); MessageBox.Show("Indstillingerne er sat tilbage, som de var.", "Opticon"); } catch (Exception ex) { MessageBox.Show(ex.Message, "Opticon"); }
            LoadAds();
        }

        async void Restore_Click(object sender, RoutedEventArgs e)
        {
            if (!Admin.IsElevated)
            {
                if (MessageBox.Show("Det kræver administrator at lave et gendannelsespunkt.\n\nGenstarte Opticon som administrator nu?", "Opticon", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes) Admin.RestartElevated("--page tools");
                return;
            }
            BtnRestore.IsEnabled = false; RestoreSub.Text = "Laver gendannelsespunkt (kan tage et minut)…";
            try { var m = await Task.Run(() => RestorePoint.Create("Opticon " + DateTime.Now.ToString("dd-MM-yyyy HH:mm"))); RestoreSub.Text = m + " " + await Task.Run(() => RestorePoint.Last()); }
            catch (Exception ex) { RestoreSub.Text = (ex.InnerException ?? ex).Message; }
            BtnRestore.IsEnabled = true;
        }

        void Rstrui_Click(object sender, RoutedEventArgs e)
        {
            try { Process.Start(new ProcessStartInfo(System.IO.Path.Combine(Environment.SystemDirectory, "rstrui.exe")) { UseShellExecute = true }); } catch (Exception ex) { MessageBox.Show(ex.Message); }
        }

        async void Bloat_Click(object sender, RoutedEventArgs e)
        {
            var sel = bloat.Where(b => b.Selected && b.Installed).ToList();
            if (sel.Count == 0) return;
            if (MessageBox.Show("Disse apps fjernes for din bruger:\n\n" + string.Join("\n", sel.Select(s => "•  " + s.Name)) + "\n\nDe kan hentes igen gratis i Microsoft Store. Fortsæt?", "Fjern apps", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            BtnBloat.IsEnabled = false;
            foreach (var b in sel) { b.Status = "Fjerner…"; var r = b; b.Status = await Task.Run(() => Bloat.Remove(r)); if (b.Status.StartsWith("✓")) b.Installed = false; }
            BtnBloat.IsEnabled = true;
            BloatSub.Text = "Færdig. Fjernede apps forsvinder fra listen næste gang, du åbner siden.";
        }

        async void Install_Click(object sender, RoutedEventArgs e)
        {
            var sel = installs.Where(i => i.Selected && !i.Installed).ToList();
            if (sel.Count == 0) { MessageBox.Show("Sæt flueben ved de programmer, du vil installere (dem, der ikke allerede er installeret).", "Opticon"); return; }
            BtnInstall.IsEnabled = false;
            int n = 0;
            foreach (var i in sel)
            {
                n++; InstallSub.Text = "Installerer " + i.Name + " (" + n + " af " + sel.Count + ")… Windows kan spørge om lov.";
                i.Status = "Installerer…"; var id = i.Id;
                i.Status = await Task.Run(() => Installs.Install(id));
                if (i.Status.StartsWith("✓")) { i.Installed = true; i.Selected = false; }
            }
            InstallSub.Text = "Færdig. Programmerne ligger i Start-menuen.";
            BtnInstall.IsEnabled = true;
        }

        void BatReport_Click(object sender, RoutedEventArgs e) { try { Battery.OpenReport(); } catch (Exception ex) { MessageBox.Show(ex.Message); } }

        async void Net_Click(object sender, RoutedEventArgs e)
        {
            BtnNet.IsEnabled = false;
            try
            {
                var r = await Task.Run(() => NetTest.Run(s => Dispatcher.BeginInvoke(new Action(() => NetSub.Text = s))));
                NetSub.Text = "Forbindelse: " + r.Item1;
                NetList.ItemsSource = r.Item2;
                NetAdvice.Text = string.Join("\n", r.Item3.Select(a => a.StartsWith("✓") ? a : "💡 " + a));
                App.Log("Netværkstest: " + r.Item1 + " · " + string.Join(" | ", r.Item2.Select(x => x.Target + " " + x.Result)));
            }
            catch (Exception ex) { NetSub.Text = "Testen fejlede: " + ex.Message; }
            BtnNet.IsEnabled = true;
        }
    }
}
