using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace Opticon.Services
{
    /// <summary>Fund, som du selv har markeret som OK i Scan pc'en. Vises ikke længere som problemer.</summary>
    public static class OkList
    {
        static string FilePath { get { return Path.Combine(App.DataDir, "ok-liste.json"); } }
        static HashSet<string> set;

        static HashSet<string> Set
        {
            get
            {
                if (set != null) return set;
                set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                try { if (File.Exists(FilePath)) foreach (var k in JsonSerializer.Deserialize<List<string>>(File.ReadAllText(FilePath)) ?? new List<string>()) set.Add(k); } catch { }
                return set;
            }
        }

        public static bool Contains(string key) { lock (typeof(OkList)) return Set.Contains(key); }

        public static void Add(string key)
        {
            lock (typeof(OkList))
            {
                Set.Add(key);
                Directory.CreateDirectory(App.DataDir);
                File.WriteAllText(FilePath, JsonSerializer.Serialize(new List<string>(Set)));
            }
        }

        public static void Clear() { lock (typeof(OkList)) { Set.Clear(); try { File.Delete(FilePath); } catch { } } }
        public static int Count { get { lock (typeof(OkList)) return Set.Count; } }
    }
}
