using System;
using System.Collections.Generic;
using System.Linq;
using System.Management;
using Microsoft.Win32;

namespace Opticon.Services
{
    /// <summary>Små hjælpere til at læse Windows' indstillinger sikkert (fejl giver null i stedet for at gå ned).</summary>
    public static class Wmi
    {
        public static List<ManagementObject> Query(string ns, string wql, int timeoutSec = 15)
        {
            var list = new List<ManagementObject>();
            try
            {
                var scope = new ManagementScope(ns);
                using (var s = new ManagementObjectSearcher(scope, new ObjectQuery(wql)))
                {
                    s.Options.Timeout = TimeSpan.FromSeconds(timeoutSec);
                    foreach (ManagementObject o in s.Get()) list.Add(o);
                }
            }
            catch (Exception e) { App.Log("WMI " + ns + " " + wql + ": " + e.Message); }
            return list;
        }

        public static ManagementObject First(string ns, string wql) { return Query(ns, wql).FirstOrDefault(); }

        public static object Prop(ManagementObject o, string name)
        {
            if (o == null) return null;
            try { return o[name]; } catch { return null; }
        }

        public static object Reg(string key, string name)
        {
            try { return Registry.GetValue(key, name, null); } catch { return null; }
        }

        public static int? RegInt(string key, string name)
        {
            var v = Reg(key, name);
            if (v == null) return null;
            try { return Convert.ToInt32(v); } catch { return null; }
        }

        public static string RegStr(string key, string name)
        {
            var v = Reg(key, name);
            return v == null ? null : v.ToString();
        }
    }
}
