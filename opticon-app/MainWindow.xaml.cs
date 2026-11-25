using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Opticon.Services;

namespace Opticon
{
    public partial class MainWindow : Window
    {
        [System.Runtime.InteropServices.DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
        const string RepoUrl = "https://github.com/Ixtland-templex/pc-tjek";

        public MainWindow()
        {
            InitializeComponent();
            var v = typeof(App).Assembly.GetName().Version;
            string ver = v.Major + "." + v.Minor + "." + v.Build;
            VersionText.Text = "Version " + ver + " (preview)" + (Services.Admin.IsElevated ? "\nKører som administrator" : "");
            AboutVersion.Text = "Opticon " + ver + " (preview)";
            AboutData.Text = "Log og indstillinger: " + App.DataDir;
            SetupTray();
            ChkTray.IsChecked = Settings.Current.CloseToTray;
            SourceInitialized += (s, e) =>
            {
                // Mørk titellinje, så den passer til resten af appen
                try
                {
                    var h = new System.Windows.Interop.WindowInteropHelper(this).Handle;
                    int on = 1; DwmSetWindowAttribute(h, 20, ref on, 4);
                    int col = 0x00140F0D; DwmSetWindowAttribute(h, 35, ref col, 4);
                }
                catch { }
            };
            Loaded += async (s, e) =>
            {
                var args = Environment.GetCommandLineArgs();
                if (Array.IndexOf(args, "security") >= 0) NavSecurity.IsChecked = true;
                else if (Array.IndexOf(args, "clean") >= 0) NavClean.IsChecked = true;
                else if (Array.IndexOf(args, "game") >= 0) NavGame.IsChecked = true;
                else if (Array.IndexOf(args, "tweaks") >= 0) NavTweaks.IsChecked = true;
                else if (Array.IndexOf(args, "modes") >= 0) NavModes.IsChecked = true;
                // Tilstande: rydder op efter et nedbrud og afslutter fokus, når tiden er gået (også uden Vagten)
                var modeTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
                modeTimer.Tick += async (s2, e2) => await Task.Run(() => Modes.Tick(false));
                modeTimer.Start();
                await LoadOverview();
                await Task.Delay(4000);
                await CheckUpdate(false);
            };
        }

        async Task LoadOverview()
        {
            PcInfo i;
            try { i = await Task.Run(() => SystemInfo.Read()); }
            catch (Exception e) { App.Log("Overblik: " + e); TxtWindows.Text = "Kunne ikke læse systeminfo"; return; }
            TxtWindows.Text = i.Windows.Length > 0 ? i.Windows : "Windows";
            TxtBuild.Text = i.Build + (i.Uptime.Length > 0 ? " · " + i.Uptime : "") + " · " + i.Arch;
            TxtBoard.Text = i.Board;
            TxtCpu.Text = i.Cpu;
            TxtCpuDetail.Text = i.CpuDetail;
            TxtGpu.Text = i.Gpus.Count > 0 ? string.Join("\n", i.Gpus) : "Ikke fundet";
            TxtRam.Text = i.Ram + " RAM · " + i.RamUsedPct + " % i brug";
            BarRam.Value = i.RamUsedPct;
            TxtDisk.Text = "C: " + i.Disk;
            BarDisk.Value = 100 - i.DiskFreePct;
        }

        void Nav_Checked(object sender, RoutedEventArgs e)
        {
            if (PageOverview == null) return;   // kaldes én gang, før vinduet er bygget færdigt
            PageOverview.Visibility = Visibility.Collapsed;
            PageSoon.Visibility = Visibility.Collapsed;
            PageAbout.Visibility = Visibility.Collapsed;
            PageSecurity.Visibility = Visibility.Collapsed;
            PageClean.Visibility = Visibility.Collapsed;
            PageGame.Visibility = Visibility.Collapsed;
            PageUpdates.Visibility = Visibility.Collapsed;
            PageTweaks.Visibility = Visibility.Collapsed;
            PageModes.Visibility = Visibility.Collapsed;
            PageHealth.Visibility = Visibility.Collapsed;
            PageTimeline.Visibility = Visibility.Collapsed;
            var rb = (RadioButton)sender;
            if (rb == NavOverview) PageOverview.Visibility = Visibility.Visible;
            else if (rb == NavSecurity) { PageSecurity.Visibility = Visibility.Visible; PageSecurity.OnShown(); }
            else if (rb == NavClean) { PageClean.Visibility = Visibility.Visible; PageClean.OnShown(); }
            else if (rb == NavGame) { PageGame.Visibility = Visibility.Visible; PageGame.OnShown(); }
            else if (rb == NavUpdates) { PageUpdates.Visibility = Visibility.Visible; PageUpdates.OnShown(); }
            else if (rb == NavTweaks) { PageTweaks.Visibility = Visibility.Visible; PageTweaks.OnShown(); }
            else if (rb == NavModes) { PageModes.Visibility = Visibility.Visible; PageModes.OnShown(); }
            else if (rb == NavHealth) { PageHealth.Visibility = Visibility.Visible; PageHealth.OnShown(); }
            else if (rb == NavTimeline) { PageTimeline.Visibility = Visibility.Visible; PageTimeline.OnShown(); }
            else if (rb == NavAbout) PageAbout.Visibility = Visibility.Visible;
            else
            {
                SoonTitle.Text = (string)rb.Tag;
                SoonText.Text = "Den her del flyttes over fra den gamle Opticon i en af de næste versioner. Indtil da kan du bruge den gamle app til det.";
                PageSoon.Visibility = Visibility.Visible;
            }
        }

        void OpenLog_Click(object sender, RoutedEventArgs e)
        {
            try { Directory.CreateDirectory(App.DataDir); Process.Start(new ProcessStartInfo("explorer.exe", "\"" + App.DataDir + "\"") { UseShellExecute = true }); } catch { }
        }

        void OpenGitHub_Click(object sender, RoutedEventArgs e)
        {
            try { Process.Start(new ProcessStartInfo(RepoUrl) { UseShellExecute = true }); } catch { }
        }

        // ---------- Ikon ved uret ----------
        System.Windows.Forms.NotifyIcon tray;

        void SetupTray()
        {
            try
            {
                tray = new System.Windows.Forms.NotifyIcon { Text = "Opticon", Visible = true };
                try { tray.Icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath); } catch { tray.Icon = System.Drawing.SystemIcons.Shield; }
                var menu = new System.Windows.Forms.ContextMenuStrip();
                menu.Items.Add("Åbn Opticon", null, (s, e) => ShowFromTray());
                menu.Items.Add("Scan pc'en", null, (s, e) => { ShowFromTray(); NavSecurity.IsChecked = true; });
                menu.Items.Add("Ryd op", null, (s, e) => { ShowFromTray(); NavClean.IsChecked = true; });
                menu.Items.Add("Tilstande", null, (s, e) => { ShowFromTray(); NavModes.IsChecked = true; });
                menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
                menu.Items.Add("Afslut Opticon", null, (s, e) => { App.Exiting = true; Application.Current.Shutdown(); });
                tray.ContextMenuStrip = menu;
                tray.MouseClick += (s, e) => { if (e.Button == System.Windows.Forms.MouseButtons.Left) ShowFromTray(); };
            }
            catch (Exception e) { App.Log("Ikon ved uret: " + e.Message); }
        }

