using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Win32;
using Opticon.Services;

namespace Opticon.Pages
{
    public partial class ModesPage : UserControl
    {
        readonly DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        int focusMin = 45;

        public ModesPage()
        {
            InitializeComponent();
            timer.Tick += (s, e) => ShowActive();
            IsVisibleChanged += (s, e) => { if (IsVisible) timer.Start(); else timer.Stop(); };
        }

        public void OnShown() { LoadGames(); ShowActive(); }

        void LoadGames()
        {
            GameList.ItemsSource = Modes.Games();
            if (!Vagt.Enabled) GameSub.Text = "Lukker de programmer, du har valgt, og slår beskeder fra, mens du spiller. Tryk \"Start nu\", eller slå Vagten til under Sikkerhed, så starter spil-tilstanden af sig selv, når spillet åbnes, og slutter, når det lukkes.";
        }

        void ShowActive()
        {
            var s = Modes.Current();
            if (s == null) { ActiveCard.Visibility = Visibility.Collapsed; return; }
            ActiveCard.Visibility = Visibility.Visible;
            if (s.Mode == "Spil")
            {
                ActiveTitle.Text = "🎮  Spil-tilstand er aktiv: " + s.Name;
                ActiveSub.Text = (s.Closed.Count > 0 ? "Lukkede: " + string.Join(", ", s.Closed.Select(c => c.Name)) + " (startes igen bagefter). " : "") + (s.NotClosed.Count > 0 ? "Kunne ikke lukkes: " + string.Join(", ", s.NotClosed) + ". " : "") + (s.PrevToast.HasValue ? "Beskeder er slået fra. " : "") + "Slutter, når spillet lukkes.";
            }
            else
            {
                var left = s.Until.HasValue ? s.Until.Value - DateTime.Now : TimeSpan.Zero;
                ActiveTitle.Text = "🎯  Fokus er aktiv" + (left > TimeSpan.Zero ? " · " + (int)left.TotalMinutes + " min tilbage" : "");
                ActiveSub.Text = (s.Sites.Count > 0 ? "Blokerer: " + string.Join(", ", s.Sites) + ". " : "") + (s.PrevToast.HasValue ? "Beskeder er slået fra." : "");
                if (left <= TimeSpan.Zero) { Stop("tiden var gået"); }
            }
        }

