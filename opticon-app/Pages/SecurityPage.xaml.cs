using System;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Opticon.Services;

namespace Opticon.Pages
{
    public partial class SecurityPage : UserControl
    {
        bool loaded, busy, scanning;
        ScanResult lastScan;

        public SecurityPage()
        {
            InitializeComponent();
            BtnAdmin.Visibility = Admin.IsElevated ? Visibility.Collapsed : Visibility.Visible;
            vagtInit = true; ChkVagt.IsChecked = Vagt.Enabled; vagtInit = false;
            ShowVagt();
            ShowMb();
        }

        void ShowMb()
        {
            bool has = MbKey.Get() != null;
            BtnMbRemove.Visibility = has ? Visibility.Visible : Visibility.Collapsed;
            MbBox.Visibility = has ? Visibility.Collapsed : Visibility.Visible;
            BtnMbSave.Visibility = MbBox.Visibility;
            if (has) MbSub.Text = "✓ Nøglen er gemt (krypteret, kun din bruger kan læse den). Scan pc'en slår nu usignerede filer op i MalwareBazaar.";
        }

        void MbOpen_Click(object sender, RoutedEventArgs e) { try { Process.Start(new ProcessStartInfo("https://auth.abuse.ch/") { UseShellExecute = true }); } catch { } }

        async void MbSave_Click(object sender, RoutedEventArgs e)
        {
            var key = MbBox.Password.Trim();
            if (key.Length < 20) { MessageBox.Show("Nøglen ser for kort ud. Kopiér hele nøglen fra auth.abuse.ch.", "Opticon", MessageBoxButton.OK, MessageBoxImage.Warning); return; }
            BtnMbSave.IsEnabled = false;
            string err;
            try { err = await Task.Run(() => MbKey.Test(key)); } catch (Exception ex) { err = "Kunne ikke nå MalwareBazaar: " + (ex.InnerException ?? ex).Message; }
            if (err == null)
            {
                try { MbKey.Save(key); MbBox.Password = ""; MessageBox.Show("Nøglen virker og er gemt.", "Opticon", MessageBoxButton.OK, MessageBoxImage.Information); }
                catch (Exception ex) { MessageBox.Show("Nøglen virker, men kunne ikke gemmes: " + ex.Message, "Opticon", MessageBoxButton.OK, MessageBoxImage.Warning); }
            }
            else MessageBox.Show(err, "Opticon", MessageBoxButton.OK, MessageBoxImage.Warning);
            BtnMbSave.IsEnabled = true;
            ShowMb();
        }

        void MbRemove_Click(object sender, RoutedEventArgs e)
        {
            MbKey.Remove();
            MbSub.Text = "Nøglen er fjernet.";
            ShowMb();
        }

        bool vagtInit;

        void ShowVagt()
        {
            if (Vagt.Enabled) VagtSub.Text = "Kører stille i baggrunden og starter, når du logger ind. Den giver besked om farlige downloads og nye programmer, der starter automatisk." + (Vagt.IsRunning ? "" : " (Starter ved næste login.)");
        }

        void Vagt_Changed(object sender, RoutedEventArgs e)
        {
            if (vagtInit) return;
            try { Vagt.SetEnabled(ChkVagt.IsChecked == true); App.Log("Vagten " + (ChkVagt.IsChecked == true ? "slået til" : "slået fra")); }
            catch (Exception ex) { MessageBox.Show("Kunne ikke ændre Vagten: " + ex.Message, "Opticon", MessageBoxButton.OK, MessageBoxImage.Warning); }
            ShowVagt();
        }

        /// <summary>Kaldes, når siden vises. Tjekker kun automatisk første gang.</summary>
        public async void OnShown()
        {
            if (!loaded) await Check();
        }

        async Task Check()
        {
            if (busy) return;
            busy = true; loaded = true;
            BtnRefresh.IsEnabled = false;
            SumBig.Text = "…"; SumTitle.Text = "Tjekker Windows' beskyttelse…"; SumSub.Text = "";
            try
            {
                var r = await Task.Run(() => SecurityCheck.Run());
                List.ItemsSource = r.Items;
                int red = r.Items.Count(i => i.Level == 0), yellow = r.Items.Count(i => i.Level == 1), green = r.Items.Count(i => i.Level == 2);
                int total = red + yellow + green;
                SumBig.Text = green + "/" + total;
                SumTitle.Text = red > 0 ? (red == 1 ? "1 vigtig ting bør rettes" : red + " vigtige ting bør rettes")
                              : yellow > 0 ? (yellow == 1 ? "God beskyttelse · 1 forslag" : "God beskyttelse · " + yellow + " forslag")
                              : "Alt ser godt ud";
                SumSub.Text = green + " af " + total + " punkter er i orden" + (r.Elevated ? "" : ". Et par punkter kan kun ses som administrator.");
                App.Log("Sikkerhedstjek: " + red + " røde, " + yellow + " gule, " + green + " grønne");
            }
            catch (Exception e)
            {
                App.Log("Sikkerhedstjek fejlede: " + e);
                SumTitle.Text = "Tjekket fejlede"; SumSub.Text = e.Message;
            }
            finally { busy = false; BtnRefresh.IsEnabled = true; }
        }

        async void Refresh_Click(object sender, RoutedEventArgs e) { await Check(); }

        void Admin_Click(object sender, RoutedEventArgs e)
        {
            Admin.RestartElevated("--page security");
        }

