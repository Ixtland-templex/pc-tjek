using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading.Tasks;

namespace Opticon.Services
{
    public class UpdateInfo
    {
        public Version Version;
        public string Tag;
        public string Notes;
        public string InstallerUrl;
        public string ShaUrl;
        public string FileName;
    }

    /// <summary>Henter nye versioner fra GitHub Releases. Installeren tjekkes med SHA-256, før den køres.</summary>
    public static class Updater
    {
        const string Api = "https://api.github.com/repos/Ixtland-templex/pc-tjek/releases?per_page=15";
        static readonly HttpClient http = MakeClient();

        static HttpClient MakeClient()
        {
            var h = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
            h.DefaultRequestHeaders.UserAgent.ParseAdd("Opticon/" + Current.ToString(3));
            return h;
        }

        public static Version Current { get { return typeof(App).Assembly.GetName().Version; } }
        static string Arch { get { return RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "arm64" : "x64"; } }

        /// <summary>Returnerer den nyeste version, hvis den er nyere end den installerede. Ellers null.</summary>
        public static async Task<UpdateInfo> Check()
        {
            var json = await http.GetStringAsync(Api);
            using (var doc = JsonDocument.Parse(json))
            {
                UpdateInfo best = null;
                foreach (var rel in doc.RootElement.EnumerateArray())
                {
                    if (rel.TryGetProperty("draft", out var d) && d.GetBoolean()) continue;
                    var tag = rel.GetProperty("tag_name").GetString() ?? "";
                    if (!tag.StartsWith("app-v")) continue;
                    Version v;
                    if (!Version.TryParse(tag.Substring(5), out v)) continue;
                    string inst = null, sha = null, name = null;
                    foreach (var a in rel.GetProperty("assets").EnumerateArray())
                    {
                        var n = a.GetProperty("name").GetString() ?? "";
                        var url = a.GetProperty("browser_download_url").GetString();
                        if (n.EndsWith("-" + Arch + ".exe", StringComparison.OrdinalIgnoreCase)) { inst = url; name = n; }
                        else if (n.EndsWith("-" + Arch + ".exe.sha256", StringComparison.OrdinalIgnoreCase)) sha = url;
                    }
                    if (inst == null || sha == null) continue;
                    if (best == null || v > best.Version)
                        best = new UpdateInfo { Version = v, Tag = tag, Notes = rel.TryGetProperty("body", out var b) ? b.GetString() : "", InstallerUrl = inst, ShaUrl = sha, FileName = name };
                }
                var cur = new Version(Current.Major, Current.Minor, Math.Max(0, Current.Build));
                return best != null && best.Version > cur ? best : null;
            }
        }

        /// <summary>Henter installeren, tjekker fingeraftrykket og starter den i stilhed. Opticon lukker, og installeren starter den nye version.</summary>
        public static async Task Install(UpdateInfo u, IProgress<string> status)
        {
            status.Report("Henter " + u.FileName + "…");
            var dir = Path.Combine(Path.GetTempPath(), "Opticon-opdatering");
            Directory.CreateDirectory(dir);
            var file = Path.Combine(dir, u.FileName);
            var bytes = await http.GetByteArrayAsync(u.InstallerUrl);
            var expected = (await http.GetStringAsync(u.ShaUrl)).Trim().Split(' ', '\t', '\r', '\n')[0].ToLowerInvariant();
            string actual;
            using (var sha = SHA256.Create()) actual = BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
            if (actual != expected) throw new Exception("Fingeraftrykket passer ikke (forventet " + expected.Substring(0, Math.Min(16, expected.Length)) + "…, fik " + actual.Substring(0, 16) + "…). Opdateringen er afbrudt, og intet er ændret.");
            File.WriteAllBytes(file, bytes);
            App.Log("Opdatering " + u.Version + " hentet og tjekket (" + actual.Substring(0, 16) + ")");
            status.Report("Installerer " + u.Version.ToString(3) + "… Opticon starter igen om lidt.");
            Process.Start(new ProcessStartInfo(file, "/SILENT /SUPPRESSMSGBOXES /NORESTART /SP-") { UseShellExecute = true });
            await Task.Delay(800);
            App.Exiting = true;
            System.Windows.Application.Current.Shutdown();
        }
    }
}