        void Stop(string reason)
        {
            try
            {
                var s = Modes.Current();
                if (s != null && s.Sites != null && s.Sites.Count > 0 && Modes.HostsBlocked && !Admin.IsElevated)
                {
                    ActiveSub.Text = "Fokus er slut, men sideblokeringen kan kun fjernes som administrator. Tryk \"Afslut nu\".";
                    return;
                }
                var msg = Modes.Stop(reason);
                if (!string.IsNullOrEmpty(msg)) MessageBox.Show(msg, "Opticon", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Opticon"); }
            ShowActive();
        }

        void Stop_Click(object sender, RoutedEventArgs e)
        {
            var s = Modes.Current();
            if (s != null && s.Sites != null && s.Sites.Count > 0 && Modes.HostsBlocked && !Admin.IsElevated)
            {
                if (MessageBox.Show("Sideblokeringen kan kun fjernes som administrator.\n\nGenstarte Opticon som administrator nu?", "Opticon", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes) Admin.RestartElevated("--page modes");
                return;
            }
            Stop("afsluttet af dig");
        }

        void Add_Click(object sender, RoutedEventArgs e)
        {
            var dlg = new OpenFileDialog { Title = "Vælg spillets programfil (.exe)", Filter = "Programmer (*.exe)|*.exe" };
            var steam = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) as string;
            if (!string.IsNullOrEmpty(steam)) dlg.InitialDirectory = System.IO.Path.Combine(steam.Replace('/', '\\'), @"steamapps\common");
            if (dlg.ShowDialog() != true) return;
            var exe = System.IO.Path.GetFileNameWithoutExtension(dlg.FileName);
            string name = System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(dlg.FileName)) ?? exe;
            var running = Modes.RunningApps().Where(a => !a.Equals(exe, StringComparison.OrdinalIgnoreCase)).ToList();
            var w = new Window { Title = "Hvad skal lukkes, mens du spiller " + name + "?", Width = 460, SizeToContent = SizeToContent.Height, WindowStartupLocation = WindowStartupLocation.CenterOwner, Owner = Window.GetWindow(this), Background = DotBrushes.For("#141821"), Foreground = DotBrushes.For("#E7E9EE"), ResizeMode = ResizeMode.NoResize };
            var sp = new StackPanel { Margin = new Thickness(18) };
            sp.Children.Add(new TextBlock { Text = "Sæt flueben ved de programmer, der skal lukkes, når " + name + " starter. Listen viser det, der er åbent lige nu. Programmerne startes igen bagefter.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10), Foreground = DotBrushes.For("#9AA3B5") });
            var boxes = new List<CheckBox>();
            foreach (var a in running) { var cb = new CheckBox { Content = a, Margin = new Thickness(0, 3, 0, 3), IsChecked = System.Text.RegularExpressions.Regex.IsMatch(a, "chrome|msedge|firefox|teams|onedrive|spotify|outlook", System.Text.RegularExpressions.RegexOptions.IgnoreCase) }; boxes.Add(cb); sp.Children.Add(cb); }
            if (running.Count == 0) sp.Children.Add(new TextBlock { Text = "Ingen andre programmer er åbne lige nu.", Foreground = DotBrushes.For("#9AA3B5") });
            var mute = new CheckBox { Content = "Slå beskeder fra, mens jeg spiller", IsChecked = true, Margin = new Thickness(0, 12, 0, 0) };
            sp.Children.Add(mute);
            var ok = new Button { Content = "Gem", Style = (Style)FindResource("Primary"), HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0), IsDefault = true };
            ok.Click += (s2, e2) => w.DialogResult = true;
            sp.Children.Add(ok);
            w.Content = sp;
            if (w.ShowDialog() != true) return;
            var games = Modes.Games();
            games.RemoveAll(g => g.Exe.Equals(exe, StringComparison.OrdinalIgnoreCase));
            games.Add(new GameProfile { Name = name, Exe = exe, Path = dlg.FileName, Close = boxes.Where(b => b.IsChecked == true).Select(b => (string)b.Content).ToList(), Mute = mute.IsChecked == true });
            Modes.SaveGames(games);
            App.Log("Spil tilføjet til spil-tilstand: " + name);
            LoadGames();
        }

        void Remove_Click(object sender, RoutedEventArgs e)
        {
            var g = (GameProfile)((Button)sender).Tag;
            var games = Modes.Games(); games.RemoveAll(x => x.Exe == g.Exe); Modes.SaveGames(games);
            LoadGames();
        }

        async void StartGame_Click(object sender, RoutedEventArgs e)
        {
            var g = (GameProfile)((Button)sender).Tag;
            var s = await Task.Run(() => Modes.StartGame(g, false));
            if (s == null) MessageBox.Show("En anden tilstand er allerede aktiv. Afslut den først.", "Opticon");
            ShowActive();
        }

        void Dur_Click(object sender, RoutedEventArgs e)
        {
            focusMin = focusMin == 25 ? 45 : focusMin == 45 ? 60 : focusMin == 60 ? 90 : focusMin == 90 ? 120 : 25;
            Dur.Content = "⏱  " + focusMin + " min";
        }

        void Focus_Click(object sender, RoutedEventArgs e)
        {
            var sites = Sites.Text.Split(new[] { ',', ' ', ';', '\n' }, StringSplitOptions.RemoveEmptyEntries).ToList();
            try { Modes.StartFocus(focusMin, ChkMute.IsChecked == true, sites); }
            catch (UnauthorizedAccessException)
            {
                var r = MessageBox.Show("Blokering af sider kræver administrator.\n\nJa: genstart Opticon som administrator.\nNej: start fokus uden at blokere sider.", "Opticon", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
                if (r == MessageBoxResult.Yes) { Admin.RestartElevated("--page modes"); return; }
                if (r == MessageBoxResult.No) { try { Modes.StartFocus(focusMin, ChkMute.IsChecked == true, null); } catch (Exception ex) { MessageBox.Show(ex.Message); } }
            }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Opticon"); }
            ShowActive();
        }
    }
}