        async void Fix_Click(object sender, RoutedEventArgs e)
        {
            var it = (SecItem)((Button)sender).Tag;
            if (!Admin.IsElevated)
            {
                if (MessageBox.Show("Det kræver administrator at rette \"" + it.Name + "\".\n\nGenstarte Opticon som administrator nu? Windows spørger om lov.", "Opticon", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                    Admin.RestartElevated("--page security");
                return;
            }
            if (MessageBox.Show(it.Name + "\n\n" + it.How + "\n\nVil du rette det nu?", "Opticon", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            ((Button)sender).IsEnabled = false;
            string msg; bool ok = true;
            try { msg = await Task.Run(() => SecurityFix.Apply(it.Fix)); }
            catch (Exception ex) { ok = false; msg = ex.Message; App.Log("Rettelse " + it.Fix + " fejlede: " + ex); }
            MessageBox.Show(msg, "Opticon", MessageBoxButton.OK, ok ? MessageBoxImage.Information : MessageBoxImage.Warning);
            await Check();
        }

        void Open_Click(object sender, RoutedEventArgs e)
        {
            var it = (SecItem)((Button)sender).Tag;
            try { Process.Start(new ProcessStartInfo(it.Uri) { UseShellExecute = true }); }
            catch (Exception ex) { App.Log("Åbn " + it.Uri + ": " + ex.Message); }
        }

        async void Scan_Click(object sender, RoutedEventArgs e)
        {
            if (scanning) return;
            scanning = true; BtnScan.IsEnabled = false;
            ScanBar.Visibility = Visibility.Visible; ScanBar.Value = 0;
            ScanSum.Text = "Scanner…";
            try
            {
                var prog = new Progress<Tuple<double, string>>(p => { if (p.Item1 >= 0) ScanBar.Value = p.Item1; ScanSum.Text = p.Item2; });
                IProgress<Tuple<double, string>> ip = prog;
                var key = MbKey.Get();
                lastScan = await Task.Run(() => MalwareScan.Run((pc, t) => ip.Report(Tuple.Create(pc, t)), true, key));
                int crit = lastScan.Finds.Count(f => f.Level >= 4), high = lastScan.Finds.Count(f => f.Level == 3), mid = lastScan.Finds.Count(f => f.Level == 2);
                ScanSum.Text = (crit > 0 ? "⛔ " + crit + " kritiske fund. Se dem herunder." : high > 0 ? "⚠ " + high + " fund bør tjekkes." : mid > 0 ? "Ingen tegn på malware. " + mid + " ting er værd at kigge på." : "✓ Ingen tegn på malware fundet.")
                    + " " + lastScan.Checked + " ting tjekket." + (lastScan.Elevated ? "" : " Kør som administrator for at se Defenders fund og undtagelser.");
                App.Log("Scan: " + crit + " kritiske, " + high + " høje, " + mid + " mellem, " + lastScan.Checked + " tjekket");
                ChkAll.Visibility = Visibility.Visible;
                ShowScan();
            }
            catch (Exception ex) { App.Log("Scan fejlede: " + ex); ScanSum.Text = "Scanningen fejlede: " + ex.Message; }
            finally { scanning = false; BtnScan.IsEnabled = true; ScanBar.Visibility = Visibility.Collapsed; }
        }

        void ChkAll_Changed(object sender, RoutedEventArgs e) { ShowScan(); }

        void ShowScan()
        {
            if (lastScan == null) return;
            ScanList.ItemsSource = ChkAll.IsChecked == true ? lastScan.Finds : lastScan.Finds.Where(f => f.Level >= 2).ToList();
        }

        async void Quick_Click(object sender, RoutedEventArgs e)
        {
            BtnQuick.IsEnabled = false;
            var old = ScanSum.Text;
            ScanSum.Text = "Microsoft Defender scanner de steder, malware typisk gemmer sig. Det tager normalt 1-5 minutter…";
            try
            {
                var r = await Task.Run(() => MalwareScan.DefenderQuickScan());
                ScanSum.Text = r.Item2;
                MessageBox.Show(r.Item2, "Defender-hurtigscanning", MessageBoxButton.OK, r.Item1 ? MessageBoxImage.Warning : MessageBoxImage.Information);
            }
            catch (Exception ex) { ScanSum.Text = old; MessageBox.Show("Scanningen kunne ikke starte: " + ex.Message, "Opticon", MessageBoxButton.OK, MessageBoxImage.Warning); }
            BtnQuick.IsEnabled = true;
        }

        void ShowFile_Click(object sender, RoutedEventArgs e)
        {
            var f = (ScanFind)((Button)sender).Tag;
            try { Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + f.FilePath + "\"") { UseShellExecute = true }); } catch { }
        }

        async void VirusTotal_Click(object sender, RoutedEventArgs e)
        {
            var f = (ScanFind)((Button)sender).Tag;
            try
            {
                // Kun filens fingeraftryk (SHA-256) sendes med i adressen, aldrig selve filen
                string hash = await Task.Run(() =>
                {
                    using (var sha = System.Security.Cryptography.SHA256.Create())
                    using (var st = System.IO.File.OpenRead(f.FilePath))
                        return BitConverter.ToString(sha.ComputeHash(st)).Replace("-", "").ToLowerInvariant();
                });
                Process.Start(new ProcessStartInfo("https://www.virustotal.com/gui/file/" + hash) { UseShellExecute = true });
            }
            catch (Exception ex) { MessageBox.Show("Kunne ikke læse filen: " + ex.Message, "Opticon", MessageBoxButton.OK, MessageBoxImage.Warning); }
        }
    }
}
