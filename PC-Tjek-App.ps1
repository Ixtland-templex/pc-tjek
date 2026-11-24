<#
  PC-Tjek 2.0  –  sikkerhed, oprydning og optimering til Windows 11
  ------------------------------------------------------------------
  * Scanninger LÆSER kun. Intet ændres, før du selv trykker på en handling og bekræfter.
  * Før større ændringer oprettes et gendannelsespunkt (hvis systembeskyttelse er slået til).
  * Filer, du sletter fra Filer-siden, flyttes til papirkurven.
  * Rapporter, snapshots, fortryd-log og fejl-log ligger i  Overførsler\PC-Tjek-rapport\
  Installation: kør "Installer PC-Tjek.cmd" én gang. Derefter starter appen fra ikonet uden UAC og uden konsol.
#>

# ---------- Elevering + STA (bruges kun, hvis appen startes uden installeren) ----------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
  return
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
  Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
  return
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, Microsoft.VisualBasic

$AppVersion = '2.18'
$OutDir   = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\PC-Tjek-rapport'
$SnapDir  = Join-Path $OutDir 'snapshots'
New-Item -ItemType Directory -Force $OutDir, $SnapDir | Out-Null
$UndoFile = Join-Path $OutDir 'fortryd-log.json'
$LogFile  = Join-Path $OutDir 'pc-tjek.log'
$TimesFile = Join-Path $OutDir 'scan-tider.json'
$IgnoreFile = Join-Path $OutDir 'markeret-ok.txt'
# Baggrundsjob kører som administrator, så deres filer må IKKE ligge et sted, almindelige programmer kan ændre (fx Temp).
# C:\ProgramData\PC-Tjek låses til kun Administratorer og SYSTEM.
$JobBase = Join-Path $env:ProgramData 'PC-Tjek'
$JobRoot = Join-Path $JobBase 'jobs'
New-Item -ItemType Directory -Force $JobRoot | Out-Null
try { & icacls.exe $JobBase /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /T /C /Q | Out-Null } catch {}
Get-ChildItem $JobRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$ConfigFile = Join-Path $PSScriptRoot 'pc-tjek.config.json'
$UpdateUrl = $null
if (Test-Path $ConfigFile) { try { $UpdateUrl = ([string](Get-Content $ConfigFile -Raw | ConvertFrom-Json).UpdateUrl).TrimEnd('/') } catch {} }
if ($UpdateUrl -notmatch '^https://raw\.githubusercontent\.com/[\w\-]+/[\w\-.]+/[\w\-./]+$' -or $UpdateUrl -match 'DIT-BRUGERNAVN') { $UpdateUrl = $null }
function Log($m) { try { [IO.File]::AppendAllText($LogFile, ("{0:yyyy-MM-dd HH:mm:ss}  {1}`r`n" -f (Get-Date), $m), [Text.Encoding]::UTF8) } catch {} }
Log "Start v$AppVersion"

# ---------- Lille C#-hjælper: rækker med afkrydsning + mørk titellinje ----------
if (-not ('PcTjek.Row' -as [type])) { Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Collections.Generic;
namespace PcTjek {
  public class Row : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    void N(string p) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }
    bool _v; string _navn, _info, _note, _gruppe, _status; double _tal;
    public bool Valgt { get { return _v; } set { _v = value; N("Valgt"); } }
    public string Navn { get { return _navn; } set { _navn = value; N("Navn"); } }
    public string Info { get { return _info; } set { _info = value; N("Info"); } }
    public string Note { get { return _note; } set { _note = value; N("Note"); } }
    public string Gruppe { get { return _gruppe; } set { _gruppe = value; N("Gruppe"); } }
    public string Status { get { return _status; } set { _status = value; N("Status"); } }
    public double Tal { get { return _tal; } set { _tal = value; N("Tal"); } }
    public string Sti { get; set; }
    public string Id { get; set; }
    public object Tag { get; set; }
  }
  public static class Win {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
    public static void Dark(IntPtr h) {
      int on = 1; DwmSetWindowAttribute(h, 20, ref on, 4);           // mørk titellinje
      int col = 0x00140F0D; DwmSetWindowAttribute(h, 35, ref col, 4);  // titellinjefarve (#0D0F14)
    }
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra; public int dmFields;
    public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
    public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
    public int dmDisplayFlags; public int dmDisplayFrequency;
    public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
    public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
  }
  public static class Screens {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    // Returnerer "enhed|skærmnavn|bredde|højde|nuværende Hz|max Hz ved samme opløsning" for hver aktiv skærm
    public static string[] List() {
      var list = new List<string>();
      for (uint i = 0; i < 16; i++) {
        var d = new DISPLAY_DEVICE(); d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        if (!EnumDisplayDevices(null, i, ref d, 0)) break;
        if ((d.StateFlags & 1) == 0) continue;
        var cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(d.DeviceName, -1, ref cur)) continue;
        int max = cur.dmDisplayFrequency;
        var m = new DEVMODE(); m.dmSize = cur.dmSize;
        for (int k = 0; k < 5000 && EnumDisplaySettings(d.DeviceName, k, ref m); k++) {
          if (m.dmPelsWidth == cur.dmPelsWidth && m.dmPelsHeight == cur.dmPelsHeight && m.dmDisplayFrequency > max) max = m.dmDisplayFrequency;
        }
        var mon = new DISPLAY_DEVICE(); mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        string monName = EnumDisplayDevices(d.DeviceName, 0, ref mon, 0) ? mon.DeviceString : "";
        list.Add(d.DeviceName + "|" + monName + "|" + cur.dmPelsWidth + "|" + cur.dmPelsHeight + "|" + cur.dmDisplayFrequency + "|" + max);
      }
      return list.ToArray();
    }
  }
}
'@ }

$ScanScript = {
  param($sync, $arg)
  $ErrorActionPreference = 'SilentlyContinue'
  # En enkelt fejl må aldrig stoppe hele scanningen: log den, og fortsæt med næste linje
  trap { if ($arg -and $arg.LogFile) { try { [IO.File]::AppendAllText($arg.LogFile, ("{0:yyyy-MM-dd HH:mm:ss}  Scan-advarsel (fortsætter): {1}`r`n" -f (Get-Date), $_.Exception.Message), [Text.Encoding]::UTF8) } catch {} }; continue }
  if ($arg -and $arg.LogFile) { try { [IO.File]::AppendAllText($arg.LogFile, ("{0:yyyy-MM-dd HH:mm:ss}  Scan-motor startet`r`n" -f (Get-Date)), [Text.Encoding]::UTF8) } catch {} }
  $since = (Get-Date).AddDays(-45)
  function Status($t) { $sync.Status = $t }
  # Faser med vægt (summer til 100) – bruges til procent og tidsestimat
  $Phases = @(4, 4, 8, 10, 5, 22, 32, 4, 9, 2)
  $sync.PhaseCount = $Phases.Count
  $sync.PhaseTimes = @{}
  function Phase([int]$i, $text) {
    $start = 0; for ($k = 0; $k -lt $i - 1; $k++) { $start += $Phases[$k] }
    $sync.Phase = $i; $sync.PhaseStart = $start; $sync.PhaseWeight = $Phases[$i - 1]
    $sync.Progress = [double]$start; $sync.Status = $text; $sync.Detail = ''
    $sync.PhaseTimes[$i] = Get-Date
    if ($arg -and $arg.LogFile) { try { [IO.File]::AppendAllText($arg.LogFile, ("{0:yyyy-MM-dd HH:mm:ss}  Scan fase {1}: {2}`r`n" -f (Get-Date), $i, $text), [Text.Encoding]::UTF8) } catch {} }
  }
  function Sub([double]$frac, $detail) {
    $sync.Progress = $sync.PhaseStart + $sync.PhaseWeight * [math]::Min(1, [math]::Max(0, $frac))
    if ($detail) { $sync.Detail = $detail }
  }

  # Windows-fejl 225 (ERROR_VIRUS_INFECTED) / 226: Defender nægter adgang til filen, fordi den er inficeret
  function IsVirusErr($e) { $m = [string]$e.Exception.Message; $h = 0; try { $h = $e.Exception.HResult -band 0xFFFF } catch {}; return ($h -eq 225 -or $h -eq 226 -or $m -match '(?i)virus|uønsket software|unwanted software') }
  function Sig($path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'Ikke fundet' }
    # Store-apps og Windows' systemapps er signeret via pakken/kataloget, ikke i selve filen. Mapperne kan kun ændres af Windows.
    if ($path -like "$env:ProgramFiles\WindowsApps\*" -or $path -like "$env:SystemRoot\SystemApps\*") { return 'Signeret: Microsoft Store-pakke' }
    try { $s = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop }
    catch { if (IsVirusErr $_) { return 'BLOKERET AF DEFENDER' }; return 'Kunne ikke læses' }
    if ($s.Status -eq 'Valid') { return 'Signeret: ' + ($s.SignerCertificate.Subject -replace '^CN="?([^,"]+).*', '$1') }
    return 'USIGNERET (' + [string]$s.Status + ')'
  }
  function ExePath($cmd) {
    if (-not $cmd) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables([string]$cmd).Trim()
    if ($c -match '^"([^"]+)"') { return $matches[1] }
    if ($c -match '^(.+?\.(exe|dll|bat|cmd|ps1|vbs|js|com|scr))(\s|$)') { return $matches[1] }
    return ($c -split ' ')[0]
  }
  $UserWritable = '\\(AppData|Temp|ProgramData|Users\\Public|Downloads)\\'
  $LolBins      = '(?i)\\(powershell|pwsh|cmd|wscript|cscript|mshta|rundll32|regsvr32|certutil|bitsadmin)\.exe'
  $BadArgs      = '(?i)(-enc|-encodedcommand|frombase64string|-w(indowstyle)?\s+hidden|iex|invoke-expression|downloadstring|http[s]?://)'

  $AllFinds = New-Object System.Collections.ArrayList   # fund
  $AllTimes = New-Object System.Collections.ArrayList   # tidslinje
  function Add-Find($risk, $cat, $title, $detail, $why, $path, $kind, $data, $raad = '') {
    $label = @('Info', 'Lav', 'Mellem', 'Høj', 'Kritisk')[$risk]
    [void]$AllFinds.Add([pscustomobject]@{ Risiko = $label; Niveau = $risk; Kategori = $cat; Titel = $title; Detalje = $detail
                                     Hvorfor = $why; Sti = $path; Type = $kind; Data = $data; SHA256 = $null; Raad = $raad })
  }
  function Add-Time($time, $type, $event, $detail) {
    if ($time) { [void]$AllTimes.Add([pscustomobject]@{ Tid = [datetime]$time; Type = $type; Hændelse = $event; Detalje = $detail; Fokus = '' }) }
  }

  # ---------- 1. Defender ----------
  Phase 1 'Læser Microsoft Defender'
  $threats = @(Get-MpThreat)
  $dets    = @(Get-MpThreatDetection)
  foreach ($th in $threats) {
    $d = $dets | Where-Object ThreatID -eq $th.ThreatID | Sort-Object InitialDetectionTime | Select-Object -First 1
    $paths = @($th.Resources | ForEach-Object { (([string]$_) -replace '^[a-zA-Z]+:_', '') -replace '->.*$', '' } | Where-Object { $_ -match '^[a-zA-Z]:\\' })
    $res = $paths -join '; '
    $still = @($paths | Where-Object { Test-Path -LiteralPath $_ })
    $ran = if ($th.DidThreatExecute) { 'JA – den nåede at køre' } else { 'nej' }
    if ($th.IsActive -or $still.Count) {
      # Stadig til stede: kræver handling
      Add-Find 4 'Trussel' $th.ThreatName "Stadig til stede · Kørte: $ran · Fundet: $($d.InitialDetectionTime)" `
        ("Fundet af Defender og stadig på pc'en{0}. Kør en dybdescanning (Defender Offline) for at fjerne den." -f $(if ($still.Count) { " ($($still.Count) fil(er))" } else { '' })) $res 'threat' $null
    } else {
      # Allerede fjernet: kun til orientering
      Add-Find 1 'Trussel (fjernet)' "$($th.ThreatName) (fjernet)" "Fjernet af Defender · Kørte: $ran · Fundet: $($d.InitialDetectionTime)" `
        ("Defender har fjernet den. Ingen handling nødvendig.{0}" -f $(if ($th.DidThreatExecute) { ' Den nåede dog at køre, så skift dine vigtigste adgangskoder for en sikkerheds skyld.' } else { '' })) $res 'threat' $null
    }
    Add-Time $d.InitialDetectionTime 'Defender' "Trussel fundet: $($th.ThreatName)" $res
  }
  $pref = Get-MpPreference
  $exCount = 0
  foreach ($x in @($pref.ExclusionPath) + @($pref.ExclusionProcess) + @($pref.ExclusionExtension)) {
    if ($x -and $x -notmatch '^N/A') {
      $exCount++
      Add-Find 3 'Defender' "Undtagelse i Defender: $x" 'Defender scanner ikke dette sted/program' `
        'Malware tilføjer ofte sig selv som undtagelse, så Defender ikke kan se den. Har du ikke selv tilføjet den, er den meget mistænkelig.' $x 'exclusion' $null
    }
  }
  $st = Get-MpComputerStatus
  if ($st -and -not $st.RealTimeProtectionEnabled) { Add-Find 4 'Defender' 'Realtidsbeskyttelse er SLÅET FRA' '' 'Malware forsøger ofte at slå Defender fra.' '' 'info' $null }
  if ($st -and -not $st.IsTamperProtected)        { Add-Find 2 'Defender' 'Manipulationsbeskyttelse er slået fra' '' 'Uden den kan programmer ændre Defenders indstillinger.' '' 'info' $null }
  Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1116, 1117, 5001, 5007; StartTime = $since } -MaxEvents 300 | ForEach-Object {
    $ev = $_
    $what = switch ($ev.Id) { 1116 { 'Defender: trussel opdaget' } 1117 { 'Defender: handling udført' } 5001 { 'Defender: realtid SLÅET FRA' } 5007 { 'Defender: indstilling ændret' } }
    $msg = ($ev.Message -split "`n" | Where-Object { $_ -match '(Navn|Name|Sti|Path|Ny værdi|New value|Exclusion)' } | Select-Object -First 3) -join ' | '
    Add-Time $ev.TimeCreated 'Defender' $what $msg.Trim()
    if ($ev.Id -eq 5007 -and $ev.Message -match 'Exclusion') { Add-Find $(if ($exCount) { 3 } else { 1 }) 'Defender' 'En Defender-undtagelse blev ændret' "$($ev.TimeCreated) · $($msg.Trim())" 'Nogen har ændret Defenders undtagelser. Tjek at det var dig.' '' 'info' $null $(if ($exCount) { 'Se om undtagelsen herunder er din egen. Kender du den ikke, så fjern den i Windows Sikkerhed → Virus- og trusselsbeskyttelse → Undtagelser.' } else { 'Der er ingen undtagelser lige nu, så der er ikke noget at gøre. Typisk var det en installer, der midlertidigt tilføjede en.' }) }
  }

  # ---------- 2. Installerede programmer + MSI-historik ----------
  Phase 2 'Læser programmer og installationshistorik'
  $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  $progs = @(Get-ItemProperty $keys | Where-Object DisplayName)
  $progNames = $progs.DisplayName
  $msi = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 1033, 1034; StartTime = $since } -MaxEvents 500
  $suspectWindows = New-Object System.Collections.ArrayList
  foreach ($e in $msi) {
    $p = $e.Properties
    $name = [string]$p[0].Value; $ver = [string]$p[1].Value
    $maker = if ($p.Count -ge 5) { [string]$p[4].Value } else { '' }
    $what = if ($e.Id -eq 1033) { 'Installeret' } else { 'Afinstalleret' }
    Add-Time $e.TimeCreated 'Installation' "$what`: $name $ver" "Producent: $(if ($maker) { $maker } else { '(ingen)' })"
    if ($e.Id -eq 1033) {
      $hidden = -not ($progNames -contains $name)
      $noMaker = [string]::IsNullOrWhiteSpace($maker)
      $kidsGame = $name -match '(?i)paw.?patrol|crack|keygen|free.?download|repack|torrent'
      if ($hidden -or $noMaker -or $kidsGame) {
        $why = @()
        if ($hidden)   { $why += 'produktet står ikke længere på listen over installerede programmer (skjult eller fjernet)' }
        if ($noMaker)  { $why += 'den har ingen producent' }
        if ($kidsGame) { $why += 'navnet ligner en typisk falsk installer' }
        $mrisk = if ($kidsGame -or ($hidden -and $noMaker)) { 3 } else { 2 }
        Add-Find $mrisk 'Installation' "MSI-installation: $name" "$($e.TimeCreated) · producent: $(if ($maker) { $maker } else { '(ingen)' })" `
          ('Bør gennemgås, fordi ' + ($why -join ', ') + '. Under Hændelsesforløb kan du se, hvad der ellers skete omkring samme tid.') '' 'msi' $null
        [void]$suspectWindows.Add([pscustomobject]@{ Start = $e.TimeCreated.AddMinutes(-30); End = $e.TimeCreated.AddHours(6); Name = $name })
      }
    }
  }

  # ---------- 3. Autostart ----------
  Phase 3 'Tjekker autostart og planlagte opgaver'
  foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce') {
    $i = Get-ItemProperty $k
    if (-not $i) { continue }
    foreach ($pr in ($i.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
      $exe = ExePath $pr.Value; $sg = Sig $exe
      $risk = 0; $why = 'Starter automatisk, når du logger ind. Signeret af en kendt udgiver.'
      if ($sg -notlike 'Signeret*') { $risk = 2; $why = 'Starter automatisk og er IKKE signeret.' }
      if ($exe -match $UserWritable -and $sg -notlike 'Signeret*') { $risk = 3; $why = 'Usigneret program i en brugermappe, der starter automatisk. Det er et klassisk tegn på malware.' }
      if ([string]$pr.Value -match $LolBins -and [string]$pr.Value -match $BadArgs) { $risk = 4; $why = 'Starter et skjult/kodet script automatisk. Det er et stærkt tegn på malware.' }
      Add-Find $risk 'Autostart' "Run: $($pr.Name)" "$sg" $why ([string]$pr.Value) 'run' ([pscustomobject]@{ Key = $k; Name = $pr.Name; Value = [string]$pr.Value })
    }
  }
  foreach ($sf in "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp") {
    Get-ChildItem $sf -Force -File | Where-Object Name -ne 'desktop.ini' | ForEach-Object {
      $r = if ($_.Extension -match '\.(vbs|js|bat|cmd|ps1|hta)$') { 3 } else { 1 }
      Add-Find $r 'Autostart' "Startmappe: $($_.Name)" "Oprettet $($_.CreationTime)" 'Filer i Startup-mappen kører ved login. Scripts her er mistænkelige.' $_.FullName 'file' $null
      Add-Time $_.CreationTime 'Fil' "Ny fil i Startup: $($_.Name)" $_.FullName
    }
  }
  $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  if ($wl.Shell -and $wl.Shell -ne 'explorer.exe') { Add-Find 4 'Autostart' 'Winlogon Shell er ændret' $wl.Shell 'Windows starter et andet program end Stifinder ved login.' $wl.Shell 'info' $null }
  if ($wl.Userinit -and $wl.Userinit -notmatch '^C:\\Windows\\system32\\userinit\.exe,?$') { Add-Find 4 'Autostart' 'Winlogon Userinit er ændret' $wl.Userinit 'Et ekstra program startes ved hvert login.' $wl.Userinit 'info' $null }
  Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' | ForEach-Object {
    $dbg = (Get-ItemProperty $_.PSPath).Debugger
    if ($dbg) { Add-Find 3 'Autostart' "IFEO-kapring: $($_.PSChildName)" $dbg 'Når programmet startes, kører Windows i stedet et andet program.' $dbg 'info' $null }
  }

  # Planlagte opgaver (ikke-Microsoft)
  Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
    $t = $_
    foreach ($a in $t.Actions) {
      if (-not $a.Execute) { continue }
      $exe = ExePath $a.Execute; $sg = Sig $exe; $full = "$($a.Execute) $($a.Arguments)".Trim()
      # PC-Tjeks egen opgave (fra installeren): kendt sti + kendt handling -> ikke et fund
      if ($t.TaskPath -eq '\' -and $t.TaskName -eq 'PC-Tjek Vagt' -and $exe -ieq "$env:SystemRoot\System32\conhost.exe" -and $a.Arguments -like "*$env:ProgramFiles\PC-Tjek\PC-Tjek-Vagt.ps1*") {
        Add-Find 0 'Planlagt opgave' 'PC-Tjek Vagt (denne app)' 'Starter vagten, når du logger ind' 'Oprettet af PC-Tjek.' $full 'self' $null
        continue
      }
      if ($t.TaskPath -eq '\' -and $t.TaskName -eq 'PC-Tjek' -and $exe -ieq "$env:SystemRoot\System32\conhost.exe" -and $a.Arguments -like "*$env:ProgramFiles\PC-Tjek\PC-Tjek-App.ps1*") {
        Add-Find 0 'Planlagt opgave' 'PC-Tjek (denne app)' 'Starter PC-Tjek, når du klikker på ikonet' 'Oprettet af PC-Tjeks installer.' $full 'self' $null
        continue
      }
      $risk = 0; $why = 'Planlagt opgave fra en signeret udgiver.'
      if ($sg -notlike 'Signeret*') { $risk = 2; $why = 'Planlagt opgave, der kører et usigneret program.' }
      if ($exe -match $UserWritable -and $sg -notlike 'Signeret*') { $risk = 3; $why = 'Usigneret program i en brugermappe, kørt af en planlagt opgave. Det er et typisk mønster for malware.' }
      if ($full -match $LolBins -and $full -match $BadArgs) { $risk = 4; $why = 'Opgaven kører et skjult/kodet script eller henter noget fra nettet. Det er et stærkt tegn på malware.' }
      if ($t.Settings.Hidden -and $risk -ge 2) { $risk = [math]::Min(4, $risk + 1); $why += ' Opgaven er desuden skjult.' }
      Add-Find $risk 'Planlagt opgave' "$($t.TaskPath)$($t.TaskName)" "$sg · kører som $($t.Principal.UserId) · $([string]$t.State)" $why $full 'task' ([pscustomobject]@{ TaskPath = $t.TaskPath; TaskName = $t.TaskName })
      if ($t.Date) { Add-Time $t.Date 'Opgave' "Planlagt opgave oprettet: $($t.TaskName)" $full }
    }
  }
  Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TaskScheduler/Operational'; Id = 106; StartTime = $since } -MaxEvents 300 | ForEach-Object {
    Add-Time $_.TimeCreated 'Opgave' "Opgave registreret: $($_.Properties[0].Value)" "af $($_.Properties[1].Value)"
  }

  # Tjenester (ikke Windows-signerede)
  Phase 4 'Tjekker tjenester'
  $svcs = @(Get-CimInstance Win32_Service); $si = 0
  $svcs | ForEach-Object {
    $si++; if ($si % 5 -eq 0) { Sub ($si / $svcs.Count) "$si af $($svcs.Count) tjenester tjekket" }
    $exe = ExePath $_.PathName; $sg = Sig $exe
    if ($sg -match 'Microsoft Windows') { return }
    $risk = 0; $why = 'Tredjepartstjeneste fra en signeret udgiver.'
    if ($sg -notlike 'Signeret*') { $risk = 2; $why = 'Tjeneste med et usigneret program.' }
    if ($exe -match $UserWritable -and $sg -notlike 'Signeret*') { $risk = 4; $why = 'Usigneret tjeneste i en brugermappe. Tjenester kører som SYSTEM, så det er meget farligt.' }
    if ($risk -ge 1 -or $_.StartMode -eq 'Auto') {
      Add-Find $risk 'Tjeneste' "$($_.DisplayName) ($($_.Name))" "$sg · $($_.State) · start: $($_.StartMode)" $why $_.PathName 'service' $null
    }
  }
  Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7045; StartTime = $since } -MaxEvents 200 | ForEach-Object {
    Add-Time $_.TimeCreated 'Tjeneste' "Ny tjeneste installeret: $($_.Properties[0].Value)" ([string]$_.Properties[1].Value)
  }

  # WMI-persistens
  foreach ($c in @(Get-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer) + @(Get-CimInstance -Namespace root\subscription -ClassName ActiveScriptEventConsumer)) {
    if ($c.Name -eq 'SCM Event Log Consumer') { continue }
    Add-Find 4 'Autostart' "WMI-abonnement: $($c.Name)" "$($c.CommandLineTemplate)$($c.ScriptText)" 'WMI-abonnementer er en skjult måde at starte kode på, som næsten kun malware bruger.' '' 'info' $null
  }

  # ---------- 4. Processer + netværk ----------
  Phase 5 'Tjekker kørende programmer og netværk'
  $procs = @{}
  Get-CimInstance Win32_Process | ForEach-Object { $procs[[int]$_.ProcessId] = $_ }
  $sigCache = @{}
  Get-NetTCPConnection -State Established | Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1|0\.0\.0\.0)' } | Group-Object OwningProcess | ForEach-Object {
    $pp = $procs[[int]$_.Name]; if (-not $pp) { return }
    if ([int]$_.Name -le 4 -or -not $pp.ExecutablePath) { return }   # Windows-kernen (System/Idle) har ingen programfil
    $path = $pp.ExecutablePath
    if (-not $sigCache.ContainsKey("$path")) { $sigCache["$path"] = Sig $path }
    $sg = $sigCache["$path"]
    if ($sg -notlike 'Signeret*') {
      $remotes = ($_.Group | Select-Object -First 5 | ForEach-Object { "$($_.RemoteAddress):$($_.RemotePort)" }) -join ', '
      $lanOnly = -not @($_.Group | Where-Object { $_.RemoteAddress -notmatch '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|fe80:|fd|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)' }).Count
      if ($lanOnly) {
        Add-Find 1 'Netværk' "Program på dit eget netværk: $($pp.Name)" "$($_.Count) forbindelser → $remotes" 'Forbindelsen går kun til enheder på dit eget netværk (fx din server, NAS eller printer).' $path 'file' $null 'Normalt ufarligt. Kender du programmet, kan du markere det som OK.'
      } else {
        $r = if ($path -match $UserWritable) { 4 } else { 3 }
        Add-Find $r 'Netværk' "Usigneret program på nettet: $($pp.Name)" "$($_.Count) forbindelser → $remotes" 'Et program uden verificeret udgiver har forbindelse til internettet. Det er tit helt normale programmer, men en backdoor ville også se sådan ud.' $path 'file' $null 'Tryk på VirusTotal. Er filen ren, og kender du programmet, så markér det som OK. Kender du det ikke, så åbn placeringen og se, hvilket program mappen hører til.'
      }
    }
  }
  foreach ($pp in $procs.Values) {
    if ($pp.CommandLine -and $pp.CommandLine -match $LolBins -and $pp.CommandLine -match $BadArgs -and $pp.ProcessId -ne $PID -and $pp.CommandLine -notmatch '(?i)\\PC-Tjek\\(PC-Tjek-App\.ps1|PC-Tjek-Vagt\.ps1|jobs\\)') {
      Add-Find 4 'Proces' "Mistænkelig kommando kører: $($pp.Name)" $pp.CommandLine 'Et skjult/kodet script kører lige nu.' $pp.ExecutablePath 'file' $null
    }
  }
  $hosts = Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" | Where-Object { $_ -and $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*(127\.0\.0\.1|::1)\s+localhost' }
  if ($hosts) { Add-Find 2 'Netværk' 'Hosts-filen er ændret' (($hosts | Select-Object -First 5) -join ' | ') 'Hosts-filen kan omdirigere hjemmesider. Det kan være legitimt (fx adblock) eller kapring.' "$env:SystemRoot\System32\drivers\etc\hosts" 'file' $null }
  $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  if ($ie.ProxyEnable -eq 1 -or $ie.AutoConfigURL) { Add-Find 3 'Netværk' 'Proxy er slået til' "$($ie.ProxyServer) $($ie.AutoConfigURL)" 'Al din trafik kan blive sendt gennem en fremmed server. Det er typisk for adware og bankmalware.' '' 'info' $null }

  # ---------- 5. Nye filer i typiske gemmesteder ----------
  Phase 6 'Leder efter nye programfiler'
  $ext = '.exe', '.dll', '.ps1', '.vbs', '.js', '.bat', '.cmd', '.msi', '.scr', '.jar', '.hta'
  $skip = '(?i)\\(Packages|WinGet|Microsoft\\Edge|Microsoft\\Teams|Google\\Chrome\\Application|Google\\Chrome\\User Data\\[^\\]+\\(Cache|Code Cache|Extensions)|npm-cache|pip\\cache|Discord\\app-|Spotify|NVIDIA|Steam|squirrel|\\Programs\\(Microsoft VS Code|Obsidian|GitHub Desktop|claude|chatgpt))\\'
  $roots = "$env:ProgramData", "$env:LOCALAPPDATA", "$env:APPDATA", "$env:TEMP", "$env:PUBLIC", 'C:\Windows\Temp'
  # Egen mappegennemgang: følger IKKE genveje/junctions (undgår løkker) og springer store caches over
  $skipDir = '(?i)^(node_modules|\.git|Packages|WindowsApps|WinGet|Package Cache|Cache|Code Cache|GPUCache|cache2|CacheStorage|Service Worker|IndexedDB|INetCache|npm-cache|\.cache|DXCache|GLCache|D3DSCache|Crashpad)$'
  $found = New-Object System.Collections.ArrayList
  $seen = 0; $ri = 0
  foreach ($r in $roots) {
    $ri++; $leaf = Split-Path $r -Leaf
    Sub (($ri - 1) / $roots.Count) "Gennemgår $leaf..."
    if (-not (Test-Path -LiteralPath $r)) { continue }
    $stack = New-Object System.Collections.Stack
    $stack.Push((New-Object IO.DirectoryInfo $r))
    while ($stack.Count -gt 0) {
      $d = $stack.Pop()
      try {
        foreach ($e in $d.EnumerateFileSystemInfos()) {
          if ($e -is [IO.DirectoryInfo]) {
            if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $e.Name -match $skipDir) { continue }
            $stack.Push($e)
          } else {
            $seen++
            if ($seen % 1000 -eq 0) { Sub (($ri - 1 + [math]::Min(0.95, $seen / 80000.0)) / $roots.Count) ('{0:N0} filer gennemgået · {1}' -f $seen, $leaf) }
            if ($e.CreationTime -gt $since -and $ext -contains $e.Extension.ToLower() -and $e.FullName -notmatch $skip) { [void]$found.Add($e) }
          }
        }
      } catch { }   # ingen adgang / mappe forsvundet
    }
  }
  $files = @($found | Sort-Object CreationTime -Descending | Select-Object -First 1500)
  Phase 7 "Tjekker signaturer på $($files.Count) nye filer"
  $n = 0
  foreach ($f in $files) {
    $n++; if ($n % 10 -eq 0) { Sub (0.7 * $n / [math]::Max(1, $files.Count)) "$n af $($files.Count) filer tjekket" }
    $isBin = $f.Extension.ToLower() -in '.exe', '.dll', '.msi', '.scr'
    $sg = if ($isBin) { Sig $f.FullName } else { 'script' }
    if ($sg -like 'Signeret*') { continue }
    $sha = $null; $blocked = $sg -eq 'BLOKERET AF DEFENDER'
    if (-not $blocked -and $f.Length -lt 100MB) {
      try { $sha = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { if (IsVirusErr $_) { $blocked = $true } }
    }
    if ($blocked) {
      Add-Time $f.CreationTime 'Defender' "INFICERET FIL: $($f.Name)" $f.FullName
      Add-Find 4 'Trussel' "Inficeret fil: $($f.Name)" "Windows nægter at åbne den · oprettet $($f.CreationTime) · $([math]::Round($f.Length / 1KB)) KB" `
        'Defender blokerer filen, fordi den indeholder malware, men den ligger stadig på disken. Kør en Microsoft Defender Offline-scanning (Ydelse og helbred → Defender Offline-scan), som kan fjerne den, før Windows starter.' $f.FullName 'file' $null
      continue
    }
    # Kun "Bør gennemgås" (2) for de klassiske gemmesteder; resten er info (1)
    $rel = $f.FullName
    $hideout = $rel -match '(?i)\\(Temp|Users\\Public|Start Menu\\Programs\\Startup)\\' -or $rel -match '(?i)\\AppData\\(Roaming|Local)\\[^\\]+$' -or $rel -match '(?i)^C:\\ProgramData\\[^\\]+$'
    $risky = ($f.Extension.ToLower() -in '.hta', '.scr') -or
             ($f.Extension.ToLower() -in '.vbs', '.js', '.jar', '.ps1', '.bat', '.cmd' -and $hideout) -or
             ($rel -match '(?i)\\Users\\Public\\') -or
             ($rel -match '(?i)\\AppData\\(Roaming|Local)\\[^\\]+\.(exe|dll|scr)$') -or
             ($rel -match '(?i)^C:\\ProgramData\\[^\\]+\.(exe|dll|scr)$') -or
             ($rel -match '(?i)\\Start Menu\\Programs\\Startup\\')
    $risk = if ($risky) { 2 } else { 1 }
    Add-Time $f.CreationTime 'Fil' "Ny usigneret fil: $($f.Name)" $f.FullName
    Add-Find $risk 'Ny fil' $f.Name "$([math]::Round($f.Length / 1KB)) KB · oprettet $($f.CreationTime) · $sg" `
      'Usigneret programfil oprettet for nylig et sted, hvor malware ofte lægger sig. Mange er ufarlige (spil, værktøjer). Brug "Tjek på VirusTotal" ved tvivl.' $f.FullName 'file' $null
    $AllFinds[$AllFinds.Count - 1].SHA256 = $sha
  }

  # Lad Defender tjekke de markerede filer, KUN læsning (-DisableRemediation: Defender ændrer intet).
  # Resultatet læses fra Defenders egen tekst: "found no threats" / "found N threats". Alt andet = kunne ikke verificeres.
  $mpcmd = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
  $toCheck = @($AllFinds | Where-Object { $_.Kategori -eq 'Ny fil' -and $_.Niveau -ge 2 -and $_.Sti } | Select-Object -First 80)
  if ($toCheck.Count -and (Test-Path $mpcmd)) {
    Status "Defender tjekker $($toCheck.Count) markerede filer"
    $ci = 0
    foreach ($x in $toCheck) {
      $ci++; Sub (0.7 + 0.3 * $ci / $toCheck.Count) "Defender tjekker fil $ci af $($toCheck.Count)"
      if (-not (Test-Path -LiteralPath $x.Sti)) { continue }
      $out = (& $mpcmd -Scan -ScanType 3 -File $x.Sti -DisableRemediation 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
      $code = $LASTEXITCODE
      $nThreat = if ($out -match '(?i)found (\d+) threat') { [int]$matches[1] } else { -1 }
      if ($nThreat -gt 0) {
        $x.Niveau = 4; $x.Risiko = 'Kritisk'; $x.Kategori = 'Trussel'; $x.Titel = "Defender fandt malware: $(Split-Path $x.Sti -Leaf)"
        $x.Hvorfor = 'Fundet af Defender under tjekket. Scanningen har ikke ændret noget, så filen ligger der stadig.'
        $x.Raad = 'Brug trinnet "Fjern virus" på Overblik. Så fjerner Defender den.'
        Add-Time (Get-Date) 'Defender' "Malware fundet ved tjek: $(Split-Path $x.Sti -Leaf)" $x.Sti
      } elseif ($code -eq 0 -and $out -match '(?i)found no threats') {
        $x.Niveau = 1; $x.Risiko = 'Lav'; $x.Detalje = '✓ Tjekket af Defender: intet fundet · ' + $x.Detalje
        $x.Raad = 'Defender har tjekket filen og fandt intet. Du behøver ikke gøre noget.'
      } else {
        $x.Detalje = '? Kunne ikke verificeres af Defender · ' + $x.Detalje
      }
    }
  }

  # ---------- 6. Browser ----------
  Phase 8 'Tjekker browserudvidelser'
  $browsers = @{ Chrome = "$env:LOCALAPPDATA\Google\Chrome\User Data"; Edge = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" }
  foreach ($b in $browsers.Keys) {
    Get-ChildItem $browsers[$b] -Directory | Where-Object { $_.Name -match '^(Default|Profile \d+)$' } | ForEach-Object {
      $prof = $_.Name
      Get-ChildItem (Join-Path $_.FullName 'Extensions') -Directory | ForEach-Object {
        $m = Get-ChildItem $_.FullName -Recurse -Filter manifest.json | Select-Object -First 1
        if (-not $m) { return }
        $j = Get-Content $m.FullName -Raw | ConvertFrom-Json
        $name = [string]$j.name
        if ($name -match '^__MSG_') { $name = "(id $($_.Name))" }
        $perms = (@($j.permissions) + @($j.host_permissions)) -join ' '
        $broad = $perms -match '<all_urls>|\*://\*/\*|http://\*/\*|https://\*/\*'
        $risk = if ($broad -and $perms -match 'webRequest|cookies|scripting|tabs') { 2 } elseif ($broad) { 1 } else { 0 }
        Add-Find $risk 'Browser' "$b-udvidelse: $name" "$prof · v$($j.version) · installeret $($m.Directory.CreationTime)" `
          $(if ($risk -ge 2) { 'Udvidelsen kan læse og ændre ALLE sider, du besøger (inkl. cookies). Kender du den ikke, så fjern den.' } else { 'Browserudvidelse.' }) $m.Directory.FullName 'file' $null
        Add-Time $m.Directory.CreationTime 'Browser' "$b-udvidelse installeret: $name" $prof
      }
    }
  }
  foreach ($pk in 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist', 'HKCU:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist') {
    $v = Get-ItemProperty $pk
    if ($v) { Add-Find 4 'Browser' 'Tvangsinstallerede browserudvidelser (politik)' (($v.PSObject.Properties | Where-Object Name -notlike 'PS*' | ForEach-Object Value) -join ' | ') 'En politik tvinger udvidelser ind i browseren, så du ikke kan fjerne dem. Det er klassisk adware/hijacker-adfærd på en privat pc.' $pk 'info' $null }
  }

  # ---------- 7. Bloat + plads ----------
  Phase 9 'Beregner plads og bloat'
  $AllSpace = New-Object System.Collections.ArrayList
  $pi = 0
  function DirSize($p) { (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
  foreach ($x in @(
      @{ N = 'Midlertidige filer (din bruger)'; P = $env:TEMP; Note = 'Sikkert at rydde (lukkede programmers rester)' },
      @{ N = 'Midlertidige filer (Windows)'; P = 'C:\Windows\Temp'; Note = 'Sikkert at rydde' },
      @{ N = 'Windows Update-downloads'; P = 'C:\Windows\SoftwareDistribution\Download'; Note = 'Ryd via Diskoprydning' },
      @{ N = 'Papirkurv'; P = 'C:\$Recycle.Bin'; Note = 'Tøm, når du har tjekket den' },
      @{ N = 'Overførsler'; P = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'); Note = 'Gennemgå manuelt (gamle installere!)' },
      @{ N = 'Crash dumps'; P = "$env:LOCALAPPDATA\CrashDumps"; Note = 'Sikkert at slette' })) {
    $pi++; Sub ($pi / 6) "Måler $($x.N)..."
    $sz = DirSize $x.P
    [void]$AllSpace.Add([pscustomobject]@{ Hvad = $x.N; GB = [math]::Round($sz / 1GB, 2); Note = $x.Note; Sti = $x.P })
  }
  $bloatRx = '(?i)^(GIGABYTE|GBT_|PowerISO|Futuremark|McAfee|Norton|WildTangent|IObit|Driver Booster|ByteFence|Segurazo|OneLaunch|Wave Browser|Web Companion|Avast|AVG |CCleaner|Advanced SystemCare|PC App Store|Shift Browser)'
  foreach ($p in ($progs | Where-Object { $_.DisplayName -match $bloatRx })) {
    Add-Find 1 'Bloat' $p.DisplayName "$($p.Publisher) · $([math]::Round(($p.EstimatedSize / 1KB), 0)) MB" 'Typisk bloat: kører ofte i baggrunden og giver kun lidt værdi. Kan afinstalleres med knappen nedenfor.' '' 'uninstall' ([pscustomobject]@{ Cmd = [string]$p.UninstallString })
  }
  $appxBloat = 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.MicrosoftSolitaireCollection', 'Clipchamp.Clipchamp',
               'Microsoft.Todos', 'Microsoft.PowerAutomateDesktop', 'MicrosoftCorporationII.MicrosoftFamily', 'Microsoft.People', 'Microsoft.Getstarted',
               'Microsoft.WindowsFeedbackHub', 'Microsoft.Copilot', 'MicrosoftTeams', 'Microsoft.MicrosoftOfficeHub'
  foreach ($a in (Get-AppxPackage | Where-Object { $appxBloat -contains $_.Name })) {
    Add-Find 1 'Bloat' "Windows-app: $($a.Name -replace '^(Microsoft|MicrosoftCorporationII|Clipchamp)\.', '')" "v$($a.Version)" 'Forudinstalleret Microsoft-app. Harmløs, men unødvendig, hvis du ikke bruger den.' '' 'appx' ([pscustomobject]@{ Package = $a.PackageFullName })
  }

  # ---------- 8. Analyse: fokusvindue + fortælling ----------
  Phase 10 'Analyserer hændelsesforløbet'
  foreach ($ev in $AllTimes) {
    foreach ($w in $suspectWindows) { if ($ev.Tid -ge $w.Start -and $ev.Tid -le $w.End) { $ev.Fokus = "⚠ efter $($w.Name)" } }
  }
  $boot = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 |
    ForEach-Object { (([xml]$_.ToXml()).Event.EventData.Data | Where-Object Name -eq 'BootTime').'#text' }
  $os = Get-CimInstance Win32_OperatingSystem
  $top = $procs.Values | Group-Object Name | ForEach-Object { [pscustomobject]@{ Navn = $_.Name; MB = [math]::Round((($_.Group | Measure-Object WorkingSetSize -Sum).Sum) / 1MB) } } | Sort-Object MB -Descending | Select-Object -First 8

  $snap = [ordered]@{
    Autostart   = @($AllFinds | Where-Object { $_.Kategori -eq 'Autostart' } | ForEach-Object { "$($_.Titel) = $($_.Sti)" } | Sort-Object -Unique)
    Opgaver     = @($AllFinds | Where-Object { $_.Kategori -eq 'Planlagt opgave' } | ForEach-Object { "$($_.Titel) = $($_.Sti)" } | Sort-Object -Unique)
    Tjenester   = @($AllFinds | Where-Object { $_.Kategori -eq 'Tjeneste' } | ForEach-Object { $_.Titel } | Sort-Object -Unique)
    Browser     = @($AllFinds | Where-Object { $_.Kategori -eq 'Browser' -and $_.Titel -like '*-udvidelse:*' } | ForEach-Object { $_.Titel } | Sort-Object -Unique)
    Programmer  = @($progs | ForEach-Object { $_.DisplayName } | Sort-Object -Unique)
    Undtagelser = @($AllFinds | Where-Object { $_.Type -eq 'exclusion' } | ForEach-Object { $_.Sti } | Sort-Object -Unique)
  }
  $phaseSec = @{}
  for ($i = 1; $i -le $Phases.Count; $i++) {
    $next = if ($i -lt $Phases.Count -and $sync.PhaseTimes[$i + 1]) { $sync.PhaseTimes[$i + 1] } else { Get-Date }
    if ($sync.PhaseTimes[$i]) { $phaseSec["$i"] = [math]::Round(($next - $sync.PhaseTimes[$i]).TotalSeconds, 1) }
  }
  $sync.Progress = 100.0
  Status 'Færdig.'
  return @{
    PhaseSec = $phaseSec
    Findings = @($AllFinds | Sort-Object Niveau -Descending)
    Timeline = @($AllTimes | Sort-Object Tid -Descending)
    Space    = @($AllSpace)
    Perf     = [pscustomobject]@{ BootSek = $(if ($boot) { [math]::Round([int]$boot / 1000) } else { $null }); RamBrugtPct = [math]::Round(100 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100)); Top = $top; SidsteStart = $os.LastBootUpTime }
    Suspect  = @($suspectWindows)
    Snapshot = $snap
  }
}

# =====================================================================
#  ARBEJDE I BAGGRUNDEN (oprydning, filer, opdateringer)
# =====================================================================
$CleanMeasureScript = {
  param($sync, $arg)
  $ErrorActionPreference = 'SilentlyContinue'
  $res = @{}
  foreach ($c in $arg.Cats) {
    $sync.Status = "Måler: $($c.Navn)..."
    $cut = (Get-Date).AddHours(-[double]$c.MinAgeHours)
    $sum = 0
    if ($c.Special -eq 'recycle') {
      $sum = (Get-ChildItem 'C:\$Recycle.Bin' -Recurse -Force -File | Measure-Object Length -Sum).Sum
    } else {
      foreach ($p in $c.Paths) {
        foreach ($root in @(Get-Item -Path $p -Force)) {
          if ($root.PSIsContainer) { $sum += (Get-ChildItem -LiteralPath $root.FullName -Recurse -Force -File | Where-Object { $_.LastWriteTime -lt $cut } | Measure-Object Length -Sum).Sum }
          else { if ($root.LastWriteTime -lt $cut) { $sum += $root.Length } }
        }
      }
    }
    $res[$c.Id] = [double]$sum
  }
  return $res
}
$CleanRunScript = {
  param($sync, $arg)
  $ErrorActionPreference = 'SilentlyContinue'
  $freed = @{}; $skipped = 0
  foreach ($c in $arg.Cats) {
    $sync.Status = "Rydder op: $($c.Navn)..."
    $cut = (Get-Date).AddHours(-[double]$c.MinAgeHours)
    $n = 0
    if ($c.Special -eq 'recycle') {
      $n = (Get-ChildItem 'C:\$Recycle.Bin' -Recurse -Force -File | Measure-Object Length -Sum).Sum
      Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    } elseif ($c.Special -eq 'do' -and (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) {
      Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue | Out-Null
    } else {
      foreach ($p in $c.Paths) {
        foreach ($root in @(Get-Item -Path $p -Force)) {
          $files = if ($root.PSIsContainer) { Get-ChildItem -LiteralPath $root.FullName -Recurse -Force -File } else { @($root) }
          foreach ($f in $files) {
            if ($f.LastWriteTime -ge $cut) { continue }
            $len = $f.Length
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n += $len } catch { $skipped++ }   # filer i brug springes over
          }
          if ($root.PSIsContainer) {   # tomme undermapper
            Get-ChildItem -LiteralPath $root.FullName -Recurse -Force -Directory | Sort-Object { $_.FullName.Length } -Descending |
              ForEach-Object { if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) { Remove-Item -LiteralPath $_.FullName -Force } }
          }
        }
      }
    }
    $freed[$c.Id] = [double]$n
  }
  $freed['_skipped'] = [double]$skipped
  return $freed
}

