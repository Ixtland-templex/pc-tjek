using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Opticon.Services;

namespace Opticon.Pages
{
    public partial class TimelinePage : UserControl
    {
        bool loaded;
        List<TimeEvent> all = new List<TimeEvent>();
        string filter = "Alle";

        public TimelinePage() { InitializeComponent(); }

        public void OnShown() { if (!loaded) { loaded = true; Load(); } }

        void Refresh_Click(object sender, RoutedEventArgs e) { Load(); }

        async void Load()
        {
            Sum.Text = "Læser Windows' logfiler…";
            try { all = await Task.Run(() => Timeline.Read(14)); }
            catch (Exception ex) { App.Log("Hændelsesforløb: " + ex); Sum.Text = "Fejl: " + ex.Message; return; }
            Filters.Children.Clear();
            foreach (var t in new[] { "Alle", "Vigtige" }.Concat(all.Select(e => e.Type).Distinct().OrderBy(x => x)))
            {
                var b = new Button { Content = t, Tag = t, Margin = new Thickness(0, 0, 8, 6) };
                if (t == filter) b.Style = (Style)FindResource("Primary");
                b.Click += (s, e) => { filter = (string)((Button)s).Tag; Load2(); };
                Filters.Children.Add(b);
            }
            Show();
            if (!Admin.IsElevated) Sum.Text += " Kør som administrator for også at se Defenders og opgavestyringens hændelser.";
        }

        void Load2()
        {
            foreach (Button b in Filters.Children) b.Style = (string)b.Tag == filter ? (Style)FindResource("Primary") : (Style)FindResource(typeof(Button));
            Show();
        }

        void Show()
        {
            var list = filter == "Alle" ? all : filter == "Vigtige" ? all.Where(e => e.Level <= 1).ToList() : all.Where(e => e.Type == filter).ToList();
            List.ItemsSource = list;
            Sum.Text = list.Count + " hændelser" + (filter == "Alle" ? "" : " · " + filter.ToLower()) + ". Røde og gule er værd at kigge på.";
        }
    }
}
