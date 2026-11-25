using System;
using System.IO;
using System.Text.Json;

namespace Opticon.Services
{
    /// <summary>Små indstillinger for appen (gemmes i %LOCALAPPDATA%\Opticon\indstillinger.json).</summary>
    public class Settings
    {
        public bool CloseToTray { get; set; } = true;
        public bool TrayTipShown { get; set; }

        static string FilePath { get { return Path.Combine(App.DataDir, "indstillinger.json"); } }
        static Settings cur;

        public static Settings Current
        {
            get
            {
                if (cur != null) return cur;
                try { if (File.Exists(FilePath)) cur = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)); } catch { }
                return cur ?? (cur = new Settings());
            }
        }

        public static void Save()
        {
            try { Directory.CreateDirectory(App.DataDir); File.WriteAllText(FilePath, JsonSerializer.Serialize(Current)); } catch (Exception e) { App.Log("Indstillinger: " + e.Message); }
        }
    }
}
