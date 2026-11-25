using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Opticon.Services
{
    /// <summary>Valgfri nøgle til MalwareBazaar (abuse.ch). Gemmes krypteret med Windows (DPAPI), så kun din bruger kan læse den.</summary>
    public static class MbKey
    {
        static string FilePath { get { return Path.Combine(App.DataDir, "malwarebazaar.key"); } }

        public static string Get()
        {
            try
            {
                if (!File.Exists(FilePath)) return null;
                var raw = ProtectedData.Unprotect(File.ReadAllBytes(FilePath), Encoding.UTF8.GetBytes("Opticon-MB"), DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(raw);
            }
            catch (Exception e) { App.Log("MalwareBazaar-nøgle kunne ikke læses: " + e.Message); return null; }
        }

        public static void Save(string key)
        {
            Directory.CreateDirectory(App.DataDir);
            File.WriteAllBytes(FilePath, ProtectedData.Protect(Encoding.UTF8.GetBytes(key.Trim()), Encoding.UTF8.GetBytes("Opticon-MB"), DataProtectionScope.CurrentUser));
            if (Get() != key.Trim()) throw new Exception("Nøglen kunne ikke læses tilbage efter den blev gemt.");
        }

        public static void Remove() { try { File.Delete(FilePath); } catch { } }

        /// <summary>Tester nøglen med et opslag af en kendt fil (EICAR-testfilen). Returnerer null, hvis den virker, ellers en fejltekst.</summary>
        public static string Test(string key)
        {
            using (var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) })
            {
                http.DefaultRequestHeaders.Add("Auth-Key", key.Trim());
                var resp = http.PostAsync("https://mb-api.abuse.ch/api/v1/", new FormUrlEncodedContent(new Dictionary<string, string> { { "query", "get_info" }, { "hash", "275a021bbfb6489e54d471899f7db9d1663fc695ec2fe2a2c4538aabf651fd0f" } })).Result;
                var body = resp.Content.ReadAsStringAsync().Result;
                if ((int)resp.StatusCode == 401 || (int)resp.StatusCode == 403) return "Nøglen blev afvist af MalwareBazaar. Tjek, at du har kopieret hele nøglen.";
                try
                {
                    using (var doc = JsonDocument.Parse(body))
                    {
                        var st = doc.RootElement.TryGetProperty("query_status", out var q) ? q.GetString() : "";
                        if (st == "ok" || st == "hash_not_found") return null;
                        return "MalwareBazaar svarede: " + st;
                    }
                }
                catch { return "Uventet svar fra MalwareBazaar (" + (int)resp.StatusCode + ")."; }
            }
        }
    }
}
