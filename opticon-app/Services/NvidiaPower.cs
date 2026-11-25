using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;

namespace Opticon.Services
{
    public class NvInfo { public string Name, Uuid; public double Limit, Default, Min, Max, Draw; }

    /// <summary>Strømgrænse på NVIDIA-grafikkort via NVIDIAs eget værktøj (nvidia-smi). Nulstilles af driveren ved genstart.</summary>
    public static class NvidiaPower
    {
        static string Smi
        {
            get
            {
                var a = Path.Combine(Environment.SystemDirectory, "nvidia-smi.exe");
                if (File.Exists(a)) return a;
                var b = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"NVIDIA Corporation\NVSMI\nvidia-smi.exe");
                return File.Exists(b) ? b : null;
            }
        }

        static Tuple<int, string> Run(string args)
        {
            var psi = new ProcessStartInfo(Smi, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            using (var p = Process.Start(psi))
            {
                var o = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
                if (!p.WaitForExit(10000)) { try { p.Kill(); } catch { } return Tuple.Create(-1, "nvidia-smi svarede ikke"); }
                return Tuple.Create(p.ExitCode, o.Trim());
            }
        }

        public static NvInfo Query()
        {
            if (Smi == null) return null;
            var r = Run("--query-gpu=name,uuid,power.limit,power.default_limit,power.min_limit,power.max_limit,power.draw --format=csv,noheader,nounits");
            if (r.Item1 != 0) return null;
            var c = r.Item2.Split('\n')[0].Split(',');
            if (c.Length < 7) return null;
            Func<string, double> d = s => { double v; return double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : 0; };
            var i = new NvInfo { Name = c[0].Trim(), Uuid = c[1].Trim(), Limit = d(c[2]), Default = d(c[3]), Min = d(c[4]), Max = d(c[5]), Draw = d(c[6]) };
            return i.Default > 0 && i.Max > i.Min ? i : null;
        }

        /// <summary>Kræver administrator.</summary>
        public static string Set(NvInfo gpu, double watts)
        {
            watts = Math.Round(Math.Max(gpu.Min, Math.Min(gpu.Max, watts)));
            var r = Run("-i " + gpu.Uuid + " -pl " + watts.ToString(CultureInfo.InvariantCulture));
            App.Log("NVIDIA strømgrænse " + watts + " W: kode " + r.Item1 + " " + r.Item2);
            if (r.Item1 != 0) throw new Exception("NVIDIA afviste ændringen: " + r.Item2);
            return "Strømgrænsen er sat til " + watts + " W. Den nulstilles, når pc'en genstarter.";
        }
    }
}