$FilesScript = {
  param($sync, $arg)
  $ErrorActionPreference = 'SilentlyContinue'
  $rows = New-Object System.Collections.ArrayList
  $prof = [Environment]::GetFolderPath('UserProfile')
  $dl = Join-Path $prof 'Downloads'
  $scanRoots = @($dl, [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), (Join-Path $prof 'Videos'), (Join-Path $prof 'Music'), (Join-Path $prof 'Pictures')) | Where-Object { Test-Path $_ }
  $sync.Status = 'Gennemgår dine mapper...'
  $all = foreach ($r in $scanRoots) { Get-ChildItem -LiteralPath $r -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(PC-Tjek-rapport|\.git|node_modules)\\' -and -not ($_.Attributes -band [IO.FileAttributes]::Offline) } }
  $all = @($all)

  # Dubletter: samme størrelse -> samme SHA256
  $sync.Status = 'Leder efter dubletter...'
  $cand = $all | Where-Object { $_.Length -ge 50KB } | Group-Object Length | Where-Object Count -gt 1
  $hashed = 0; $budget = 30GB
  foreach ($g in $cand) {
    if ($hashed -gt $budget) { break }
    $byHash = $g.Group | ForEach-Object { $hashed += $_.Length; [pscustomobject]@{ F = $_; H = $(try { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $null }) } } | Where-Object H | Group-Object H | Where-Object Count -gt 1
    foreach ($h in $byHash) {
      # behold den med "pæneste" navn (uden (1)), ellers den nyeste
      $sorted = $h.Group | Sort-Object @{ e = { $_.F.Name -match '\(\d+\)|kopi|copy' } }, @{ e = { $_.F.LastWriteTime }; Descending = $true }
      $keep = $sorted[0].F
      foreach ($x in $sorted) {
        $isKeep = $x.F.FullName -eq $keep.FullName
        [void]$rows.Add([pscustomobject]@{ Gruppe = 'Dublet'; Navn = $x.F.Name; Mappe = $x.F.DirectoryName; MB = [math]::Round($x.F.Length / 1MB, 1)
          Dato = $x.F.LastWriteTime; Forslag = -not $isKeep; Note = $(if ($isKeep) { "Behold (original) · $($h.Count) ens kopier" } else { "Kopi af $($keep.Name)" }); Sti = $x.F.FullName; Hash = $h.Name.Substring(0, 8) })
      }
    }
  }

  # Gamle installere i Overførsler
  $sync.Status = 'Finder gamle installere...'
  $progs = @($arg.Programs | ForEach-Object { ($_ -replace '[^a-z0-9]', '').ToLower() })
  Get-ChildItem -LiteralPath $dl -File -Force | Where-Object { $_.Extension -match '^\.(exe|msi|msix|msixbundle|appx)$' } | ForEach-Object {
    $base = (($_.BaseName -split '[-_ .(]')[0] -replace '[^a-z0-9]', '').ToLower()
    $installed = $base.Length -ge 4 -and ($progs | Where-Object { $_ -like "$base*" } | Select-Object -First 1)
    $old = $_.LastWriteTime -lt (Get-Date).AddDays(-14)
    $note = if ($installed) { 'Programmet er installeret, så installeren skal ikke bruges igen' } elseif ($old) { 'Gammel installer (over 14 dage)' } else { 'Ny installer. Behold, hvis du ikke har kørt den endnu' }
    [void]$rows.Add([pscustomobject]@{ Gruppe = 'Installer'; Navn = $_.Name; Mappe = $_.DirectoryName; MB = [math]::Round($_.Length / 1MB, 1); Dato = $_.LastWriteTime
      Forslag = [bool]($installed -or $old); Note = $note; Sti = $_.FullName; Hash = '' })
  }

  # Store filer
  $sync.Status = 'Finder de største filer...'
  $all | Where-Object { $_.Length -ge 300MB } | Sort-Object Length -Descending | Select-Object -First 30 | ForEach-Object {
    $fi = $_
    $note = switch -Regex ($fi.Extension) { '\.iso$' { 'Diskbillede. Kan slettes, hvis programmet er installeret' } '\.(zip|7z|rar)$' { 'Arkiv. Slet, hvis det allerede er pakket ud' } '\.(mp4|mkv|mov)$' { 'Video' } default { 'Stor fil' } }
    [void]$rows.Add([pscustomobject]@{ Gruppe = 'Stor fil'; Navn = $fi.Name; Mappe = $fi.DirectoryName; MB = [math]::Round($fi.Length / 1MB, 0); Dato = $fi.LastWriteTime
      Forslag = $false; Note = $note; Sti = $fi.FullName; Hash = '' })
  }
  return @($rows)
}

$WingetListScript = {
  param($sync, $arg)
  $sync.Status = 'Spørger winget om opdateringer (kan tage et minut)...'
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget blev ikke fundet. Installér "App Installer" fra Microsoft Store.' }
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  $lines = @(& winget upgrade --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { ([string]$_ -split "`r")[-1] })
  $sep = -1
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^-{10,}') { $sep = $i; break } }
  if ($sep -lt 1) {
    if (($lines -join ' ') -match '(?i)no installed package|no applicable|ingen installerede|ingen tilgængelige|no available upgrade') { return @() }
    throw 'Kunne ikke læse svaret fra winget. Prøv igen senere.'
  }
  $starts = @(); $m = [regex]::Matches($lines[$sep - 1], '\S+')
  foreach ($x in $m) { $starts += $x.Index }
  if ($starts.Count -lt 4) { return @() }
  $out = @()
  for ($i = $sep + 1; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ([string]::IsNullOrWhiteSpace($l) -or $l -match '^-{5,}') { if ($out.Count) { break } else { continue } }
    if ($l.Length -lt $starts[3] -or $l -match '^\d+ (opgraderinger|upgrades|pakke|package)' ) { continue }
    $cut = { param($a, $b) if ($l.Length -le $a) { '' } elseif ($b -lt 0 -or $b -gt $l.Length) { $l.Substring($a).Trim() } else { $l.Substring($a, $b - $a).Trim() } }
    $name = & $cut $starts[0] $starts[1]; $id = & $cut $starts[1] $starts[2]; $ver = & $cut $starts[2] $starts[3]
    $avail = & $cut $starts[3] $(if ($starts.Count -gt 4) { $starts[4] } else { -1 })
    if ($id -and $id -notmatch '\s' -and $avail) { $out += [pscustomobject]@{ Navn = $name; Id = $id; Version = $ver; Ny = $avail } }
  }
  return $out
}
$WingetUpgradeScript = {
  param($sync, $arg)
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  $res = @{}
  $i = 0
  foreach ($id in $arg.Ids) {
    $i++
    $sync.Status = "Opdaterer $id ($i af $($arg.Ids.Count))..."
    $o = & winget upgrade --id $id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { [string]$_ }
    $res[$id] = if ($LASTEXITCODE -eq 0) { 'OK' } else { "Fejl ($LASTEXITCODE)" }
  }
  return $res
}
$RestorePointScript = {
  param($sync, $arg)
  $sync.Status = 'Opretter gendannelsespunkt (kan tage op til et minut)...'
  Checkpoint-Computer -Description "PC-Tjek $($arg.Why)" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
  return 'ok'
}


$UpdateCheckScript = {
  param($sync, $arg)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $sync.Status = 'Søger efter app-opdatering...'
  # Find den nyeste udgave (commit) via GitHubs API, og hent filerne fra netop den. Så rammer vi aldrig en forældet kopi.
  $m = [regex]::Match($arg.Url, '^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/(.+)$')
  if ($m.Success) {
    try {
      $c = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/{1}/commits/{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value) -UseBasicParsing -TimeoutSec 15 -Headers @{ 'User-Agent' = 'PC-Tjek'; 'Accept' = 'application/vnd.github+json' }
      if ($c.sha -match '^[0-9a-f]{40}$') {
        $base = "https://raw.githubusercontent.com/{0}/{1}/{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $c.sha
        $v = Invoke-RestMethod -Uri "$base/version.json" -UseBasicParsing -TimeoutSec 15
        $v | Add-Member -NotePropertyName BaseUrl -NotePropertyValue $base -Force
        return $v
      }
    } catch { }
  }
  return (Invoke-RestMethod -Uri ("{0}/version.json?t={1}" -f $arg.Url, [DateTime]::UtcNow.Ticks) -UseBasicParsing -TimeoutSec 15 -Headers @{ 'Cache-Control' = 'no-cache' })
}
$UpdateApplyScript = {
  param($sync, $arg)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $tmp = Join-Path $arg.JobRoot ("update-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force $tmp | Out-Null
  $allowed = '^[\w\-. ]+\.(ps1|ico|cmd|md|txt)$'
  $i = 0
  $todo = @()
  foreach ($f in $arg.Files) {
    if ($f.name -notmatch $allowed -or $f.name -match '\.\.') { throw "Ugyldigt filnavn i opdateringen: $($f.name)" }
    $cur = Join-Path $arg.Dest $f.name
    if ((Test-Path $cur) -and (Get-FileHash -LiteralPath $cur -Algorithm SHA256).Hash -eq ([string]$f.sha256).ToUpper()) { continue }   # uændret: spring over
    $todo += $f
  }
  $arg.Files = $todo
  foreach ($f in $arg.Files) {
    $i++
    if ($f.name -notmatch $allowed -or $f.name -match '\.\.') { throw "Ugyldigt filnavn i opdateringen: $($f.name)" }
    $sync.Status = "Henter $($f.name) ($i af $($arg.Files.Count))..."
    $out = Join-Path $tmp $f.name
    Invoke-WebRequest -Uri ("{0}/{1}?t={2}" -f $arg.Url, [Uri]::EscapeDataString($f.name), [DateTime]::UtcNow.Ticks) -OutFile $out -UseBasicParsing -TimeoutSec 60
    $h = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash
    if ($h -ne ([string]$f.sha256).ToUpper()) { throw "Fingeraftrykket for $($f.name) passer ikke (forventet $($f.sha256), fik $h). Opdateringen er afbrudt, og intet er ændret." }
  }
  $sync.Status = 'Installerer opdatering...'
  $backup = Join-Path $arg.Dest ("backup-v" + $arg.OldVersion)
  New-Item -ItemType Directory -Force $backup | Out-Null
  foreach ($f in $arg.Files) {
    $target = Join-Path $arg.Dest $f.name
    if (Test-Path $target) { Copy-Item -Force $target $backup }
    $ok = $false
    for ($try = 0; $try -lt 5 -and -not $ok; $try++) {
      try { Copy-Item -Force (Join-Path $tmp $f.name) $target -ErrorAction Stop; $ok = $true } catch { Start-Sleep -Milliseconds 600 }
    }
    if (-not $ok) { throw "Kunne ikke erstatte $($f.name) (filen er i brug). Luk appen, og kør installeren i stedet." }
    Unblock-File $target -ErrorAction SilentlyContinue
  }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  return 'ok'
}


$SysInfoScript = {
  param($sync, $arg)
  $ErrorActionPreference = 'SilentlyContinue'
  $sync.Status = 'Læser pc-oplysninger...'
  $o = [ordered]@{}
  $os = Get-CimInstance Win32_OperatingSystem
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $up = (Get-Date) - $os.LastBootUpTime
  $o.OS = "$($os.Caption -replace 'Microsoft ', '') $($cv.DisplayVersion)"
  $o.OSsub = "Build $($cv.CurrentBuild).$($cv.UBR) · oppe i $([int]$up.TotalDays) d $($up.Hours) t"
  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  $o.CPU = ($cpu.Name -replace '\s+', ' ' -replace '\(R\)|\(TM\)', '').Trim()
  $o.CPUsub = "$($cpu.NumberOfCores) kerner / $($cpu.NumberOfLogicalProcessors) tråde · $([math]::Round($cpu.MaxClockSpeed / 1000, 1)) GHz · belastning $($cpu.LoadPercentage) %"
  $smi = "$env:SystemRoot\System32\nvidia-smi.exe"
  if (-not (Test-Path $smi)) { $smi = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe" }
  $gpuDone = $false
  if (Test-Path $smi) {
    $q = & $smi --query-gpu=name,memory.total,temperature.gpu,utilization.gpu,driver_version --format=csv,noheader,nounits 2>$null | Select-Object -First 1
    if ($q) { $p = $q -split ',\s*'; $o.GPU = $p[0]; $o.GPUsub = "$([math]::Round([double]$p[1] / 1024)) GB VRAM · $($p[2]) °C · belastning $($p[3]) % · driver $($p[4])"; $gpuDone = $true }
  }
  if (-not $gpuDone) {
    $g = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch '(?i)basic|virtual|remote|parsec|meta|mirage' } | Select-Object -First 1
    $vram = $null
    Get-ChildItem 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue | ForEach-Object {
      $pp = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
      if ($pp.DriverDesc -eq $g.Name -and $pp.'HardwareInformation.qwMemorySize') { $vram = [math]::Round([double]$pp.'HardwareInformation.qwMemorySize' / 1GB) }
    }
    $o.GPU = $g.Name; $o.GPUsub = "$(if ($vram) { "$vram GB VRAM · " })driver $($g.DriverVersion)"
  }
  $mods = @(Get-CimInstance Win32_PhysicalMemory)
  $tot = ($mods | Measure-Object Capacity -Sum).Sum
  $spd = ($mods | Measure-Object ConfiguredClockSpeed -Maximum).Maximum
  $used = [math]::Round(100 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100)
  $o.RAM = "$([math]::Round($tot / 1GB)) GB$(if ($spd) { " · $spd MT/s" })"
  $o.RAMsub = "$($mods.Count) moduler · $used % i brug lige nu"
  $mb = Get-CimInstance Win32_BaseBoard; $bios = Get-CimInstance Win32_BIOS
  $o.Board = "$($mb.Manufacturer -replace 'Micro-Star International Co., Ltd.', 'MSI' -replace 'ASUSTeK COMPUTER INC.', 'ASUS' -replace 'Gigabyte Technology Co., Ltd.', 'GIGABYTE') $($mb.Product)".Trim()
  $o.Boardsub = "BIOS $($bios.SMBIOSBIOSVersion) · $(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('dd-MM-yyyy') })"
  $dl = @()
  foreach ($d in @(Get-PhysicalDisk)) {
    $rc = $d | Get-StorageReliabilityCounter
    $t = if ($rc.Temperature) { " · $($rc.Temperature) °C" } else { '' }
    $h = if ($d.HealthStatus -eq 'Healthy') { 'sund' } else { [string]$d.HealthStatus }
    $dl += "$($d.FriendlyName) ($([math]::Round($d.Size / 1GB)) GB $($d.MediaType -replace 'Unspecified', '')) · $h$t"
  }
  $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
  $o.Disk = "C: $([math]::Round($c.FreeSpace / 1GB)) GB ledig af $([math]::Round($c.Size / 1GB)) GB"
  $o.Disksub = ($dl -join "`n")
  return $o
}


$CrashScript = {
  param($sync, $arg)
  $ErrorActionPreference = 'SilentlyContinue'
  $sync.Status = 'Læser nedbrud fra de seneste 14 dage...'
  $since = (Get-Date).AddDays(-14)
  $out = @{ Apps = @(); System = @(); Installs = @() }
  $apps = @{}
  foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1002; StartTime = $since } -MaxEvents 2000)) {
    if ($e.ProviderName -notin 'Application Error', 'Application Hang') { continue }
    $name = [string]$e.Properties[0].Value
    if (-not $name) { continue }
    $key = $name.ToLower()
    if (-not $apps.ContainsKey($key)) { $apps[$key] = @{ Name = $name; Crash = 0; Hang = 0; First = $e.TimeCreated; Last = $e.TimeCreated } }
    $a = $apps[$key]
    if ($e.Id -eq 1000) { $a.Crash++ } else { $a.Hang++ }
    if ($e.TimeCreated -lt $a.First) { $a.First = $e.TimeCreated }
    if ($e.TimeCreated -gt $a.Last) { $a.Last = $e.TimeCreated }
  }
  $out.Apps = @($apps.Values | ForEach-Object { [pscustomobject]$_ })
  $sys = @()
  foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 6008, 1001; StartTime = $since } -MaxEvents 500)) {
    if ($e.Id -eq 41 -and $e.ProviderName -like '*Kernel-Power*') { $sys += [pscustomobject]@{ Kind = 'restart'; Time = $e.TimeCreated } }
    elseif ($e.Id -eq 6008) { $sys += [pscustomobject]@{ Kind = 'shutdown'; Time = $e.TimeCreated } }
    elseif ($e.Id -eq 1001 -and $e.ProviderName -like '*WER-SystemErrorReporting*') { $sys += [pscustomobject]@{ Kind = 'bsod'; Time = $e.TimeCreated } }
  }
  $out.System = $sys
  $ins = @()
  foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 1033; StartTime = $since.AddDays(-3) } -MaxEvents 300)) { $ins += [pscustomobject]@{ Time = $e.TimeCreated; Name = [string]$e.Properties[0].Value } }
  foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19; StartTime = $since.AddDays(-3) } -MaxEvents 300)) { $ins += [pscustomobject]@{ Time = $e.TimeCreated; Name = "Windows-opdatering: $([string]$e.Properties[0].Value)" } }
  $out.Installs = $ins
  return $out
}


