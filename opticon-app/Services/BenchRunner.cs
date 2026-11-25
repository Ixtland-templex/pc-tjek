using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using Opticon.Services.Bench;

namespace Opticon.Services
{
    public class BenchResult
    {
        public DateTime Date { get; set; }
        public string Version { get; set; }
        public double Cpu1 { get; set; }
        public double CpuN { get; set; }
        public int Sustain { get; set; }
        public double Ram { get; set; }
        public double DiskW { get; set; }
        public double DiskR { get; set; }
        public double Iops { get; set; }
        public double Gpu { get; set; }          // FPS i 1080p uden skærmlås
        public double GpuNative { get; set; }
        public string GpuNativeRes { get; set; }
        public double Gpu4K { get; set; }
        public string Renderer { get; set; }
        public string GpuNote { get; set; }
        public int Score { get; set; }
        public bool OnBattery { get; set; }
    }

    public static class BenchRunner
    {
        // Samme faste pejlemærker som den gamle app, så tallene kan sammenlignes: 1000 point = referencepc
        static readonly Dictionary<string, double> Ref = new Dictionary<string, double> { { "Cpu1", 1000 }, { "CpuN", 8000 }, { "Ram", 15 }, { "DiskR", 2000 }, { "Gpu", 1000 } };
        static string HistFile { get { return Path.Combine(App.DataDir, "benchmark-historik.json"); } }

        public static int Total(BenchResult r)
        {
            var v = new[] { r.Cpu1, r.CpuN, r.Ram, r.DiskR, r.Gpu };
            var k = new[] { "Cpu1", "CpuN", "Ram", "DiskR", "Gpu" };
            double sum = 0;
            for (int i = 0; i < v.Length; i++) { if (v[i] <= 0) return 0; sum += Math.Log(v[i] / Ref[k[i]]); }
            return (int)Math.Round(1000 * Math.Exp(sum / v.Length));
        }

        /// <summary>CPU, RAM og disk. progress(procent, tekst). Tager ca. 1½ minut.</summary>
        public static BenchResult RunCpuRamDisk(Action<double, string> progress)
        {
            var r = new BenchResult { Date = DateTime.Now, OnBattery = PowerMode.OnBattery() };
            int threads = Environment.ProcessorCount;
            progress(2, "CPU · én kerne (10 sek.)");
            Cpu.Run(1, 1.0);
            r.Cpu1 = Math.Round(Cpu.Run(1, 10.0));
            var buckets = new List<double>();
            for (int i = 0; i < 12; i++)
            {
                progress(15 + i * 5, "CPU · alle " + threads + " tråde · " + (60 - i * 5) + " sek. tilbage (holder den farten, når den bliver varm?)");
                buckets.Add(Cpu.Run(threads, 5.0));
            }
            double multi = (buckets[0] + buckets[1]) / 2, hot = (buckets[10] + buckets[11]) / 2;
            r.CpuN = Math.Round(multi);
            r.Sustain = (int)Math.Round(100 * hot / Math.Max(1, multi));
            progress(76, "RAM · kopierer store blokke…");
            r.Ram = Math.Round(Mem.CopyGBs(Math.Min(4, threads), 3.0), 1);
            progress(82, "Disk · skriver og læser en testfil på 512 MB (uden Windows' cache)…");
            var tmp = Path.Combine(Path.GetTempPath(), "opticon-disktest-" + Guid.NewGuid().ToString("N") + ".tmp");
            try { var d = Disk.Test(tmp, 512, 3.0); r.DiskW = Math.Round(d[0]); r.DiskR = Math.Round(d[1]); r.Iops = Math.Round(d[2]); }
            catch (Exception e) { App.Log("Disktest: " + e.Message); }
            finally { try { File.Delete(tmp); } catch { } }
            progress(90, "Klar til grafiktesten…");
            return r;
        }

        public static List<BenchResult> History()
        {
            try { if (File.Exists(HistFile)) return JsonSerializer.Deserialize<List<BenchResult>>(File.ReadAllText(HistFile)) ?? new List<BenchResult>(); }
            catch (Exception e) { App.Log("Benchmark-historik: " + e.Message); }
            return new List<BenchResult>();
        }

        public static void Save(BenchResult r)
        {
            try
            {
                var h = History(); h.Add(r);
                Directory.CreateDirectory(App.DataDir);
                File.WriteAllText(HistFile, JsonSerializer.Serialize(h.Skip(Math.Max(0, h.Count - 30)).ToList()));
            }
            catch (Exception e) { App.Log("Gem benchmark: " + e.Message); }
        }

        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("gdi32.dll")] static extern int GetDeviceCaps(IntPtr dc, int i);

        /// <summary>Skærmens rigtige opløsning i pixels (uden Windows' skalering).</summary>
        public static string NativeRes()
        {
            IntPtr dc = GetDC(IntPtr.Zero);
            try { return GetDeviceCaps(dc, 118) + "x" + GetDeviceCaps(dc, 117); }   // DESKTOPHORZRES, DESKTOPVERTRES
            finally { ReleaseDC(IntPtr.Zero, dc); }
        }
    }
}
