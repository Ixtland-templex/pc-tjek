using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management;
using Microsoft.Win32;

namespace Opticon.Services
{
    public class PcInfo
    {
        public string Windows = "";
        public string Build = "";
        public string Uptime = "";
        public string Cpu = "";
        public string CpuDetail = "";
        public List<string> Gpus = new List<string>();
        public string Ram = "";
        public int RamUsedPct;
        public string Disk = "";
        public int DiskFreePct;
        public string Board = "";
        public string Arch = "";
    }

    public static class SystemInfo
    {
        static IEnumerable<ManagementObject> Query(string wql)
        {
            using (var s = new ManagementObjectSearcher(wql))
            {
                s.Options.Timeout = TimeSpan.FromSeconds(10);
                foreach (ManagementObject o in s.Get()) yield return o;
            }
        }

        static string S(object o) { return o == null ? "" : o.ToString().Trim(); }

        public static PcInfo Read()
        {
            var i = new PcInfo();
            try
            {
                var os = Query("SELECT Caption, BuildNumber, LastBootUpTime, TotalVisibleMemorySize, FreePhysicalMemory FROM Win32_OperatingSystem").FirstOrDefault();
                if (os != null)
                {
                    string ver = "";
                    try { ver = S(Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "DisplayVersion", "")); } catch { }
                    i.Windows = (S(os["Caption"]).Replace("Microsoft ", "") + " " + ver).Trim();
                    string ubr = "";
                    try { ubr = S(Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "UBR", "")); } catch { }
                    i.Build = "Build " + S(os["BuildNumber"]) + (ubr.Length > 0 ? "." + ubr : "");
                    var boot = ManagementDateTimeConverter.ToDateTime(S(os["LastBootUpTime"]));
                    var up = DateTime.Now - boot;
                    i.Uptime = up.TotalDays >= 1 ? string.Format("tændt i {0:0.#} dage", up.TotalDays) : ((int)up.TotalHours == 1 ? "tændt i 1 time" : string.Format("tændt i {0} timer", (int)up.TotalHours));
                    double totKb = Convert.ToDouble(os["TotalVisibleMemorySize"]), freeKb = Convert.ToDouble(os["FreePhysicalMemory"]);
                    i.RamUsedPct = (int)Math.Round(100 - freeKb / totKb * 100);
                    i.Ram = string.Format("{0} GB", Math.Round(totKb / 1024 / 1024));
                }
            }
            catch (Exception e) { App.Log("OS-info: " + e.Message); }

            try
            {
                var cpu = Query("SELECT Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed FROM Win32_Processor").FirstOrDefault();
                if (cpu != null)
                {
                    i.Cpu = S(cpu["Name"]).Replace("(R)", "").Replace("(TM)", "");
                    i.CpuDetail = string.Format("{0} kerner / {1} tråde · {2:0.0} GHz", cpu["NumberOfCores"], cpu["NumberOfLogicalProcessors"], Convert.ToDouble(cpu["MaxClockSpeed"]) / 1000);
                }
            }
            catch (Exception e) { App.Log("CPU-info: " + e.Message); }

            try
            {
                foreach (var g in Query("SELECT Name, DriverVersion FROM Win32_VideoController"))
                {
                    var n = S(g["Name"]);
                    if (n.Length == 0 || n.IndexOf("Basic", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("Virtual", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                    i.Gpus.Add(n + "  ·  driver " + S(g["DriverVersion"]));
                }
            }
            catch (Exception e) { App.Log("GPU-info: " + e.Message); }

            try
            {
                var b = Query("SELECT Manufacturer, Product FROM Win32_BaseBoard").FirstOrDefault();
                if (b != null) i.Board = (S(b["Manufacturer"]) + " " + S(b["Product"])).Trim();
            }
            catch { }

            try
            {
                var c = new DriveInfo("C");
                i.DiskFreePct = (int)Math.Round(100.0 * c.AvailableFreeSpace / c.TotalSize);
                i.Disk = string.Format("{0} GB ledig af {1} GB", c.AvailableFreeSpace / 1073741824L, c.TotalSize / 1073741824L);
            }
            catch { }

            var a = System.Runtime.InteropServices.RuntimeInformation.OSArchitecture;
            i.Arch = a == System.Runtime.InteropServices.Architecture.Arm64 ? "ARM (Snapdragon)" : a == System.Runtime.InteropServices.Architecture.X64 ? "64-bit" : a.ToString();
            return i;
        }
    }
}