        public void ShowFromTray()
        {
            Show();
            if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
            Activate(); Topmost = true; Topmost = false; Focus();
        }

        protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
        {
            if (!App.Exiting && Settings.Current.CloseToTray && tray != null)
            {
                e.Cancel = true;
                Hide();
                if (!Settings.Current.TrayTipShown)
                {
                    tray.ShowBalloonTip(5000, "Opticon kører videre", "Opticon ligger nu som et ikon ved uret. Klik på det for at åbne, eller højreklik for at afslutte.", System.Windows.Forms.ToolTipIcon.Info);
                    Settings.Current.TrayTipShown = true; Settings.Save();
                }
                return;
            }
            base.OnClosing(e);
        }

        protected override void OnClosed(EventArgs e)
        {
            if (tray != null) { tray.Visible = false; tray.Dispose(); }
            base.OnClosed(e);
            Application.Current.Shutdown();
        }

        void Tray_Changed(object sender, RoutedEventArgs e)
        {
            Settings.Current.CloseToTray = ChkTray.IsChecked == true; Settings.Save();
        }

        UpdateInfo pending;

        async Task CheckUpdate(bool manual)
        {
            try
            {
                if (manual) { BtnCheckUpdate.IsEnabled = false; BtnCheckUpdate.Content = "Søger…"; }
                pending = await Updater.Check();
                if (pending != null)
                {
                    BtnUpdate.Content = "⬇  Opdatér til " + pending.Version.ToString(3);
                    BtnUpdate.Visibility = Visibility.Visible;
                    if (manual) Update_Click(null, null);
                }
                else if (manual) MessageBox.Show("Du har den nyeste version.", "Opticon", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception e)
            {
                App.Log("Søg efter opdatering: " + e.Message);
                if (manual) MessageBox.Show("Kunne ikke søge efter opdateringer: " + e.Message, "Opticon", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            finally { if (manual) { BtnCheckUpdate.IsEnabled = true; BtnCheckUpdate.Content = "Søg efter opdatering"; } }
        }

        async void CheckUpdate_Click(object sender, RoutedEventArgs e) { await CheckUpdate(true); }

        async void Update_Click(object sender, RoutedEventArgs e)
        {
            if (pending == null) return;
            var notes = string.IsNullOrWhiteSpace(pending.Notes) ? "" : "\n\n" + (pending.Notes.Length > 600 ? pending.Notes.Substring(0, 600) + "…" : pending.Notes);
            if (MessageBox.Show("Opticon " + pending.Version.ToString(3) + " er klar." + notes + "\n\nOpdatér nu? Opticon lukker kort og starter igen.", "Ny version", MessageBoxButton.YesNo, MessageBoxImage.Information) != MessageBoxResult.Yes) return;
            BtnUpdate.IsEnabled = false;
            try { await Updater.Install(pending, new Progress<string>(t => BtnUpdate.Content = t)); }
            catch (Exception ex)
            {
                App.Log("Opdatering fejlede: " + ex);
                MessageBox.Show("Opdateringen blev ikke installeret:\n\n" + ex.Message, "Opdatering", MessageBoxButton.OK, MessageBoxImage.Warning);
                BtnUpdate.IsEnabled = true; BtnUpdate.Content = "⬇  Opdatér til " + pending.Version.ToString(3);
            }
        }
    }
}
