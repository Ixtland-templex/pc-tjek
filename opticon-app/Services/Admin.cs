using System;
using System.Diagnostics;
using System.Security.Principal;
using System.Windows;

namespace Opticon.Services
{
    public static class Admin
    {
        public static bool IsElevated
        {
            get
            {
                try { using (var id = WindowsIdentity.GetCurrent()) return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator); }
                catch { return false; }
            }
        }

        /// <summary>Starter Opticon igen som administrator (Windows spørger). Returnerer false, hvis man sagde nej.</summary>
        public static bool RestartElevated(string args)
        {
            try
            {
                var exe = Environment.ProcessPath;
                Process.Start(new ProcessStartInfo(exe, ((args ?? "") + " --restart").Trim()) { UseShellExecute = true, Verb = "runas" });
                App.Exiting = true;
                Application.Current.Shutdown();
                return true;
            }
            catch (Exception e)
            {
                App.Log("Genstart som administrator: " + e.Message);
                return false;
            }
        }
    }
}
