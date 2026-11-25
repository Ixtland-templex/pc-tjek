using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Opticon.Services;

namespace Opticon.Pages
{
    public partial class TweaksPage : UserControl
    {
        bool loaded;
        List<StartupItem> items;

        public TweaksPage() { InitializeComponent(); }

        public void OnShown() { if (!loaded) { loaded = true; Load(); } }

        void Refresh_Click(object sender, RoutedEventArgs e) { Load(); }

        async void Load()
        {
            Sum.Text = "Tjekker…";
            try
            {
                var cards = await Task.Run(() => Tweaks.Check());
                Cards.ItemsSource = cards;
                int tips = cards.Count(c => c.State == "tip");
                Sum.Text = tips == 0 ? "✓ Ingen glemt ydelse fundet. Intet ændres, uden at du selv gør det." : "💡 " + tips + (tips == 1 ? " ting" : " ting") + " kan give mere ydelse. Intet ændres, uden at du selv gør det.";
            }
            catch (Exception ex) { App.Log("Optimering: " + ex); Sum.Text = "Fejl: " + ex.Message; }
            await LoadStartup();
        }

        async Task LoadStartup()
        {
            try
            {
                items = await Task.Run(() => StartupApps.List());
                StartList.ItemsSource = items;
                int on = items.Count(i => i.On), can = items.Count(i => i.On && i.CanDisable);
                StartSum.Text = on + " af " + items.Count + " programmer starter automatisk" + (can > 0 ? " · " + can + " kan uden videre slås fra" : "") + ". Til/fra virker som i Jobliste: intet slettes.";
                BtnFast.IsEnabled = can > 0;
            }
            catch (Exception ex) { App.Log("Opstart: " + ex); StartSum.Text = "Fejl: " + ex.Message; }
        }

        async void Toggle_Click(object sender, RoutedEventArgs e)
        {
            var it = (StartupItem)((Button)sender).Tag;
            try
            {
                StartupApps.Set(it, !it.On);
                App.Log("Opstart " + it.Name + " -> " + (!it.On ? "til" : "fra"));
            }
            catch (UnauthorizedAccessException)
            {
                if (MessageBox.Show("Programmer for alle brugere kræver administrator.\n\nGenstarte Opticon som administrator nu?", "Opticon", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes) Admin.RestartElevated("--page tweaks");
                return;
            }
            catch (Exception ex) { MessageBox.Show("Det lykkedes ikke: " + ex.Message, "Opticon", MessageBoxButton.OK, MessageBoxImage.Warning); }
            await LoadStartup();
        }

        async void Fast_Click(object sender, RoutedEventArgs e)
        {
            var sel = items.Where(i => i.On && i.CanDisable).ToList();
            if (sel.Count == 0) return;
            if (MessageBox.Show("Disse programmer starter ikke længere automatisk:\n\n" + string.Join("\n", sel.Select(i => "•  " + i.Name)) + "\n\nDu kan stadig åbne dem selv, og du kan slå dem til igen her.", "Gør opstarten hurtigere", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            int fail = 0;
            foreach (var it in sel) { try { StartupApps.Set(it, false); } catch { fail++; } }
            App.Log("Opstart: " + (sel.Count - fail) + " slået fra");
            if (fail > 0) MessageBox.Show(fail + " programmer kunne ikke slås fra (de gælder alle brugere og kræver administrator).", "Opticon", MessageBoxButton.OK, MessageBoxImage.Information);
            await LoadStartup();
        }

        void Action_Click(object sender, RoutedEventArgs e)
        {
            var id = ((Button)sender).Tag as string ?? "";
            try
            {
                if (id == "display") Open("ms-settings:display");
                else if (id == "bios")
                {
                    if (!Admin.IsElevated)
                    {
                        if (MessageBox.Show("Det kræver administrator at genstarte direkte til BIOS.\n\nGenstarte Opticon som administrator nu?", "Opticon", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes) Admin.RestartElevated("--page tweaks");
                        return;
                    }
                    if (MessageBox.Show("Pc'en genstarter nu direkte til BIOS. Gem dit arbejde først.\n\nGenstart nu?", "Genstart til BIOS", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
                    var p = Process.Start(new ProcessStartInfo(System.IO.Path.Combine(Environment.SystemDirectory, "shutdown.exe"), "/r /fw /t 0") { UseShellExecute = false, CreateNoWindow = true });
                    p.WaitForExit(5000);
                    if (p.HasExited && p.ExitCode != 0) MessageBox.Show("Pc'en kan ikke genstarte direkte til BIOS (kræver UEFI). Genstart, og tryk gentagne gange på Del eller F2, mens den starter.", "Opticon");
                }
                else if (id.StartsWith("gpudriver:"))
                {
                    var gpu = id.Substring(10).ToLowerInvariant();
                    if (gpu.Contains("nvidia")) Open("https://www.nvidia.com/da-dk/software/nvidia-app/");
                    else if (gpu.Contains("amd") || gpu.Contains("radeon")) Open("https://www.amd.com/en/support/download/drivers.html");
                    else if (gpu.Contains("qualcomm") || gpu.Contains("adreno") || gpu.Contains("snapdragon")) Open("https://www.qualcomm.com/products/mobile/snapdragon/pcs-and-tablets/software/snapdragon-control-panel");
                    else if (gpu.Contains("intel")) Open("https://www.intel.com/content/www/us/en/support/detect.html");
                    else Open("ms-settings:windowsupdate");
                }
                else if (id.StartsWith("biossearch:")) Open("https://www.google.com/search?q=" + Uri.EscapeDataString(id.Substring(11) + " BIOS download"));
            }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Opticon"); }
        }

        static void Open(string url) { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
    }
}