$GpuMeasureScript = {
  param($sync, $arg)
  $ErrorActionPreference = 'SilentlyContinue'
  $smi = "$env:SystemRoot\System32\nvidia-smi.exe"
  if (-not (Test-Path $smi)) { $smi = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe" }
  if (-not (Test-Path $smi)) { throw 'nvidia-smi blev ikke fundet. Måling kræver et NVIDIA-kort med driver.' }
  $dur = [int]$arg.Seconds
  $inv = [Globalization.CultureInfo]::InvariantCulture
  $samples = New-Object System.Collections.ArrayList
  $t0 = Get-Date
  for ($i = 0; $i -lt $dur; $i++) {
    $q = & $smi --query-gpu=power.draw,power.limit,temperature.gpu,fan.speed,clocks.gr,utilization.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1
    $p = @($q -split ',\s*')
    $num = { param($x) $v = 0.0; if ([double]::TryParse(([string]$x).Trim(), [Globalization.NumberStyles]::Float, $inv, [ref]$v)) { $v } else { $null } }
    $s = [pscustomobject]@{ W = (& $num $p[0]); Lim = (& $num $p[1]); T = (& $num $p[2]); F = (& $num $p[3]); C = (& $num $p[4]); U = (& $num $p[5]) }
    [void]$samples.Add($s)
    $sync.Progress = [double](100 * ($i + 1) / $dur)
    $sync.Status = "Måler... $($dur - $i - 1) sek tilbage · $([int]$s.W) W · $([int]$s.T) °C · $([int]$s.U) % belastning"
    $next = $t0.AddSeconds($i + 1); $wait = ($next - (Get-Date)).TotalMilliseconds; if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
  }
  $load = @($samples | Where-Object { $_.U -ge 60 })
  $use = if ($load.Count -ge 10) { $load } else { @($samples) }
  $avg = { param($prop) $v = @($use | ForEach-Object { $_.$prop } | Where-Object { $null -ne $_ }); if ($v.Count) { [math]::Round(($v | Measure-Object -Average).Average, 1) } else { $null } }
  return @{ W = (& $avg 'W'); Lim = (& $avg 'Lim'); T = (& $avg 'T'); F = (& $avg 'F'); C = (& $avg 'C'); U = (& $avg 'U')
            LowLoad = ($load.Count -lt 10); N = $use.Count; Time = (Get-Date) }
}
$GpuLibScript = {
  param($sync, $arg)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $sync.Status = 'Henter GPU-eksempler...'
  $j = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/iBlessi/gpu-undervolt-db/main/data/undervolt_results.json' -UseBasicParsing -TimeoutSec 15
  return @($j.results)
}

# =====================================================================
#  GUI
# =====================================================================
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC-Tjek" Width="1280" Height="820" MinWidth="1050" MinHeight="650" WindowStartupLocation="CenterScreen"
        Background="#0D0F14" Foreground="#E7E9EE" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="Card" Color="#161A23"/>
    <SolidColorBrush x:Key="Line" Color="#242A39"/>
    <SolidColorBrush x:Key="Muted" Color="#8A94A7"/>
    <LinearGradientBrush x:Key="Accent" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#8B5CF6" Offset="0"/><GradientStop Color="#3B9EFF" Offset="1"/>
    </LinearGradientBrush>

    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#E7E9EE"/><Setter Property="Background" Value="#222837"/>
      <Setter Property="Padding" Value="14,8"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.82"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.65"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource Accent}"/><Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#5A1E26"/>
    </Style>

    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#AEB6C6"/><Setter Property="Margin" Value="0,2"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid>
              <Border x:Name="bd" Background="Transparent" CornerRadius="8" Padding="14,10">
                <ContentPresenter/>
              </Border>
              <Border x:Name="bar" Width="3" CornerRadius="2" HorizontalAlignment="Left" Margin="0,9" Background="{StaticResource Accent}" Visibility="Collapsed"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#171B26"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1D2230"/>
                <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CardB" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Card}"/><Setter Property="CornerRadius" Value="12"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="16"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock"><Setter Property="FontSize" Value="24"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
    <Style x:Key="Sub" TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="TextWrapping" Value="Wrap"/></Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#10131A"/><Setter Property="Foreground" Value="#E7E9EE"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/><Setter Property="Padding" Value="8,5"/><Setter Property="CaretBrush" Value="#E7E9EE"/>
    </Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#E7E9EE"/><Setter Property="VerticalAlignment" Value="Center"/></Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="#E7E9EE"/>
      <Setter Property="RowBackground" Value="Transparent"/><Setter Property="AlternatingRowBackground" Value="#131722"/>
      <Setter Property="GridLinesVisibility" Value="None"/><Setter Property="BorderThickness" Value="0"/>
      <Setter Property="HeadersVisibility" Value="Column"/><Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/><Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="RowHeight" Value="32"/><Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Padding" Value="8,8"/><Setter Property="BorderThickness" Value="0,0,0,1"/><Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#2A2F55"/><Setter Property="Foreground" Value="White"/></Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="236"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

    <!-- ===== Sidemenu ===== -->
    <Border Background="#0A0C10" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
      <Grid Margin="14,20,14,16">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Orientation="Horizontal" Margin="8,0,0,22">
          <Border Width="34" Height="34" CornerRadius="9" Background="{StaticResource Accent}">
            <TextBlock Text="✓" FontSize="19" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="White"/>
          </Border>
          <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="PC-Tjek" FontSize="18" FontWeight="SemiBold"/>
            <TextBlock Name="VerText" Text="v2.0" FontSize="11" Foreground="{StaticResource Muted}"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Row="1">
          <RadioButton Name="NavHome"    Style="{StaticResource Nav}" GroupName="nav" IsChecked="True" Content="🏠   Overblik"/>
          <RadioButton Name="NavTweaks"  Style="{StaticResource Nav}" GroupName="nav" Content="⚡   Optimering"/>
          <RadioButton Name="NavVagt"    Style="{StaticResource Nav}" GroupName="nav" Content="🛡   Vagt"/>
          <RadioButton Name="NavFind"    Style="{StaticResource Nav}" GroupName="nav" Content="🚩   Fund"/>
          <RadioButton Name="NavTime"    Style="{StaticResource Nav}" GroupName="nav" Content="🕒   Hændelsesforløb"/>
          <RadioButton Name="NavStart"   Style="{StaticResource Nav}" GroupName="nav" Content="🚀   Opstart"/>
          <RadioButton Name="NavClean"   Style="{StaticResource Nav}" GroupName="nav" Content="🧹   Oprydning"/>
          <RadioButton Name="NavFiles"   Style="{StaticResource Nav}" GroupName="nav" Content="🗂   Filer"/>
          <RadioButton Name="NavUpdates" Style="{StaticResource Nav}" GroupName="nav" Content="⬆   Opdateringer"/>
          <RadioButton Name="NavHealth"  Style="{StaticResource Nav}" GroupName="nav" Content="💓   Ydelse og helbred"/>
        </StackPanel>
        <StackPanel Grid.Row="2">
          <Border Name="UpdateBanner" Visibility="Collapsed" CornerRadius="10" Padding="12" Margin="0,0,0,12" Background="#1E1838" BorderBrush="#8B5CF6" BorderThickness="1">
            <StackPanel>
              <TextBlock Name="UpdateText" Text="✨ Ny version klar" FontWeight="SemiBold" TextWrapping="Wrap"/>
              <TextBlock Name="UpdateNotes" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,4,0,10"/>
              <Button Name="BtnUpdateApp" Content="⬇  Opdatér nu" Style="{StaticResource Primary}" Margin="0"/>
            </StackPanel>
          </Border>
          <Button Name="BtnScan" Style="{StaticResource Primary}" Content="🔍   Scan pc'en" Padding="14,12" Margin="0,0,0,10" FontSize="14"/>
          <ProgressBar Name="Busy" Height="3" Maximum="100" IsIndeterminate="True" Visibility="Hidden" Foreground="#8B5CF6" Background="Transparent" BorderThickness="0" Margin="0,0,0,8"/>
          <TextBlock Name="StatusText" Text="Klar" Foreground="{StaticResource Muted}" TextWrapping="Wrap" FontSize="12"/>
          <Button Name="BtnCheckUpdate" Content="Søg efter app-opdatering" Background="Transparent" Foreground="#6B7488" Padding="0,8,0,0" HorizontalAlignment="Left" FontSize="11" Margin="0"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ===== Indhold ===== -->
    <Grid Grid.Column="1" Margin="28,22,28,20">

      <!-- OVERBLIK -->
      <Grid Name="PageHome">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <DockPanel Margin="0,0,0,18">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <Button Name="BtnExport" Content="📄  Eksportér rapport" IsEnabled="False"/>
            <Button Name="BtnUndo" Content="↶  Fortryd seneste" Margin="0"/>
          </StackPanel>
          <StackPanel><TextBlock Style="{StaticResource H1}" Text="Overblik"/><TextBlock Name="Verdict" Style="{StaticResource Sub}" Text="Tryk på Scan pc'en. Scanningen læser kun og ændrer intet."/></StackPanel>
        </DockPanel>
        <Grid Grid.Row="1" Margin="0,0,0,16">
          <Grid.ColumnDefinitions><ColumnDefinition Width="250"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Border Style="{StaticResource CardB}" Margin="0,0,16,0">
            <Grid Width="150" Height="150" HorizontalAlignment="Center" VerticalAlignment="Center">
              <Ellipse Stroke="#242A39" StrokeThickness="12" Margin="6"/>
              <Path Name="ScoreArc" StrokeThickness="12" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stroke="{StaticResource Accent}"/>
              <StackPanel VerticalAlignment="Center">
                <TextBlock Name="ScoreText" Text="–" FontSize="42" FontWeight="Bold" HorizontalAlignment="Center"/>
                <TextBlock Name="ScoreLabel" Text="ikke scannet" FontSize="12" Foreground="{StaticResource Muted}" HorizontalAlignment="Center"/>
              </StackPanel>
            </Grid>
          </Border>
          <UniformGrid Grid.Column="1" Columns="3">
            <Border Name="SecCard" Style="{StaticResource CardB}" Margin="0,0,10,0" Cursor="Hand" ToolTip="Klik for at se fundene">
              <StackPanel><TextBlock Text="🛡  Sikkerhed" Foreground="{StaticResource Muted}"/>
                <TextBlock Name="SecValue" Text="–" FontSize="26" FontWeight="Bold" Margin="0,6,0,0"/>
                <TextBlock Name="SecSub" Text="ikke scannet endnu" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,4,0,0"/></StackPanel></Border>
            <Border Style="{StaticResource CardB}" Margin="0,0,10,0">
              <StackPanel><TextBlock Text="💾  Lagerplads" Foreground="{StaticResource Muted}"/>
                <TextBlock Name="CntSpace" Text="–" FontSize="26" FontWeight="Bold" Foreground="#60A5FA" Margin="0,6,0,0"/>
                <TextBlock Name="SpaceSub" Text="kan ryddes" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,4,0,0"/></StackPanel></Border>
            <Border Style="{StaticResource CardB}">
              <StackPanel><TextBlock Text="🚀  Opstart" Foreground="{StaticResource Muted}"/>
                <TextBlock Name="StartValue" Text="–" FontSize="26" FontWeight="Bold" Foreground="#C084FC" Margin="0,6,0,0"/>
                <TextBlock Name="StartSub" Text="programmer starter med Windows" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,4,0,0"/></StackPanel></Border>
          </UniformGrid>
        </Grid>
        <Border Grid.Row="2" Style="{StaticResource CardB}" Margin="0,0,0,16" Padding="18,14">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <DockPanel Margin="0,0,0,10">
              <Button Name="BtnCopyInfo" DockPanel.Dock="Right" Content="📋  Kopiér til support" Padding="10,5" Margin="0" FontSize="12"/>
              <TextBlock Text="💻  Din pc" FontWeight="SemiBold" FontSize="15" VerticalAlignment="Center"/>
            </DockPanel>
            <UniformGrid Grid.Row="1" Columns="3">
              <StackPanel Margin="0,0,16,10"><TextBlock Text="SYSTEM" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="SysOS" Text="…" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/><TextBlock Name="SysOSsub" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap"/></StackPanel>
              <StackPanel Margin="0,0,16,10"><TextBlock Text="PROCESSOR" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="SysCpu" Text="…" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/><TextBlock Name="SysCpusub" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap"/></StackPanel>
              <StackPanel Margin="0,0,0,10"><TextBlock Text="GRAFIKKORT" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="SysGpu" Text="…" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/><TextBlock Name="SysGpusub" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap"/></StackPanel>
              <StackPanel Margin="0,0,16,0"><TextBlock Text="HUKOMMELSE" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="SysRam" Text="…" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/><TextBlock Name="SysRamsub" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap"/></StackPanel>
              <StackPanel Margin="0,0,16,0"><TextBlock Text="BUNDKORT" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="SysBoard" Text="…" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/><TextBlock Name="SysBoardsub" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap"/></StackPanel>
              <StackPanel><TextBlock Text="LAGER" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="SysDisk" Text="…" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/><TextBlock Name="SysDisksub" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap"/></StackPanel>
            </UniformGrid>
          </Grid>
        </Border>
        <Grid Grid.Row="3">
        <Border Name="ScanCard" Style="{StaticResource CardB}" Padding="28,24" Visibility="Collapsed" Panel.ZIndex="1">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" HorizontalAlignment="Right">
                <TextBlock Name="ScanEta" Text="beregner tid..." FontSize="17" FontWeight="SemiBold" HorizontalAlignment="Right"/>
                <TextBlock Name="ScanElapsed" Text="" Foreground="{StaticResource Muted}" HorizontalAlignment="Right" Margin="0,2,0,0"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal">
                <TextBlock Name="ScanPct" Text="0" FontSize="40" FontWeight="Bold"/>
                <TextBlock Text="%" FontSize="22" Foreground="{StaticResource Muted}" VerticalAlignment="Bottom" Margin="4,0,0,8"/>
              </StackPanel>
            </DockPanel>
            <ProgressBar Name="ScanBar" Grid.Row="1" Height="10" Maximum="100" Margin="0,14,0,16" Foreground="{StaticResource Accent}" Background="#242A39" BorderThickness="0"/>
            <TextBlock Name="ScanStep" Grid.Row="2" Text="Starter..." FontSize="16" FontWeight="SemiBold"/>
            <TextBlock Name="ScanDetail" Grid.Row="3" Text="" Foreground="#6FA8FF" Margin="0,4,0,0"/>
            <TextBlock Name="ScanPhases" Grid.Row="4" Margin="0,18,0,0" FontSize="14" LineHeight="26" Foreground="{StaticResource Muted}"/>
          </Grid>
        </Border>
        <!-- DIN PLAN -->
        <Grid Name="PlanCard">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,12">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
              <Button Name="BtnFixAll" Content="🧹  Ryd anbefalede filer" Style="{StaticResource Primary}" Visibility="Collapsed" Padding="18,10" FontSize="14"/>
              <Button Name="BtnDetails" Content="Vis detaljer" Visibility="Collapsed" Margin="0"/>
            </StackPanel>
            <StackPanel>
              <TextBlock Name="PlanTitle" Text="Din plan" FontSize="20" FontWeight="SemiBold"/>
              <TextBlock Name="PlanSub" Style="{StaticResource Sub}" Text="Tryk på Scan pc'en. Bagefter får du en kort liste med det, du skal gøre, med én knap til hvert trin."/>
            </StackPanel>
          </DockPanel>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <ItemsControl Name="PlanList">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <Border Background="#161A23" BorderBrush="#242A39" BorderThickness="1" CornerRadius="12" Padding="16,14" Margin="0,0,0,10">
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="52"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <Border Width="36" Height="36" CornerRadius="18" Background="{StaticResource Accent}" VerticalAlignment="Center" HorizontalAlignment="Left">
                        <TextBlock Text="{Binding Gruppe}" FontSize="15" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Border>
                      <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,16,0">
                        <TextBlock Text="{Binding Navn}" FontSize="15.5" FontWeight="SemiBold" TextWrapping="Wrap"/>
                        <TextBlock Text="{Binding Info}" Foreground="#8A94A7" TextWrapping="Wrap" Margin="0,3,0,0"/>
                      </StackPanel>
                      <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="{Binding Status}" Foreground="#4ADE80" VerticalAlignment="Center" Margin="0,0,12,0" FontWeight="SemiBold"/>
                        <Button Content="{Binding Note}" Tag="{Binding Id}" IsEnabled="{Binding Valgt}" Style="{StaticResource Primary}" Margin="0" MinWidth="150"/>
                      </StackPanel>
                    </Grid>
                  </Border>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </ScrollViewer>
        </Grid>
        <Border Name="StoryCard" Style="{StaticResource CardB}" Padding="0" Visibility="Collapsed">
          <TextBox Name="Story" Background="Transparent" BorderThickness="0" Padding="20,16" IsReadOnly="True" TextWrapping="Wrap" FontSize="13.5"
                   VerticalScrollBarVisibility="Auto" FontFamily="Segoe UI Variable Text, Segoe UI"
                   Text="Analysen vises her efter scanningen: hvad der er fundet, hvad en evt. falsk installer gjorde, og hvad du bør gøre."/>
        </Border>
        </Grid>
      </Grid>

      <!-- VAGT -->
      <Grid Name="PageVagt" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <StackPanel Margin="0,0,0,16">
          <TextBlock Style="{StaticResource H1}" Text="Vagt"/>
          <TextBlock Style="{StaticResource Sub}" Text="Passer på din pc i baggrunden, også når PC-Tjek er lukket. Du får en lille besked nederst til højre, hvis der sker noget."/>
        </StackPanel>
        <Border Grid.Row="1" Style="{StaticResource CardB}" Padding="22,18" Margin="0,0,0,14">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="72"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border Name="VagtIconBg" Width="56" Height="56" CornerRadius="16" Background="#242A39" HorizontalAlignment="Left">
              <TextBlock Name="VagtIcon" Text="🛡" FontSize="27" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1" VerticalAlignment="Center">
              <TextBlock Name="VagtStatus" Text="Tjekker..." FontSize="20" FontWeight="SemiBold"/>
              <TextBlock Name="VagtSub" Style="{StaticResource Sub}" Margin="0,3,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
              <Button Name="BtnVagtTest" Content="👀  Vis et eksempel"/>
              <Button Name="BtnVagtToggle" Content="Slå vagten til" Style="{StaticResource Primary}" Padding="18,10" Margin="0"/>
            </StackPanel>
          </Grid>
        </Border>
        <UniformGrid Grid.Row="2" Columns="2" Margin="0,0,0,14">
          <Border Style="{StaticResource CardB}" Margin="0,0,7,0" Padding="18,16">
            <DockPanel>
              <CheckBox Name="ChkDl" DockPanel.Dock="Right" IsChecked="True" VerticalAlignment="Top" RenderTransformOrigin="0.5,0.5"><CheckBox.RenderTransform><ScaleTransform ScaleX="1.4" ScaleY="1.4"/></CheckBox.RenderTransform></CheckBox>
              <StackPanel Margin="0,0,12,0">
                <TextBlock Text="🛡  Download-vagt" FontSize="15.5" FontWeight="SemiBold"/>
                <TextBlock Style="{StaticResource Sub}" Margin="0,5,0,0" Text="Tjekker programfiler, du henter, med det samme: hvem der har lavet dem, hvor de kommer fra, og om Defender finder noget. Advarer, før du kører noget farligt."/>
                <TextBlock Name="VagtDlInfo" Margin="0,8,0,0" FontSize="12" Foreground="#6FA8FF"/>
              </StackPanel>
            </DockPanel>
          </Border>
          <Border Style="{StaticResource CardB}" Margin="7,0,0,0" Padding="18,16">
            <DockPanel>
              <CheckBox Name="ChkWd" DockPanel.Dock="Right" IsChecked="True" VerticalAlignment="Top" RenderTransformOrigin="0.5,0.5"><CheckBox.RenderTransform><ScaleTransform ScaleX="1.4" ScaleY="1.4"/></CheckBox.RenderTransform></CheckBox>
              <StackPanel Margin="0,0,12,0">
                <TextBlock Text="👀  Vagthund" FontSize="15.5" FontWeight="SemiBold"/>
                <TextBlock Style="{StaticResource Sub}" Margin="0,5,0,0" Text="Giver besked, når noget nyt sætter sig fast, eller når noget kendt pludselig peger på et andet program: opstart, planlagte opgaver, tjenester, browserudvidelser og Defender-undtagelser."/>
                <TextBlock Name="VagtWdInfo" Margin="0,8,0,0" FontSize="12" Foreground="#6FA8FF"/>
              </StackPanel>
            </DockPanel>
          </Border>
        </UniformGrid>
        <Border Grid.Row="3" Style="{StaticResource CardB}" Padding="6">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <DockPanel Margin="10,6,6,6">
              <Button Name="BtnVagtRefresh" DockPanel.Dock="Right" Content="⟳" Margin="0" Padding="10,4"/>
              <TextBlock Text="Det har vagten set" FontWeight="SemiBold" VerticalAlignment="Center"/>
            </DockPanel>
            <DataGrid Name="GridVagt" Grid.Row="1" IsReadOnly="True">
              <DataGrid.Columns>
                <DataGridTextColumn Header="TID" Binding="{Binding Tid, StringFormat='dd-MM HH:mm'}" Width="100"/>
                <DataGridTextColumn Header="" Binding="{Binding Ikon}" Width="36"/>
                <DataGridTextColumn Header="TYPE" Binding="{Binding Type}" Width="100"/>
                <DataGridTextColumn Header="HVAD" Binding="{Binding Titel}" Width="2*"/>
                <DataGridTextColumn Header="DETALJE" Binding="{Binding Detalje}" Width="3*"/>
              </DataGrid.Columns>
            </DataGrid>
          </Grid>
        </Border>
      </Grid>

      <!-- OPTIMERING -->
      <Grid Name="PageTweaks" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <DockPanel Margin="0,0,0,16">
          <Button Name="BtnTweakRefresh" DockPanel.Dock="Right" Content="⟳  Tjek igen" VerticalAlignment="Center" Margin="0"/>
          <StackPanel>
            <TextBlock Style="{StaticResource H1}" Text="Optimering"/>
            <TextBlock Name="TweakSummary" Style="{StaticResource Sub}" Text="Gratis ydelse, der ofte bliver glemt. Intet ændres, uden at du selv gør det."/>
          </StackPanel>
        </DockPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
          <StackPanel>
        <Border Style="{StaticResource CardB}" Margin="0,0,0,14" Padding="20,18">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="66"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border Width="50" Height="50" CornerRadius="15" Background="{StaticResource Accent}" VerticalAlignment="Top" HorizontalAlignment="Left">
              <TextBlock Text="🧠" FontSize="24" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1" Margin="0,0,16,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Hukommelse (RAM)" FontSize="17" FontWeight="SemiBold" VerticalAlignment="Center"/>
                <Border Name="RamBadge" CornerRadius="10" Padding="10,3" Margin="12,0,0,0" Background="#1D2433" VerticalAlignment="Center">
                  <TextBlock Name="RamBadgeText" Text="Tjekker..." FontSize="12" FontWeight="SemiBold" Foreground="#8AB4FF"/>
                </Border>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                <StackPanel><TextBlock Name="RamNowLbl" Text="NU" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="RamNow" Text="–" FontSize="26" FontWeight="Bold"/></StackPanel>
                <TextBlock Name="RamArrow" Text="→" FontSize="24" Foreground="#5A6478" Margin="20,16,20,0"/>
                <StackPanel><TextBlock Name="RamCanLbl" Text="MULIGT" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="RamCan" Text="–" FontSize="26" FontWeight="Bold" Foreground="#A78BFA"/></StackPanel>
              </StackPanel>
              <TextBlock Name="RamText" TextWrapping="Wrap" Foreground="#AEB6C6" Margin="0,12,0,0" LineHeight="20"/>
              <Border Name="RamSteps" Visibility="Collapsed" Background="#10131A" BorderBrush="#242A39" BorderThickness="1" CornerRadius="10" Padding="16,12" Margin="0,12,0,0">
                <TextBlock Name="RamStepsText" TextWrapping="Wrap" LineHeight="23"/>
              </Border>
            </StackPanel>
            <StackPanel Grid.Column="2" VerticalAlignment="Top" MinWidth="190">
              <Button Name="RamAction" Content="" Style="{StaticResource Primary}" Margin="0,0,0,8" Visibility="Collapsed"/>
              <Button Name="RamAction2" Content="" Margin="0,0,0,8" Visibility="Collapsed"/>
              <Button Name="RamHow" Content="📖  Sådan gør du" Margin="0"/>
            </StackPanel>
          </Grid>
        </Border>
        <Border Style="{StaticResource CardB}" Margin="0,0,0,14" Padding="20,18">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="66"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border Width="50" Height="50" CornerRadius="15" Background="{StaticResource Accent}" VerticalAlignment="Top" HorizontalAlignment="Left">
              <TextBlock Text="🖥" FontSize="24" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1" Margin="0,0,16,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Skærmens opdateringshastighed" FontSize="17" FontWeight="SemiBold" VerticalAlignment="Center"/>
                <Border Name="HzBadge" CornerRadius="10" Padding="10,3" Margin="12,0,0,0" Background="#1D2433" VerticalAlignment="Center">
                  <TextBlock Name="HzBadgeText" Text="Tjekker..." FontSize="12" FontWeight="SemiBold" Foreground="#8AB4FF"/>
                </Border>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                <StackPanel><TextBlock Name="HzNowLbl" Text="NU" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="HzNow" Text="–" FontSize="26" FontWeight="Bold"/></StackPanel>
                <TextBlock Name="HzArrow" Text="→" FontSize="24" Foreground="#5A6478" Margin="20,16,20,0"/>
                <StackPanel><TextBlock Name="HzCanLbl" Text="MULIGT" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="HzCan" Text="–" FontSize="26" FontWeight="Bold" Foreground="#A78BFA"/></StackPanel>
              </StackPanel>
              <TextBlock Name="HzText" TextWrapping="Wrap" Foreground="#AEB6C6" Margin="0,12,0,0" LineHeight="20"/>
              <Border Name="HzSteps" Visibility="Collapsed" Background="#10131A" BorderBrush="#242A39" BorderThickness="1" CornerRadius="10" Padding="16,12" Margin="0,12,0,0">
                <TextBlock Name="HzStepsText" TextWrapping="Wrap" LineHeight="23"/>
              </Border>
            </StackPanel>
            <StackPanel Grid.Column="2" VerticalAlignment="Top" MinWidth="190">
              <Button Name="HzAction" Content="" Style="{StaticResource Primary}" Margin="0,0,0,8" Visibility="Collapsed"/>
              <Button Name="HzAction2" Content="" Margin="0,0,0,8" Visibility="Collapsed"/>
              <Button Name="HzHow" Content="📖  Sådan gør du" Margin="0"/>
            </StackPanel>
          </Grid>
        </Border>
        <Border Style="{StaticResource CardB}" Margin="0,0,0,14" Padding="20,18">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="66"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border Width="50" Height="50" CornerRadius="15" Background="{StaticResource Accent}" VerticalAlignment="Top" HorizontalAlignment="Left">
              <TextBlock Text="🔧" FontSize="24" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1" Margin="0,0,16,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Drivere og BIOS" FontSize="17" FontWeight="SemiBold" VerticalAlignment="Center"/>
                <Border Name="DrvBadge" CornerRadius="10" Padding="10,3" Margin="12,0,0,0" Background="#1D2433" VerticalAlignment="Center">
                  <TextBlock Name="DrvBadgeText" Text="Tjekker..." FontSize="12" FontWeight="SemiBold" Foreground="#8AB4FF"/>
                </Border>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                <StackPanel><TextBlock Name="DrvNowLbl" Text="NU" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="DrvNow" Text="–" FontSize="26" FontWeight="Bold"/></StackPanel>
                <TextBlock Name="DrvArrow" Text="→" FontSize="24" Foreground="#5A6478" Margin="20,16,20,0"/>
                <StackPanel><TextBlock Name="DrvCanLbl" Text="MULIGT" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="DrvCan" Text="–" FontSize="26" FontWeight="Bold" Foreground="#A78BFA"/></StackPanel>
              </StackPanel>
              <TextBlock Name="DrvText" TextWrapping="Wrap" Foreground="#AEB6C6" Margin="0,12,0,0" LineHeight="20"/>
              <Border Name="DrvSteps" Visibility="Collapsed" Background="#10131A" BorderBrush="#242A39" BorderThickness="1" CornerRadius="10" Padding="16,12" Margin="0,12,0,0">
                <TextBlock Name="DrvStepsText" TextWrapping="Wrap" LineHeight="23"/>
              </Border>
            </StackPanel>
            <StackPanel Grid.Column="2" VerticalAlignment="Top" MinWidth="190">
              <Button Name="DrvAction" Content="" Style="{StaticResource Primary}" Margin="0,0,0,8" Visibility="Collapsed"/>
              <Button Name="DrvAction2" Content="" Margin="0,0,0,8" Visibility="Collapsed"/>
              <Button Name="DrvHow" Content="📖  Sådan gør du" Margin="0"/>
            </StackPanel>
          </Grid>
        </Border>
        <!-- GPU-TUNING -->
        <Border Style="{StaticResource CardB}" Margin="0,0,0,14" Padding="20,18">
          <StackPanel>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="66"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Border Width="50" Height="50" CornerRadius="15" Background="{StaticResource Accent}" VerticalAlignment="Top" HorizontalAlignment="Left">
                <TextBlock Text="🎮" FontSize="24" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="Grafikkort: mindre strøm og støj" FontSize="17" FontWeight="SemiBold" VerticalAlignment="Center"/>
                  <Border CornerRadius="10" Padding="10,3" Margin="12,0,0,0" Background="#3B2C6E" VerticalAlignment="Center"><TextBlock Text="Avanceret" FontSize="12" FontWeight="SemiBold" Foreground="#C4B5FD"/></Border>
                </StackPanel>
                <TextBlock Name="GpuName" Foreground="#AEB6C6" Margin="0,4,0,0"/>
                <TextBlock Style="{StaticResource Sub}" Margin="0,8,0,0" Text="Kan dit grafikkort bruge mindre strøm og larme mindre, uden at du mister mærkbar ydelse? Mål det før og efter én ændring, så du kan se, om det var det værd."/>
              </StackPanel>
              <StackPanel Grid.Column="2" VerticalAlignment="Top" MinWidth="190">
                <Button Name="BtnGpuTool" Content="🛠  Åbn tuningværktøj" Style="{StaticResource Primary}" Margin="0,0,0,8"/>
                <Button Name="BtnGpuAb" Content="MSI Afterburner" Margin="0,0,0,8"/>
                <Button Name="GpuHow" Content="📖  Sådan gør du" Margin="0"/>
              </StackPanel>
            </Grid>
            <Border Name="GpuSteps" Visibility="Collapsed" Background="#10131A" BorderBrush="#242A39" BorderThickness="1" CornerRadius="10" Padding="16,12" Margin="0,14,0,0">
              <TextBlock Name="GpuStepsText" TextWrapping="Wrap" LineHeight="23"/>
            </Border>
            <!-- live -->
            <UniformGrid Columns="5" Margin="0,16,0,0">
              <StackPanel><TextBlock Text="EFFEKT" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GpuLiveW" Text="–" FontSize="22" FontWeight="Bold"/></StackPanel>
              <StackPanel><TextBlock Text="TEMPERATUR" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GpuLiveT" Text="–" FontSize="22" FontWeight="Bold"/></StackPanel>
              <StackPanel><TextBlock Text="BLÆSER" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GpuLiveF" Text="–" FontSize="22" FontWeight="Bold"/></StackPanel>
              <StackPanel><TextBlock Text="CLOCK" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GpuLiveC" Text="–" FontSize="22" FontWeight="Bold"/></StackPanel>
              <StackPanel><TextBlock Text="BELASTNING" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GpuLiveU" Text="–" FontSize="22" FontWeight="Bold"/></StackPanel>
            </UniformGrid>
            <!-- mål før/efter -->
            <Border Background="#10131A" BorderBrush="#242A39" BorderThickness="1" CornerRadius="12" Padding="16,14" Margin="0,16,0,0">
              <StackPanel>
                <TextBlock Text="📏  Mål før og efter" FontSize="15" FontWeight="SemiBold"/>
                <TextBlock Name="GpuMeasureInfo" Style="{StaticResource Sub}" Margin="0,4,0,10" Text="1) Start et spil, og stil dig samme sted med samme indstillinger. 2) Tryk 'Mål FØR', og spil i 2 minutter. 3) Lav ÉN ændring i tuningværktøjet. 4) Tryk 'Mål EFTER', og spil samme sekvens igen."/>
                <WrapPanel>
                  <Button Name="BtnGpuBefore" Content="①  Mål FØR (2 min)" Style="{StaticResource Primary}"/>
                  <Button Name="BtnGpuAfter" Content="②  Mål EFTER (2 min)" IsEnabled="False"/>
                  <TextBlock Text="FPS før:" VerticalAlignment="Center" Margin="10,0,6,0" Foreground="{StaticResource Muted}"/>
                  <TextBox Name="TxtFpsBefore" Width="60" ToolTip="Valgfrit: læs FPS i spillet eller i NVIDIA-overlay (Alt+R)"/>
                  <TextBlock Text="efter:" VerticalAlignment="Center" Margin="8,0,6,0" Foreground="{StaticResource Muted}"/>
                  <TextBox Name="TxtFpsAfter" Width="60"/>
                </WrapPanel>
                <ProgressBar Name="GpuMeasureBar" Height="6" Maximum="100" Margin="0,12,0,0" Foreground="{StaticResource Accent}" Background="#242A39" BorderThickness="0" Visibility="Collapsed"/>
                <TextBlock Name="GpuResult" TextWrapping="Wrap" FontSize="15" FontWeight="SemiBold" Margin="0,12,0,0"/>
                <TextBlock Name="GpuVerdict" TextWrapping="Wrap" Margin="0,6,0,0" Foreground="#AEB6C6"/>
                <DockPanel Name="GpuSavePanel" Margin="0,10,0,0" Visibility="Collapsed">
                  <Button Name="BtnGpuSave" DockPanel.Dock="Right" Content="💾  Gem som 'Testet på min pc'" Margin="8,0,0,0"/>
                  <TextBox Name="TxtGpuNote" ToolTip="Hvad ændrede du? Fx 'Afterburner: 900 mV @ 2600 MHz' eller 'NVIDIA App: auto-tuning'"/>
                </DockPanel>
              </StackPanel>
            </Border>
            <!-- testet på min pc -->
            <TextBlock Text="🏠  Testet på min pc" FontSize="15" FontWeight="SemiBold" Margin="0,18,0,6"/>
            <DataGrid Name="GridGpuMine" IsReadOnly="True" MaxHeight="200">
              <DataGrid.Columns>
                <DataGridTextColumn Header="DATO" Binding="{Binding Gruppe}" Width="100"/>
                <DataGridTextColumn Header="ÆNDRING" Binding="{Binding Navn}" Width="2*"/>
                <DataGridTextColumn Header="RESULTAT" Binding="{Binding Info}" Width="3*"/>
              </DataGrid.Columns>
            </DataGrid>
            <TextBlock Name="GpuMineEmpty" Style="{StaticResource Sub}" Text="Ingen målinger endnu. Gem din første før/efter-måling ovenfor."/>
            <!-- testet af andre -->
            <DockPanel Margin="0,18,0,6">
              <Button Name="BtnGpuSrc" DockPanel.Dock="Right" Content="🔗  Åbn kilde" Padding="10,5" Margin="0" IsEnabled="False"/>
              <TextBlock Text="🌍  Testet af andre" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
            </DockPanel>
            <TextBlock Name="GpuLibInfo" Style="{StaticResource Sub}" Margin="0,0,0,6" Text="Henter eksempler..."/>
            <DataGrid Name="GridGpuLib" IsReadOnly="True" MaxHeight="240">
              <DataGrid.Columns>
                <DataGridTextColumn Header="KORT" Binding="{Binding Navn}" Width="2*"/>
                <DataGridTextColumn Header="METODE / INDSTILLING" Binding="{Binding Info}" Width="3*"/>
                <DataGridTextColumn Header="RESULTAT" Binding="{Binding Note}" Width="2*"/>
                <DataGridTextColumn Header="KILDETYPE" Binding="{Binding Gruppe}" Width="120"/>
              </DataGrid.Columns>
            </DataGrid>
            <TextBlock FontSize="11" Foreground="#6B7488" Margin="0,6,0,0" TextWrapping="Wrap" Text="Eksempler: TechFuelHQ Community GPU Undervolt Results (CC BY 4.0), github.com/iBlessi/gpu-undervolt-db. To kort med samme GPU kan opføre sig forskelligt, så din egen måling tæller mest."/>
          </StackPanel>
        </Border>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- FUND -->
      <Grid Name="PageFind" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Margin="0,0,0,14"><TextBlock Style="{StaticResource H1}" Text="Fund"/><TextBlock Style="{StaticResource Sub}" Text="Alt, scanningen har fundet, sorteret efter risiko. Vælg en række for at se forklaringen og hvad du kan gøre."/></StackPanel>
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10">
          <ComboBox Name="FilterRisk" Width="190" SelectedIndex="1">
            <ComboBoxItem Content="Alt"/><ComboBoxItem Content="Mellem og derover"/><ComboBoxItem Content="Kun Høj og Kritisk"/><ComboBoxItem Content="Kun bloat"/><ComboBoxItem Content="Kun nyt siden sidst"/>
          </ComboBox>
          <TextBox Name="FilterText" Width="280" Margin="10,0,0,0" ToolTip="Søg i fund"/>
        </StackPanel>
        <Border Grid.Row="2" Style="{StaticResource CardB}" Padding="6">
          <DataGrid Name="GridFind" IsReadOnly="True">
            <DataGrid.Columns>
              <DataGridTextColumn Header="RISIKO" Binding="{Binding Risiko}" Width="80"/>
              <DataGridTextColumn Header="KATEGORI" Binding="{Binding Kategori}" Width="130"/>
              <DataGridTextColumn Header="FUND" Binding="{Binding Titel}" Width="2*"/>
              <DataGridTextColumn Header="DETALJE" Binding="{Binding Detalje}" Width="3*"/>
            </DataGrid.Columns>
          </DataGrid>
        </Border>
        <Border Grid.Row="3" Style="{StaticResource CardB}" Margin="0,12,0,0">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock Name="DetWhy" TextWrapping="Wrap" Text="Vælg et fund for at se forklaringen."/>
              <TextBlock Name="DetAdvice" TextWrapping="Wrap" Margin="0,8,0,0" FontWeight="SemiBold" Foreground="#A78BFA"/>
              <TextBox Name="DetPath" Margin="0,6,0,0" Background="Transparent" Foreground="{StaticResource Muted}" BorderThickness="0" Padding="0" IsReadOnly="True" TextWrapping="Wrap"/>
            </StackPanel>
            <WrapPanel Grid.Column="1" VerticalAlignment="Center" MaxWidth="560">
              <Button Name="BtnIgnore" Content="✓ Markér som OK" IsEnabled="False" Background="#1E3A2B"/>
              <Button Name="BtnOpen" Content="📂 Åbn placering" IsEnabled="False"/>
              <Button Name="BtnVT" Content="🛡 VirusTotal" IsEnabled="False"/>
              <Button Name="BtnDisable" Content="⛔ Deaktivér" IsEnabled="False" Style="{StaticResource Danger}"/>
              <Button Name="BtnUninstall" Content="🗑 Afinstallér" IsEnabled="False" Style="{StaticResource Danger}" Margin="0"/>
            </WrapPanel>
          </Grid>
        </Border>
      </Grid>

      <!-- HÆNDELSESFORLØB -->
      <Grid Name="PageTime" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <StackPanel Margin="0,0,0,14"><TextBlock Style="{StaticResource H1}" Text="Hændelsesforløb"/><TextBlock Style="{StaticResource Sub}" Text="Installationer, nye tjenester og opgaver, Defender-hændelser, nye filer og browserudvidelser fra de sidste 45 dage. ⚠ markerer tidsrummet efter en mistænkelig installation."/></StackPanel>
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10">
          <TextBox Name="TimeFilter" Width="280" ToolTip="Søg, fx paw"/>
          <CheckBox Name="OnlyFocus" Content="Kun ⚠ mistænkelige tidsrum" Margin="16,0,0,0"/>
        </StackPanel>
        <Border Grid.Row="2" Style="{StaticResource CardB}" Padding="6">
          <DataGrid Name="GridTime" IsReadOnly="True">
            <DataGrid.Columns>
              <DataGridTextColumn Header="TID" Binding="{Binding Tid, StringFormat='dd-MM-yyyy HH:mm'}" Width="130"/>
              <DataGridTextColumn Header="TYPE" Binding="{Binding Type}" Width="100"/>
              <DataGridTextColumn Header="" Binding="{Binding Fokus}" Width="170"/>
              <DataGridTextColumn Header="HÆNDELSE" Binding="{Binding Hændelse}" Width="2*"/>
              <DataGridTextColumn Header="DETALJE" Binding="{Binding Detalje}" Width="3*"/>
            </DataGrid.Columns>
          </DataGrid>
        </Border>
      </Grid>

      <!-- OPSTART -->
      <Grid Name="PageStart" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Margin="0,0,0,14"><TextBlock Style="{StaticResource H1}" Text="Opstart"/><TextBlock Name="StartInfo" Style="{StaticResource Sub}" Text="Programmer, der starter, når du logger ind. Til/fra virker som i Jobliste: intet slettes."/></StackPanel>
        <Border Grid.Row="1" Style="{StaticResource CardB}" Padding="6">
          <DataGrid Name="GridStart" IsReadOnly="True">
            <DataGrid.Columns>
              <DataGridTextColumn Header="STATUS" Binding="{Binding Status}" Width="90"/>
              <DataGridTextColumn Header="PROGRAM" Binding="{Binding Navn}" Width="2*"/>
              <DataGridTextColumn Header="ANBEFALING" Binding="{Binding Tip}" Width="3*"/>
              <DataGridTextColumn Header="UDGIVER" Binding="{Binding Udgiver}" Width="2*"/>
              <DataGridTextColumn Header="KILDE" Binding="{Binding Kilde}" Width="120"/>
            </DataGrid.Columns>
          </DataGrid>
        </Border>
        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,12,0,0">
          <Button Name="BtnToggle" Content="⏻  Slå til / fra" Style="{StaticResource Primary}" IsEnabled="False"/>
          <Button Name="BtnStartAll" Content="⚡  Slå alle anbefalede fra"/>
          <Button Name="BtnStartRefresh" Content="⟳  Opdatér"/>
          <TextBlock Text="Tip: dobbeltklik på en række for at slå den til eller fra." VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="8,0,0,0"/>
        </StackPanel>
      </Grid>

      <!-- OPRYDNING -->
      <Grid Name="PageClean" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Margin="0,0,0,14"><TextBlock Style="{StaticResource H1}" Text="Oprydning"/><TextBlock Style="{StaticResource Sub}" Text="Midlertidige filer og caches, som Windows og programmer selv genskaber. Filer, der er i brug eller yngre end 24 timer, springes over."/></StackPanel>
        <Border Grid.Row="1" Style="{StaticResource CardB}" Padding="6">
          <DataGrid Name="GridClean">
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="" Width="44">
                <DataGridTemplateColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding Valgt, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center"/></DataTemplate></DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTextColumn Header="HVAD" Binding="{Binding Navn}" Width="2*" IsReadOnly="True"/>
              <DataGridTextColumn Header="STØRRELSE" Binding="{Binding Info}" Width="110" IsReadOnly="True"/>
              <DataGridTextColumn Header="BESKRIVELSE" Binding="{Binding Note}" Width="3*" IsReadOnly="True"/>
              <DataGridTextColumn Header="RESULTAT" Binding="{Binding Status}" Width="130" IsReadOnly="True"/>
            </DataGrid.Columns>
          </DataGrid>
        </Border>
        <DockPanel Grid.Row="2" Margin="0,12,0,0">
          <StackPanel Orientation="Horizontal">
            <Button Name="BtnCleanMeasure" Content="📏  Beregn størrelser"/>
            <Button Name="BtnCleanRun" Content="🧹  Ryd op i valgte" Style="{StaticResource Primary}" IsEnabled="False"/>
            <Button Name="BtnCleanmgr" Content="Avanceret: Diskoprydning"/>
          </StackPanel>
          <TextBlock Name="CleanTotal" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="15" FontWeight="SemiBold"/>
        </DockPanel>
      </Grid>

      <!-- FILER -->
      <Grid Name="PageFiles" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Margin="0,0,0,14"><TextBlock Style="{StaticResource H1}" Text="Filer"/><TextBlock Style="{StaticResource Sub}" Text="Dubletter, gamle installere og de største filer i dine mapper. Slettede filer flyttes til papirkurven, så du kan fortryde."/></StackPanel>
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10">
          <Button Name="BtnFilesScan" Content="🔎  Analysér mine filer" Style="{StaticResource Primary}"/>
          <ComboBox Name="FilesFilter" Width="170" SelectedIndex="0" Margin="4,0,0,0" VerticalContentAlignment="Center">
            <ComboBoxItem Content="Alle"/><ComboBoxItem Content="Dubletter"/><ComboBoxItem Content="Gamle installere"/><ComboBoxItem Content="Store filer"/>
          </ComboBox>
        </StackPanel>
        <Border Grid.Row="2" Style="{StaticResource CardB}" Padding="6">
          <DataGrid Name="GridFiles">
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="" Width="44">
                <DataGridTemplateColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding Valgt, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center"/></DataTemplate></DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTextColumn Header="TYPE" Binding="{Binding Gruppe}" Width="90" IsReadOnly="True"/>
              <DataGridTextColumn Header="FIL" Binding="{Binding Navn}" Width="2*" IsReadOnly="True"/>
              <DataGridTextColumn Header="MB" Binding="{Binding Tal}" Width="80" IsReadOnly="True"/>
              <DataGridTextColumn Header="NOTE" Binding="{Binding Note}" Width="2*" IsReadOnly="True"/>
              <DataGridTextColumn Header="MAPPE" Binding="{Binding Info}" Width="2*" IsReadOnly="True"/>
            </DataGrid.Columns>
          </DataGrid>
        </Border>
        <DockPanel Grid.Row="3" Margin="0,12,0,0">
          <StackPanel Orientation="Horizontal">
            <Button Name="BtnFilesSuggest" Content="✨  Vælg forslag"/>
            <Button Name="BtnFilesNone" Content="Fravælg alle"/>
            <Button Name="BtnFilesOpen" Content="📂  Åbn placering"/>
            <Button Name="BtnFilesDelete" Content="🗑  Flyt valgte til papirkurv" Style="{StaticResource Danger}"/>
          </StackPanel>
          <TextBlock Name="FilesTotal" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="15" FontWeight="SemiBold"/>
        </DockPanel>
      </Grid>

      <!-- OPDATERINGER -->
      <Grid Name="PageUpdates" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Margin="0,0,0,14"><TextBlock Style="{StaticResource H1}" Text="Opdateringer"/><TextBlock Style="{StaticResource Sub}" Text="Gamle programmer er en af de største sikkerhedsrisici. Bruger Windows' egen pakkehåndtering (winget) til at opdatere i baggrunden."/></StackPanel>
        <Border Grid.Row="1" Style="{StaticResource CardB}" Padding="6">
          <DataGrid Name="GridUpdates">
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="" Width="44">
                <DataGridTemplateColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding Valgt, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center"/></DataTemplate></DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTextColumn Header="PROGRAM" Binding="{Binding Navn}" Width="2*" IsReadOnly="True"/>
              <DataGridTextColumn Header="NUVÆRENDE" Binding="{Binding Info}" Width="130" IsReadOnly="True"/>
              <DataGridTextColumn Header="NY VERSION" Binding="{Binding Note}" Width="130" IsReadOnly="True"/>
              <DataGridTextColumn Header="ID" Binding="{Binding Id}" Width="2*" IsReadOnly="True"/>
              <DataGridTextColumn Header="STATUS" Binding="{Binding Status}" Width="110" IsReadOnly="True"/>
            </DataGrid.Columns>
          </DataGrid>
        </Border>
        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,12,0,0">
          <Button Name="BtnUpdCheck" Content="🔄  Søg efter opdateringer"/>
          <Button Name="BtnUpdRun" Content="⬆  Opdatér valgte" Style="{StaticResource Primary}" IsEnabled="False"/>
            <TextBlock Name="UpdInfo" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="8,0,0,0"/>
            <TextBlock Name="UpdReboot" VerticalAlignment="Center" Foreground="#F6C344" Margin="12,0,0,0" FontWeight="SemiBold"/>
        </StackPanel>
      </Grid>

      <!-- YDELSE OG HELBRED -->
      <Grid Name="PageHealth" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Margin="0,0,0,14"><TextBlock Style="{StaticResource H1}" Text="Ydelse og helbred"/><TextBlock Name="PerfText" Style="{StaticResource Sub}" Text="Diskens tilstand, strømplan, spilindstillinger og hvor længe siden pc'en blev genstartet."/></StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <Border Name="RebootBanner" Visibility="Collapsed" CornerRadius="12" Background="#2A2210" BorderBrush="#F6C344" BorderThickness="1" Padding="16,12" Margin="0,0,0,12">
              <DockPanel>
                <Button Name="BtnRebootNow" DockPanel.Dock="Right" Content="🔁  Genstart nu" Style="{StaticResource Primary}" Margin="0"/>
                <StackPanel VerticalAlignment="Center"><TextBlock Text="🔁  Genstart for at færdiggøre en opdatering" FontWeight="SemiBold" FontSize="14.5"/><TextBlock Name="RebootWhy" Style="{StaticResource Sub}" Margin="0,3,0,0"/></StackPanel>
              </DockPanel>
            </Border>
            <Border Style="{StaticResource CardB}" Padding="6" Margin="0,0,0,12">
              <DataGrid Name="GridHealth" IsReadOnly="True" MaxHeight="330">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="" Binding="{Binding Status}" Width="40"/>
                  <DataGridTextColumn Header="EMNE" Binding="{Binding Navn}" Width="2*"/>
                  <DataGridTextColumn Header="VÆRDI" Binding="{Binding Info}" Width="2*"/>
                  <DataGridTextColumn Header="VURDERING" Binding="{Binding Note}" Width="3*"/>
                </DataGrid.Columns>
              </DataGrid>
            </Border>
            <Border Style="{StaticResource CardB}" Padding="20,16" Margin="0,0,0,12">
              <StackPanel>
                <DockPanel>
                  <TextBlock Name="BootBig" DockPanel.Dock="Right" FontSize="22" FontWeight="Bold" Foreground="#A78BFA" VerticalAlignment="Center"/>
                  <StackPanel><TextBlock Text="⏱  Opstartstid" FontSize="15.5" FontWeight="SemiBold"/><TextBlock Name="BootSub" Style="{StaticResource Sub}" Margin="0,3,0,0" Text="Henter målinger..."/></StackPanel>
                </DockPanel>
                <Grid Height="150" Margin="0,14,0,0">
                  <ItemsControl Name="BootBars" VerticalAlignment="Bottom">
                    <ItemsControl.ItemsPanel><ItemsPanelTemplate><StackPanel Orientation="Horizontal"/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                    <ItemsControl.ItemTemplate>
                      <DataTemplate>
                        <StackPanel Margin="0,0,10,0" VerticalAlignment="Bottom" ToolTip="{Binding Note}">
                          <TextBlock Text="{Binding Info}" FontSize="11" Foreground="#AEB6C6" HorizontalAlignment="Center"/>
                          <Border Height="{Binding Tal}" Width="26" CornerRadius="6,6,2,2" Background="{Binding Gruppe}" Margin="0,3,0,3"/>
                          <TextBlock Text="{Binding Navn}" FontSize="10.5" Foreground="#6B7488" HorizontalAlignment="Center"/>
                        </StackPanel>
                      </DataTemplate>
                    </ItemsControl.ItemTemplate>
                  </ItemsControl>
                </Grid>
                <TextBlock Name="BootLegend" FontSize="11.5" Foreground="#6B7488" Margin="0,6,0,0" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource CardB}" Padding="20,16">
              <StackPanel>
                <DockPanel>
                  <TextBlock Name="CrashBig" DockPanel.Dock="Right" FontSize="22" FontWeight="Bold" VerticalAlignment="Center"/>
                  <StackPanel><TextBlock Text="💥  Hvad crasher?" FontSize="15.5" FontWeight="SemiBold"/><TextBlock Name="CrashSub" Style="{StaticResource Sub}" Margin="0,3,0,0" Text="Henter de seneste 14 dages hændelser..."/></StackPanel>
                </DockPanel>
                <DataGrid Name="GridCrash" IsReadOnly="True" Margin="0,12,0,0" MaxHeight="300">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="" Binding="{Binding Status}" Width="36"/>
                    <DataGridTextColumn Header="HVAD" Binding="{Binding Navn}" Width="2*"/>
                    <DataGridTextColumn Header="ANTAL" Binding="{Binding Info}" Width="120"/>
                    <DataGridTextColumn Header="SIDST" Binding="{Binding Gruppe}" Width="120"/>
                    <DataGridTextColumn Header="MULIG SAMMENHÆNG" Binding="{Binding Note}" Width="3*"/>
                  </DataGrid.Columns>
                </DataGrid>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
        <WrapPanel Grid.Row="2" Margin="0,12,0,0">
          <Button Name="BtnHealthRefresh" Content="⟳  Tjek igen"/>
          <Button Name="BtnPowerHigh" Content="⚡  Strømplan: Høj ydelse"/>
          <Button Name="BtnPowerBal" Content="🍃  Strømplan: Balanceret"/>
          <Button Name="BtnGameMode" Content="🎮  Slå spiltilstand til"/>
          <Button Name="BtnOfflineScan" Content="🛡  Defender Offline-scan"/>
        </WrapPanel>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($node in $xaml.SelectNodes('//*[@Name]')) { $ui[$node.Name] = $win.FindName($node.Name) }
