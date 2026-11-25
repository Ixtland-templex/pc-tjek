/**
 * Opticon – fælles benchmark-resultater (Google Apps Script)
 *
 * Opsætning (ca. 3 minutter, én gang):
 *  1. Opret et nyt Google-regneark, fx "Opticon resultater".
 *  2. Udvidelser → Apps Script. Slet alt i Code.gs, og sæt hele denne fil ind. Gem.
 *  3. Implementér → Ny implementering → tandhjulet → Webapp.
 *       Udfør som: Mig      Hvem har adgang: Alle
 *  4. Tryk Implementér, giv lov (Avanceret → Gå til projektet), og kopiér webapp-URL'en (slutter på /exec).
 *  5. Giv URL'en til Claude, så sættes den ind i opticon-app/community.json.
 *
 * Appen sender kun: processor, grafikkort, RAM, diskmodel, bærbar/stationær, strømtilstand og testtallene.
 * Ingen navne, IP-adresser eller filer gemmes.
 */

var SHEET = 'Resultater';
var MAX_PER_DAY = 1000;

function sheet_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(SHEET);
  if (!sh) { sh = ss.insertSheet(SHEET); sh.appendRow(['tid', 'json']); }
  return sh;
}

function out_(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }

function num_(v, lo, hi) { return typeof v === 'number' && isFinite(v) && v >= lo && v <= hi; }
function str_(v, max) { return typeof v === 'string' && v.length > 0 && v.length <= max && !/[<>]/.test(v); }

function valid_(r) {
  if (!r || typeof r !== 'object') return 'ikke et objekt';
  if (r.v !== 3) return 'forkert testversion';
  if (!str_(r.app, 12) || !str_(r.cpu, 100) || !str_(r.gpu, 100)) return 'mangler navne';
  if (r.battery === true) return 'målt på batteri';
  var s = r.scores || {};
  if (!num_(s.cpu1, 1, 100000) || !num_(s.cpuN, 1, 2000000) || !num_(s.ram, 0.1, 1000) || !num_(s.diskR, 1, 100000) || !num_(s.gpu, 0, 1000000) || !num_(s.total, 1, 100000)) return 'ugyldige tal';
  return null;
}

function doPost(e) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(10000);
    var r = JSON.parse(e.postData.contents);
    var err = valid_(r);
    if (err) return out_({ ok: false, error: err });
    var props = PropertiesService.getScriptProperties();
    var day = Utilities.formatDate(new Date(), 'UTC', 'yyyy-MM-dd');
    var count = Number(props.getProperty('n_' + day) || 0);
    if (count >= MAX_PER_DAY) return out_({ ok: false, error: 'for mange i dag' });
    // samme resultat to gange tæller kun én gang
    var key = Utilities.base64Encode(Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, JSON.stringify([r.cpu, r.gpu, r.scores])));
    var cache = CacheService.getScriptCache();
    if (cache.get(key)) return out_({ ok: true, duplicate: true });
    var clean = { v: 3, app: r.app, cpu: r.cpu, gpu: r.gpu, cores: r.cores | 0, threads: r.threads | 0, ramGB: r.ramGB | 0, ramMHz: r.ramMHz | 0,
                  disk: String(r.disk || '').slice(0, 100), laptop: r.laptop === true, battery: false, power: String(r.power || '').slice(0, 40), scores: r.scores };
    sheet_().appendRow([new Date(), JSON.stringify(clean)]);
    cache.put(key, '1', 21600);
    props.setProperty('n_' + day, String(count + 1));
    CacheService.getScriptCache().remove('all');
    return out_({ ok: true });
  } catch (x) {
    return out_({ ok: false, error: String(x) });
  } finally {
    try { lock.releaseLock(); } catch (y) {}
  }
}

function doGet() {
  var cache = CacheService.getScriptCache();
  var hit = cache.get('all');
  if (hit) return ContentService.createTextOutput(hit).setMimeType(ContentService.MimeType.JSON);
  var rows = sheet_().getDataRange().getValues().slice(1);
  var list = [];
  for (var i = Math.max(0, rows.length - 5000); i < rows.length; i++) { try { list.push(JSON.parse(rows[i][1])); } catch (x) {} }
  var txt = JSON.stringify(list);
  if (txt.length < 90000) cache.put('all', txt, 300);
  return ContentService.createTextOutput(txt).setMimeType(ContentService.MimeType.JSON);
}
