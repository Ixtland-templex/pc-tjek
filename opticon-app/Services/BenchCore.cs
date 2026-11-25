using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;

namespace Opticon.Services.Bench
{
    public static class Cpu
    {
        // Én arbejdsenhed: heltal (primtal), kommatal (matrix), kryptografi (SHA-256) og komprimering
        static int Unit(byte[] buf, double[] a, double[] b, double[] c, bool[] comp, SHA256 sha)
        {
            int count = 0;
            Array.Clear(comp, 0, comp.Length);
            int lim = comp.Length - 1;
            for (int i = 2; i <= lim; i++)
            {
                if (!comp[i]) { count++; for (int j = i * 2; j <= lim; j += i) comp[j] = true; }
            }
            const int n = 48;
            for (int i = 0; i < n; i++)
                for (int j = 0; j < n; j++)
                {
                    double s = 0;
                    for (int k = 0; k < n; k++) s += a[i * n + k] * b[k * n + j];
                    c[i * n + j] = s;
                }
            byte[] h = sha.ComputeHash(buf);
            count += h[0];
            using (MemoryStream ms = new MemoryStream())
            {
                using (DeflateStream z = new DeflateStream(ms, CompressionMode.Compress, true)) { z.Write(buf, 0, buf.Length); }
                count += (int)(ms.Length & 1);
            }
            return count;
        }

        // Kører arbejdsenheder i 'seconds' sekunder på 'threads' tråde. Returnerer enheder pr. sekund (i alt).
        public static double Run(int threads, double seconds)
        {
            long total = 0;
            object lk = new object();
            Thread[] ts = new Thread[threads];
            Stopwatch sw = Stopwatch.StartNew();
            for (int t = 0; t < threads; t++)
            {
                int seed = t + 1;
                ts[t] = new Thread(() =>
                {
                    Random r = new Random(seed);
                    byte[] buf = new byte[32 * 1024];
                    for (int i = 0; i < buf.Length; i++) buf[i] = (byte)(r.Next(256) & (i % 7 == 0 ? 0xFF : 0x3F));
                    double[] a = new double[48 * 48], b = new double[48 * 48], c = new double[48 * 48];
                    for (int i = 0; i < a.Length; i++) { a[i] = r.NextDouble(); b[i] = r.NextDouble(); }
                    bool[] comp = new bool[15001];
                    long mine = 0; int sink = 0;
                    using (SHA256 sha = SHA256.Create())
                    {
                        while (sw.Elapsed.TotalSeconds < seconds) { sink += Unit(buf, a, b, c, comp, sha); mine++; }
                    }
                    lock (lk) { total += mine; if (sink == int.MinValue) total++; }
                });
                ts[t].IsBackground = true;
                ts[t].Start();
            }
            foreach (Thread th in ts) th.Join();
            return total / Math.Max(0.001, sw.Elapsed.TotalSeconds);
        }
    }

    public static class Mem
    {
        // Kopierer store blokke på flere tråde. Returnerer GB/s (kopieret data pr. sekund).
        public static double CopyGBs(int threads, double seconds)
        {
            const int size = 64 * 1024 * 1024;
            long bytes = 0;
            object lk = new object();
            Thread[] ts = new Thread[threads];
            Stopwatch sw = Stopwatch.StartNew();
            for (int t = 0; t < threads; t++)
            {
                ts[t] = new Thread(() =>
                {
                    byte[] src = new byte[size], dst = new byte[size];
                    for (int i = 0; i < size; i += 4096) src[i] = (byte)i;
                    long mine = 0;
                    while (sw.Elapsed.TotalSeconds < seconds) { Buffer.BlockCopy(src, 0, dst, 0, size); mine += size; }
                    lock (lk) { bytes += mine; }
                });
                ts[t].IsBackground = true;
                ts[t].Start();
            }
            foreach (Thread th in ts) th.Join();
            return bytes / Math.Max(0.001, sw.Elapsed.TotalSeconds) / 1e9;
        }
    }

    public static class Disk
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool WriteFile(IntPtr h, IntPtr buf, uint n, out uint done, IntPtr ov);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadFile(IntPtr h, IntPtr buf, uint n, out uint done, IntPtr ov);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFilePointerEx(IntPtr h, long dist, out long newPos, uint method);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr h);
        // Disktesten uden cache kræver sektor-justeret hukommelse: tag lidt ekstra og ret adressen op til 4 KB
        static IntPtr Align4K(IntPtr p) { long v = p.ToInt64(); return new IntPtr((v + 4095) & ~4095L); }

        const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000, CREATE_ALWAYS = 2;
        const uint NO_BUFFERING = 0x20000000, WRITE_THROUGH = 0x80000000, DELETE_ON_CLOSE = 0x04000000;

        // Skriver og læser en testfil uden Windows' cache. Returnerer { skriv MB/s, læs MB/s, små læsninger pr. sek (4 KB) }
        public static double[] Test(string path, long sizeMB, double randSeconds)
        {
            const uint chunk = 4 * 1024 * 1024;
            long size = sizeMB * 1024 * 1024;
            IntPtr bufRaw = Marshal.AllocHGlobal((int)chunk + 4096);
            IntPtr smallRaw = Marshal.AllocHGlobal(8192);
            IntPtr buf = Align4K(bufRaw), small = Align4K(smallRaw);
            byte[] rnd = new byte[chunk];
            new Random(42).NextBytes(rnd);
            Marshal.Copy(rnd, 0, buf, (int)chunk);
            IntPtr h = CreateFile(path, GENERIC_READ | GENERIC_WRITE, 0, IntPtr.Zero, CREATE_ALWAYS, NO_BUFFERING | WRITE_THROUGH | DELETE_ON_CLOSE, IntPtr.Zero);
            if (h == new IntPtr(-1)) throw new Exception("Kunne ikke oprette testfilen (fejl " + Marshal.GetLastWin32Error() + ").");
            try
            {
                uint done;
                long pos;
                Stopwatch sw = Stopwatch.StartNew();
                for (long w = 0; w < size; w += chunk)
                    if (!WriteFile(h, buf, chunk, out done, IntPtr.Zero)) throw new Exception("Skrivefejl " + Marshal.GetLastWin32Error());
                double write = size / 1048576.0 / Math.Max(0.001, sw.Elapsed.TotalSeconds);

                SetFilePointerEx(h, 0, out pos, 0);
                sw.Restart();
                for (long r = 0; r < size; r += chunk)
                    if (!ReadFile(h, buf, chunk, out done, IntPtr.Zero)) throw new Exception("Læsefejl " + Marshal.GetLastWin32Error());
                double read = size / 1048576.0 / Math.Max(0.001, sw.Elapsed.TotalSeconds);

                Random rr = new Random(7);
                long blocks = size / 4096, ops = 0;
                sw.Restart();
                while (sw.Elapsed.TotalSeconds < randSeconds)
                {
                    long off = (long)(rr.NextDouble() * (blocks - 1)) * 4096;
                    SetFilePointerEx(h, off, out pos, 0);
                    if (!ReadFile(h, small, 4096, out done, IntPtr.Zero)) break;
                    ops++;
                }
                double iops = ops / Math.Max(0.001, sw.Elapsed.TotalSeconds);
                return new double[] { write, read, iops };
            }
            finally
            {
                CloseHandle(h);
                Marshal.FreeHGlobal(bufRaw);
                Marshal.FreeHGlobal(smallRaw);
            }
        }
    }
}