$ui.VerText.Text = "v$AppVersion"
$icoPath = Join-Path $PSScriptRoot 'PC-Tjek.ico'
if (Test-Path $icoPath) { try { $ms = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($icoPath)); $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create($ms, 'None', 'OnLoad') } catch {} }   # indlæst i hukommelsen, så filen ikke låses
$win.Add_SourceInitialized({ try { [PcTjek.Win]::Dark((New-Object System.Windows.Interop.WindowInteropHelper $win).Handle) } catch {} })
$win.Dispatcher.Add_UnhandledException({
  param($s, $e)
  Log "FEJL: $($e.Exception)"
  [Windows.MessageBox]::Show("Der skete en fejl:`n`n$($e.Exception.Message)`n`nDetaljer er gemt i pc-tjek.log.", 'PC-Tjek', 'OK', 'Error') | Out-Null
  $e.Handled = $true
})
$Brush = New-Object Windows.Media.BrushConverter
function Msg($text, $title = 'PC-Tjek', $buttons = 'OK', $icon = 'Information') { [Windows.MessageBox]::Show($text, $title, $buttons, $icon) }
function Fmt-GB($bytes) { if ($bytes -ge 1GB) { '{0:N1} GB' -f ($bytes / 1GB) } elseif ($bytes -ge 1MB) { '{0:N0} MB' -f ($bytes / 1MB) } else { '{0:N0} KB' -f ($bytes / 1KB) } }

# =====================================================================
#  Baggrundsjob: én timer holder øje med alle job
# =====================================================================
# Hvert job kører som sin egen PowerShell-proces (arver administratorrettigheder).
# Fremdrift skrives til progress.txt, resultatet til out.xml (Export-Clixml bevarer typer som datoer).
$JobRunnerText = @'
param([string]$Dir)
$ErrorActionPreference = 'SilentlyContinue'
$logFile = [IO.File]::ReadAllText((Join-Path $Dir 'log.txt')).Trim()
function JLog($m) { try { [IO.File]::AppendAllText($logFile, ("{0:yyyy-MM-dd HH:mm:ss}  {1}`r`n" -f (Get-Date), $m), [Text.Encoding]::UTF8) } catch {} }
JLog "Job-proces kører (PID $PID)"
if (-not ('PcTjekSyncTable' -as [type])) {
Add-Type -TypeDefinition @"
using System; using System.Collections; using System.IO; using System.Text; using System.Globalization;
public class PcTjekSyncTable : Hashtable {
  string path; DateTime last = DateTime.MinValue;
  public PcTjekSyncTable(string p) { path = p; }
  public override object this[object key] { get { return base[key]; } set { base[key] = value; Flush(false); } }
  public void Flush(bool force) {
    if (!force && (DateTime.Now - last).TotalMilliseconds < 200) return;
    last = DateTime.Now;
    var sb = new StringBuilder();
    foreach (DictionaryEntry e in this) {
      object v = e.Value;
      if (v is string || v is double || v is int || v is long || v is bool || v is decimal)
        sb.Append(e.Key).Append('\t').Append(Convert.ToString(v, CultureInfo.InvariantCulture).Replace('\n', ' ').Replace('\r', ' ').Replace('\t', ' ')).Append('\n');
    }
    try { File.WriteAllText(path + ".tmp", sb.ToString(), Encoding.UTF8); File.Copy(path + ".tmp", path, true); } catch { }
  }
}
"@
}
$sync = New-Object PcTjekSyncTable (Join-Path $Dir 'progress.txt')
$sync['Progress'] = -1.0
try {
  $arg = Import-Clixml (Join-Path $Dir 'in.xml')
  $work = [scriptblock]::Create([IO.File]::ReadAllText((Join-Path $Dir 'work.ps1')))
  $result = & $work $sync $arg
  Export-Clixml -InputObject $result -Path (Join-Path $Dir 'out.xml') -Depth 8
  JLog 'Job-proces færdig'
} catch {
  [IO.File]::WriteAllText((Join-Path $Dir 'error.txt'), [string]$_.Exception.Message, [Text.Encoding]::UTF8)
  JLog "Job-proces FEJL: $($_.Exception.Message)"
}
$sync.Flush($true)
'@

