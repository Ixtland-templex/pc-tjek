using System;
using System.Collections.Generic;
using System.Diagnostics.Eventing.Reader;
using System.Linq;

namespace Opticon.Services
{
    /// <summary>Læser Windows' hændelseslog sikkert (fejl giver en tom liste).</summary>
    public static class Events
    {
        public static List<EventRecord> Read(string log, string ids, int days, int max = 1000, string provider = null)
        {
            var list = new List<EventRecord>();
            long ms = (long)days * 24 * 3600 * 1000;
            string q = "*[System[(" + string.Join(" or ", ids.Split(',').Select(i => "EventID=" + i.Trim())) + ")" + (provider != null ? " and Provider[@Name='" + provider + "']" : "") + " and TimeCreated[timediff(@SystemTime) <= " + ms + "]]]";
            try
            {
                using (var r = new EventLogReader(new EventLogQuery(log, PathType.LogName, q) { ReverseDirection = true }))
                {
                    EventRecord e;
                    while (list.Count < max && (e = r.ReadEvent()) != null) list.Add(e);
                }
            }
            catch (Exception ex) { App.Log("Hændelseslog " + log + ": " + ex.Message); }
            return list;
        }

        public static string Prop(EventRecord e, int i)
        {
            try { return e.Properties.Count > i ? Convert.ToString(e.Properties[i].Value) : ""; } catch { return ""; }
        }

        public static string Msg(EventRecord e)
        {
            try { return e.FormatDescription() ?? ""; } catch { return ""; }
        }
    }
}
