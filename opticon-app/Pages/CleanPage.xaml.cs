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
    public partial class CleanPage : UserControl
    {
        readonly List<CleanRow> rows = Cleanup.Categories();
        bool measured;

        public CleanPage()
        {
            InitializeComponent();
            CleanList.ItemsSource = rows;
            BtnAdmin.Visibility = Admin.IsElevated ? Visibility.Collapsed : Visibility.Visible;
        }

        public void OnShown() { }

        void Admin_Click(object sender, RoutedEventArgs e) { Admin.RestartElevated("--page clean"); }

        void Sel_Changed(object sender, RoutedEventArgs e) { UpdateSum(); }

        void UpdateSum()
        {
            if (!measured) return;
            long all = rows.Where(r => r.Bytes > 0).Sum(r => r.Bytes), sel = rows.Where(r => r.Selected && r.Bytes > 0).Sum(r => r.Bytes);
            CleanSum.Text = "I alt " + Cleanup.Fmt(all) + " kan ryddes · valgt: " + Cleanup.Fmt(sel);
            BtnClean.IsEnabled = rows.Any(r => r.Selected);
        }

        async void Measure_Click(object sender, RoutedEventArgs e)
        {
            BtnMeasure.IsEnabled = false; BtnClean.IsEnabled = false;
            CleanSum.Text = "Måler…";
            foreach (var r in rows) { r.Status = ""; r.Bytes = -1; }
            foreach (var r in rows)
            {
                var row = r;
                row.Bytes = await Task.Run(() => { try { return Cleanup.Measure(row); } catch (Exception ex) { App.Log("Mål " + row.Id + ": " + ex.Message); return 0L; } });
            }
            measured = true;
            BtnMeasure.IsEnabled = true;
            UpdateSum();
        }

        async void Clean_Click(object sender, RoutedEventArgs e)
        {
            var sel = rows.Where(r => r.Selected).ToList();
            if (sel.Count == 0) return;
            if (sel.Any(r => r.Id == "browser") && Cleanup.BrowserRunning() &&
                MessageBox.Show("Chrome eller Edge kører. Browsercachen kan kun ryddes, når browseren er lukket.\n\nLuk den nu, og tryk OK. Eller tryk Annullér.", "Luk browseren", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
            if (sel.Any(r => r.Id == "recycle") &&
                MessageBox.Show("Papirkurven tømmes PERMANENT. Fortsæt?", "Bekræft", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;

            BtnClean.IsEnabled = false; BtnMeasure.IsEnabled = false;
            long total = 0; int skipped = 0;
            foreach (var r in sel)
            {
                var row = r;
                row.Status = "Rydder op…";
                var res = await Task.Run(() => { try { return Cleanup.Clean(row); } catch (Exception ex) { App.Log("Ryd " + row.Id + ": " + ex.Message); return Tuple.Create(0L, 0); } });
                total += res.Item1; skipped += res.Item2;
                row.Status = "✓ " + Cleanup.Fmt(res.Item1) + " frigjort" + (res.Item2 > 0 ? " · " + res.Item2 + " filer i brug sprunget over" : "");
                row.Bytes = await Task.Run(() => { try { return Cleanup.Measure(row); } catch { return 0L; } });
            }
            App.Log("Oprydning: " + Cleanup.Fmt(total) + " frigjort, " + skipped + " sprunget over");
            CleanSum.Text = "Færdig: " + Cleanup.Fmt(total) + " frigjort." + (skipped > 0 ? " Filer, som et program bruger lige nu, blev sprunget over." : "");
            BtnMeasure.IsEnabled = true; BtnClean.IsEnabled = true;
        }

        async void Space_Click(object sender, RoutedEventArgs e)
        {
            BtnSpace.IsEnabled = false;
            SpaceSum.Text = "Måler… (kan tage et par minutter første gang)";
            try
            {
                var res = await Task.Run(() => SpaceScan.Run(s => Dispatcher.BeginInvoke(new Action(() => SpaceSum.Text = s))));
                SpaceList.ItemsSource = res.Rows;
                SpaceSum.Text = res.Drive + (res.PrevDate.HasValue ? " · sammenlignet med " + res.PrevDate.Value.ToString("d. MMM 'kl.' HH:mm", new System.Globalization.CultureInfo("da-DK")) : " · første måling, næste gang ser du hvad der er vokset") + (res.Partial ? " · stoppet efter 2½ minut, tallene er for lave" : "");
            }
            catch (Exception ex) { App.Log("Hvad fylder: " + ex); SpaceSum.Text = "Målingen fejlede: " + ex.Message; }
            BtnSpace.IsEnabled = true;
        }

        void OpenFolder_Click(object sender, RoutedEventArgs e)
        {
            var p = (string)((Button)sender).Tag;
            try { Process.Start(new ProcessStartInfo("explorer.exe", "\"" + p + "\"") { UseShellExecute = true }); } catch { }
        }

        List<FileRow> files;

        void FileSel_Changed(object sender, RoutedEventArgs e) { UpdateFilesSum(); }

        void UpdateFilesSum()
        {
            if (files == null) return;
            var sel = files.Where(f => f.Selected).ToList();
            FilesSum.Text = files.Count + " filer fundet · valgt: " + sel.Count + " (" + Cleanup.Fmt(sel.Sum(f => f.Size)) + ")";
            BtnFilesDel.IsEnabled = sel.Count > 0;
        }

        async void Files_Click(object sender, RoutedEventArgs e)
        {
            BtnFiles.IsEnabled = false; BtnFilesDel.IsEnabled = false;
            FilesSum.Text = "Leder…";
            try
            {
                files = await Task.Run(() => FileFinder.Run(s => Dispatcher.BeginInvoke(new Action(() => FilesSum.Text = s))));
                FilesList.ItemsSource = files;
                if (files.Count == 0) FilesSum.Text = "Ingen dubletter, gamle installere eller store filer fundet. 👍";
                else UpdateFilesSum();
            }
            catch (Exception ex) { App.Log("Filer: " + ex); FilesSum.Text = "Fejl: " + ex.Message; }
            BtnFiles.IsEnabled = true;
        }

        async void FilesDel_Click(object sender, RoutedEventArgs e)
        {
            var sel = files.Where(f => f.Selected).ToList();
            if (MessageBox.Show(sel.Count + " filer (" + Cleanup.Fmt(sel.Sum(f => f.Size)) + ") lægges i papirkurven. Du kan hente dem tilbage derfra.\n\nFortsæt?", "Opticon", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            BtnFilesDel.IsEnabled = false;
            int ok = await Task.Run(() => FileFinder.ToRecycleBin(sel.Select(f => f.FullPath)));
            App.Log("Filer i papirkurven: " + ok + " af " + sel.Count);
            files = files.Where(f => System.IO.File.Exists(f.FullPath)).ToList();
            FilesList.ItemsSource = files;
            UpdateFilesSum();
            FilesSum.Text = ok + " filer lagt i papirkurven. " + FilesSum.Text;
        }

        void ShowFile_Click(object sender, RoutedEventArgs e)
        {
            var p = (string)((Button)sender).Tag;
            try { Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + p + "\"") { UseShellExecute = true }); } catch { }
        }
    }
}