$script:Jobs = New-Object System.Collections.ArrayList
function Invoke-Bg([scriptblock]$Work, $Arg, [scriptblock]$Done, $Ctx) {
  try {
    $dir = Join-Path $JobRoot ('job-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $dir | Out-Null
    $utf8 = New-Object Text.UTF8Encoding $true
    [IO.File]::WriteAllText((Join-Path $dir 'work.ps1'), $Work.ToString(), $utf8)
    [IO.File]::WriteAllText((Join-Path $dir 'runner.ps1'), $JobRunnerText, $utf8)
    [IO.File]::WriteAllText((Join-Path $dir 'log.txt'), $LogFile, $utf8)
    if ($null -eq $Arg) { $Arg = @{} }
    Export-Clixml -InputObject $Arg -Path (Join-Path $dir 'in.xml') -Depth 6
    $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -PassThru `
         -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\runner.ps1`" -Dir `"$dir`""
    $s = @{ Status = ''; Detail = ''; Progress = -1.0 }
    [void]$script:Jobs.Add(@{ S = $s; P = $p; Dir = $dir; Done = $Done; Ctx = $Ctx })
    $ui.Busy.Visibility = 'Visible'
    Log "Job startet (proces $($p.Id))"
  } catch {
    Log "Invoke-Bg FEJL: $($_.Exception.Message)"
    Msg "Kunne ikke starte baggrundsjob:`n$($_.Exception.Message)" 'PC-Tjek' 'OK' 'Error' | Out-Null
  }
}
function Read-JobProgress($j) {
  $f = Join-Path $j.Dir 'progress.txt'
  if (-not (Test-Path $f)) { return }
  try { $lines = [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8) } catch { return }
  foreach ($l in $lines) {
    $kv = $l -split "`t", 2
    if ($kv.Count -ne 2) { continue }
    $num = 0.0
    if ([double]::TryParse($kv[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$num) -and $kv[0] -ne 'Status' -and $kv[0] -ne 'Detail') { $j.S[$kv[0]] = $num }
    else { $j.S[$kv[0]] = $kv[1] }
  }
}
$jobTimer = New-Object Windows.Threading.DispatcherTimer
$jobTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$jobTimer.Add_Tick({
  if ($script:Jobs.Count -eq 0) { return }
  foreach ($j in @($script:Jobs)) { Read-JobProgress $j }
  $last = $script:Jobs[$script:Jobs.Count - 1]
  if ($last.S.Status) { $ui.StatusText.Text = $last.S.Status }
  if ([double]$last.S.Progress -ge 0) { $ui.Busy.IsIndeterminate = $false; $ui.Busy.Value = [double]$last.S.Progress } else { $ui.Busy.IsIndeterminate = $true }
  $sj = $script:Jobs | Where-Object { $_.Ctx -is [hashtable] -and $_.Ctx.Kind -eq 'scan' } | Select-Object -First 1
  if ($sj) { try { Update-ScanProgress $sj.S } catch { if (-not $script:ProgErrLogged) { Log "Fremdrift-fejl: $_"; $script:ProgErrLogged = $true } } }
  foreach ($j in @($script:Jobs)) {
    if (-not $j.P.HasExited) { continue }
    [void]$script:Jobs.Remove($j)
    $res = $null; $err = $null
    $out = Join-Path $j.Dir 'out.xml'; $ef = Join-Path $j.Dir 'error.txt'
    if (Test-Path $ef) { $err = [IO.File]::ReadAllText($ef) }
    elseif (Test-Path $out) { try { $res = Import-Clixml $out } catch { $err = "Kunne ikke læse resultatet: $($_.Exception.Message)" } }
    else { $err = "Jobbet stoppede uventet (kode $($j.P.ExitCode))." }
    if ($err) { Log "Job-fejl: $err" }
    Remove-Item -Recurse -Force $j.Dir -ErrorAction SilentlyContinue
    try { & $j.Done $res $err $j.Ctx } catch { Log "Done-fejl: $_"; Msg "Fejl: $($_.Exception.Message)" 'PC-Tjek' 'OK' 'Error' | Out-Null }
  }
  if ($script:Jobs.Count -eq 0) { $ui.Busy.Visibility = 'Hidden' }
})
$jobTimer.Start()
# Luk evt. kørende job-processer, når appen lukkes
$win.Add_Closed({ foreach ($j in @($script:Jobs)) { try { if (-not $j.P.HasExited) { $j.P.Kill() } } catch {} } })

# Gendannelsespunkt før ændringer (én gang pr. session)
$script:RestoreDone = $false
function With-RestorePoint($why, $ctx, [scriptblock]$then) {
  if ($script:RestoreDone) { & $then $ctx; return }
  Invoke-Bg $RestorePointScript @{ Why = $why } {
    param($r, $err, $c)
    if ($err) {
      $a = Msg "Kunne ikke oprette et gendannelsespunkt:`n$err`n`n(Systembeskyttelse er måske slået fra.) Vil du fortsætte alligevel?" 'Gendannelsespunkt' 'YesNo' 'Warning'
      if ($a -ne 'Yes') { $ui.StatusText.Text = 'Annulleret.'; return }
    } else { $ui.StatusText.Text = 'Gendannelsespunkt oprettet.' }
    $script:RestoreDone = $true
    & $c.Then $c.Ctx
  } @{ Then = $then; Ctx = $ctx }
}

# =====================================================================
#  Navigation
# =====================================================================
$pages = @{ NavVagt = 'PageVagt'; NavTweaks = 'PageTweaks'; NavHome = 'PageHome'; NavFind = 'PageFind'; NavTime = 'PageTime'; NavStart = 'PageStart'; NavClean = 'PageClean'; NavFiles = 'PageFiles'; NavUpdates = 'PageUpdates'; NavHealth = 'PageHealth' }
foreach ($nav in $pages.Keys) {
  $ui[$nav].Add_Checked({
    param($sender, $e)
    foreach ($k in $pages.Keys) { $ui[$pages[$k]].Visibility = $(if ($ui[$k].IsChecked) { 'Visible' } else { 'Collapsed' }) }
    if ($sender.Name -eq 'NavHealth' -and -not $script:HealthLoaded) { Load-Health; try { Show-Reboot; Show-Boot } catch { Log "Boot-fejl: $_" }; Show-Crashes }
    if ($sender.Name -eq 'NavUpdates') { try { Show-Reboot } catch {} }
    if ($sender.Name -eq 'NavVagt') { try { Load-Vagt } catch { Log "Vagt-fejl: $_" } }
    if ($sender.Name -eq 'NavTweaks' -and -not $script:TweaksLoaded) { try { Show-Tweaks } catch { Log "Tweak-fejl: $_" } }
    if ($sender.Name -eq 'NavTweaks') { try { Load-Gpu } catch { Log "GPU-fejl: $_" } } else { $gpuTimer.Stop() }
  })
}

# =====================================================================
#  Scan + analyse
# =====================================================================
$script:Result = $null
$script:NewSince = @()

function Set-ScoreArc([double]$pct, $color) {
  $r = 63.0; $cx = 75.0; $cy = 75.0
  $deg = [math]::Min(359.9, [math]::Max(0.5, 360.0 * $pct / 100.0))
  $a = $deg * [math]::PI / 180.0
  $x = $cx + $r * [math]::Sin($a); $y = $cy - $r * [math]::Cos($a)
  $large = if ($deg -gt 180) { 1 } else { 0 }
  $inv = [Globalization.CultureInfo]::InvariantCulture
  $ui.ScoreArc.Data = [Windows.Media.Geometry]::Parse([string]::Format($inv, 'M {0},{1} A {2},{2} 0 {3} 1 {4},{5}', $cx, ($cy - $r), $r, $large, $x, $y))
  $ui.ScoreArc.Stroke = $Brush.ConvertFromString($color)
}
function Animate-Score([int]$target, $color) {
  $script:AnimVal = 0; $script:AnimTarget = $target; $script:AnimColor = $color
  if (-not $script:AnimTimer) {
    $script:AnimTimer = New-Object Windows.Threading.DispatcherTimer
    $script:AnimTimer.Interval = [TimeSpan]::FromMilliseconds(15)
    $script:AnimTimer.Add_Tick({
      $script:AnimVal = [math]::Min($script:AnimTarget, $script:AnimVal + [math]::Max(1, [math]::Ceiling(($script:AnimTarget - $script:AnimVal) / 8)))
      Set-ScoreArc $script:AnimVal $script:AnimColor
      $ui.ScoreText.Text = [int]$script:AnimVal
      if ($script:AnimVal -ge $script:AnimTarget) { $script:AnimTimer.Stop() }
    })
  }
  $script:AnimTimer.Start()
}


# ---------- Fremdrift under scanning ----------
$ScanPhaseNames = @('Microsoft Defender', 'Programmer og installationer', 'Autostart og planlagte opgaver', 'Tjenester', 'Processer og netværk',
                    'Finder nye programfiler', 'Tjekker signaturer', 'Browserudvidelser', 'Plads og bloat', 'Analyse')
function Fmt-Dur([double]$sec) {
  if ($sec -lt 60) { return "$([int]$sec) sek" }
  $m = [math]::Floor($sec / 60); $s = [int]($sec - 60 * $m)
  return $(if ($s -gt 0) { "$m min $s sek" } else { "$m min" })
}
function Get-ScanEta($s) {
  $el = ((Get-Date) - $script:ScanStart).TotalSeconds
  $p = [double]$s.Progress
  if ($script:PrevTimes -and $s.Phase) {
    $cur = [int]$s.Phase
    $frac = if ([double]$s.PhaseWeight -gt 0) { [math]::Min(1, [math]::Max(0, ($p - [double]$s.PhaseStart) / [double]$s.PhaseWeight)) } else { 0 }
    $done = 0.0; $rem = 0.0
    for ($i = 1; $i -le $ScanPhaseNames.Count; $i++) {
      $t = [double]($script:PrevTimes.("$i"))
      if ($i -lt $cur) { $done += $t } elseif ($i -eq $cur) { $done += $t * $frac; $rem += $t * (1 - $frac) } else { $rem += $t }
    }
    $scale = if ($done -gt 3) { [math]::Min(2.5, [math]::Max(0.4, $el / $done)) } else { 1.0 }   # tilpas til dagens tempo
    return $rem * $scale
  }
  if ($p -lt 4 -or $el -lt 4) { return $null }
  return $el * (100 - $p) / $p
}
function Update-ScanProgress($s) {
  $p = [math]::Max(0, [double]$s.Progress)
  $ui.ScanBar.Value = $ui.ScanBar.Value + ($p - $ui.ScanBar.Value) * 0.3      # glidende bevægelse
  $shown = [math]::Floor($ui.ScanBar.Value)
  $ui.ScanPct.Text = $shown
  Set-ScoreArc ([math]::Max(1, $ui.ScanBar.Value)) '#8B5CF6'
  $ui.ScoreText.Text = "$shown%"
  $cur = [int]$s.Phase
  if ($cur -gt 0) { $ui.ScanStep.Text = "Trin $cur af $($ScanPhaseNames.Count) · $($s.Status)" }
  $ui.ScanDetail.Text = [string]$s.Detail
  $el = ((Get-Date) - $script:ScanStart).TotalSeconds
  $ui.ScanElapsed.Text = "brugt: $(Fmt-Dur $el)"
  $eta = Get-ScanEta $s
  if ($null -ne $eta) {
    $script:EtaSmooth = if ($null -eq $script:EtaSmooth) { $eta } else { 0.85 * ([math]::Max(0, $script:EtaSmooth - 0.25)) + 0.15 * $eta }
    $e = $script:EtaSmooth
    $ui.ScanEta.Text = if ($e -lt 8) { 'næsten færdig...' } elseif ($e -lt 60) { "ca. $([int]([math]::Ceiling($e / 5) * 5)) sek tilbage" } else { "ca. $(Fmt-Dur ([math]::Ceiling($e / 10) * 10)) tilbage" }
  }
  $lines = for ($i = 1; $i -le $ScanPhaseNames.Count; $i++) {
    if ($i -lt $cur) { "✓   $($ScanPhaseNames[$i - 1])" } elseif ($i -eq $cur) { "▶   $($ScanPhaseNames[$i - 1])" } else { "○   $($ScanPhaseNames[$i - 1])" }
  }
  $ui.ScanPhases.Text = $lines -join "`n"
}

function Compare-Snapshot($snap) {
  $new = @()
  $prev = Get-ChildItem $SnapDir -Filter 'snap-*.json' | Sort-Object Name -Descending | Select-Object -First 1
  if ($prev) {
    $old = Get-Content $prev.FullName -Raw | ConvertFrom-Json
    foreach ($k in 'Autostart', 'Opgaver', 'Tjenester', 'Browser', 'Undtagelser', 'Programmer') {
      $o = @($old.$k); $n = @($snap[$k])
      foreach ($item in $n) { if ($item -and $o -notcontains $item) { $new += [pscustomobject]@{ Type = $k; Item = $item; Siden = $prev.LastWriteTime } } }
    }
  }
  $file = Join-Path $SnapDir ("snap-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))
  $snap | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 $file
  return @($new)
}

function Build-Story($r) {
  $f = $r.Findings
  $crit = @($f | Where-Object Niveau -eq 4); $high = @($f | Where-Object Niveau -eq 3)
  $sb = New-Object System.Text.StringBuilder
  function L($t) { [void]$sb.AppendLine($t) }
  if ($crit.Count) { L "🔴  $($crit.Count) KRITISKE FUND. De skal håndteres nu." }
  elseif ($high.Count) { L "🟠  Ingen kritiske fund, men $($high.Count) med høj risiko, som du bør se på." }
  else { L "🟢  Ingen tegn på aktiv malware de steder, der er tjekket." }
  L ''

  $thr = @($f | Where-Object { $_.Kategori -like 'Trussel*' })
  L '━━  1 · HVAD DEFENDER HAR FANGET'
  if ($thr.Count) {
    foreach ($t in $thr) { L "   • $($t.Titel)"; L "     $($t.Detalje)"; L "     $($t.Sti)" }
    if ($thr.Sti -match 'Windows\\Installer') { L "   → Filerne lå i Windows' installer-cache. Det betyder, at en .msi-installer FAKTISK blev kørt med administratorrettigheder. Defender har fjernet kopien i cachen. Afsnit 2 viser, hvad installeren nåede at lave." }
  } else { L '   Ingen trusler i Defenders historik.' }
  L ''

  L '━━  2 · HÆNDELSER OMKRING EN INSTALLATION, DER BØR GENNEMGÅS'
  if ($r.Suspect.Count) {
    foreach ($w in $r.Suspect) {
      $evs = @($r.Timeline | Where-Object { $_.Tid -ge $w.Start -and $_.Tid -le $w.End } | Sort-Object Tid)
      L "   '$($w.Name)' · $($w.Start.AddMinutes(30).ToString('dd-MM-yyyy HH:mm'))"
      if ($evs.Count) {
        L ('   De næste timer: ' + (($evs | Group-Object Type | ForEach-Object { "$($_.Count) × $($_.Name.ToLower())" }) -join ', '))
        foreach ($e in ($evs | Where-Object { $_.Type -in 'Tjeneste', 'Opgave', 'Fil', 'Browser', 'Defender' } | Select-Object -First 12)) { L "     $($e.Tid.ToString('HH:mm'))  $($e.Hændelse)" }
        if (@($evs | Where-Object { $_.Type -in 'Tjeneste', 'Opgave' }).Count) { L '   → Der blev oprettet tjenester/opgaver i samme tidsrum. Det beviser ikke en sammenhæng, men gennemgå dem under Fund.' }
        else { L '   → Ingen nye tjenester eller planlagte opgaver i samme tidsrum.' }
      } else { L '   Ingen andre spor i tidsrummet.' }
      L ''
    }
  } else {
    L '   Ingen mistænkelige MSI-installationer de sidste 45 dage (skjult produkt, ingen producent eller mistænkeligt navn).'
    L '   Tip: søg på "paw" under Hændelsesforløb.'
    L ''
  }

  L '━━  3 · NYT SIDEN SIDSTE SCANNING'
  if ($script:NewSince.Count) {
    foreach ($n in @($script:NewSince | Select-Object -First 15)) { L "   + [$($n.Type)] $($n.Item)" }
  } elseif (@(Get-ChildItem $SnapDir -Filter 'snap-*.json').Count -le 1) { L '   Første scanning. Næste gang vises alt, hvad der er kommet til.' }
  else { L '   Intet nyt i autostart, opgaver, tjenester, udvidelser eller programmer.' }
  L ''

  L '━━  4 · DET VIGTIGSTE AT GØRE'
  $todo = @($f | Where-Object Niveau -ge 3 | Select-Object -First 8)
  if ($todo.Count) { foreach ($x in $todo) { L "   [$($x.Risiko)] $($x.Titel)"; L "        $($x.Hvorfor)" } } else { L '   Intet med høj risiko.' }
  if ($thr | Where-Object { $_.Detalje -match 'JA' }) { L '   [Kritisk] En trussel NÅEDE AT KØRE: skift adgangskoder fra en anden enhed (e-mail først) og slå 2-faktor til.' }
  L ''
  $p = $r.Perf
  L '━━  5 · YDELSE'
  L "   RAM i brug: $($p.RamBrugtPct)%  ·  opstartstid: $(if ($p.BootSek) { "$($p.BootSek) sek" } else { 'ukendt' })  ·  bloat: $(@($f | Where-Object Kategori -eq 'Bloat').Count) stk."
  L ('   Tungeste: ' + (($p.Top | Select-Object -First 5 | ForEach-Object { "$($_.Navn) $($_.MB) MB" }) -join ', '))
  L ''
  L "NB: 'Usigneret' betyder ikke automatisk farligt, kun at udgiveren ikke er verificeret."
  return $sb.ToString()
}

function Show-Result {
  $r = $script:Result
  $f = $r.Findings
  $c4 = @($f | Where-Object Niveau -eq 4).Count; $c3 = @($f | Where-Object Niveau -eq 3).Count
  $c2 = @($f | Where-Object Niveau -eq 2).Count; $cb = @($f | Where-Object Kategori -eq 'Bloat').Count
  Update-SecCard $f
  Show-Result-Rest
}
function Update-SecCard($f) {
  $c4 = @($f | Where-Object Niveau -eq 4).Count; $c3 = @($f | Where-Object Niveau -eq 3).Count
  $removed = @($f | Where-Object { $_.Kategori -eq 'Trussel (fjernet)' }).Count
  if ($c4) { $ui.SecValue.Text = 'Kræver handling'; $ui.SecValue.Foreground = $Brush.ConvertFromString('#FF5D6C'); $ui.SecSub.Text = "$c4 aktive fund$(if ($c3) { " · $c3 bør gennemgås" })" }
  elseif ($c3) { $ui.SecValue.Text = 'Bør gennemgås'; $ui.SecValue.Foreground = $Brush.ConvertFromString('#FFA24A'); $ui.SecSub.Text = "$c3 ting at kigge på · se planen nedenfor" }
  else { $ui.SecValue.Text = 'Ingen trusler'; $ui.SecValue.Foreground = $Brush.ConvertFromString('#4ADE80'); $ui.SecSub.Text = $(if ($removed) { "$removed tidligere trussel(er) er fjernet af Defender" } else { 'Windows Sikkerhed er aktiv' }) }
}
function Show-Result-Rest {
  $r = $script:Result; $f = $r.Findings
  $c4 = @($f | Where-Object Niveau -eq 4).Count; $c3 = @($f | Where-Object Niveau -eq 3).Count
  $c2 = @($f | Where-Object Niveau -eq 2).Count; $cb = @($f | Where-Object Kategori -eq 'Bloat').Count
  $ui.CntSpace.Text = '…'   # udfyldes af Measure-PlanClean med samme beregning som oprydningen
  $score = [math]::Max(0, 100 - 40 * $c4 - 12 * $c3)   # kun sikkerhed (ikke bloat eller plads), så et fald betyder noget
  $color = if ($score -ge 80) { '#4ADE80' } elseif ($score -ge 50) { '#F6D44A' } elseif ($score -ge 25) { '#FFA24A' } else { '#FF5D6C' }
  $ui.ScoreLabel.Text = if ($c4) { 'sikkerhed: handling' } elseif ($c3) { 'sikkerhed: tjek' } else { 'sikkerhed: god' }
  Animate-Score $score $color
  $ui.Verdict.Text = if ($c4) { 'Kritiske fund. Læs analysen nedenfor.' } elseif ($c3) { 'Ingen kritiske fund, men nogle ting bør tjekkes.' } else { "Ser fornuftigt ud. Kig på Oprydning og Opstart, hvis pc'en er langsom." }
  $ui.Story.Text = Build-Story $r
  try { Build-Plan $r } catch { Log "Plan-fejl: $_" }
  $left = @($script:PlanRows).Count
  $ui.Verdict.Text = if ($c4) { "Der er fundet noget alvorligt. Følg planen nedenfor, start fra toppen." } elseif ($left) { "Følg de $left trin nedenfor. Det tager kun et par minutter." } else { "Din pc ser fin ud. 🎉" }
  Apply-FindFilter; Apply-TimeFilter
  $ui.BtnExport.IsEnabled = $true
  Fill-CleanFromScan
}

$ui.BtnScan.Add_Click({
  $ui.BtnScan.IsEnabled = $false; $ui.BtnScan.Content = '⏳   Scanner...'
  $ui.NavHome.IsChecked = $true
  $script:ScanStart = Get-Date; $script:EtaSmooth = $null; $ui.ScanBar.Value = 0
  $script:PrevTimes = $null
  if (Test-Path $TimesFile) { try { $script:PrevTimes = Get-Content $TimesFile -Raw | ConvertFrom-Json } catch {} }
  $ui.ScanCard.Visibility = 'Visible'; $ui.StoryCard.Visibility = 'Collapsed'; $ui.PlanCard.Visibility = 'Hidden'; $script:ShowDetails = $false
  $ui.ScoreLabel.Text = 'scanner...'
  Log 'Scan startet'
  Invoke-Bg $ScanScript @{ LogFile = $LogFile } {
    param($res, $err, $c)
    $ui.ScanCard.Visibility = 'Collapsed'; $ui.PlanCard.Visibility = 'Visible'; $ui.BtnDetails.Content = 'Vis detaljer'
    $ui.BtnScan.IsEnabled = $true; $ui.BtnScan.Content = "🔍   Scan igen"
    if ($res -is [array]) { $res = @($res | Where-Object { $_ -is [hashtable] })[-1] }   # sikkerhed mod løst output
    if ($err -or -not $res) { Msg "Scanningen fejlede: $err" 'PC-Tjek' 'OK' 'Error' | Out-Null; return }
    if ($res.PhaseSec) { try { $res.PhaseSec | ConvertTo-Json | Out-File -Encoding utf8 $TimesFile } catch {} }
    $script:NewSince = @(Compare-Snapshot $res.Snapshot)
    $findings = [System.Collections.ArrayList]@($res.Findings)
    foreach ($n in @($script:NewSince | Where-Object { $_.Type -ne 'Programmer' })) {
      [void]$findings.Add([pscustomobject]@{ Risiko = 'Mellem'; Niveau = 2; Kategori = 'Nyt siden sidst'; Titel = "Ny $($n.Type.ToLower()): $($n.Item)"
        Detalje = "Ikke set ved scanningen $($n.Siden)"; Hvorfor = 'Er dukket op siden sidste scanning. Genkender du den, er det fint. Ellers så undersøg den.'
        Sti = ($n.Item -split ' = ', 2)[-1]; Type = 'new'; Data = $null; SHA256 = $null })
    }
    $ign = Get-Ignored
    $hidden = @($findings | Where-Object { $_.Kategori -ne 'Trussel' -and $ign -contains (Get-FindKey $_) }).Count
    $findings = @($findings | Where-Object { $_.Kategori -eq 'Trussel' -or $ign -notcontains (Get-FindKey $_) })
    if ($hidden) { Log "$hidden fund skjult (markeret som OK tidligere)" }
    $script:Result = [pscustomobject]@{ Findings = @($findings | Sort-Object Niveau -Descending); Timeline = $res.Timeline; Space = $res.Space; Perf = $res.Perf; Suspect = $res.Suspect }
    Show-Result
    $ui.StatusText.Text = "Scanning færdig $(Get-Date -Format 'HH:mm') · $($script:Result.Findings.Count) fund · $($script:Result.Timeline.Count) hændelser"
    Log "Scan: $($script:Result.Findings.Count) fund på $([math]::Round(((Get-Date) - $script:ScanStart).TotalSeconds)) sek"
  } @{ Kind = 'scan' }
})

# =====================================================================
#  Fund
# =====================================================================
function Get-FindKey($x) { "$($x.Kategori)|$($x.Titel)|$($x.Sti)" }
function Get-Ignored { if (Test-Path $IgnoreFile) { @(Get-Content $IgnoreFile -Encoding UTF8) } else { @() } }
function Add-Ignored($x) { try { Add-Content -Path $IgnoreFile -Value (Get-FindKey $x) -Encoding UTF8 } catch {} }
function Get-Advice($x) {
  if ($x.Raad) { return $x.Raad }
  switch ($x.Kategori) {
    'Trussel'           { 'Følg trinnet "Fjern virus" på Overblik.' }
    'Trussel (fjernet)' { 'Ingen handling nødvendig. Defender har ryddet op.' }
    'Installation'      { 'Kender du programmet? Så markér det som OK. Ellers så find det under Indstillinger → Apps, og afinstallér det.' }
    'Planlagt opgave'   { 'Kender du den ikke, så tryk Deaktivér (kan fortrydes). Kender du den, så markér den som OK.' }
    'Autostart'         { 'Kender du den ikke, så tryk Deaktivér (kan fortrydes). Kender du den, så markér den som OK.' }
    'Tjeneste'          { 'Tjek udgiveren. Er den ukendt og usigneret, så tryk VirusTotal.' }
    'Ny fil'            { 'Tryk VirusTotal ved tvivl. Ellers kan du roligt ignorere den.' }
    'Browser'           { 'Kender du ikke udvidelsen, så fjern den i browserens liste over udvidelser.' }
    'Bloat'             { 'Afinstallér, hvis du ikke bruger det.' }
    'Nyt siden sidst'   { 'Genkender du det, så markér det som OK.' }
    default             { 'Kender du det, så markér det som OK.' }
  }
}
function Apply-FindFilter {
  if (-not $script:Result) { return }
  $i = $ui.FilterRisk.SelectedIndex; $txt = $ui.FilterText.Text
  $rows = $script:Result.Findings | Where-Object {
    $x = $_
    if ($i -eq 1) { $x.Niveau -ge 2 } elseif ($i -eq 2) { $x.Niveau -ge 3 } elseif ($i -eq 3) { $x.Kategori -eq 'Bloat' } elseif ($i -eq 4) { $x.Kategori -eq 'Nyt siden sidst' } else { $true }
  } | Where-Object { -not $txt -or "$($_.Titel) $($_.Detalje) $($_.Sti)" -match [regex]::Escape($txt) }
  $ui.GridFind.ItemsSource = @($rows)
}
$ui.FilterRisk.Add_SelectionChanged({ Apply-FindFilter })
$ui.FilterText.Add_TextChanged({ Apply-FindFilter })

function ExeOf($cmd) {
  if (-not $cmd) { return $null }
  $c = [Environment]::ExpandEnvironmentVariables([string]$cmd).Trim()
  if ($c -match '^"([^"]+)"') { return $matches[1] }
  if (Test-Path -LiteralPath $c) { return $c }
  if ($c -match '^(.+?\.(exe|dll|bat|cmd|ps1|vbs|js|msi))(\s|$)') { return $matches[1] }
  return $c
}
$ui.GridFind.Add_SelectionChanged({
  $s = $ui.GridFind.SelectedItem
  if (-not $s) { return }
  $ui.DetWhy.Text = "[$($s.Risiko)]  $($s.Hvorfor)"
  $ui.DetAdvice.Text = "👉  Hvad du skal gøre: $(Get-Advice $s)"
  $ui.BtnIgnore.IsEnabled = $s.Kategori -ne 'Trussel'
  $ui.DetPath.Text = (@($s.Sti, $(if ($s.SHA256) { "SHA256: $($s.SHA256)" })) | Where-Object { $_ }) -join "`n"
  $p = ExeOf $s.Sti
  $exists = [bool]($p -and (Test-Path -LiteralPath $p))
  $ui.BtnOpen.IsEnabled = $exists
  $ui.BtnVT.IsEnabled = [bool]$s.SHA256 -or ($exists -and (Test-Path -LiteralPath $p -PathType Leaf))
  $ui.BtnDisable.IsEnabled = $s.Type -in 'task', 'run'
  $ui.BtnUninstall.IsEnabled = ($s.Type -eq 'appx') -or ($s.Type -eq 'uninstall' -and $s.Data.Cmd)
})
$ui.BtnIgnore.Add_Click({
  $s = $ui.GridFind.SelectedItem
  if (-not $s) { return }
  Add-Ignored $s
  $script:Result = [pscustomobject]@{ Findings = @($script:Result.Findings | Where-Object { $_ -ne $s }); Timeline = $script:Result.Timeline; Space = $script:Result.Space; Perf = $script:Result.Perf; Suspect = $script:Result.Suspect }
  Update-SecCard $script:Result.Findings; Apply-FindFilter
  $ui.DetWhy.Text = "✓ '$($s.Titel)' er markeret som OK og vises ikke igen."
  $ui.DetAdvice.Text = ''; $ui.DetPath.Text = ''; $ui.BtnIgnore.IsEnabled = $false
  Log "Markeret OK: $(Get-FindKey $s)"
})
$ui.BtnOpen.Add_Click({
  $p = ExeOf $ui.GridFind.SelectedItem.Sti
  if (Test-Path -LiteralPath $p -PathType Leaf) { Start-Process explorer.exe "/select,`"$p`"" } else { Start-Process explorer.exe "`"$p`"" }
})
$ui.BtnVT.Add_Click({
  $s = $ui.GridFind.SelectedItem; $h = $s.SHA256
  if (-not $h) { try { $h = (Get-FileHash -LiteralPath (ExeOf $s.Sti) -Algorithm SHA256 -ErrorAction Stop).Hash } catch { Msg "Filen kan ikke åbnes. Windows blokerer den sandsynligvis, fordi den er inficeret." | Out-Null; return } }
  if ($h) { Start-Process "https://www.virustotal.com/gui/file/$h" }   # kun fingeraftrykket sendes, ikke filen
})

function Read-Undo { if (Test-Path $UndoFile) { @((Get-Content $UndoFile -Raw | ConvertFrom-Json) | ForEach-Object { $_ }) } else { @() } }
function Write-Undo($list) { ConvertTo-Json -InputObject @($list) -Depth 5 | Out-File -Encoding utf8 $UndoFile }

$ui.BtnDisable.Add_Click({
  $s = $ui.GridFind.SelectedItem
  if ((Msg "Deaktivér:`n`n$($s.Titel)`n$($s.Sti)`n`nKan fortrydes med 'Fortryd seneste' på Overblik." 'Bekræft' 'YesNo' 'Warning') -ne 'Yes') { return }
  With-RestorePoint 'før deaktivering' $s {
    param($s)
    $n = Disable-Findings @($s)
    $ui.GridFind.Items.Refresh()
    if ($n) { $ui.StatusText.Text = "Deaktiveret: $($s.Titel)" } else { Msg 'Det lykkedes ikke at deaktivere den. Se pc-tjek.log.' 'PC-Tjek' 'OK' 'Error' | Out-Null }
  }
})
$ui.BtnUninstall.Add_Click({
  $s = $ui.GridFind.SelectedItem
  if ((Msg "Afinstallér $($s.Titel)?" 'Bekræft' 'YesNo' 'Warning') -ne 'Yes') { return }
  With-RestorePoint 'før afinstallation' $s {
    param($s)
    try {
      if ($s.Type -eq 'appx') {
        Remove-AppxPackage -Package $s.Data.Package -ErrorAction Stop
        $s.Detalje = 'AFINSTALLERET · kan geninstalleres fra Microsoft Store'
      } else {
        $cmd = $s.Data.Cmd
        if ($cmd -match '(?i)msiexec') { $args2 = ($cmd -replace '(?i)^.*?msiexec(\.exe)?"?\s*', '') -replace '(?i)/I\{', '/X{'; Start-Process msiexec.exe -ArgumentList $args2 }
        else { $exe = ExeOf $cmd; $rest = $cmd.Substring([math]::Min($cmd.Length, $cmd.IndexOf($exe) + $exe.Length)).Trim(' "'); Start-Process -FilePath $exe -ArgumentList $rest }
        $s.Detalje = 'Afinstalleringsprogrammet er startet. Følg dets vejledning'
      }
      $ui.GridFind.Items.Refresh(); Log "Afinstallér $($s.Titel)"
    } catch { Msg "Det lykkedes ikke: $($_.Exception.Message)" 'PC-Tjek' 'OK' 'Error' | Out-Null }
  }
})
$ui.BtnUndo.Add_Click({
  $undo = [System.Collections.ArrayList]@(Read-Undo)
  if ($undo.Count -eq 0) { Msg 'Der er intet at fortryde.' | Out-Null; return }
  $last = $undo[$undo.Count - 1]
  $desc = if ($last.Kind -eq 'task') { "Genaktivér opgaven $($last.TaskPath)$($last.TaskName)" } else { "Gendan autostart '$($last.Name)'" }
  if ((Msg "$desc ?" 'Fortryd' 'YesNo' 'Question') -ne 'Yes') { return }
  try {
    if ($last.Kind -eq 'task') { Enable-ScheduledTask -TaskPath $last.TaskPath -TaskName $last.TaskName -ErrorAction Stop | Out-Null }
    else { New-ItemProperty -Path $last.Key -Name $last.Name -Value $last.Value -PropertyType String -Force -ErrorAction Stop | Out-Null }
    $undo.RemoveAt($undo.Count - 1); Write-Undo $undo
    Msg 'Fortrudt.' | Out-Null
  } catch { Msg "Det lykkedes ikke: $($_.Exception.Message)" 'PC-Tjek' 'OK' 'Error' | Out-Null }
})

# =====================================================================
#  Hændelsesforløb
# =====================================================================
function Apply-TimeFilter {
  if (-not $script:Result) { return }
  $txt = $ui.TimeFilter.Text
  $ui.GridTime.ItemsSource = @($script:Result.Timeline | Where-Object { (-not $ui.OnlyFocus.IsChecked -or $_.Fokus) -and (-not $txt -or "$($_.Hændelse) $($_.Detalje)" -match [regex]::Escape($txt)) })
}
$ui.TimeFilter.Add_TextChanged({ Apply-TimeFilter })
$ui.OnlyFocus.Add_Click({ Apply-TimeFilter })

# =====================================================================
#  Opstart (samme mekanisme som Jobliste: StartupApproved)
# =====================================================================
$StartTips = [ordered]@{
  '(?i)security|defender|securityhealth'      = 'BEHOLD: Windows Sikkerhed'
  '(?i)realtek|audio|nvidia|amd|intel|touchpad|synaptics|bærbare|portable' = 'Behold: driver/hardware'
  '(?i)tailscale|synology|launcher'           = 'Behold, hvis du bruger synkronisering/fjernadgang'
  '(?i)nzxt'                                  = 'Valgfri: tung (CPU/RAM), men styrer måske blæsere/køling'
  '(?i)poweriso'                              = 'Kan slås fra: Windows kan selv montere ISO-filer'
  '(?i)spotify'                               = 'Kan slås fra: åbn den, når du vil høre musik'
  '(?i)discord'                               = 'Kan slås fra: åbn den, når du skal bruge den'
  '(?i)chatgpt|claude|copilot'                = 'Kan slås fra: åbn den, når du skal bruge den'
  '(?i)steam|battle\.net|epic|xbox'           = 'Kan slås fra: spil-launchere behøver ikke at starte med Windows'
  '(?i)onedrive'                              = 'Valgfri: behold, hvis du synkroniserer filer med OneDrive'
  '(?i)teams|skype'                           = 'Valgfri: slå fra, hvis du ikke bruger den dagligt'
  '(?i)gigabyte|gcc|rgb|corsair|icue|armoury' = 'Valgfri: behold, hvis den styrer blæsere eller RGB'
  '(?i)cisco|anyconnect'                      = 'Valgfri: behold, hvis du bruger VPN (fx skolens)'
  '(?i)adobe|acrobat|updater|update'          = 'Kan slås fra: opdaterer også, når programmet åbnes'
}
function Get-StartTip($name, $cmd, $sig) {
  foreach ($k in $StartTips.Keys) { if ("$name $cmd" -match $k) { return $StartTips[$k] } }
  if ($sig -like 'USIGNERET*') { return '⚠ Usigneret. Kender du den ikke, så slå den fra og tjek den under Fund' }
  return 'Valgfri'
}
function Sig-Short($path) {
  if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return '(fil ikke fundet)' }
  try { $s = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop } catch { return 'BLOKERET AF DEFENDER?' }
  if ($s.Status -eq 'Valid') { return ($s.SignerCertificate.Subject -replace '^CN="?([^,"]+).*', '$1') }
  return 'USIGNERET'
}
$ApprovedBase = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
function Get-StartupItems {
  $items = New-Object System.Collections.ArrayList
  foreach ($src in @(
      @{ Hive = 'HKCU'; Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Appr = 'Run'; Label = 'Bruger' },
      @{ Hive = 'HKLM'; Run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Appr = 'Run'; Label = 'Alle brugere' },
      @{ Hive = 'HKLM'; Run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Appr = 'Run32'; Label = 'Alle (32-bit)' })) {
    $props = Get-ItemProperty $src.Run -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    foreach ($pr in ($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
      $apprKey = "$($src.Hive):\$ApprovedBase\$($src.Appr)"
      $bytes = (Get-ItemProperty $apprKey -Name $pr.Name -ErrorAction SilentlyContinue).($pr.Name)
      $on = -not ($bytes -and ($bytes[0] -band 1))
      $sg = Sig-Short (ExeOf $pr.Value)
      [void]$items.Add([pscustomobject]@{ Status = $(if ($on) { '🟢 Til' } else { '⚪ Fra' }); Aktiv = $on; Navn = $pr.Name; Tip = (Get-StartTip $pr.Name $pr.Value $sg)
        Udgiver = $sg; Kilde = $src.Label; Kind = 'reg'; ApprKey = $apprKey; ValueName = $pr.Name })
    }
  }
  foreach ($sf in @(@{ P = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"; Hive = 'HKCU'; Label = 'Startmappe' },
                    @{ P = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"; Hive = 'HKLM'; Label = 'Startmappe (alle)' })) {
    foreach ($fi in @(Get-ChildItem $sf.P -File -Force -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini')) {
      $apprKey = "$($sf.Hive):\$ApprovedBase\StartupFolder"
      $bytes = (Get-ItemProperty $apprKey -Name $fi.Name -ErrorAction SilentlyContinue).($fi.Name)
      $on = -not ($bytes -and ($bytes[0] -band 1))
      $target = $fi.FullName
      if ($fi.Extension -eq '.lnk') { try { $target = (New-Object -ComObject WScript.Shell).CreateShortcut($fi.FullName).TargetPath } catch {} }
      $sg = Sig-Short $target
      [void]$items.Add([pscustomobject]@{ Status = $(if ($on) { '🟢 Til' } else { '⚪ Fra' }); Aktiv = $on; Navn = $fi.BaseName; Tip = (Get-StartTip $fi.BaseName $target $sg)
        Udgiver = $sg; Kilde = $sf.Label; Kind = 'reg'; ApprKey = $apprKey; ValueName = $fi.Name })
    }
  }
  # Store-apps (Spotify, ChatGPT, ...): StartupTask State. 2 = til, 1 = slået fra af bruger, 4 = tvunget til af politik
  $appData = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
  foreach ($pk in @(Get-ChildItem $appData -ErrorAction SilentlyContinue)) {
    foreach ($tk in @(Get-ChildItem $pk.PSPath -ErrorAction SilentlyContinue)) {
      $state = (Get-ItemProperty $tk.PSPath -Name State -ErrorAction SilentlyContinue).State
      if ($null -eq $state) { continue }
      $nice = ($pk.PSChildName -split '_')[0] -replace '^[^.]+\.', ''
      $on = $state -in 2, 4
      [void]$items.Add([pscustomobject]@{ Status = $(if ($on) { '🟢 Til' } else { '⚪ Fra' }); Aktiv = $on; Navn = $nice; Tip = (Get-StartTip $nice $pk.PSChildName 'Store')
        Udgiver = 'Microsoft Store-app'; Kilde = 'Store-app'; Kind = 'appx'; ApprKey = $tk.PSPath; ValueName = 'State' })
    }
  }
  @($items | Sort-Object @{ e = { -not $_.Aktiv } }, Navn)
}
function Set-StartupState($item, [bool]$enable) {
  if ($item.Kind -eq 'appx') {
    if (-not $enable -and (Get-ItemProperty $item.ApprKey -Name State).State -eq 4) { throw 'Appen er låst til at starte af en politik.' }
    Set-ItemProperty -Path $item.ApprKey -Name State -Value $(if ($enable) { 2 } else { 1 }) -Type DWord -ErrorAction Stop
    return
  }
  if (-not (Test-Path $item.ApprKey)) { New-Item -Path $item.ApprKey -Force | Out-Null }
  $b = New-Object byte[] 12
  if ($enable) { $b[0] = 2 } else { $b[0] = 3; [BitConverter]::GetBytes([DateTime]::Now.ToFileTime()).CopyTo($b, 4) }
  New-ItemProperty -Path $item.ApprKey -Name $item.ValueName -Value $b -PropertyType Binary -Force -ErrorAction Stop | Out-Null
}
function Load-Startup {
  $list = @(Get-StartupItems)
  $ui.GridStart.ItemsSource = $list
  $on = @($list | Where-Object Aktiv).Count
  $can = @($list | Where-Object { $_.Aktiv -and $_.Tip -like 'Kan slås fra*' }).Count
  $ui.StartInfo.Text = "$on af $($list.Count) programmer starter automatisk · $can kan uden videre slås fra · Til/fra virker som i Jobliste: intet slettes."
  $ui.StartValue.Text = "$on"
  $ui.StartSub.Text = "starter med Windows$(if ($can) { " · $can kan slås fra" } else { '' })"
}
function Toggle-Selected {
  $it = $ui.GridStart.SelectedItem
  if (-not $it) { return }
  try {
    Set-StartupState $it (-not $it.Aktiv)
    Mark-StartupChange
    Load-Startup
    $ui.StatusText.Text = "$($it.Navn) er slået $(if ($it.Aktiv) { 'FRA' } else { 'TIL' }). Gælder fra næste login."
    Log "Opstart $($it.Navn) -> $(-not $it.Aktiv)"
  } catch { Msg "Det lykkedes ikke: $($_.Exception.Message)" 'PC-Tjek' 'OK' 'Error' | Out-Null }
}
$ui.GridStart.Add_SelectionChanged({
  $it = $ui.GridStart.SelectedItem
  $ui.BtnToggle.IsEnabled = [bool]$it
  if ($it) { $ui.BtnToggle.Content = $(if ($it.Aktiv) { '⏻  Slå FRA' } else { '⏻  Slå TIL' }) }
})
$ui.GridStart.Add_MouseDoubleClick({ Toggle-Selected })
$ui.BtnToggle.Add_Click({ Toggle-Selected })
$ui.BtnStartRefresh.Add_Click({ Load-Startup })
$ui.BtnStartAll.Add_Click({
  $targets = @($ui.GridStart.ItemsSource | Where-Object { $_.Aktiv -and $_.Tip -like 'Kan slås fra*' })
  if (-not $targets.Count) { Msg 'Der er intet, der anbefales slået fra.' | Out-Null; return }
  $names = ($targets | ForEach-Object { "  • $($_.Navn)" }) -join "`n"
  if ((Msg "Slå disse fra ved opstart?`n`n$names`n`nDu kan slå dem til igen her når som helst." 'Bekræft' 'YesNo' 'Question') -ne 'Yes') { return }
  $fail = @()
  foreach ($t in $targets) { try { Set-StartupState $t $false } catch { $fail += $t.Navn } }
  Mark-StartupChange
  Load-Startup
  $ui.StatusText.Text = "$($targets.Count - $fail.Count) programmer slået fra ved opstart." + $(if ($fail) { " Kunne ikke: $($fail -join ', ')" })
})

# =====================================================================
#  Oprydning
# =====================================================================
$L = $env:LOCALAPPDATA
$CleanCats = @(
  @{ Id = 'utemp';  Navn = 'Midlertidige filer (din bruger)'; Paths = @($env:TEMP); MinAgeHours = 24; Note = 'Rester fra programmer og installere'; Default = $true },
  @{ Id = 'wtemp';  Navn = 'Midlertidige filer (Windows)'; Paths = @('C:\Windows\Temp'); MinAgeHours = 24; Note = 'Systemets midlertidige filer'; Default = $true },
  @{ Id = 'wu';     Navn = 'Windows Update-downloads'; Paths = @('C:\Windows\SoftwareDistribution\Download'); MinAgeHours = 72; Note = 'Allerede installerede opdateringer. Windows rydder normalt selv op'; Default = $false },
  @{ Id = 'do';     Navn = 'Leveringsoptimering (cache)'; Paths = @('C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'); MinAgeHours = 0; Note = 'Opdateringsfiler delt med andre pc''er. Windows rydder normalt selv op'; Special = 'do'; Default = $false },
  @{ Id = 'dumps';  Navn = 'Crash dumps og fejlrapporter'; Paths = @("$L\CrashDumps", 'C:\Windows\Minidump', 'C:\Windows\MEMORY.DMP', 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive', 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue'); MinAgeHours = 24; Note = 'Bruges kun til fejlsøgning af gamle nedbrud'; Default = $true },
  @{ Id = 'shader'; Navn = 'Shader-cache (DirectX/NVIDIA)'; Paths = @("$L\D3DSCache", "$L\NVIDIA\DXCache", "$L\NVIDIA\GLCache", "$L\AMD\DxCache"); MinAgeHours = 24; Note = 'Genopbygges automatisk. Spil kan hakke lidt første gang efter'; Default = $false },
  @{ Id = 'thumbs'; Navn = 'Miniaturebilleder (thumbnail-cache)'; Paths = @("$L\Microsoft\Windows\Explorer\thumbcache_*.db"); MinAgeHours = 0; Note = 'Genopbygges, når du åbner mapper'; Default = $false },
  @{ Id = 'browser';Navn = 'Browsercache (Chrome og Edge)'; Paths = @("$L\Google\Chrome\User Data\*\Cache", "$L\Google\Chrome\User Data\*\Code Cache", "$L\Google\Chrome\User Data\*\GPUCache", "$L\Microsoft\Edge\User Data\*\Cache", "$L\Microsoft\Edge\User Data\*\Code Cache", "$L\Microsoft\Edge\User Data\*\GPUCache"); MinAgeHours = 0; Note = 'Luk browseren først. Logins og historik bevares'; Default = $false },
  @{ Id = 'recycle';Navn = 'Papirkurv'; Paths = @(); MinAgeHours = 0; Note = 'Tømmes permanent. Tjek den først'; Special = 'recycle'; Default = $false }
)
$script:CleanRows = @($CleanCats | ForEach-Object { $r = New-Object PcTjek.Row; $r.Id = $_.Id; $r.Navn = $_.Navn; $r.Note = $_.Note; $r.Valgt = $_.Default; $r.Info = '–'; $r.Tag = $_; $r })
$ui.GridClean.ItemsSource = $script:CleanRows
function Update-CleanTotal {
  $sel = ($script:CleanRows | Where-Object Valgt | Measure-Object Tal -Sum).Sum
  $ui.CleanTotal.Text = if ($script:CleanMeasured) { "Valgt: $(Fmt-GB $sel)" } else { '' }
}
foreach ($r in $script:CleanRows) { $r.Add_PropertyChanged({ Update-CleanTotal }) }
function Fill-CleanFromScan { if (-not $script:CleanMeasured) { $ui.CleanTotal.Text = 'Tryk på "Beregn størrelser"' } }
$ui.BtnCleanMeasure.Add_Click({
  $ui.BtnCleanMeasure.IsEnabled = $false
  Invoke-Bg $CleanMeasureScript @{ Cats = $CleanCats } {
    param($res, $err, $c)
    $ui.BtnCleanMeasure.IsEnabled = $true
    if ($err) { Msg "Fejl: $err" | Out-Null; return }
    if ($res -is [array]) { $res = @($res | Where-Object { $_ -is [hashtable] })[-1] }
    foreach ($r in $script:CleanRows) { $r.Tal = [double]$res[$r.Id]; $r.Info = Fmt-GB $r.Tal; $r.Status = '' }
    $script:CleanMeasured = $true; $ui.BtnCleanRun.IsEnabled = $true
    Update-CleanTotal
    $ui.StatusText.Text = "I alt $(Fmt-GB (($script:CleanRows | Measure-Object Tal -Sum).Sum)) kan ryddes."
  } $null
})
$ui.BtnCleanRun.Add_Click({
  $sel = @($script:CleanRows | Where-Object Valgt)
  if (-not $sel.Count) { return }
  if ($sel.Id -contains 'browser' -and (Get-Process chrome, msedge -ErrorAction SilentlyContinue)) {
    if ((Msg "Chrome eller Edge kører. Browsercachen kan kun ryddes, når browseren er lukket.`n`nLuk den nu, og tryk OK. Eller tryk Annullér." 'Luk browseren' 'OKCancel' 'Warning') -ne 'OK') { return }
  }
  if ($sel.Id -contains 'recycle' -and (Msg 'Papirkurven tømmes PERMANENT. Fortsæt?' 'Bekræft' 'YesNo' 'Warning') -ne 'Yes') { return }
  $ui.BtnCleanRun.IsEnabled = $false
  Invoke-Bg $CleanRunScript @{ Cats = @($sel | ForEach-Object { $_.Tag }) } {
    param($res, $err, $c)
    $ui.BtnCleanRun.IsEnabled = $true
    if ($res -is [array]) { $res = @($res | Where-Object { $_ -is [hashtable] })[-1] }
    $total = 0
    foreach ($r in $script:CleanRows) { if ($res -and $res.ContainsKey($r.Id)) { $r.Status = "✓ " + (Fmt-GB $res[$r.Id]); $total += $res[$r.Id] } }
    $ui.StatusText.Text = "Oprydning færdig: $(Fmt-GB $total) frigjort."
    Log "Oprydning: $total bytes"
    Msg "Færdig! $(Fmt-GB $total) frigjort.`n`n(Filer i brug er sprunget over.)" 'Oprydning' | Out-Null
  } $null
})
$ui.BtnCleanmgr.Add_Click({ Start-Process cleanmgr.exe })

# =====================================================================
#  Filer
# =====================================================================
$script:FileRows = @()
function Apply-FilesFilter {
  $g = switch ($ui.FilesFilter.SelectedIndex) { 1 { 'Dublet' } 2 { 'Installer' } 3 { 'Stor fil' } default { $null } }
  $ui.GridFiles.ItemsSource = @($script:FileRows | Where-Object { -not $g -or $_.Gruppe -eq $g })
  Update-FilesTotal
}
function Update-FilesTotal {
  $sel = @($script:FileRows | Where-Object Valgt)
  $ui.FilesTotal.Text = if ($script:FileRows.Count) { "$($sel.Count) valgt · $(Fmt-GB ((($sel | Measure-Object Tal -Sum).Sum) * 1MB))" } else { '' }
}
$ui.FilesFilter.Add_SelectionChanged({ Apply-FilesFilter })
$ui.BtnFilesScan.Add_Click({
  $ui.BtnFilesScan.IsEnabled = $false
  $progNames = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName | ForEach-Object DisplayName)
  Invoke-Bg $FilesScript @{ Programs = $progNames } {
    param($res, $err, $c)
    $ui.BtnFilesScan.IsEnabled = $true
    if ($err) { Msg "Fejl: $err" | Out-Null; return }
    $script:FileRows = @($res | ForEach-Object {
      $r = New-Object PcTjek.Row
      $r.Gruppe = $_.Gruppe; $r.Navn = $_.Navn; $r.Info = $_.Mappe; $r.Tal = [double]$_.MB; $r.Note = $_.Note; $r.Sti = $_.Sti; $r.Tag = $_.Forslag; $r.Valgt = $false
      $r.Add_PropertyChanged({ Update-FilesTotal }); $r })
    Apply-FilesFilter
    $d = @($script:FileRows | Where-Object { $_.Gruppe -eq 'Dublet' -and $_.Tag }); $i = @($script:FileRows | Where-Object { $_.Gruppe -eq 'Installer' -and $_.Tag })
    $ui.StatusText.Text = "Fundet: $($d.Count) overflødige dubletter ($(Fmt-GB ((($d | Measure-Object Tal -Sum).Sum) * 1MB))) og $($i.Count) gamle installere ($(Fmt-GB ((($i | Measure-Object Tal -Sum).Sum) * 1MB)))."
  } $null
})
$ui.BtnFilesSuggest.Add_Click({ foreach ($r in $ui.GridFiles.ItemsSource) { $r.Valgt = [bool]$r.Tag } })
$ui.BtnFilesNone.Add_Click({ foreach ($r in $script:FileRows) { $r.Valgt = $false } })
$ui.BtnFilesOpen.Add_Click({ $r = $ui.GridFiles.SelectedItem; if ($r -and (Test-Path -LiteralPath $r.Sti)) { Start-Process explorer.exe "/select,`"$($r.Sti)`"" } })
$ui.BtnFilesDelete.Add_Click({
  $sel = @($script:FileRows | Where-Object Valgt)
  if (-not $sel.Count) { Msg 'Vælg først nogle filer (afkryds dem, eller tryk "Vælg forslag").' | Out-Null; return }
  $mb = ($sel | Measure-Object Tal -Sum).Sum
  if ((Msg "Flyt $($sel.Count) filer ($(Fmt-GB ($mb * 1MB))) til papirkurven?`n`nDu kan gendanne dem fra papirkurven." 'Bekræft' 'YesNo' 'Question') -ne 'Yes') { return }
  $ok = 0; $fail = 0
  foreach ($r in $sel) {
    try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($r.Sti, 'OnlyErrorDialogs', 'SendToRecycleBin'); $ok++; $r.Note = '🗑 Flyttet til papirkurven'; $r.Valgt = $false; $r.Tag = $false }
    catch { $fail++; $r.Note = "Fejl: $($_.Exception.Message)" }
  }
  $ui.StatusText.Text = "$ok filer flyttet til papirkurven" + $(if ($fail) { ", $fail fejlede" } else { '' }) + '.'
  Log "Filer til papirkurv: $ok"
})

# =====================================================================
#  Opdateringer (winget)
# =====================================================================
$script:UpdRows = @()
$ui.BtnUpdCheck.Add_Click({
  $ui.BtnUpdCheck.IsEnabled = $false; $ui.UpdInfo.Text = 'Søger...'
  Invoke-Bg $WingetListScript $null {
    param($res, $err, $c)
    $ui.BtnUpdCheck.IsEnabled = $true
    if ($err) { $ui.UpdInfo.Text = $err; return }
    $script:UpdRows = @($res | ForEach-Object { $r = New-Object PcTjek.Row; $r.Navn = $_.Navn; $r.Id = $_.Id; $r.Info = $_.Version; $r.Note = $_.Ny; $r.Valgt = $true; $r.Status = 'Klar'; $r })
    $ui.GridUpdates.ItemsSource = $script:UpdRows
    $ui.BtnUpdRun.IsEnabled = $script:UpdRows.Count -gt 0
    $ui.UpdInfo.Text = if ($script:UpdRows.Count) { "$($script:UpdRows.Count) programmer kan opdateres." } else { 'Alt er opdateret. 🎉' }
  } $null
})
$ui.BtnUpdRun.Add_Click({
  $sel = @($script:UpdRows | Where-Object Valgt)
  if (-not $sel.Count) { return }
  foreach ($r in $sel) { $r.Status = '⏳ I kø' }
  $ui.BtnUpdRun.IsEnabled = $false
  Invoke-Bg $WingetUpgradeScript @{ Ids = @($sel | ForEach-Object Id) } {
    param($res, $err, $c)
    $ui.BtnUpdRun.IsEnabled = $true
    if ($res -is [array]) { $res = @($res | Where-Object { $_ -is [hashtable] })[-1] }
    if (-not $res) { $ui.UpdInfo.Text = "Fejl: $err"; return }
    foreach ($r in $script:UpdRows) { if ($res -and $res.ContainsKey($r.Id)) { $r.Status = $(if ($res[$r.Id] -eq 'OK') { '✓ Opdateret' } else { "✗ $($res[$r.Id])" }); $r.Valgt = $false } }
    $okc = @($res.Values | Where-Object { $_ -eq 'OK' }).Count
    $ui.UpdInfo.Text = "$okc af $($res.Count) opdateret. Nogle programmer skal lukkes eller genstartes for at opdatere."
    Log "winget: $okc/$($res.Count)"
  } $null
})

# =====================================================================
#  Ydelse og helbred
# =====================================================================
function HRow($ok, $name, $val, $note) { $r = New-Object PcTjek.Row; $r.Status = $(switch ($ok) { 2 { '🟢' } 1 { '🟡' } 0 { '🔴' } default { 'ℹ' } }); $r.Navn = $name; $r.Info = [string]$val; $r.Note = $note; $r }
function Load-Health {
  $rows = New-Object System.Collections.ArrayList
  foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
    $rc = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    $ok = if ($d.HealthStatus -eq 'Healthy') { 2 } elseif ($d.HealthStatus -eq 'Warning') { 1 } else { 0 }
    [void]$rows.Add((HRow $ok "Disk: $($d.FriendlyName)" "$($d.MediaType) · $([math]::Round($d.Size / 1GB)) GB · $($d.HealthStatus)" $(if ($ok -eq 2) { 'Disken melder sund' } else { 'Tag backup snarest, og overvej at udskifte disken' })))
    if ($rc) {
      if ($rc.Temperature) { $t = [int]$rc.Temperature; [void]$rows.Add((HRow $(if ($t -lt 55) { 2 } elseif ($t -lt 70) { 1 } else { 0 }) '   Temperatur' "$t °C" $(if ($t -lt 55) { 'Fin' } elseif ($t -lt 70) { 'Varm. Tjek luftgennemstrømning' } else { 'For varm!' }))) }
      if ($null -ne $rc.Wear) { $w = [int]$rc.Wear; [void]$rows.Add((HRow $(if ($w -lt 50) { 2 } elseif ($w -lt 85) { 1 } else { 0 }) '   Slid (SSD)' "$w %" $(if ($w -lt 50) { 'Masser af levetid tilbage' } elseif ($w -lt 85) { 'Halvvejs. Hold øje' } else { 'Tæt på slidt op: tag backup' }))) }
      if ($rc.PowerOnHours) { [void]$rows.Add((HRow 3 '   Driftstimer' "$($rc.PowerOnHours) t" '')) }
    }
  }
  $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
  $pct = [math]::Round($c.FreeSpace / $c.Size * 100)
  [void]$rows.Add((HRow $(if ($pct -ge 20) { 2 } elseif ($pct -ge 10) { 1 } else { 0 }) 'Ledig plads på C:' "$([math]::Round($c.FreeSpace / 1GB)) GB ($pct %)" $(if ($pct -ge 20) { 'Fint' } else { 'Under 20 % ledig gør Windows langsommere. Brug Oprydning og Filer' })))
  $os = Get-CimInstance Win32_OperatingSystem
  $days = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
  [void]$rows.Add((HRow $(if ($days -lt 7) { 2 } else { 1 }) 'Tid siden genstart' "$days dage" $(if ($days -lt 7) { 'Fint' } else { 'Genstart pc''en: Hurtig start betyder, at "Luk computeren" ikke rydder hukommelsen' })))
  $ram = [math]::Round(100 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100)
  [void]$rows.Add((HRow $(if ($ram -lt 75) { 2 } elseif ($ram -lt 90) { 1 } else { 0 }) 'RAM i brug' "$ram % af $([math]::Round($os.TotalVisibleMemorySize / 1MB)) GB" $(if ($ram -lt 75) { 'Fint' } else { 'Luk tunge programmer, eller slå opstartsprogrammer fra' })))
  $plan = (powercfg /getactivescheme) -join ' '
  $planName = if ($plan -match '\((.+)\)') { $matches[1] } else { $plan }
  $script:PlanIsHigh = $plan -match '8c5e7fda|e9a42b02'
  [void]$rows.Add((HRow $(if ($script:PlanIsHigh) { 2 } else { 1 }) 'Strømplan' $planName $(if ($script:PlanIsHigh) { 'Maks. ydelse' } else { 'På en stationær gaming-pc giver "Høj ydelse" lidt hurtigere respons (lidt mere strømforbrug)' })))
  $gm = (Get-ItemProperty 'HKCU:\Software\Microsoft\GameBar' -Name AutoGameModeEnabled -ErrorAction SilentlyContinue).AutoGameModeEnabled
  $script:GameModeOn = ($null -eq $gm) -or ($gm -eq 1)
  [void]$rows.Add((HRow $(if ($script:GameModeOn) { 2 } else { 1 }) 'Spiltilstand' $(if ($script:GameModeOn) { 'Til' } else { 'Fra' }) $(if ($script:GameModeOn) { 'Windows prioriterer spil' } else { 'Slå den til: Windows prioriterer spil og pauser opdateringer under spil' })))
  $hags = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
  [void]$rows.Add((HRow $(if ($hags -eq 2) { 2 } else { 3 }) 'Hardware-accelereret GPU-planlægning' $(if ($hags -eq 2) { 'Til' } else { 'Fra' }) 'Kan slås til i Indstillinger → Skærm → Grafik (kræver genstart). Giver lavere latens i nogle spil'))
  $boot = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction SilentlyContinue |
    ForEach-Object { (([xml]$_.ToXml()).Event.EventData.Data | Where-Object Name -eq 'BootTime').'#text' }
  if ($boot) { $bs = [math]::Round([int]$boot / 1000); [void]$rows.Add((HRow $(if ($bs -lt 40) { 2 } elseif ($bs -lt 90) { 1 } else { 0 }) 'Seneste opstartstid' "$bs sek" $(if ($bs -lt 40) { 'Hurtig' } else { 'Langsom: slå opstartsprogrammer fra under Opstart' }))) }
  $ui.GridHealth.ItemsSource = @($rows)
  $ui.BtnPowerHigh.IsEnabled = -not $script:PlanIsHigh
  $ui.BtnGameMode.IsEnabled = -not $script:GameModeOn
  $script:HealthLoaded = $true
}
$ui.BtnHealthRefresh.Add_Click({ Load-Health; try { Show-Reboot; Show-Boot } catch {}; Show-Crashes })
$ui.BtnPowerHigh.Add_Click({
  powercfg /setactive SCHEME_MIN 2>$null
  if ($LASTEXITCODE -ne 0) {   # skjult på nogle pc'er: lav en kopi af "Høj ydelse"
    $o = powercfg /duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
    if (($o -join ' ') -match '([0-9a-f]{8}-[0-9a-f-]{27})') { powercfg /setactive $matches[1] }
  }
  Log 'Strømplan: Høj ydelse'; Load-Health
})
$ui.BtnPowerBal.Add_Click({ powercfg /setactive SCHEME_BALANCED; Log 'Strømplan: Balanceret'; Load-Health })
$ui.BtnGameMode.Add_Click({
  New-Item 'HKCU:\Software\Microsoft\GameBar' -Force -ErrorAction SilentlyContinue | Out-Null
  Set-ItemProperty 'HKCU:\Software\Microsoft\GameBar' -Name AutoGameModeEnabled -Value 1 -Type DWord
  Log 'Spiltilstand til'; Load-Health
})
$ui.BtnOfflineScan.Add_Click({ Start-Process 'windowsdefender://threatsettings' })

# =====================================================================
#  DIN PLAN: få, simple trin med én knap hver
# =====================================================================
$script:PlanRows = @()
$script:AutoQueue = New-Object System.Collections.ArrayList
$script:ShowDetails = $false

function New-Step($id, $title, $why, $button, $data) {
  $r = New-Object PcTjek.Row
  $r.Id = $id; $r.Navn = $title; $r.Info = $why; $r.Note = $button; $r.Valgt = $true; $r.Status = ''; $r.Tag = $data
  return $r
}
function Get-Step($id) { $script:PlanRows | Where-Object { $_.Id -eq $id } | Select-Object -First 1 }
function Set-StepState($id, $state, $text) {
  $st = Get-Step $id; if (-not $st) { return }
  switch ($state) {
    'busy' { $st.Status = '⏳ ' + $text; $st.Valgt = $false }
    'done' { $st.Status = '✓ ' + $text; $st.Valgt = $false; $st.Gruppe = '✓'; $st.Note = 'Klaret' }
    'fail' { $st.Status = '✗ ' + $text; $st.Valgt = $true }
  }
  Update-PlanHeader
}
function Update-PlanHeader {
  $left = @($script:PlanRows | Where-Object { $_.Gruppe -ne '✓' })
  if (-not $script:PlanRows.Count) { return }
  if ($left.Count -eq 0) { $ui.PlanTitle.Text = '🎉 Alt er klaret'; $ui.PlanSub.Text = "Din pc er ryddet op. Scan igen om en uges tid, eller hvis noget føles mærkeligt."; $ui.BtnFixAll.Visibility = 'Collapsed' }
  else { $ui.PlanTitle.Text = "Din plan · $($left.Count) $(if ($left.Count -eq 1) { 'ting' } else { 'ting' }) at gøre"; $ui.PlanSub.Text = 'Start fra toppen. Tryk på knappen ud for hvert trin, eller lad appen klare de sikre ting for dig.' }
}

function Build-Plan($r) {
  $f = $r.Findings
  $steps = New-Object System.Collections.ArrayList
  $threats = @($f | Where-Object { $_.Kategori -eq 'Trussel' })
  $infected = @($threats | Where-Object { $_.Titel -like 'Inficeret fil:*' })
  $ran = @($f | Where-Object { $_.Kategori -like 'Trussel*' -and $_.Detalje -match 'Kørte: JA' })
  $pwFlag = Join-Path $OutDir 'adgangskoder-skiftet.txt'
  if ($ran.Count -and (Test-Path $pwFlag)) {
    $doneNames = @(Get-Content $pwFlag -Encoding UTF8)
    $ran = @($ran | Where-Object { $doneNames -notcontains (($_.Titel) -replace ' \(fjernet\)$', '') })
  }
  if ($infected.Count -or @($threats | Where-Object { $_.Niveau -ge 4 }).Count) {
    $why = if ($infected.Count) { "Der ligger $($infected.Count) fil(er) med virus på pc'en. En dybdescanning fjerner dem, før Windows starter (ca. 15 min)." } else { 'Windows har fundet en aktiv trussel. En dybdescanning fjerner den, før Windows starter (ca. 15 min).' }
    [void]$steps.Add((New-Step 'virus' 'Fjern virus' $why 'Start dybdescanning' $null))
  }
  $persist = @($f | Where-Object { $_.Niveau -ge 3 -and $_.Type -in 'task', 'run' })
  if ($persist.Count) {
    [void]$steps.Add((New-Step 'persist' 'Stop mistænkelige programmer' "$($persist.Count) ukendt(e) program(mer) starter automatisk på en måde, der ligner malware. De slås fra, men slettes ikke, så du kan fortryde." 'Slå dem fra' $persist))
  }
  # Alt andet, der "bør gennemgås", får sit eget trin med forklaring, så intet er skjult
  $review = @($f | Where-Object { $_.Niveau -ge 3 -and $_.Type -notin 'task', 'run' -and $_.Kategori -ne 'Trussel' })
  $ri = 0
  foreach ($x in ($review | Select-Object -First 3)) {
    $ri++
    $label = switch -Wildcard ($x.Kategori) { 'Installation' { 'Se nærmere på en installation' } 'Defender' { 'Tjek en indstilling i Defender' } 'Netværk' { 'Tjek en netværksforbindelse' } 'Autostart' { 'Tjek noget, der starter automatisk' } 'Tjeneste' { 'Tjek en baggrundstjeneste' } 'Browser' { 'Tjek din browser' } 'Proces' { 'Tjek et program, der kører' } default { 'Se nærmere på et fund' } }
    [void]$steps.Add((New-Step "review$ri" "$label" "$($x.Titel). $(Get-Advice $x)" 'Vis detaljer' $x))
  }
  if ($review.Count -gt 3) {
    [void]$steps.Add((New-Step 'reviewall' "$($review.Count - 3) ting mere bør gennemgås" 'Se hele listen under Fund. Ingen af dem er bekræftet farlige, men de skiller sig ud.' 'Vis alle' $null))
  }
  if ($ran.Count) {
    [void]$steps.Add((New-Step 'passwords' 'Skift dine vigtigste adgangskoder' 'Noget skadeligt nåede at køre og kan have set dine gemte logins. Skift e-mail først, gerne fra din telefon.' 'Vis hvordan' $null))
  }
  $start = @(@(Get-StartupItems) | Where-Object { $_.Aktiv -and $_.Tip -like 'Kan slås fra*' })
  if ($start.Count) {
    [void]$steps.Add((New-Step 'startup' 'Gør opstarten hurtigere' "$($start.Count) programmer starter med Windows uden grund ($((($start | Select-Object -First 4).Navn) -join ', ')$(if ($start.Count -gt 4) { ' ...' })). De kan stadig åbnes, når du vil." "Slå $($start.Count) fra" $null))
  }
  $cs = New-Step 'clean' 'Ryd op i midlertidige filer' 'Måler, hvor meget der kan ryddes...' 'Ryd op' $null
  $cs.Valgt = $false
  [void]$steps.Add($cs)
  try { if (-not $script:TweaksLoaded) { Show-Tweaks } } catch { Log "Tweak-fejl: $_" }
  if ($script:TweakTips) {
    $bits = @()
    if ($script:Tweaks.Ram -and $script:Tweaks.Ram.Gain) { $bits += "RAM kører $($script:Tweaks.Ram.Cfg) i stedet for $($script:Tweaks.Ram.Rated) MT/s" }
    $lowHz = @($script:Tweaks.Hz | Where-Object { $_.Max -gt $_.Cur + 1 }) | Select-Object -First 1
    if ($lowHz) { $bits += "skærmen kører $($lowHz.Cur) Hz, men kan $($lowHz.Max) Hz" }
    [void]$steps.Add((New-Step 'tweaks' 'Få gratis ydelse' (($bits -join ' · ') + '. Se hvordan under Optimering.') 'Vis mig hvordan' $null))
  }
  if (-not (Get-ScheduledTask -TaskName 'PC-Tjek Vagt' -ErrorAction SilentlyContinue)) {
    [void]$steps.Add((New-Step 'vagt' 'Slå Vagten til' 'Få en advarsel, hvis du henter noget farligt, eller hvis et nyt program sætter sig fast i opstarten. Kører stille i baggrunden.' 'Slå til' $null))
  }
  [void]$steps.Add((New-Step 'update' 'Opdatér dine programmer' 'Gamle programmer er en af de mest almindelige måder, virus kommer ind på. Opdateringen kører i baggrunden.' 'Opdatér alt' $null))
  $ext = @($f | Where-Object { $_.Kategori -eq 'Browser' -and $_.Niveau -ge 2 })
  if ($ext.Count) {
    [void]$steps.Add((New-Step 'extensions' 'Tjek dine browserudvidelser' "$($ext.Count) udvidelse(r) kan læse alt, hvad du gør på nettet: $((($ext | Select-Object -First 3).Titel -replace '^.*?: ', '') -join ', '). Fjern dem, du ikke kender." 'Åbn udvidelser' $ext))
  }
  $bloat = @($f | Where-Object { $_.Kategori -eq 'Bloat' -and $_.Type -eq 'appx' })
  if ($bloat.Count -ge 3) {
    [void]$steps.Add((New-Step 'bloat' 'Fjern unødvendige Windows-apps' "$($bloat.Count) forudinstallerede apps, som du kan undvære (nyheder, kabale og lignende). De kan hentes igen fra Microsoft Store." 'Fjern dem' $bloat))
  }
  $up = ((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalDays
  $pend = @(Get-PendingReboot)
  if ($pend.Count) {
    [void]$steps.Add((New-Step 'restart' 'Genstart for at færdiggøre en opdatering' "Windows venter på en genstart ($($pend -join ' og ')). Ændringerne træder først i kraft bagefter." 'Genstart' $null))
  } elseif ($up -ge 5) {
    [void]$steps.Add((New-Step 'restart' 'Genstart pc''en' ("Pc'en har kørt i {0:N0} dage uden genstart. Det gør den langsommere. Gør det til sidst." -f $up) 'Genstart' $null))
  }
  $n = 0; foreach ($s in $steps) { $n++; $s.Gruppe = "$n" }
  $script:PlanRows = @($steps)
  $ui.PlanList.ItemsSource = $script:PlanRows
  $ui.BtnFixAll.Visibility = 'Collapsed'   # vises, når oprydningen er målt
  $ui.BtnDetails.Visibility = 'Visible'
  Update-PlanHeader
  Measure-PlanClean
}
# Samme kategorier og filtre bruges til målingen og selve oprydningen, så tallene passer sammen
function Measure-PlanClean {
  $ui.CntSpace.Text = '…'
  Invoke-Bg $CleanMeasureScript @{ Cats = @($CleanCats | Where-Object { $_.Default }) } {
    param($res, $err, $c)
    if ($res -is [array]) { $res = @($res | Where-Object { $_ -is [hashtable] })[-1] }
    $tot = 0.0; if ($res) { foreach ($k in $res.Keys) { $tot += [double]$res[$k] } }
    foreach ($row in $script:CleanRows) { if ($res -and $res.ContainsKey($row.Id)) { $row.Tal = [double]$res[$row.Id]; $row.Info = Fmt-GB $row.Tal } }
    $script:CleanMeasured = $true; $ui.BtnCleanRun.IsEnabled = $true
    $ui.CntSpace.Text = Fmt-GB $tot
    try { $cc = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"; $ui.SpaceSub.Text = "kan ryddes · $([math]::Round($cc.FreeSpace / 1GB)) GB ledig på C:" } catch {}
    $st = Get-Step 'clean'; if (-not $st) { return }
    if ($err) { $st.Info = 'Kunne ikke måle. Du kan stadig prøve at rydde op.'; $st.Valgt = $true; return }
    if ($tot -lt 50MB) { Set-StepState 'clean' 'done' 'Intet at rydde'; $st.Info = 'Der er næsten ingen midlertidige filer.'; return }
    $st.Info = "Ca. $(Fmt-GB $tot) midlertidige filer og cache, som Windows ikke har brug for. Filer i brug springes over."
    $st.Valgt = $true
    $ui.BtnFixAll.Visibility = 'Visible'
  } $null
}

# ---------- Handlinger for hvert trin ----------
function Disable-Findings($items) {
  $undo = [System.Collections.ArrayList]@(Read-Undo)
  $ok = 0
  foreach ($s in $items) {
    try {
      if ($s.Type -eq 'task') {
        Disable-ScheduledTask -TaskPath $s.Data.TaskPath -TaskName $s.Data.TaskName -ErrorAction Stop | Out-Null
        [void]$undo.Add([pscustomobject]@{ Kind = 'task'; TaskPath = $s.Data.TaskPath; TaskName = $s.Data.TaskName; When = (Get-Date).ToString('s') })
      } elseif ($s.Type -eq 'run') {
        [void]$undo.Add([pscustomobject]@{ Kind = 'run'; Key = $s.Data.Key; Name = $s.Data.Name; Value = $s.Data.Value; When = (Get-Date).ToString('s') })
        Write-Undo $undo
        Remove-ItemProperty -Path $s.Data.Key -Name $s.Data.Name -ErrorAction Stop
      }
      $s.Detalje = "DEAKTIVERET $(Get-Date -Format 'HH:mm') · " + $s.Detalje; $ok++
      Log "Deaktiveret $($s.Titel)"
    } catch { Log "Kunne ikke deaktivere $($s.Titel): $_" }
  }
  Write-Undo $undo
  return $ok
}

function Run-Step($id, [bool]$auto) {
  $st = Get-Step $id
  if (-not $st -or ($st.Gruppe -eq '✓')) { Next-Auto; return }
  switch ($id) {
    'virus' {
      if ((Msg "Pc'en genstarter nu og scanner i ca. 15 minutter, før Windows starter.`n`nGem dit arbejde, og luk andre programmer først.`n`nStart dybdescanningen?" 'Fjern virus' 'YesNo' 'Warning') -ne 'Yes') { return }
      try { Start-MpWDOScan -ErrorAction Stop; Set-StepState 'virus' 'busy' 'Genstarter...' } catch { Start-Process 'windowsdefender://threatsettings'; Set-StepState 'virus' 'fail' 'Start den i Windows Sikkerhed' }
    }
    'passwords' {
      Msg ("Sådan gør du (helst fra din telefon):`n`n1. Skift adgangskoden til din e-mail først.`n2. Derefter bank (MitID er ikke påvirket), Discord, Steam og sociale medier.`n3. Slå to-trins-bekræftelse til, hvor du kan.`n4. Log ud af alle enheder i de vigtigste tjenester.`n`nBrug ikke den samme adgangskode flere steder.") 'Adgangskoder' | Out-Null
      if ((Msg 'Har du skiftet dem? (Ja = marker som klaret, så du ikke bliver spurgt igen for de samme trusler)' 'Adgangskoder' 'YesNo' 'Question') -eq 'Yes') {
        $names = @($script:Result.Findings | Where-Object { $_.Kategori -like 'Trussel*' -and $_.Detalje -match 'Kørte: JA' } | ForEach-Object { ($_.Titel) -replace ' \(fjernet\)$', '' })
        try { $names | Add-Content -Path (Join-Path $OutDir 'adgangskoder-skiftet.txt') -Encoding UTF8 } catch {}
        Set-StepState 'passwords' 'done' 'Klaret'
      }
    }
    'persist' {
      $names = ($st.Tag | ForEach-Object { "  • $($_.Titel)" }) -join "`n"
      if (-not $auto -and (Msg "Disse programmer slås fra ved opstart:`n`n$names`n`nDe slettes ikke. Du kan fortryde med 'Fortryd seneste'." 'Bekræft' 'YesNo' 'Question') -ne 'Yes') { return }
      Set-StepState 'persist' 'busy' 'Slår fra...'
      With-RestorePoint 'før deaktivering' $st { param($st) $n = Disable-Findings $st.Tag; Set-StepState 'persist' 'done' "$n slået fra"; Next-Auto }
    }
    'startup' {
      $t = @(@(Get-StartupItems) | Where-Object { $_.Aktiv -and $_.Tip -like 'Kan slås fra*' })
      $names = ($t | ForEach-Object { "  • $($_.Navn)" }) -join "`n"
      if ((Msg "Disse programmer starter ikke længere automatisk:`n`n$names`n`nDu kan stadig åbne dem selv, og du kan slå dem til igen under Opstart." 'Gør opstarten hurtigere' 'YesNo' 'Question') -ne 'Yes') { return }
      $ok = 0; $fail = @()
      foreach ($x in $t) { try { Set-StartupState $x $false; $ok++ } catch { $fail += $x.Navn } }
      if ($ok) { Mark-StartupChange }
      Load-Startup
      if ($fail.Count) { Set-StepState 'startup' 'fail' "$ok af $($t.Count) slået fra · ikke: $($fail -join ', ')" } else { Set-StepState 'startup' 'done' "$ok slået fra" }
      Log "Plan: opstart $ok/$($t.Count)"
    }
    'clean' {
      Set-StepState 'clean' 'busy' 'Rydder op...'
      $cats = @($CleanCats | Where-Object { $_.Default })
      Invoke-Bg $CleanRunScript @{ Cats = $cats } {
        param($res, $err, $c)
        if ($res -is [array]) { $res = @($res | Where-Object { $_ -is [hashtable] })[-1] }
        $tot = 0; $sk = 0
        if ($res) { foreach ($k in $res.Keys) { if ($k -eq '_skipped') { $sk = [int]$res[$k] } else { $tot += [double]$res[$k] } } }
        if ($err) { Set-StepState 'clean' 'fail' 'Fejl. Prøv igen' }
        else { Set-StepState 'clean' 'done' ("$(Fmt-GB $tot) ryddet" + $(if ($sk) { " · $sk filer i brug sprunget over" } else { '' })) }
        Next-Auto
      } $null
    }
    'update' {
      Set-StepState 'update' 'busy' 'Finder opdateringer...'
      Invoke-Bg $WingetListScript $null {
        param($res, $err, $c)
        if ($err) { Set-StepState 'update' 'fail' 'Kunne ikke søge efter opdateringer'; Log "winget: $err"; return }
        $list = @($res | Where-Object { $_.Id })
        if (-not $list.Count) { Set-StepState 'update' 'done' 'Alt er opdateret'; return }
        $names = ($list | ForEach-Object { "  • $($_.Navn)  ($($_.Version) → $($_.Ny))" }) -join "`n"
        if ((Msg "Disse programmer opdateres:`n`n$names`n`nLuk dem gerne først. Det kører i baggrunden." 'Opdatér programmer' 'YesNo' 'Question') -ne 'Yes') { $st2 = Get-Step 'update'; $st2.Status = ''; $st2.Valgt = $true; return }
        $ids = @($list | ForEach-Object { $_.Id })
        Set-StepState 'update' 'busy' "Opdaterer $($ids.Count) programmer..."
        Invoke-Bg $WingetUpgradeScript @{ Ids = $ids } {
          param($res2, $err2, $c2)
          if ($res2 -is [array]) { $res2 = @($res2 | Where-Object { $_ -is [hashtable] })[-1] }
          $failed = @(); $okc = 0
          if ($res2) { foreach ($k in $res2.Keys) { if ($res2[$k] -eq 'OK') { $okc++ } else { $failed += $k } } }
          if ($err2 -or -not $res2) { Set-StepState 'update' 'fail' 'Opdateringen fejlede. Prøv igen' }
          elseif ($failed.Count) { Set-StepState 'update' 'fail' "$okc af $($c2.N) opdateret · prøv igen for $((($failed | ForEach-Object { ($_ -split '\.')[-1] }) -join ', '))" }
          else { Set-StepState 'update' 'done' "$okc af $($c2.N) opdateret" }
        } @{ N = $ids.Count }
      } $null
    }
    'extensions' {
      $hasChrome = @($st.Tag | Where-Object { $_.Titel -like 'Chrome*' }).Count
      if ($hasChrome) { Start-Process 'chrome.exe' 'chrome://extensions' } else { Start-Process 'msedge.exe' 'edge://extensions' }
      Msg "Browseren åbner nu listen over udvidelser.`n`nFjern dem, du ikke selv har installeret eller ikke kender:`n`n$((($st.Tag | ForEach-Object { '  • ' + ($_.Titel -replace '^.*?: ', '') }) -join "`n"))" 'Udvidelser' | Out-Null
      Set-StepState 'extensions' 'done' 'Tjekket'
    }
    'bloat' {
      $names = ($st.Tag | ForEach-Object { '  • ' + ($_.Titel -replace '^Windows-app: ', '') }) -join "`n"
      if ((Msg "Disse apps fjernes:`n`n$names`n`nDe kan hentes igen fra Microsoft Store." 'Bekræft' 'YesNo' 'Question') -ne 'Yes') { return }
      $ok = 0; foreach ($b in $st.Tag) { try { Remove-AppxPackage -Package $b.Data.Package -ErrorAction Stop; $ok++ } catch {} }
      Set-StepState 'bloat' 'done' "$ok fjernet"; Log "Plan: bloat $ok"
    }
    'tweaks' { $ui.NavTweaks.IsChecked = $true; Set-StepState 'tweaks' 'done' 'Åbnet' }
    'vagt' { if (Install-Vagt) { Set-StepState 'vagt' 'done' 'Vagten passer på dig' } }
    { $_ -like 'review*' } {
      $ui.NavFind.IsChecked = $true
      $ui.FilterText.Text = ''
      $ui.FilterRisk.SelectedIndex = 2
      Apply-FindFilter
      if ($st.Tag) {
        $hit = @($ui.GridFind.ItemsSource | Where-Object { $_.Titel -eq $st.Tag.Titel -and $_.Sti -eq $st.Tag.Sti }) | Select-Object -First 1
        if ($hit) { $ui.GridFind.SelectedItem = $hit; $ui.GridFind.ScrollIntoView($hit) }
        if ((Msg "$($st.Tag.Titel)`n`n$($st.Tag.Hvorfor)`n`nHvad du skal gøre: $(Get-Advice $st.Tag)`n`n$($st.Tag.Sti)`n`nKender du den, og er den i orden?`n(Ja = markér som OK, så den ikke vises igen)" 'Gennemgå' 'YesNo' 'Question') -eq 'Yes') { Add-Ignored $st.Tag; Set-StepState $id 'done' 'Markeret som OK' }
      } else { Set-StepState $id 'done' 'Åbnet' }
    }
    'restart' {
      if ((Msg "Genstart pc'en om 30 sekunder?`n`nGem dit arbejde først." 'Genstart' 'YesNo' 'Question') -ne 'Yes') { return }
      shutdown.exe /r /t 30 /c "PC-Tjek genstarter pc'en om 30 sekunder."
      Set-StepState 'restart' 'busy' 'Genstarter om 30 sek.'
    }
  }
}
function Next-Auto {
  if ($script:AutoQueue.Count -eq 0) { return }
  $nxt = $script:AutoQueue[0]; $script:AutoQueue.RemoveAt(0)
  Run-Step $nxt $true
}
$ui.PlanList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
  param($sender, $e)
  $b = $e.OriginalSource
  if ($b -is [Windows.Controls.Button] -and $b.Tag) { Run-Step ([string]$b.Tag) $false }
})
# Hovedknappen gør kun én forudsigelig ting: rydder de anbefalede midlertidige filer
$ui.BtnFixAll.Add_Click({
  $st = Get-Step 'clean'
  if (-not $st -or $st.Gruppe -eq '✓' -or -not $st.Valgt) { return }
  $ui.BtnFixAll.Visibility = 'Collapsed'
  Run-Step 'clean' $true
})
$ui.SecCard.Add_MouseLeftButtonUp({ if ($script:Result) { $ui.NavFind.IsChecked = $true; $ui.FilterText.Text = ''; $ui.FilterRisk.SelectedIndex = 2; Apply-FindFilter } })
$ui.BtnDetails.Add_Click({
  $script:ShowDetails = -not $script:ShowDetails
  $ui.StoryCard.Visibility = $(if ($script:ShowDetails) { 'Visible' } else { 'Collapsed' })
  $ui.PlanCard.Visibility = $(if ($script:ShowDetails) { 'Collapsed' } else { 'Visible' })
  $ui.BtnDetails.Content = $(if ($script:ShowDetails) { '← Tilbage til planen' } else { 'Vis detaljer' })
})

# =====================================================================
#  OPTIMERING: RAM (XMP/EXPO), skærm-Hz, driver- og BIOS-alder
# =====================================================================
$script:Tweaks = $null
function Get-RamRated([string]$pn) {
  $pn = $pn.Trim().ToUpper()
  $v = $null
  if ($pn -match 'F[45]-(\d{4})[A-Z]') { $v = [int]$matches[1] }                     # G.Skill: F5-6000J3038...
  elseif ($pn -match '^KF\d(\d{2})C\d') { $v = [int]$matches[1] * 100 }              # Kingston Fury: KF560C36 -> 6000
  elseif ($pn -match '^C[TP]\d+G(\d{2})C\d') { $v = [int]$matches[1] * 100 }         # Crucial: CP16G60C36 -> 6000
  elseif ($pn -match '(\d{4})H?C\d{2}') { $v = [int]$matches[1] }                    # Corsair/TeamGroup: ...B6000C36 / 6000HC38
  if ($v -and ($v -lt 1600 -or $v -gt 9600)) { $v = $null }
  return $v
}
function Get-TweakResults {
  $t = @{}
  # ---- RAM ----
  try {
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $cfg = [int](($mods | Measure-Object ConfiguredClockSpeed -Maximum).Maximum)
    $spd = [int](($mods | Measure-Object Speed -Maximum).Maximum)
    $pn = [string]$mods[0].PartNumber
    $type = switch ([int]$mods[0].SMBIOSMemoryType) { 26 { 'DDR4' } 34 { 'DDR5' } default { '' } }
    $rated = Get-RamRated $pn
    if (-not $rated -or $rated -lt $spd) { $rated = $spd }
    $board = (Get-CimInstance Win32_BaseBoard).Manufacturer
    $amd = (Get-CimInstance Win32_Processor | Select-Object -First 1).Manufacturer -match 'AMD'
    $prof = if ($amd -and $type -eq 'DDR5') { 'EXPO' } else { 'XMP' }
    $t.Ram = @{ Cfg = $cfg; Rated = $rated; Type = $type; Count = $mods.Count; Pn = $pn.Trim(); Board = $board; Prof = $prof
                Gain = ($cfg -gt 0 -and $rated -gt $cfg + 150); Single = ($mods.Count -eq 1); Unknown = ($cfg -le 0) }
  } catch { $t.Ram = $null }
  # ---- Skærme ----
  try {
    $t.Hz = @([PcTjek.Screens]::List() | ForEach-Object {
      $p = $_ -split '\|'
      [pscustomobject]@{ Dev = $p[0]; Name = $p[1]; W = [int]$p[2]; H = [int]$p[3]; Cur = [int]$p[4]; Max = [int]$p[5] }
    })
    $friendly = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue | ForEach-Object { (($_.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join '').Trim() })
    for ($i = 0; $i -lt $t.Hz.Count; $i++) { if (($t.Hz[$i].Name -match '(?i)generic|generisk|pnp|^$') -and $friendly[$i]) { $t.Hz[$i].Name = $friendly[$i] } }
  } catch { $t.Hz = @() }
  # ---- Driver og BIOS ----
  try {
    $g = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch '(?i)basic|virtual|remote|parsec|meta|mirage' } | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS
    $mb = Get-CimInstance Win32_BaseBoard
    $t.Drv = @{ Gpu = $g.Name; DrvDate = $g.DriverDate; DrvVer = $g.DriverVersion
                DrvDays = $(if ($g.DriverDate) { [int]((Get-Date) - $g.DriverDate).TotalDays } else { $null })
                BiosVer = $bios.SMBIOSBIOSVersion; BiosDate = $bios.ReleaseDate
                BiosDays = $(if ($bios.ReleaseDate) { [int]((Get-Date) - $bios.ReleaseDate).TotalDays } else { $null })
                Board = "$($mb.Manufacturer) $($mb.Product)".Trim() }
  } catch { $t.Drv = $null }
  $script:Tweaks = $t
  return $t
}
function Set-Badge($p, $state, $text) {
  $c = switch ($state) { 'good' { @('#173325', '#4ADE80') } 'tip' { @('#3A2E12', '#F6C344') } default { @('#1D2433', '#8AB4FF') } }
  $ui["${p}Badge"].Background = $Brush.ConvertFromString($c[0])
  $ui["${p}BadgeText"].Foreground = $Brush.ConvertFromString($c[1])
  $ui["${p}BadgeText"].Text = $text
}
function Fmt-Age($days) {
  if ($null -eq $days) { return 'ukendt' }
  if ($days -lt 31) { return "$days dage" }
  if ($days -lt 365) { return "$([math]::Round($days / 30.4)) mdr." }
  return "$([math]::Round($days / 365.0, 1).ToString('0.#')) år"
}
function Show-Tweaks {
  $t = Get-TweakResults
  $tips = 0
  # ---- RAM-kort ----
  $r = $t.Ram
  $ui.RamNowLbl.Text = 'I BRUG'; $ui.RamCanLbl.Text = 'MODULET ER MÆRKET'
  if ($r -and $r.Unknown) { $r = $null }
  if ($r) {
    $ui.RamNow.Text = "$($r.Cfg) MT/s"
    if ($r.Gain) {
      $tips++
      Set-Badge 'Ram' 'tip' "💡 Mulig forbedring · Avanceret"
      $ui.RamCan.Text = "$($r.Rated) MT/s"; $ui.RamArrow.Visibility = 'Visible'; $ui.RamCan.Visibility = 'Visible'; $ui.RamCanLbl.Visibility = 'Visible'
      $ui.RamText.Text = "Din $($r.Type) RAM kører med $($r.Cfg) MT/s. Ud fra modelnummeret ($($r.Pn)) ser modulet ud til at være mærket $($r.Rated) MT/s. Den hastighed får man normalt ved at slå $($r.Prof) til i BIOS.`n`n$($r.Prof) er en profil, som RAM-producenten har testet, men teknisk set er det overclocking. Om det kører stabilt, afhænger af dit bundkort og din processor. Hvor meget hurtigere spil bliver, varierer fra spil til spil."
    } else {
      Set-Badge 'Ram' 'good' '✓ Alt godt'
      $ui.RamArrow.Visibility = 'Collapsed'; $ui.RamCan.Visibility = 'Collapsed'; $ui.RamCanLbl.Visibility = 'Collapsed'
      $ui.RamText.Text = "Din $($r.Type) RAM kører med sin fulde hastighed ($($r.Cfg) MT/s, $($r.Count) moduler). Der er ikke mere at hente her."
    }
    if ($r.Single) { $ui.RamText.Text += "`n`n💡 Du har kun ét RAM-modul. Med to moduler (dual channel) får processoren næsten dobbelt så hurtig adgang til hukommelsen. Det kan mærkes i spil." }
    $bios = if ($r.Board -match '(?i)gigabyte') { "I GIGABYTE-BIOS: Tweaker (eller Easy Mode) → Extreme Memory Profile (X.M.P.) → vælg Profile 1." }
            elseif ($r.Board -match '(?i)asus') { "I ASUS-BIOS: Ai Tweaker (eller tryk F7 for Advanced) → Ai Overclock Tuner → $($r.Prof) I." }
            elseif ($r.Board -match '(?i)micro-star|msi') { "I MSI-BIOS: øverst til venstre findes en $($r.Prof)-knap. Slå den til (Profile 1)." }
            elseif ($r.Board -match '(?i)asrock') { "I ASRock-BIOS: OC Tweaker → DRAM Configuration → Load $($r.Prof) Setting → Profile 1." }
            else { "Find indstillingen $($r.Prof) (eller 'Memory Profile') i BIOS, og vælg Profile 1." }
    $ui.RamStepsText.Text = "Avanceret: gør det kun, hvis du er tryg ved at ændre i BIOS.`n`n1.  Tryk på 'Genstart til BIOS' (eller genstart, og tryk gentagne gange på Del, mens pc'en starter).`n2.  $bios`n3.  Tryk F10 for at gemme og genstarte.`n4.  Åbn PC-Tjek igen, og tryk 'Tjek igen'. Nu bør der stå $($r.Rated) MT/s.`n`nStarter pc'en ikke bagefter, venter den typisk lidt og nulstiller selv. Ellers så slå $($r.Prof) fra igen."
    $ui.RamAction.Content = '🔁  Genstart til BIOS'; $ui.RamAction.Visibility = $(if ($r.Gain) { 'Visible' } else { 'Collapsed' })
  } else { Set-Badge 'Ram' 'info' 'Kunne ikke måles'; $ui.RamNow.Text = '–'; $ui.RamArrow.Visibility = 'Collapsed'; $ui.RamCan.Visibility = 'Collapsed'; $ui.RamCanLbl.Visibility = 'Collapsed'; $ui.RamText.Text = 'Windows oplyser ikke RAM-hastigheden på denne pc, så den kan ikke vurderes.'; $ui.RamAction.Visibility = 'Collapsed' }

  # ---- Skærm-kort ----
  $hz = @($t.Hz)
  if ($hz.Count) {
    $low = @($hz | Where-Object { $_.Max -gt $_.Cur + 1 })
    $first = if ($low.Count) { $low[0] } else { $hz[0] }
    $ui.HzNow.Text = "$($first.Cur) Hz"
    $lines = ($hz | ForEach-Object { "•  $(if ($_.Name) { $_.Name } else { $_.Dev }): $($_.W)×$($_.H) på $($_.Cur) Hz$(if ($_.Max -gt $_.Cur + 1) { "  →  kan køre $($_.Max) Hz" } else { '  ✓' })" }) -join "`n"
    if ($low.Count) {
      $tips++
      Set-Badge 'Hz' 'tip' '💡 Gratis ydelse'
      $ui.HzCan.Text = "$($first.Max) Hz"; $ui.HzArrow.Visibility = 'Visible'; $ui.HzCan.Visibility = 'Visible'; $ui.HzCanLbl.Visibility = 'Visible'
      $ui.HzText.Text = "Din skærm kan vise $($first.Max) billeder i sekundet, men Windows bruger kun $($first.Cur). Alt føles mere flydende, når den kører fuld hastighed, også musen og scrolling.`n`n$lines"
    } else {
      Set-Badge 'Hz' 'good' '✓ Alt godt'
      $ui.HzArrow.Visibility = 'Collapsed'; $ui.HzCan.Visibility = 'Collapsed'; $ui.HzCanLbl.Visibility = 'Collapsed'
      $ui.HzText.Text = "Dine skærme kører allerede med den højeste hastighed, de understøtter.`n`n$lines"
    }
    $ui.HzStepsText.Text = "1.  Tryk på 'Åbn skærmindstillinger'.`n2.  Vælg skærmen øverst (hvis du har flere).`n3.  Under 'Vælg en opdateringshastighed' vælger du den højeste værdi$(if ($low.Count) { " ($($first.Max) Hz)" }).`n4.  Tryk 'Behold ændringer'.`n`nTip: brug DisplayPort-kablet til skærme over 144 Hz. Gamle HDMI-kabler kan begrænse hastigheden."
    $ui.HzAction.Content = '🖥  Åbn skærmindstillinger'; $ui.HzAction.Visibility = 'Visible'
  } else { Set-Badge 'Hz' 'info' 'Kunne ikke læses'; $ui.HzText.Text = 'Kunne ikke læse skærmens indstillinger.' }

  # ---- Driver/BIOS-kort ----
  $d = $t.Drv
  if ($d) {
    $ui.DrvNowLbl.Text = 'GRAFIKDRIVER (INSTALLERET)'; $ui.DrvCanLbl.Text = 'BIOS (INSTALLERET)'; $ui.DrvArrow.Text = '·'
    $ver = [string]$d.DrvVer
    if ($d.Gpu -match '(?i)nvidia' -and $ver -match '\d+\.\d+\.\d(\d)\.(\d{2})(\d{2})$') { $ver = "$($matches[1])$($matches[2]).$($matches[3])" }
    $ui.DrvNow.Text = $ver; $ui.DrvCan.Text = [string]$d.BiosVer
    $ui.DrvCan.Foreground = $ui.DrvNow.Foreground
    $oldDrv = $d.DrvDays -gt 120; $oldBios = $d.BiosDays -gt 730
    $parts = @()
    $parts += "Grafikdriver til $($d.Gpu): version $ver fra $(if ($d.DrvDate) { $d.DrvDate.ToString('dd-MM-yyyy') } else { '?' }) ($(Fmt-Age $d.DrvDays) gammel)."
    $parts += "BIOS på $($d.Board): $($d.BiosVer) fra $(if ($d.BiosDate) { $d.BiosDate.ToString('dd-MM-yyyy') } else { '?' }) ($(Fmt-Age $d.BiosDays) gammel)."
    $parts += "Datoen alene siger ikke, om der findes en relevant opdatering. Det kan kun producenten svare på. Tryk på knapperne for at tjekke hos dem."
    $ui.DrvText.Text = $parts -join "`n`n"
    if ($oldDrv -or $oldBios) { Set-Badge 'Drv' 'info' 'ℹ Tjek hos producenten' } else { Set-Badge 'Drv' 'good' '✓ Ret nye versioner' }
    if ($oldDrv) { $ui.DrvNow.Foreground = $Brush.ConvertFromString('#F6C344') }
    $ui.DrvStepsText.Text = "Grafikdriver:`n1.  Tryk på 'Opdatér grafikdriver'. Det åbner NVIDIA App / AMD Software (eller Windows Update).`n2.  Gå til Drivere, og tryk Hent/Installér.`n`nBIOS (kun hvis du vil):`n1.  Tryk på 'Find BIOS-opdatering', og åbn producentens side for $($d.Board).`n2.  Læs producentens vejledning grundigt. Sluk ALDRIG pc'en under en BIOS-opdatering.`n3.  Efter opdateringen skal $(if ($t.Ram) { $t.Ram.Prof } else { 'XMP' }) ofte slås til igen."
    $ui.DrvAction.Content = '⬇  Opdatér grafikdriver'; $ui.DrvAction.Visibility = 'Visible'
    $ui.DrvAction2.Content = '🔎  Find BIOS-opdatering'; $ui.DrvAction2.Visibility = 'Visible'
  } else { Set-Badge 'Drv' 'info' 'Kunne ikke læses' }

  $ui.TweakSummary.Text = if ($tips) { "💡 $tips gratis forbedring$(if ($tips -gt 1) { 'er' }) fundet. Intet ændres, uden at du selv gør det." } else { '✓ Din pc er sat godt op. Der er ingen gratis ydelse at hente lige nu.' }
  $script:TweakTips = $tips
  $script:TweaksLoaded = $true
}
foreach ($p in 'Ram', 'Hz', 'Drv') {
  $ui["${p}How"].Tag = $p
  $ui["${p}How"].Add_Click({ param($sender, $e)
    $q = $sender.Tag; $b = $ui["${q}Steps"]
    $b.Visibility = $(if ($b.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' })
    $sender.Content = $(if ($b.Visibility -eq 'Visible') { '✕  Skjul guiden' } else { '📖  Sådan gør du' })
  })
}
$ui.RamAction.Add_Click({
  if ((Msg "Pc'en genstarter om 10 sekunder og åbner BIOS'en direkte.`n`nGem dit arbejde først. Guiden står i PC-Tjek under 'Sådan gør du'. Tag gerne et billede af den med telefonen.`n`nGenstart nu?" 'Genstart til BIOS' 'YesNo' 'Question') -ne 'Yes') { return }
  $o = & shutdown.exe /r /fw /t 10 2>&1
  if ($LASTEXITCODE -ne 0) { Msg "Din pc understøtter ikke genstart direkte til BIOS fra Windows.`n`nGenstart i stedet, og tryk gentagne gange på Del-tasten, mens pc'en starter." 'Genstart til BIOS' | Out-Null }
})
$ui.HzAction.Add_Click({ Start-Process 'ms-settings:display-advanced' })
$ui.DrvAction.Add_Click({
  $nv = @("$env:ProgramFiles\NVIDIA Corporation\NVIDIA App\CEF\NVIDIA App.exe", "$env:ProgramFiles\NVIDIA Corporation\NVIDIA App\NVIDIA App.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  $amd = "$env:ProgramFiles\AMD\CNext\CNext\RadeonSoftware.exe"
  if ($nv) { Start-Process $nv } elseif (Test-Path $amd) { Start-Process $amd } else { Start-Process 'ms-settings:windowsupdate-optionalupdates' }
})
$ui.DrvAction2.Add_Click({
  $b = if ($script:Tweaks -and $script:Tweaks.Drv) { $script:Tweaks.Drv.Board } else { 'bundkort' }
  Start-Process ("https://www.google.com/search?q=" + [Uri]::EscapeDataString("$b BIOS download support"))
})
$ui.BtnTweakRefresh.Add_Click({ Show-Tweaks })


# =====================================================================
#  VAGT: Download-vagt + Vagthund (baggrundsproces ved login)
# =====================================================================
$VagtScript = Join-Path $PSScriptRoot 'PC-Tjek-Vagt.ps1'
$VagtCfg    = Join-Path $JobBase 'vagt.json'
$VagtLog    = Join-Path $JobBase 'vagt-log.txt'
function Get-VagtTask { Get-ScheduledTask -TaskName 'PC-Tjek Vagt' -ErrorAction SilentlyContinue }
function Get-VagtProc { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*PC-Tjek-Vagt.ps1*' }) }
function Restart-Vagt {
  try { Stop-ScheduledTask -TaskName 'PC-Tjek Vagt' -ErrorAction SilentlyContinue } catch {}
  foreach ($p in Get-VagtProc) { try { Stop-Process -Id $p.ProcessId -Force } catch {} }
  Start-Sleep -Milliseconds 1200
  try { Start-ScheduledTask -TaskName 'PC-Tjek Vagt' -ErrorAction Stop } catch { Log "Vagt-start fejl: $_" }
}
function Test-VagtAlive {
  if ((Get-VagtProc).Count) { return $true }
  try { $st = Get-Content (Join-Path $JobBase 'vagt-status.json') -Raw | ConvertFrom-Json; return (((Get-Date) - [datetime]$st.Heartbeat).TotalSeconds -lt 90) } catch { return $false }
}
function Install-Vagt {
  if ($PSScriptRoot -notlike "$env:ProgramFiles\*") { Msg "Vagten kan kun slås til, når PC-Tjek er installeret med installeren (i Program Files).`n`nKør 'Installer PC-Tjek.cmd' først." 'Vagt' 'OK' 'Warning' | Out-Null; return $false }
  if (-not (Test-Path $VagtScript)) { Msg "Filen PC-Tjek-Vagt.ps1 mangler. Opdatér PC-Tjek, eller kør installeren igen." 'Vagt' 'OK' 'Warning' | Out-Null; return $false }
  try {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $sys = Join-Path $env:SystemRoot 'System32'
    $args2 = "--headless `"$sys\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$VagtScript`""
    $action = New-ScheduledTaskAction -Execute "$sys\conhost.exe" -Argument $args2 -WorkingDirectory $PSScriptRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName 'PC-Tjek Vagt' -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'PC-Tjek Vagt: tjekker downloads og nye opstartsprogrammer. Starter ved login.' -Force | Out-Null
    Save-VagtCfg
    Restart-Vagt
    Log 'Vagt slået til'
    return $true
  } catch { Msg "Kunne ikke slå vagten til: $($_.Exception.Message)" 'Vagt' 'OK' 'Error' | Out-Null; return $false }
}
function Remove-Vagt {
  try { Stop-ScheduledTask -TaskName 'PC-Tjek Vagt' -ErrorAction SilentlyContinue } catch {}
  foreach ($p in Get-VagtProc) { try { Stop-Process -Id $p.ProcessId -Force } catch {} }
  try { Unregister-ScheduledTask -TaskName 'PC-Tjek Vagt' -Confirm:$false -ErrorAction Stop } catch {}
  Log 'Vagt slået fra'
}
function Save-VagtCfg {
  $o = [ordered]@{ Downloads = [bool]$ui.ChkDl.IsChecked; Watchdog = [bool]$ui.ChkWd.IsChecked }
  try { [IO.File]::WriteAllText($VagtCfg, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch {}
}
function Load-Vagt {
  if (Test-Path $VagtCfg) { try { $j = Get-Content $VagtCfg -Raw | ConvertFrom-Json; $script:VagtLoading = $true; $ui.ChkDl.IsChecked = [bool]$j.Downloads; $ui.ChkWd.IsChecked = [bool]$j.Watchdog; $script:VagtLoading = $false } catch {} }
  $task = Get-VagtTask; $running = Test-VagtAlive
  $stat = $null; try { $stat = Get-Content (Join-Path $JobBase 'vagt-status.json') -Raw | ConvertFrom-Json } catch {}
  $fmtT = { param($t) if ($t) { $d = [datetime]$t; if ($d.Date -eq (Get-Date).Date) { 'kl. ' + $d.ToString('HH:mm') } else { $d.ToString('dd-MM HH:mm') } } else { 'endnu ikke' } }
  $dlOn = [bool]$ui.ChkDl.IsChecked; $wdOn = [bool]$ui.ChkWd.IsChecked
  $ui.VagtDlInfo.Text = if (-not $dlOn) { 'Slået fra' } elseif ($running -and $stat) { "● Aktiv · senest kontrolleret $(& $fmtT $stat.DownloadsChecked)" } else { 'Venter på, at vagten kører' }
  $ui.VagtWdInfo.Text = if (-not $wdOn) { 'Slået fra' } elseif ($running -and $stat) { "● Aktiv · senest kontrolleret $(& $fmtT $stat.WatchdogChecked)" } else { 'Venter på, at vagten kører' }
  if ($task -and $running -and -not ($dlOn -or $wdOn)) {
    $ui.VagtStatus.Text = 'Vagten kører, men begge tjek er slået fra'; $ui.VagtSub.Text = 'Slå mindst ét af tjekkene herunder til.'
    $ui.VagtIconBg.Background = $Brush.ConvertFromString('#6B5313'); $ui.BtnVagtToggle.Content = 'Slå vagten fra'; $ui.BtnVagtToggle.Style = $win.FindResource([Windows.Controls.Button])
    $ui.BtnVagtTest.IsEnabled = $true
  } elseif ($task -and $running) {
    $ui.VagtStatus.Text = 'Vagten passer på din pc ✓'; $ui.VagtSub.Text = 'Kører i baggrunden og starter automatisk, når du logger ind.'
    $ui.VagtIconBg.Background = $Brush.ConvertFromString('#1E5A3A'); $ui.BtnVagtToggle.Content = 'Slå vagten fra'; $ui.BtnVagtToggle.Style = $win.FindResource([Windows.Controls.Button])
    $ui.BtnVagtTest.IsEnabled = $true
  } elseif ($task) {
    $ui.VagtStatus.Text = 'Vagten er slået til, men kører ikke lige nu'; $ui.VagtSub.Text = 'Den starter ved næste login, eller tryk Genstart.'
    $ui.VagtIconBg.Background = $Brush.ConvertFromString('#6B5313'); $ui.BtnVagtToggle.Content = 'Genstart vagten'; $ui.BtnVagtToggle.Style = $win.FindResource('Primary')
    $ui.BtnVagtTest.IsEnabled = $false
  } else {
    $ui.VagtStatus.Text = 'Vagten er slået fra'; $ui.VagtSub.Text = 'Slå den til for at få besked, hvis du henter noget farligt, eller hvis noget nyt sætter sig fast.'
    $ui.VagtIconBg.Background = $Brush.ConvertFromString('#242A39'); $ui.BtnVagtToggle.Content = 'Slå vagten til'; $ui.BtnVagtToggle.Style = $win.FindResource('Primary')
    $ui.BtnVagtTest.IsEnabled = $false
  }
  $rows = @()
  if (Test-Path $VagtLog) {
    $lines = @(Get-Content $VagtLog -Encoding UTF8 -Tail 300)
    [array]::Reverse($lines)
    $rows = @($lines | ForEach-Object {
      try { $o = $_ | ConvertFrom-Json
        $ik = switch ($o.Niveau) { 'danger' { '⛔' } 'caution' { '⚠' } 'safe' { '✓' } 'handling' { '👆' } default { '•' } }
        [pscustomobject]@{ Tid = [datetime]$o.Tid; Ikon = $ik; Type = $o.Type; Titel = $o.Titel; Detalje = $o.Detalje }
      } catch {}
    })
  }
  $ui.GridVagt.ItemsSource = $rows
  $script:VagtLoaded = $true
}
$ui.BtnVagtToggle.Add_Click({
  $task = Get-VagtTask
  if ($task -and (Test-VagtAlive)) {
    if ((Msg 'Slå vagten fra? Du får så ingen advarsler om farlige downloads.' 'Vagt' 'YesNo' 'Question') -ne 'Yes') { return }
    Remove-Vagt
  } elseif ($task) { Restart-Vagt; Start-Sleep -Milliseconds 2500 }
  else { if (Install-Vagt) { Start-Sleep -Milliseconds 2000 } }
  Load-Vagt
  $st = Get-Step 'vagt'; if ($st -and (Get-VagtTask)) { Set-StepState 'vagt' 'done' 'Slået til' }
})
$ui.ChkDl.Add_Click({ if (-not $script:VagtLoading) { Save-VagtCfg; Load-Vagt } })
$ui.ChkWd.Add_Click({ if (-not $script:VagtLoading) { Save-VagtCfg; Load-Vagt } })
$ui.BtnVagtRefresh.Add_Click({ Load-Vagt })
$ui.BtnVagtTest.Add_Click({ try { [IO.File]::WriteAllText((Join-Path $JobBase 'vagt-test.flag'), 'test'); $ui.StatusText.Text = 'Kig nederst til højre om et par sekunder 👀' } catch {} })

# =====================================================================
#  FEJLFINDING: nedbrud, opstartstid før/efter, genstart-venter, supporttekst
# =====================================================================
$StartMarkFile = Join-Path $OutDir 'opstart-aendringer.txt'
function Mark-StartupChange { try { Add-Content -Path $StartMarkFile -Value (Get-Date).ToString('s') -Encoding UTF8 } catch {} }

function Get-PendingReboot {
  $why = @()
  if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $why += 'Windows Update' }
  if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $why += 'en Windows-komponent' }
  $pfr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
  if ($pfr -and @($pfr | Where-Object { $_ }).Count -gt 0 -and -not $why.Count) { $why += 'en installation' }
  return $why
}
function Show-Reboot {
  $w = @(Get-PendingReboot)
  if ($w.Count) {
    $ui.RebootBanner.Visibility = 'Visible'
    $ui.RebootWhy.Text = "Venter på: $($w -join ' og '). Ændringerne træder først i kraft efter en genstart."
    $ui.UpdReboot.Text = "🔁 Genstart venter ($($w -join ', '))"
  } else { $ui.RebootBanner.Visibility = 'Collapsed'; $ui.UpdReboot.Text = '' }
}
$ui.BtnRebootNow.Add_Click({
  if ((Msg "Genstart pc'en om 30 sekunder?`n`nGem dit arbejde først." 'Genstart' 'YesNo' 'Question') -ne 'Yes') { return }
  shutdown.exe /r /t 30 /c "PC-Tjek genstarter for at færdiggøre en opdatering."
})

function Get-Median($xs) { $v = @($xs | Sort-Object); if (-not $v.Count) { return $null }; return $v[[math]::Floor(($v.Count - 1) / 2)] }
function Show-Boot {
  $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 14 -ErrorAction SilentlyContinue)
  $boots = @($ev | ForEach-Object {
    $ms = (([xml]$_.ToXml()).Event.EventData.Data | Where-Object Name -eq 'BootTime').'#text'
    if ($ms) { [pscustomobject]@{ Time = $_.TimeCreated; Sek = [int][math]::Round([double]$ms / 1000) } }
  } | Sort-Object Time)
  if (-not $boots.Count) { $ui.BootSub.Text = 'Windows har ikke gemt nogen opstartsmålinger på denne pc.'; $ui.BootBig.Text = ''; return }
  $marks = @(); if (Test-Path $StartMarkFile) { $marks = @(Get-Content $StartMarkFile -Encoding UTF8 | ForEach-Object { try { [datetime]$_ } catch {} } | Where-Object { $_ } | Sort-Object) }
  $lastMark = if ($marks.Count) { $marks[-1] } else { $null }
  $max = [math]::Max(30, ($boots | Measure-Object Sek -Maximum).Maximum)
  $ui.BootBars.ItemsSource = @($boots | ForEach-Object {
    $r = New-Object PcTjek.Row
    $r.Navn = $_.Time.ToString('dd/MM'); $r.Info = "$($_.Sek)s"; $r.Tal = [math]::Max(4, 110.0 * $_.Sek / $max)
    $after = [bool]($lastMark -and $_.Time -gt $lastMark)
    $r.Gruppe = $(if ($after) { '#4ADE80' } else { '#7C5CFF' })
    $r.Note = "$($_.Time.ToString('dd-MM-yyyy HH:mm')): $($_.Sek) sek$(if ($after) { ' (efter ændring af opstart)' })"
    $r })
  $typ = Get-Median @($boots | Select-Object -Last 5 | ForEach-Object { $_.Sek })
  $ui.BootBig.Text = "$typ sek"
  if ($lastMark) {
    $before = @($boots | Where-Object { $_.Time -le $lastMark } | Select-Object -Last 5 | ForEach-Object { $_.Sek })
    $afterB = @($boots | Where-Object { $_.Time -gt $lastMark } | ForEach-Object { $_.Sek })
    if ($before.Count -and $afterB.Count) {
      $b = Get-Median $before; $a = Get-Median $afterB; $diff = $b - $a
      $ui.BootSub.Text = "Typisk opstart: $b → $a sekunder $(if ($diff -ge 3) { "· $diff sek hurtigere 🎉" } elseif ($diff -le -3) { "· $([math]::Abs($diff)) sek langsommere" } else { '· ingen tydelig forskel' }) (siden du ændrede opstarten $($lastMark.ToString('dd-MM')))"
    } elseif ($before.Count) { $ui.BootSub.Text = "Typisk opstart: $typ sek. Du ændrede opstarten $($lastMark.ToString('dd-MM')), så genstart pc'en for at måle effekten." }
    else { $ui.BootSub.Text = "Typisk opstart: $typ sek (median af de seneste 5)." }
  } else { $ui.BootSub.Text = "Typisk opstart: $typ sek (median af de seneste 5). Slår du programmer fra under Opstart, viser appen her, om det hjalp." }
  $ui.BootLegend.Text = 'Lilla = før, grøn = efter din seneste ændring af opstarten. Windows måler kun nogle opstarter, ikke alle.'
}

function Show-Crashes {
  Invoke-Bg $CrashScript $null {
    param($res, $err, $c)
    if ($res -is [array]) { $res = @($res | Where-Object { $_ -is [Collections.IDictionary] })[-1] }
    if (-not $res) { $ui.CrashSub.Text = 'Kunne ikke læse hændelsesloggen.'; return }
    $script:Crashes = $res
    $rows = New-Object System.Collections.ArrayList
    foreach ($a in @($res.Apps | Sort-Object { $_.Crash + $_.Hang } -Descending)) {
      $n = $a.Crash + $a.Hang
      $r = New-Object PcTjek.Row
      $r.Status = $(if ($n -ge 3) { '🔴' } elseif ($n -ge 2) { '🟡' } else { '⚪' })
      $nice = $a.Name -replace '\.exe$', ''
      $r.Navn = "$nice $(if ($a.Crash -and $a.Hang) { 'lukkede uventet / hang' } elseif ($a.Crash) { 'lukkede uventet' } else { 'holdt op med at svare' })"
      $r.Info = "$n gang$(if ($n -ne 1) { 'e' })"
      $r.Gruppe = $a.Last.ToString('dd-MM HH:mm')
      $near = @($res.Installs | Where-Object { $_.Time -le $a.First -and $_.Time -ge $a.First.AddHours(-48) } | Sort-Object Time -Descending | Select-Object -First 1)
      $r.Note = if ($near.Count) { "Begyndte $($a.First.ToString('dd-MM')), kort efter: $($near[0].Name) ($($near[0].Time.ToString('dd-MM HH:mm')))" } elseif ($n -ge 2) { "Første gang $($a.First.ToString('dd-MM HH:mm')). Ingen installation lige før." } else { '' }
      [void]$rows.Add($r)
    }
    foreach ($k in @(@{ K = 'bsod'; T = 'Blå skærm (systemnedbrud)'; I = '🔴' }, @{ K = 'restart'; T = 'Uventet genstart / strømtab'; I = '🟡' }, @{ K = 'shutdown'; T = 'Pc''en lukkede ned uventet'; I = '🟡' })) {
      $ev = @($res.System | Where-Object { $_.Kind -eq $k.K })
      if ($ev.Count) {
        $r = New-Object PcTjek.Row; $r.Status = $k.I; $r.Navn = $k.T; $r.Info = "$($ev.Count) gang$(if ($ev.Count -ne 1) { 'e' })"
        $r.Gruppe = ($ev | Sort-Object Time | Select-Object -Last 1).Time.ToString('dd-MM HH:mm')
        $r.Note = if ($k.K -eq 'bsod') { 'Ofte driver, RAM (fx ustabil XMP) eller overophedning' } elseif ($k.K -eq 'restart') { 'Strømafbrydelse, holdt tænd/sluk inde, eller ustabil hardware' } else { '' }
        [void]$rows.Insert(0, $r)
      }
    }
    $ui.GridCrash.ItemsSource = @($rows)
    $top = $res.Apps | Sort-Object { $_.Crash + $_.Hang } -Descending | Select-Object -First 1
    $total = [int](($res.Apps | Measure-Object Crash -Sum).Sum + ($res.Apps | Measure-Object Hang -Sum).Sum) + @($res.System).Count
    $ui.CrashBig.Text = "$total"
    $ui.CrashBig.Foreground = $Brush.ConvertFromString($(if ($total -ge 5) { '#FF5D6C' } elseif ($total -ge 1) { '#F6C344' } else { '#4ADE80' }))
    $ui.CrashSub.Text = if (-not $rows.Count) { 'Ingen nedbrud eller uventede genstarter de seneste 14 dage. 🎉' }
                        elseif ($top -and ($top.Crash + $top.Hang) -ge 2) { "$($top.Name -replace '\.exe$', '') har haft problemer $($top.Crash + $top.Hang) gange de seneste 14 dage. Start dér." }
                        else { 'Enkelte nedbrud de seneste 14 dage. Intet gentager sig.' }
  } $null
}

# ---------- Kopiér pc-info til support ----------
$ui.BtnCopyInfo.Add_Click({
  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add("PC-Tjek – pc-oplysninger ($(Get-Date -Format 'dd-MM-yyyy HH:mm'))")
  [void]$lines.Add('')
  foreach ($p in @(@('System', 'SysOS'), @('Processor', 'SysCpu'), @('Grafikkort', 'SysGpu'), @('Hukommelse', 'SysRam'), @('Bundkort', 'SysBoard'), @('Lager', 'SysDisk'))) {
    $v = $ui[$p[1]].Text; $sub = $ui["$($p[1])sub"].Text
    if ($v -and $v -ne '…') { [void]$lines.Add("$($p[0]): $v$(if ($sub) { ' · ' + ($sub -replace "`r?`n", ' | ') })") }
  }
  $w = @(Get-PendingReboot); if ($w.Count) { [void]$lines.Add("Venter på genstart: $($w -join ', ')") }
  if ($script:Crashes) {
    $top = @($script:Crashes.Apps | Sort-Object { $_.Crash + $_.Hang } -Descending | Select-Object -First 5)
    if ($top.Count) { [void]$lines.Add(''); [void]$lines.Add('Nedbrud (14 dage):'); foreach ($a in $top) { [void]$lines.Add("  - $($a.Name): $($a.Crash) nedbrud, $($a.Hang) hængt, sidst $($a.Last.ToString('dd-MM HH:mm'))") } }
    $bs = @($script:Crashes.System | Where-Object { $_.Kind -eq 'bsod' }).Count; if ($bs) { [void]$lines.Add("  - Blå skærm: $bs gange") }
  } else { [void]$lines.Add(''); [void]$lines.Add('(Åbn "Ydelse og helbred" først, hvis nedbrud skal med.)') }
  $text = $lines -join "`r`n"
  [xml]$dx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Kopiér pc-info til support" Width="660" Height="520" WindowStartupLocation="CenterOwner"
        Background="#0D0F14" Foreground="#E7E9EE" FontFamily="Segoe UI Variable Text, Segoe UI">
  <Grid Margin="18">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock TextWrapping="Wrap" Foreground="#8A94A7" Margin="0,0,0,10" Text="Det her bliver kopieret. Du kan rette eller slette linjer, før du kopierer. Der er ingen adgangskoder eller personlige filer med."/>
    <TextBox Name="Txt" Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#10131A" Foreground="#E7E9EE" BorderBrush="#242A39" Padding="10" FontFamily="Consolas" FontSize="12.5"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button Name="CopyBtn" Content="📋  Kopiér" Padding="16,8" Margin="0,0,8,0"/>
      <Button Name="CloseBtn" Content="Luk" Padding="16,8"/>
    </StackPanel>
  </Grid>
</Window>
'@
  $d = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
  $d.Owner = $win
  $d.FindName('Txt').Text = $text
  $d.FindName('CopyBtn').Add_Click({ param($s, $e) $dw = [Windows.Window]::GetWindow($s); [Windows.Clipboard]::SetText($dw.FindName('Txt').Text); $s.Content = '✓  Kopieret' })
  $d.FindName('CloseBtn').Add_Click({ param($s, $e) [Windows.Window]::GetWindow($s).Close() })
  [void]$d.ShowDialog()
})

# =====================================================================
#  GPU-TUNING: live-data, mål før/efter, testet på min pc, testet af andre
# =====================================================================
$GpuTestsFile = Join-Path $OutDir 'gpu-tests.json'
$script:GpuBefore = $null; $script:GpuAfter = $null
function Get-Smi { $p = "$env:SystemRoot\System32\nvidia-smi.exe"; if (-not (Test-Path $p)) { $p = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe" }; if (Test-Path $p) { $p } else { $null } }
function Get-GpuName { (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch '(?i)basic|virtual|remote|parsec|meta|mirage' } | Select-Object -First 1).Name }
function Update-GpuLive {
  $smi = Get-Smi
  if (-not $smi) { $ui.GpuLiveW.Text = '–'; return }
  $q = & $smi --query-gpu=power.draw,power.limit,temperature.gpu,fan.speed,clocks.gr,utilization.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1
  $p = @($q -split ',\s*')
  if ($p.Count -lt 6) { return }
  $f = { param($x, $u) $x = ([string]$x).Trim(); if ($x -match '^[\d.]+$') { "$([math]::Round([double]::Parse($x, [Globalization.CultureInfo]::InvariantCulture)))$u" } else { 'n/a' } }
  $ui.GpuLiveW.Text = (& $f $p[0] ' W') + $(if ($p[1] -match '^[\d.]+') { " / $(& $f $p[1] '')" } else { '' })
  $ui.GpuLiveT.Text = & $f $p[2] ' °C'
  $ui.GpuLiveF.Text = & $f $p[3] ' %'
  $ui.GpuLiveC.Text = & $f $p[4] ' MHz'
  $ui.GpuLiveU.Text = & $f $p[5] ' %'
}
$gpuTimer = New-Object Windows.Threading.DispatcherTimer
$gpuTimer.Interval = [TimeSpan]::FromSeconds(3)
$gpuTimer.Add_Tick({ if ($ui.PageTweaks.Visibility -eq 'Visible' -and -not $script:GpuMeasuring) { try { Update-GpuLive } catch {} } })

function Fmt-Delta($a, $b, $unit, [switch]$Pct) {
  if ($null -eq $a -or $null -eq $b) { return $null }
  $s = "$([math]::Round($a)) → $([math]::Round($b))$unit"
  if ($Pct -and $a -gt 0) { $d = [math]::Round(($b - $a) / $a * 100); $s += " ($(if ($d -gt 0) { '+' })$d %)" }
  return $s
}
function Show-GpuCompare {
  $a = $script:GpuBefore; $b = $script:GpuAfter
  $parts = @()
  $x = Fmt-Delta $a.W $b.W ' W' -Pct; if ($x) { $parts += "Effekt $x" }
  $x = Fmt-Delta $a.T $b.T ' °C'; if ($x) { $parts += "Temp $x" }
  $x = Fmt-Delta $a.F $b.F ' %'; if ($x) { $parts += "Blæser $x" }
  $x = Fmt-Delta $a.C $b.C ' MHz' -Pct; if ($x) { $parts += "Clock $x" }
  $fb = 0.0; $fa = 0.0
  $hasFps = [double]::TryParse($ui.TxtFpsBefore.Text, [ref]$fb) -and [double]::TryParse($ui.TxtFpsAfter.Text, [ref]$fa) -and $fb -gt 0
  if ($hasFps) { $parts += "FPS $(Fmt-Delta $fb $fa '' -Pct)" }
  $ui.GpuResult.Text = $parts -join '  ·  '
  $wPct = if ($a.W -gt 0 -and $null -ne $b.W) { ($b.W - $a.W) / $a.W * 100 } else { 0 }
  $perfPct = if ($hasFps) { ($fa - $fb) / $fb * 100 } elseif ($a.C -gt 0 -and $null -ne $b.C) { ($b.C - $a.C) / $a.C * 100 } else { 0 }
  $what = if ($hasFps) { 'FPS' } else { 'clock (FPS ikke indtastet)' }
  $ui.GpuVerdict.Text = if ($wPct -le -8 -and $perfPct -ge -3) { "👍 Værd at beholde: $([math]::Abs([math]::Round($wPct))) % mindre strøm, og $what faldt kun $([math]::Abs([math]::Round($perfPct))) %. Spil et par timer i dine egne spil for at sikre, at det er stabilt. Går et spil ned, så skru lidt tilbage." }
                        elseif ($perfPct -lt -5) { "⚠ Ydelsen faldt mærkbart ($([math]::Round($perfPct)) % $what). Prøv en mildere indstilling." }
                        elseif ($wPct -gt -3) { "Næsten ingen forskel i strømforbrug. Ændringen gjorde ikke meget, eller kortet var ikke fuldt belastet." }
                        else { "Lidt mindre strøm ($([math]::Round($wPct)) %). Sammenlign, om det er det værd for dig." }
  if ($a.LowLoad -or $b.LowLoad) { $ui.GpuVerdict.Text += "`n⚠ Grafikkortet var ikke fuldt belastet under en af målingerne. Kørte spillet i forgrunden?" }
  $ui.GpuSavePanel.Visibility = 'Visible'
}
function Start-GpuMeasure($which) {
  if (-not (Get-Smi)) { Msg 'Måling kræver et NVIDIA-grafikkort (nvidia-smi). Til AMD: brug målingerne i AMD Adrenalin.' 'GPU' | Out-Null; return }
  $script:GpuMeasuring = $true
  $ui.BtnGpuBefore.IsEnabled = $false; $ui.BtnGpuAfter.IsEnabled = $false
  $ui.GpuMeasureBar.Visibility = 'Visible'; $ui.GpuMeasureBar.Value = 0
  $ui.GpuResult.Text = "Måler $(if ($which -eq 'before') { 'FØR' } else { 'EFTER' })... Skift til spillet nu, og spil i 2 minutter."
  $ui.GpuVerdict.Text = ''
  Invoke-Bg $GpuMeasureScript @{ Seconds = 120 } {
    param($res, $err, $c)
    $script:GpuMeasuring = $false; $ui.GpuMeasureBar.Visibility = 'Collapsed'
    $ui.BtnGpuBefore.IsEnabled = $true
    if ($res -is [array]) { $res = @($res | Where-Object { $_ -is [Collections.IDictionary] })[-1] }
    if ($err -or -not $res) { $ui.GpuResult.Text = "Målingen fejlede: $err"; return }
    if ($c.Which -eq 'before') {
      $script:GpuBefore = $res; $script:GpuAfter = $null
      $ui.GpuResult.Text = "FØR: $([math]::Round($res.W)) W · $([math]::Round($res.T)) °C · blæser $(if ($null -ne $res.F) { "$([math]::Round($res.F)) %" } else { 'n/a' }) · $([math]::Round($res.C)) MHz · $([math]::Round($res.U)) % belastning"
      $ui.GpuVerdict.Text = "Lav nu ÉN ændring i tuningværktøjet (fx et lavere power limit, kortets Quiet-profil eller auto-tuning), og tryk så 'Mål EFTER'.$(if ($res.LowLoad) { "`n⚠ Kortet var ikke fuldt belastet. Kørte spillet?" })"
      $ui.BtnGpuAfter.IsEnabled = $true
    } else { $script:GpuAfter = $res; $ui.BtnGpuAfter.IsEnabled = $true; Show-GpuCompare }
    try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
  } @{ Which = $which }
  # vis måle-fremdrift i bjælken
  $script:GpuProgTimer = New-Object Windows.Threading.DispatcherTimer
  $script:GpuProgTimer.Interval = [TimeSpan]::FromMilliseconds(500)
  $script:GpuProgTimer.Add_Tick({
    if (-not $script:GpuMeasuring) { $script:GpuProgTimer.Stop(); return }
    $j = $script:Jobs | Where-Object { $_.Ctx -is [hashtable] -and $_.Ctx.Which } | Select-Object -First 1
    if ($j -and [double]$j.S.Progress -ge 0) { $ui.GpuMeasureBar.Value = [double]$j.S.Progress; if ($j.S.Status) { $ui.GpuMeasureInfo.Text = $j.S.Status } }
  })
  $script:GpuProgTimer.Start()
}
$ui.BtnGpuBefore.Add_Click({ Start-GpuMeasure 'before' })
$ui.BtnGpuAfter.Add_Click({ Start-GpuMeasure 'after' })
$ui.TxtFpsAfter.Add_TextChanged({ if ($script:GpuBefore -and $script:GpuAfter) { Show-GpuCompare } })
$ui.TxtFpsBefore.Add_TextChanged({ if ($script:GpuBefore -and $script:GpuAfter) { Show-GpuCompare } })

function Load-GpuMine {
  $list = @(); if (Test-Path $GpuTestsFile) { try { $list = @((Get-Content $GpuTestsFile -Raw | ConvertFrom-Json) | ForEach-Object { $_ }) } catch {} }
  $ui.GridGpuMine.ItemsSource = @($list | Sort-Object Dato -Descending | ForEach-Object { $r = New-Object PcTjek.Row; $r.Gruppe = ([datetime]$_.Dato).ToString('dd-MM-yyyy'); $r.Navn = $_.Note; $r.Info = $_.Resultat; $r })
  $ui.GpuMineEmpty.Visibility = $(if ($list.Count) { 'Collapsed' } else { 'Visible' })
  $ui.GridGpuMine.Visibility = $(if ($list.Count) { 'Visible' } else { 'Collapsed' })
}
$ui.BtnGpuSave.Add_Click({
  $list = @(); if (Test-Path $GpuTestsFile) { try { $list = @((Get-Content $GpuTestsFile -Raw | ConvertFrom-Json) | ForEach-Object { $_ }) } catch {} }
  $note = if ($ui.TxtGpuNote.Text) { $ui.TxtGpuNote.Text } else { '(ingen beskrivelse)' }
  $list += [pscustomobject]@{ Dato = (Get-Date).ToString('s'); Gpu = (Get-GpuName); Note = $note; Resultat = $ui.GpuResult.Text; Dom = $ui.GpuVerdict.Text; Foer = $script:GpuBefore; Efter = $script:GpuAfter }
  ConvertTo-Json -InputObject @($list) -Depth 4 | Out-File -Encoding utf8 $GpuTestsFile
  Load-GpuMine; $ui.GpuSavePanel.Visibility = 'Collapsed'; $ui.StatusText.Text = 'Gemt under "Testet på min pc".'
})

function Load-GpuLib {
  Invoke-Bg $GpuLibScript $null {
    param($res, $err, $c)
    if ($err -or -not $res) { $ui.GpuLibInfo.Text = "Kunne ikke hente eksempler lige nu. $err"; return }
    $mine = (Get-GpuName) -replace '(?i)nvidia|geforce|amd|radeon|\s', ''
    $rows = @($res | ForEach-Object {
      $g = [string]$_.gpu
      $key = $g -replace '(?i)nvidia|geforce|amd|radeon|\s', ''
      $r = New-Object PcTjek.Row
      $r.Navn = "$g$(if ($_.board) { " · $($_.board)" })"
      $set = @($_.method, $_.setting) | Where-Object { $_ }
      $r.Info = ($set -join ': ')
      $res2 = @()
      if ($_.power_saved_w) { $res2 += "−$($_.power_saved_w) W" }
      if ($null -ne $_.fps_delta_pct -and "$($_.fps_delta_pct)" -ne '') { $res2 += "FPS $(if ([double]$_.fps_delta_pct -gt 0) { '+' })$($_.fps_delta_pct) %" }
      if ($_.temp_drop_c) { $res2 += "−$($_.temp_drop_c) °C" }
      $r.Note = ($res2 -join ' · ') + $(if ($_.test_method) { " ($($_.test_method))" })
      $r.Gruppe = [string]$_.source_type
      $r.Sti = [string]$_.source_url
      $r.Valgt = ($mine -and $key -and ($mine -like "*$key*" -or $key -like "*$mine*"))
      $r })
    $match = @($rows | Where-Object Valgt)
    $ui.GridGpuLib.ItemsSource = $(if ($match.Count) { $match } else { $rows })
    $ui.GpuLibInfo.Text = if ($match.Count) { "$($match.Count) eksempel$(if ($match.Count -ne 1) { 'er' }) med dit kort ($(Get-GpuName)). Brug dem som udgangspunkt, og mål selv." } else { "Ingen eksempler med dit kort endnu. Her er dem, der findes ($($rows.Count)), til inspiration." }
  } $null
}
$ui.GridGpuLib.Add_SelectionChanged({ $ui.BtnGpuSrc.IsEnabled = [bool]($ui.GridGpuLib.SelectedItem -and $ui.GridGpuLib.SelectedItem.Sti) })
$ui.BtnGpuSrc.Add_Click({ $u = $ui.GridGpuLib.SelectedItem.Sti; if ($u -match '^https?://') { Start-Process $u } })

$ui.GpuHow.Add_Click({
  $ui.GpuSteps.Visibility = $(if ($ui.GpuSteps.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' })
  $ui.GpuHow.Content = $(if ($ui.GpuSteps.Visibility -eq 'Visible') { '✕  Skjul guiden' } else { '📖  Sådan gør du' })
})
$ui.GpuStepsText.Text = "Vælg ét mål ad gangen, og mål før og efter:`n`n🔋  MINDRE STRØM`n•  Nemmest: sæt et FPS-loft lidt over din skærms Hz (fx 141 på en 144 Hz-skærm) i spillet eller i NVIDIA-kontrolpanelet. Så arbejder kortet ikke for billeder, du ikke kan se.`n•  Eller sænk 'Power limit' 10-20 % i MSI Afterburner, og se, hvad det koster i FPS.`n`n🤫  MINDRE STØJ`n•  Brug kortets egen Quiet-profil (BIOS-knap på kortet eller producentens program), hvis den findes.`n•  Eller lav en roligere blæserkurve i Afterburner. Hold øje med temperaturen her i appen.`n`n⚡  SAMME YDELSE VED FÆRRE WATT (undervolt)`n•  NVIDIA App → System → Ydeevne → automatisk tuning (på understøttede kort).`n•  MSI Afterburner → Ctrl+F → spændings-/frekvenskurve: lås fx en lidt lavere frekvens ved en lavere spænding.`n•  AMD: Adrenalin → Ydeevne → Tuning → Undervolt GPU.`n`nTest stabiliteten ved at spille et par timer. Går et spil ned eller får du grafikfejl, så skru lidt tilbage. Det ødelægger ikke kortet, men kan give nedbrud."
$ui.BtnGpuTool.Add_Click({
  $nv = @("$env:ProgramFiles\NVIDIA Corporation\NVIDIA App\CEF\NVIDIA App.exe", "$env:ProgramFiles\NVIDIA Corporation\NVIDIA App\NVIDIA App.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  $amd = "$env:ProgramFiles\AMD\CNext\CNext\RadeonSoftware.exe"
  if ($nv) { Start-Process $nv } elseif (Test-Path $amd) { Start-Process $amd } else { Msg 'Hverken NVIDIA App eller AMD Adrenalin blev fundet. Installér dit grafikkorts program fra producenten.' 'GPU' | Out-Null }
})
$ui.BtnGpuAb.Add_Click({
  $ab = @("${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe", "$env:ProgramFiles\MSI Afterburner\MSIAfterburner.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($ab) { Start-Process $ab } else { Start-Process 'https://www.msi.com/Landing/afterburner/graphics-cards' }
})
function Load-Gpu {
  $n = Get-GpuName
  $ui.GpuName.Text = "$n$(if (-not (Get-Smi)) { ' · live-måling kræver NVIDIA (nvidia-smi)' })"
  $ab = @("${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe", "$env:ProgramFiles\MSI Afterburner\MSIAfterburner.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  $ui.BtnGpuAb.Content = $(if ($ab) { '🎚  Åbn MSI Afterburner' } else { '⬇  Hent MSI Afterburner' })
  try { Update-GpuLive } catch {}
  Load-GpuMine
  if (-not $script:GpuLibLoaded) { $script:GpuLibLoaded = $true; Load-GpuLib }
  $gpuTimer.Start()
}

# =====================================================================
#  Eksport
# =====================================================================
$ui.BtnExport.Add_Click({
  $r = $script:Result
  $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
  $rows = ($r.Findings | Where-Object Niveau -ge 1 | ForEach-Object { "<tr class='r$($_.Niveau)'><td>$($_.Risiko)</td><td>$(& $enc $_.Kategori)</td><td><b>$(& $enc $_.Titel)</b><br><small>$(& $enc $_.Hvorfor)</small></td><td><small>$(& $enc $_.Detalje)<br>$(& $enc $_.Sti)</small></td></tr>" }) -join "`n"
  $tl = ($r.Timeline | Select-Object -First 400 | ForEach-Object { "<tr class='$(if ($_.Fokus) { 'focus' })'><td>$($_.Tid.ToString('dd-MM-yyyy HH:mm'))</td><td>$($_.Type)</td><td>$(& $enc $_.Fokus)</td><td>$(& $enc $_.Hændelse)</td><td><small>$(& $enc $_.Detalje)</small></td></tr>" }) -join "`n"
  $html = @"
<!DOCTYPE html><html lang="da"><meta charset="utf-8"><title>PC-Tjek rapport $(Get-Date -Format 'yyyy-MM-dd HH:mm')</title>
<style>body{font-family:'Segoe UI',sans-serif;background:#0D0F14;color:#E7E9EE;max-width:1100px;margin:auto;padding:32px}
h1{background:linear-gradient(90deg,#8B5CF6,#3B9EFF);-webkit-background-clip:text;color:transparent}
pre{white-space:pre-wrap;background:#161A23;border:1px solid #242A39;padding:20px;border-radius:12px;font-family:'Segoe UI',sans-serif}
table{width:100%;border-collapse:collapse;margin-bottom:32px;background:#161A23;border-radius:12px;overflow:hidden}
td,th{padding:8px 10px;border-bottom:1px solid #242A39;vertical-align:top;text-align:left}th{color:#8A94A7;font-weight:600}small{color:#8A94A7}
.r4 td:first-child{color:#FF5D6C;font-weight:bold}.r3 td:first-child{color:#FFA24A;font-weight:bold}.r2 td:first-child{color:#F6D44A}.r1 td:first-child{color:#4ADE80}
.focus{background:#2A1E12}</style>
<h1>PC-Tjek rapport</h1><p>$(Get-Date -Format 'dd-MM-yyyy HH:mm') · $env:COMPUTERNAME · score $($ui.ScoreText.Text)</p>
<h2>Analyse</h2><pre>$(& $enc $ui.Story.Text)</pre>
<h2>Fund</h2><table><tr><th>Risiko</th><th>Kategori</th><th>Fund</th><th>Detalje</th></tr>$rows</table>
<h2>Hændelsesforløb</h2><table><tr><th>Tid</th><th>Type</th><th></th><th>Hændelse</th><th>Detalje</th></tr>$tl</table></html>
"@
  $file = Join-Path $OutDir ("PC-Tjek-rapport-{0:yyyy-MM-dd_HHmm}.html" -f (Get-Date))
  $html | Out-File -Encoding utf8 $file
  [pscustomobject]@{ Findings = $r.Findings; Timeline = $r.Timeline; Space = $r.Space; Perf = $r.Perf; NewSince = $script:NewSince } | ConvertTo-Json -Depth 5 | Out-File -Encoding utf8 (Join-Path $OutDir 'PC-Tjek-data.json')
  Start-Process $file
  $ui.StatusText.Text = 'Rapport gemt i Overførsler\PC-Tjek-rapport'
})


# =====================================================================
#  App-opdatering (GitHub)
# =====================================================================
$script:PendingUpdate = $null
function Check-AppUpdate([bool]$manual) {
  if (-not $UpdateUrl) {
    if ($manual) { Msg "Opdateringer er ikke sat op endnu.`n`nDer mangler en gyldig UpdateUrl i pc-tjek.config.json ved siden af appen." | Out-Null }
    return
  }
  Invoke-Bg $UpdateCheckScript @{ Url = $UpdateUrl } {
    param($v, $err, $c)
    if ($err -or -not $v) { if ($c.Manual) { Msg "Kunne ikke tjekke for opdateringer:`n$err" | Out-Null }; Log "Update-check: $err"; return }
    $newer = $false
    try { $newer = [version]$v.version -gt [version]$AppVersion } catch {}
    if ($newer) {
      $script:PendingUpdate = $v
      $ui.UpdateText.Text = "✨ Version $($v.version) er klar"
      $ui.UpdateNotes.Text = (@($v.notes) | Select-Object -First 3 | ForEach-Object { "• $_" }) -join "`n"
      $ui.UpdateBanner.Visibility = 'Visible'
      $ui.StatusText.Text = "Ny version $($v.version) kan hentes."
    } else {
      $ui.StatusText.Text = "PC-Tjek $AppVersion er den nyeste version."
      if ($c.Manual) { Msg "Du har den nyeste version ($AppVersion)." | Out-Null }
    }
  } @{ Manual = $manual }
}
$ui.BtnCheckUpdate.Add_Click({ Check-AppUpdate $true })
$ui.BtnUpdateApp.Add_Click({
  $v = $script:PendingUpdate
  if (-not $v) { return }
  $notes = (@($v.notes) | ForEach-Object { "  • $_" }) -join "`n"
  if ((Msg "Opdatér PC-Tjek fra $AppVersion til $($v.version)?`n`nNyheder:`n$notes`n`nFilernes fingeraftryk (SHA256) bliver tjekket, før noget installeres. Den gamle version gemmes som backup." 'Opdatering' 'YesNo' 'Question') -ne 'Yes') { return }
  $ui.BtnUpdateApp.IsEnabled = $false
  Invoke-Bg $UpdateApplyScript @{ Url = $(if ($v.BaseUrl) { $v.BaseUrl } else { $UpdateUrl }); Files = @($v.files); Dest = $PSScriptRoot; OldVersion = $AppVersion; JobRoot = $JobRoot } {
    param($r, $err, $c)
    if ($err) { $ui.BtnUpdateApp.IsEnabled = $true; Log "Opdatering fejlede: $err"; Msg "Opdateringen blev ikke installeret:`n`n$err" 'Opdatering' 'OK' 'Error' | Out-Null; return }
    Log "Opdateret til $($c.Version)"
    Msg "PC-Tjek er opdateret til $($c.Version). Appen genstarter nu." 'Opdatering' | Out-Null
    # Genstart: en lille hjælper venter, til dette vindue er lukket, og starter så den nye version (allerede med admin-rettigheder)
    $app = Join-Path $PSScriptRoot 'PC-Tjek-App.ps1'
    $cmd = "Wait-Process -Id $PID -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500; Start-Process '$env:SystemRoot\System32\conhost.exe' -ArgumentList '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""$app""'"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc"
    $win.Close()
  } @{ Version = $v.version }
})

# =====================================================================
Load-Startup
function Load-SysInfo {
  Invoke-Bg $SysInfoScript $null {
    param($o, $err, $c)
    if ($o -is [array]) { $o = @($o | Where-Object { $_ -is [Collections.IDictionary] })[-1] }
    if (-not $o) { return }
    foreach ($k in 'OS', 'CPU', 'GPU', 'RAM', 'Board', 'Disk') {
      $n = @{ OS = 'SysOS'; CPU = 'SysCpu'; GPU = 'SysGpu'; RAM = 'SysRam'; Board = 'SysBoard'; Disk = 'SysDisk' }[$k]
      $ui[$n].Text = [string]$o[$k]; $ui[$n].ToolTip = [string]$o[$k]
      $ui["${n}sub"].Text = [string]$o["${k}sub"]
    }
  } $null
}
function Refresh-VagtVersion {
  try {
    $vp = Get-VagtProc | Select-Object -First 1
    if ($vp -and (Test-Path $VagtScript) -and (Get-Item $VagtScript).LastWriteTime -gt $vp.CreationDate) {
      Restart-Vagt; Log 'Vagten genstartet med ny version'
    }
  } catch {}
}
$win.Add_ContentRendered({ Load-SysInfo; Refresh-VagtVersion; Check-AppUpdate $false })
Log 'UI klar'
[void]$win.ShowDialog()
$jobTimer.Stop()
Log 'Lukket'
