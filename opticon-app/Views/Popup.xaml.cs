using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Threading;

namespace Opticon.Views
{
    /// <summary>Lille besked nederst til højre fra Vagten.</summary>
    public partial class Popup : Window
    {
        static readonly List<Popup> open = new List<Popup>();
        readonly string file;

        public Popup(string icon, string title, string body, string file, int autoCloseSec)
        {
            InitializeComponent();
            this.file = file;
            TitleText.Text = icon + "  " + title;
            BodyText.Text = body;
            if (!string.IsNullOrEmpty(file)) BtnShow.Visibility = Visibility.Visible;
            Loaded += (s, e) => { open.Add(this); Place(); };
            Closed += (s, e) => { open.Remove(this); Place(); };
            if (autoCloseSec > 0)
            {
                var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(autoCloseSec) };
                t.Tick += (s, e) => { t.Stop(); Close(); };
                t.Start();
            }
        }

        static void Place()
        {
            var wa = SystemParameters.WorkArea;
            double y = wa.Bottom;
            foreach (var p in open.ToList())
            {
                p.UpdateLayout();
                y -= p.ActualHeight;
                p.Left = wa.Right - p.Width;
                p.Top = y;
            }
        }

        void Close_Click(object sender, RoutedEventArgs e) { Close(); }

        void Open_Click(object sender, RoutedEventArgs e)
        {
            try { Process.Start(new ProcessStartInfo(Environment.ProcessPath) { UseShellExecute = true }); } catch { }
            Close();
        }

        void Show_Click(object sender, RoutedEventArgs e)
        {
            try { Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + file + "\"") { UseShellExecute = true }); } catch { }
        }
    }
}
