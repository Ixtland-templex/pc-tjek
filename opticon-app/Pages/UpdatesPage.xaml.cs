using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Opticon.Services;

namespace Opticon.Pages
{
    public partial class UpdatesPage : UserControl
    {
        List<AppUpdate> items;
        bool loaded, busy;

        public UpdatesPage() { InitializeComponent(); }

        public async void OnShown() { if (!loaded) { loaded = true; await Check(); } }

        async void Check_Click(object sender, RoutedEventArgs e) { await Check(); }

        async Task Check()
        {
            if (busy) return;
            busy = true; BtnCheck.IsEnabled = false; BtnUpgrade.IsEnabled = false;
            Sum.Text = "Spørger winget om opdateringer (kan tage et minut)…";
            try
            {
                items = await Task.Run(() => WingetUpdates.List());
                List.ItemsSource = items;
                Sum.Text = items.Count == 0 ? "✓ Alle programmer er opdaterede." : items.Count + " programmer kan opdateres.";
                BtnUpgrade.IsEnabled = items.Any(i => i.Selected);
            }
            catch (Exception ex) { App.Log("winget: " + ex.Message); Sum.Text = ex.Message; }
            finally { busy = false; BtnCheck.IsEnabled = true; }
        }

        void Sel_Changed(object sender, RoutedEventArgs e) { if (items != null && !busy) BtnUpgrade.IsEnabled = items.Any(i => i.Selected); }

        async void Upgrade_Click(object sender, RoutedEventArgs e)
        {
            var sel = items.Where(i => i.Selected).ToList();
            if (sel.Count == 0) return;
            busy = true; BtnUpgrade.IsEnabled = false; BtnCheck.IsEnabled = false;
            int n = 0;
            foreach (var it in sel)
            {
                n++;
                Sum.Text = "Opdaterer " + it.Name + " (" + n + " af " + sel.Count + ")… Windows kan spørge om lov.";
                it.Status = "Opdaterer…";
                var item = it;
                try { it.Status = await Task.Run(() => WingetUpdates.Upgrade(item.Id)); }
                catch (Exception ex) { it.Status = "Fejl: " + ex.Message; }
            }
            Sum.Text = "Færdig. Tryk \"Søg efter opdateringer\" for at se, om der er flere.";
            busy = false; BtnCheck.IsEnabled = true;
        }
    }
}
