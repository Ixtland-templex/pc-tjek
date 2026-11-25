using System;
using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace Opticon
{
    public partial class App : Application
    {
        public static readonly string DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Opticon");

        public static bool VagtMode;
        public static bool Exiting;
        static System.Threading.Mutex single;

        public static void Log(string msg)
        {
            try
            {
                Directory.CreateDirectory(DataDir);
                File.AppendAllText(Path.Combine(DataDir, "opticon.log"), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + Environment.NewLine);
            }
            catch { }
        }

        protected override void OnStartup(StartupEventArgs e)
        {
            DispatcherUnhandledException += OnUiError;
            AppDomain.CurrentDomain.UnhandledException += (s, a) => Log("Fejl: " + a.ExceptionObject);
            base.OnStartup(e);
            if (Array.IndexOf(e.Args, "--vagt") >= 0)
            {
                VagtMode = true;
                ShutdownMode = ShutdownMode.OnExplicitShutdown;
                Services.Vagt.Start();
                return;
            }
            // Kun én Opticon ad gangen: åbnes den igen, vises det vindue, der allerede kører (fx fra ikonet ved uret)
            bool created;
            try { single = new System.Threading.Mutex(true, "Local\\OpticonApp", out created); }
            catch (UnauthorizedAccessException) { created = false; single = null; }   // kører allerede som administrator
            if (!created && single != null && Array.IndexOf(e.Args, "--restart") >= 0)
            {
                try { created = single.WaitOne(8000); } catch (System.Threading.AbandonedMutexException) { created = true; }   // den gamle er ved at lukke (genstart som administrator)
            }
            if (!created)
            {
                try { using (var ev = System.Threading.EventWaitHandle.OpenExisting("Local\\OpticonShow")) ev.Set(); } catch { }
                Exiting = true; Shutdown(); return;
            }
            var show = new System.Threading.EventWaitHandle(false, System.Threading.EventResetMode.AutoReset, "Local\\OpticonShow");
            Log("Start " + typeof(App).Assembly.GetName().Version + (Services.Admin.IsElevated ? " (administrator)" : ""));
            var w = new MainWindow();
            new System.Threading.Thread(() => { while (true) { show.WaitOne(); Dispatcher.BeginInvoke(new Action(() => w.ShowFromTray())); } }) { IsBackground = true }.Start();
            w.Show();
        }

        void OnUiError(object sender, DispatcherUnhandledExceptionEventArgs e)
        {
            Log("Fejl: " + e.Exception);
            e.Handled = true;
            if (VagtMode) return;
            MessageBox.Show("Der skete en fejl:\n\n" + e.Exception.Message, "Opticon", MessageBoxButton.OK, MessageBoxImage.Warning);
            e.Handled = true;
        }
    }
}
