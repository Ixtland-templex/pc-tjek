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
            Log("Start " + typeof(App).Assembly.GetName().Version + (Services.Admin.IsElevated ? " (administrator)" : ""));
            new MainWindow().Show();
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
