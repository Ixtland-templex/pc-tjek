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
        bool loaded, busy;

        public SecurityPage()
        {
            InitializeComponent();
            BtnAdmin.Visibility = Admin.IsElevated ? Visibility.Collapsed : Visibility.Visible;
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
    }
}
