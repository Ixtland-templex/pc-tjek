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
        const string RepoUrl = "https://github.com/Ixtland-templex/pc-tjek";

        public MainWindow()
        {
            InitializeComponent();
            var v = typeof(App).Assembly.GetName().Version;
            string ver = v.Major + "." + v.Minor + "." + v.Build;
            VersionText.Text = "Version " + ver + " (preview)" + (Services.Admin.IsElevated ? "\nKører som administrator" : "");
            AboutVersion.Text = "Opticon " + ver + " (preview)";
            AboutData.Text = "Log og indstillinger: " + App.DataDir;
            Loaded += async (s, e) =>
            {
                var args = Environment.GetCommandLineArgs();
                if (Array.IndexOf(args, "security") >= 0) NavSecurity.IsChecked = true;
                else if (Array.IndexOf(args, "clean") >= 0) NavClean.IsChecked = true;
                await LoadOverview();
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
            var rb = (RadioButton)sender;
            if (rb == NavOverview) PageOverview.Visibility = Visibility.Visible;
            else if (rb == NavSecurity) { PageSecurity.Visibility = Visibility.Visible; PageSecurity.OnShown(); }
            else if (rb == NavClean) { PageClean.Visibility = Visibility.Visible; PageClean.OnShown(); }
            else if (rb == NavGame) { PageGame.Visibility = Visibility.Visible; PageGame.OnShown(); }
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
    }
}
