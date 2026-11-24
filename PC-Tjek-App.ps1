<#
  Opticon 2.0  –  sikkerhed, oprydning og optimering til Windows 11
  ------------------------------------------------------------------
  * Scanninger LÆSER kun. Intet ændres, før du selv trykker på en handling og bekræfter.
  * Før større ændringer oprettes et gendannelsespunkt (hvis systembeskyttelse er slået til).
  * Filer, du sletter fra Filer-siden, flyttes til papirkurven.
  * Rapporter, snapshots, fortryd-log og fejl-log ligger i  Overførsler\PC-Tjek-rapport\
  Installation: kør "Installer Opticon.cmd" én gang. Derefter starter appen fra ikonet uden UAC og uden konsol.
#>
param([switch]$RestoreOnly)   # bruges af afinstalleren: sæt alt tilbage og afslut

# ---------- Elevering + STA (bruges kun, hvis appen startes uden installeren) ----------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy RemoteSigned -STA -WindowStyle Hidden -File `"$PSCommandPath`""
  return
}
if (-not $RestoreOnly -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
  Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy RemoteSigned -STA -WindowStyle Hidden -File `"$PSCommandPath`""
  return
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, Microsoft.VisualBasic

$AppVersion = '2.52'
$AppName = 'Opticon'   # visningsnavn (sættes af build-scriptet)
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
# Lås kun selve mappen; alt indeni arver adgangen derfra.
# (Før blev låsen også sat direkte på hver fil med /T, og det efterlod filer helt uden adgang. /reset reparerer dem.)
try {
  & icacls.exe $JobBase /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /C /Q | Out-Null
  & icacls.exe (Join-Path $JobBase '*') /reset /T /C /Q | Out-Null
} catch {}
Get-ChildItem $JobRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$ConfigFile = Join-Path $PSScriptRoot 'pc-tjek.config.json'
$UpdateUrl = $null
if (Test-Path $ConfigFile) { try { $UpdateUrl = ([string](Get-Content $ConfigFile -Raw | ConvertFrom-Json).UpdateUrl).TrimEnd('/') } catch {} }
if ($UpdateUrl -notmatch '^https://raw\.githubusercontent\.com/[\w\-]+/[\w\-.]+/[\w\-./]+$' -or $UpdateUrl -match 'DIT-BRUGERNAVN') { $UpdateUrl = $null }
function Log($m) { try { [IO.File]::AppendAllText($LogFile, ("{0:yyyy-MM-dd HH:mm:ss}  {1}`r`n" -f (Get-Date), $m), [Text.Encoding]::UTF8) } catch {} }
Log "Start v$AppVersion"

# ---------- Lille C#-hjælper: rækker med afkrydsning + mørk titellinje ----------
# C#-hjælpere oversættes kun én gang pr. version og gemmes i C:\ProgramData\PC-Tjek\cache (kun administratorer kan skrive der).
# Så starter Windows' C#-oversætter ikke hver gang appen eller Vagten starter, hvilket nogle antivirus reagerer på.
function Import-OpticonType([string]$TypeName, [string]$Source) {
  if ($TypeName -as [type]) { return }
  try {
    $dir = Join-Path $env:ProgramData 'PC-Tjek\cache'
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Source + [Environment]::Version))).Replace('-', '').Substring(0, 16)
    $stem = $TypeName.Replace('.', '-')
    $dll = Join-Path $dir "$stem-$hash.dll"
    if (-not (Test-Path $dll)) {
      if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
      Get-ChildItem $dir -Filter "$stem-*.dll" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
      Add-Type -TypeDefinition $Source -Language CSharp -OutputAssembly $dll -OutputType Library -ErrorAction Stop
    }
    Add-Type -Path $dll -ErrorAction Stop
  } catch {
    if (-not ($TypeName -as [type])) { Add-Type -TypeDefinition $Source -Language CSharp }
  }
}
$RowSource = @'
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
'@
Import-OpticonType 'PcTjek.Row' $RowSource


# =====================================================================
#  TILSTANDE (Spil / Fokus) + SIKKER GENDANNELSE  -  deles af appen og Vagten
#  Princip: alt, der ændres, skrives i mode.json FØR det ændres. Så kan det altid
#  sættes tilbage, også hvis appen, Vagten eller pc'en går ned midt i det hele.
# =====================================================================
$ModeBase       = Join-Path $env:ProgramData 'PC-Tjek'
$ModeFile       = Join-Path $ModeBase 'mode.json'
$ModeEnding     = Join-Path $ModeBase 'mode-ending.json'
$ModeLast       = Join-Path $ModeBase 'mode-last.json'
$ModeStopFlag   = Join-Path $ModeBase 'mode-stop.flag'
$GamesFile      = Join-Path $ModeBase 'spil.json'
$GpuRestoreFile = Join-Path $ModeBase 'gpu-restore.json'
$ModePending    = Join-Path $ModeBase 'mode-pending.json'   # det, der IKKE kunne sættes tilbage; prøves igen
$HostsFile      = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$HostsBegin     = '# >>> Opticon Fokus (fjernes automatisk, når fokus slutter)'
$HostsEnd       = '# <<< Opticon Fokus'
# Vises aldrig som "må lukkes": Windows, sikkerhed, drivere, lyd og anti-cheat
$ModeNever = @('system','idle','registry','smss','csrss','wininit','winlogon','services','lsass','lsaiso','svchost','dwm','explorer','fontdrvhost','sihost','ctfmon',
  'taskhostw','runtimebroker','searchhost','searchindexer','startmenuexperiencehost','shellexperiencehost','textinputhost','dllhost','conhost','audiodg','msmpeng','nissrv',
  'securityhealthservice','securityhealthsystray','mpdefendercoreservice','smartscreen','spoolsv','wmiprvse','wuauclt','tiworker','trustedinstaller','mousocoreworker',
  'usoclient','powershell','pwsh','nvcontainer','nvdisplay.container','nvsphelper64','nvidia share','nvidia overlay','nvidia-smi','nvidia app','amdrsserv','atiesrxx',
  'atieclxx','radeonsoftware','easyanticheat','easyanticheat_eos','beservice','bedaisy','vgc','vgtray','faceit','faceitservice','eaanticheat.gameservice','applicationframehost',
  'systemsettings','lockapp','msedgewebview2','useroobebroker','securityhealthhost','memcompression','secure system','wudfhost','igfxem','rtkaudupd64','rtkauduservice64',
  'nahimicsvc64','realtekaudioservice','msiafterburner','rtss')
# Bruges ofte under spil: vises, men er ikke valgt
$ModeUsual = @('steam','steamwebhelper','steamservice','epicgameslauncher','epicwebhelper','battle.net','agent','eadesktop','eabackgroundservice','upc','ubisoftconnect',
  'riotclientservices','riotclientux','galaxyclient','discord','obs64','obs32','spotify','teams','ms-teams','lghub','lghub_agent','icue','razer synapse 3','steelseriesgg',
  'armourycrate','logioptionsplus','voicemeeter','voicemeeter8x64')
$ModeLaunchers = @('steam','steamwebhelper','epicgameslauncher','battle.net','agent','eadesktop','upc','ubisoftconnect','riotclientservices','galaxyclient')

function ModeLog($msg) {
  if (Get-Command VLog -CommandType Function -ErrorAction SilentlyContinue) { VLog 'Tilstand' 'info' $msg '' '' }
  elseif (Get-Command Log -CommandType Function -ErrorAction SilentlyContinue) { Log $msg }
}
function Get-ModeState { if (Test-Path $ModeFile) { try { return (Get-Content $ModeFile -Raw -ErrorAction Stop | ConvertFrom-Json) } catch {} }; return $null }
function Save-ModeState($m) { [IO.File]::WriteAllText($ModeFile, ($m | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false)) }
function Get-Games {
  if (-not (Test-Path $GamesFile)) { return @() }
  try { return @(Get-Content $GamesFile -Raw -ErrorAction Stop | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.Exe }) } catch { return @() }
}
function Save-Games($list) { [IO.File]::WriteAllText($GamesFile, (ConvertTo-Json -InputObject @($list) -Depth 5), (New-Object Text.UTF8Encoding $false)) }
function Exe-Key($exe) { ([IO.Path]::GetFileNameWithoutExtension([string]$exe)).ToLower() }

function Get-SmiPath { foreach ($p in "$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") { if (Test-Path $p) { return $p } }; return $null }
# Grafikkortets faste ID (UUID). Bruges i stedet for "kort nr. 0", så indstillinger altid rammer det rigtige kort,
# også hvis pc'en har flere grafikkort, eller rækkefølgen ændrer sig.
function Get-GpuId {
  if ($script:GpuIdCache) { return $script:GpuIdCache }
  $s = Get-SmiPath; if (-not $s) { return '0' }
  try { $u = ([string](& $s --query-gpu=uuid --format=csv,noheader 2>$null | Select-Object -First 1)).Trim(); if ($u -like 'GPU-*') { $script:GpuIdCache = $u; return $u } } catch {}
  return '0'
}
function Test-GpuIdPresent([string]$id) {
  if (-not $id -or $id -eq '0') { return $true }
  $s = Get-SmiPath; if (-not $s) { return $false }
  try { return [bool](@(& $s --query-gpu=uuid --format=csv,noheader 2>$null) | Where-Object { ([string]$_).Trim() -eq $id }) } catch { return $false }
}
function Get-GpuPlNow {
  $s = Get-SmiPath; if (-not $s) { return $null }
  $v = & $s -i (Get-GpuId) --query-gpu=power.limit --format=csv,noheader,nounits 2>$null | Select-Object -First 1
  $d = 0.0
  if ([double]::TryParse(([string]$v).Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -gt 0) { return [int][math]::Round($d) }
  return $null
}
function Set-GpuPlNow($w) { $s = Get-SmiPath; if ($s -and [int]$w -gt 0) { $null = & $s -i (Get-GpuId) -pl ([int]$w) 2>&1; return ($LASTEXITCODE -eq 0) }; return $false }
# Sæt OG bekræft: læs værdien tilbage, før det kaldes en succes
function Restore-GpuPl($w) {
  if (-not ([int]$w -gt 0)) { return $true }
  [void](Set-GpuPlNow $w)
  Start-Sleep -Milliseconds 300
  $now = Get-GpuPlNow
  return ($null -ne $now -and [math]::Abs($now - [int]$w) -le 2)
}

# Windows' strømtilstand (Indstillinger > System > Strøm): virker på alle pc'er, også AMD og Intel
if (-not (Get-Command Import-OpticonType -ErrorAction SilentlyContinue)) {   # Vagten har ikke appens hoveddel
  function Import-OpticonType([string]$TypeName, [string]$Source) {
    if ($TypeName -as [type]) { return }
    try {
      $dir = Join-Path $env:ProgramData 'PC-Tjek\cache'
      $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Source + [Environment]::Version))).Replace('-', '').Substring(0, 16)
      $stem = $TypeName.Replace('.', '-')
      $dll = Join-Path $dir "$stem-$hash.dll"
      if (-not (Test-Path $dll)) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        Get-ChildItem $dir -Filter "$stem-*.dll" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Add-Type -TypeDefinition $Source -Language CSharp -OutputAssembly $dll -OutputType Library -ErrorAction Stop
      }
      Add-Type -Path $dll -ErrorAction Stop
    } catch {
      if (-not ($TypeName -as [type])) { Add-Type -TypeDefinition $Source -Language CSharp }
    }
  }
}
$PowerModeSource = @'
using System;
using System.Runtime.InteropServices;
namespace PcTjek {
  public static class PowerMode {
    [DllImport("powrprof.dll")] public static extern uint PowerSetActiveOverlayScheme(Guid g);
    [DllImport("powrprof.dll")] public static extern uint PowerGetEffectiveOverlayScheme(out Guid g);
  }
}
'@
try { Import-OpticonType 'PcTjek.PowerMode' $PowerModeSource } catch {}
$PowerModeList = @(
  [pscustomobject]@{ Key = 'eff';  Guid = '961cc777-2547-4f9d-8174-7d86181b8a7a'; Name = 'Bedste energieffektivitet' }
  [pscustomobject]@{ Key = 'bal';  Guid = '00000000-0000-0000-0000-000000000000'; Name = 'Balanceret' }
  [pscustomobject]@{ Key = 'perf'; Guid = 'ded574b5-45a0-4f42-8737-46345c09c238'; Name = 'Bedste ydeevne' }
)
function Get-PowerMode { try { $g = [guid]::Empty; if ([PcTjek.PowerMode]::PowerGetEffectiveOverlayScheme([ref]$g) -eq 0) { return $g.ToString() } } catch {}; return $null }
function Set-PowerMode($guid) { try { [void][PcTjek.PowerMode]::PowerSetActiveOverlayScheme([guid]$guid) } catch {}; Start-Sleep -Milliseconds 300; return ((Get-PowerMode) -eq ([guid]$guid).ToString()) }
function PowerMode-Name($guid) { $m = $PowerModeList | Where-Object { $_.Guid -eq ([string]$guid) } | Select-Object -First 1; if ($m) { $m.Name } else { 'ukendt' } }

# Windows-beskeder (samme kontakt som Indstillinger > System > Meddelelser)
$ToastKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
function Get-Toasts { try { return [int](Get-ItemProperty $ToastKey -Name ToastEnabled -ErrorAction Stop).ToastEnabled } catch { return 1 } }
function Set-Toasts([int]$on) { try { if (-not (Test-Path $ToastKey)) { New-Item $ToastKey -Force | Out-Null }; Set-ItemProperty $ToastKey -Name ToastEnabled -Value $on -Type DWord -Force } catch {} }

function Clean-Site($s) { (([string]$s).Trim().ToLower() -replace '^https?://', '' -replace '/.*$', '' -replace '^www\.', '' -replace '^m\.', '') }
function Remove-HostsBlock {
  if (-not (Test-Path $HostsFile)) { return }
  $txt = [IO.File]::ReadAllText($HostsFile)
  if ($txt -notlike "*$HostsBegin*") { return }
  $new = [regex]::Replace($txt, '(\r?\n)?' + [regex]::Escape($HostsBegin) + '.*?' + [regex]::Escape($HostsEnd) + '\r?\n?', "`r`n", 'Singleline')
  [IO.File]::WriteAllText($HostsFile, $new.TrimEnd() + "`r`n", (New-Object Text.UTF8Encoding $false))
  & ipconfig.exe /flushdns 2>&1 | Out-Null
}
function Set-HostsBlock($sites) {
  Remove-HostsBlock
  $lines = @('', $HostsBegin)
  foreach ($s in @($sites)) {
    $d = Clean-Site $s
    if ($d -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+)+$') { continue }
    foreach ($h in $d, "www.$d", "m.$d") { $lines += "0.0.0.0 $h"; $lines += ":: $h" }
  }
  $lines += $HostsEnd
  $txt = ''; if (Test-Path $HostsFile) { $txt = [IO.File]::ReadAllText($HostsFile).TrimEnd() }
  [IO.File]::WriteAllText($HostsFile, $txt + "`r`n" + ($lines -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $false))
  & ipconfig.exe /flushdns 2>&1 | Out-Null
}

function Start-GameMode($game) {
  if (Test-Path $ModeFile) { return $null }
  $m = [ordered]@{ Mode = 'Spil'; Name = [string]$game.Name; Exe = [string]$game.Exe; Started = (Get-Date).ToString('s'); Until = ''
                   Paused = @(); NotClosed = @(); PrevPl = $null; NewPl = $null; PrevToast = $null; Sites = @(); Notes = @() }
  Save-ModeState $m
  if ($game.Mute) { $m.PrevToast = Get-Toasts; Save-ModeState $m; Set-Toasts 0 }
  if ([int]$game.GpuWatts -gt 0) {
    $prev = Get-GpuPlNow
    if ($prev) { $m.PrevPl = $prev; Save-ModeState $m; if (Set-GpuPlNow $game.GpuWatts) { $m.NewPl = [int]$game.GpuWatts } else { $m.PrevPl = $null } }
    Save-ModeState $m
  }
  $asked = New-Object System.Collections.ArrayList
  foreach ($n in @($game.Close)) {
    if (-not $n -or ($ModeNever -contains ([string]$n).ToLower())) { continue }
    $ps = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
    if (-not $ps.Count) { continue }
    $path = ($ps | Where-Object { $_.Path } | Select-Object -First 1).Path
    [void]$asked.Add([ordered]@{ Name = [string]$n; Path = [string]$path })
    # Kun en almindelig lukning, som når du selv trykker på krydset. Intet tvangsstop, så du aldrig mister noget, der ikke er gemt.
    if (([string]$n).ToLower() -eq 'onedrive' -and $path) { try { Start-Process -FilePath $path -ArgumentList '/shutdown' -WindowStyle Hidden } catch {} }
    foreach ($p in $ps) { try { [void]$p.CloseMainWindow() } catch {} }
  }
  $closed = New-Object System.Collections.ArrayList; $open = New-Object System.Collections.ArrayList
  if ($asked.Count) {
    $until = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $until -and @($asked | Where-Object { Get-Process -Name $_.Name -ErrorAction SilentlyContinue }).Count) { Start-Sleep -Milliseconds 400 }
    foreach ($x in $asked) { if (Get-Process -Name $x.Name -ErrorAction SilentlyContinue) { [void]$open.Add($x.Name) } else { [void]$closed.Add($x) } }
  }
  $m.Paused = @($closed); $m.NotClosed = @($open); Save-ModeState $m
  ModeLog "Spil-tilstand startet: $($game.Name) (lukket: $(@($closed | ForEach-Object { $_.Name }) -join ', '); kunne ikke lukkes: $($open -join ', '))"
  return $m
}
function Start-FocusMode([int]$min, [bool]$mute, $sites) {
  if (Test-Path $ModeFile) { throw 'En anden tilstand er allerede aktiv. Afslut den først.' }
  $clean = @(@($sites) | ForEach-Object { Clean-Site $_ } | Where-Object { $_ -match '^[a-z0-9-]+(\.[a-z0-9-]+)+$' } | Select-Object -Unique)
  $m = [ordered]@{ Mode = 'Fokus'; Name = "$min min"; Exe = ''; Started = (Get-Date).ToString('s'); Until = (Get-Date).AddMinutes($min).ToString('s')
                   Paused = @(); PrevPl = $null; NewPl = $null; PrevToast = $null; Sites = @($clean); Notes = @() }
  if ($mute) { $m.PrevToast = Get-Toasts }
  Save-ModeState $m
  if ($mute) { Set-Toasts 0 }
  if ($clean.Count) { Set-HostsBlock $clean }
  ModeLog "Fokus startet: $min min$(if ($clean.Count) { " · blokerer $($clean -join ', ')" })"
  return $m
}
# Sætter alt tilbage. Kun én proces kan gøre det ad gangen (filen flyttes atomisk).
function Stop-Mode($reason) {
  if (-not (Test-Path $ModeFile)) { return $null }
  try { Move-Item -LiteralPath $ModeFile -Destination $ModeEnding -Force -ErrorAction Stop } catch { return $null }
  $m = $null; try { $m = Get-Content $ModeEnding -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
  $done = New-Object System.Collections.ArrayList
  $r = @{ Fail = @() }
  if ($m) {
    $r = Restore-Parts $m.PrevToast @($m.Sites) $m.PrevPl
    foreach ($x in $r.Ok) { [void]$done.Add($x) }
    foreach ($p in @($m.Paused)) {
      if (-not $p.Path -or -not (Test-Path -LiteralPath $p.Path)) { continue }
      if (Get-Process -Name $p.Name -ErrorAction SilentlyContinue) { continue }
      # explorer.exe starter programmet som dig selv, IKKE som administrator
      try { Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList "`"$($p.Path)`""; [void]$done.Add("$($p.Name) er startet igen") } catch {}
    }
  }
  $sum = [ordered]@{ Mode = $(if ($m) { $m.Mode } else { '' }); Name = $(if ($m) { $m.Name } else { '' }); Started = $(if ($m) { $m.Started } else { '' })
                     Ended = (Get-Date).ToString('s'); Reason = [string]$reason; Done = @($done); Failed = @($r.Fail | ForEach-Object { $_.Text }) }
  try { [IO.File]::WriteAllText($ModeLast, ($sum | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false)) } catch {}
  Remove-Item $ModeEnding, $ModeStopFlag -Force -ErrorAction SilentlyContinue
  ModeLog "$($sum.Mode) sluttede ($reason): $(@($done) -join ' · ')"
  return $sum
}
# Appen og Vagten må ikke gendanne på samme tid: de deler denne lås
function Invoke-ModeLocked([scriptblock]$Body) {
  $mx = New-Object System.Threading.Mutex($false, 'Global\OpticonModeRestore'); $got = $false
  try { $got = $mx.WaitOne(20000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
  try { & $Body } finally { if ($got) { try { $mx.ReleaseMutex() } catch {} }; $mx.Dispose() }
}
# Sætter beskeder, sider og grafikkort tilbage, og BEKRÆFTER hver del. Det, der fejler, gemmes og prøves igen senere.
function Restore-Parts($prevToast, $sites, $prevPl) {
  Invoke-ModeLocked { Restore-PartsCore $prevToast $sites $prevPl }
}
function Restore-PartsCore($prevToast, $sites, $prevPl) {
  $ok = New-Object System.Collections.ArrayList; $fail = New-Object System.Collections.ArrayList
  $tried = New-Object System.Collections.ArrayList   # hvilke dele der blev forsøgt nu (kun dem må fjernes fra journalen)
  if ($null -ne $prevToast) {
    [void]$tried.Add('toast'); Set-Toasts ([int]$prevToast)
    if ((Get-Toasts) -eq [int]$prevToast) { [void]$ok.Add('Windows-beskeder er som før') } else { [void]$fail.Add(@{ Kind = 'toast'; Value = [int]$prevToast; Text = 'Windows-beskeder kunne ikke slås til igen' }) }
  }
  $hostsNeeded = @($sites).Count -or ((Test-Path $HostsFile) -and ([IO.File]::ReadAllText($HostsFile) -like "*$HostsBegin*"))
  if ($hostsNeeded) {
    [void]$tried.Add('hosts'); try { Remove-HostsBlock } catch {}
    $still = (Test-Path $HostsFile) -and ([IO.File]::ReadAllText($HostsFile) -like "*$HostsBegin*")
    if ($still) { [void]$fail.Add(@{ Kind = 'hosts'; Value = $null; Text = 'Blokeringen af sider kunne ikke fjernes' }) }
    elseif (@($sites).Count) { [void]$ok.Add("Siderne er åbne igen ($(@($sites) -join ', '))") }
  }
  if ($prevPl) {
    [void]$tried.Add('gpu')
    if (Restore-GpuPl $prevPl) { [void]$ok.Add("Grafikkortet er tilbage på $($prevPl) W (bekræftet)") }
    else { [void]$fail.Add(@{ Kind = 'gpu'; Value = [int]$prevPl; Text = "Grafikkortet kunne ikke sættes tilbage til $($prevPl) W" }) }
  }
  # Journal: behold alt, der ikke blev forsøgt nu, og det der fejlede. Kun det, der er BEKRÆFTET sat tilbage, fjernes.
  $old = @(); if (Test-Path $ModePending) { try { $old = @(Get-Content $ModePending -Raw | ConvertFrom-Json | ForEach-Object { $_ }) } catch {} }
  $keep = @(@($old | Where-Object { $tried -notcontains [string]$_.Kind }) + @($fail))
  try {
    if ($keep.Count) { $tmp = "$ModePending.tmp"; [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject @($keep) -Depth 3), (New-Object Text.UTF8Encoding $false)); Move-Item -LiteralPath $tmp -Destination $ModePending -Force -ErrorAction Stop }
    elseif (Test-Path $ModePending) { Remove-Item $ModePending -Force -ErrorAction Stop }
  } catch { ModeLog "Gendannelsesjournalen kunne ikke opdateres: $($_.Exception.Message)" }
  if ($fail.Count) { ModeLog "Kunne ikke sætte tilbage: $(@($fail | ForEach-Object { $_.Text }) -join ' · ')" }
  return @{ Ok = @($ok); Fail = @($fail) }
}
# Prøv igen at sætte det tilbage, der fejlede sidst
function Retry-Pending {
  if (-not (Test-Path $ModePending)) { return }
  $items = @(); try { $items = @(Get-Content $ModePending -Raw | ConvertFrom-Json | ForEach-Object { $_ }) } catch { return }
  # Journalen slettes IKKE her. Restore-Parts fjerner kun de dele, der er bekræftet sat tilbage.
  $t = ($items | Where-Object Kind -eq 'toast' | Select-Object -First 1); $g = ($items | Where-Object Kind -eq 'gpu' | Select-Object -First 1); $h = ($items | Where-Object Kind -eq 'hosts')
  $r = Restore-Parts $(if ($t) { $t.Value } else { $null }) $(if ($h) { @('x') } else { @() }) $(if ($g) { $g.Value } else { $null })
  if (-not $r.Fail.Count) { ModeLog 'Det, der manglede at blive sat tilbage, er nu på plads' }
}
# Afbrudt GPU-test: gendan strømgrænsen, hvis test-processen ikke længere kører
function Repair-GpuRestore {
  if (-not (Test-Path $GpuRestoreFile)) { return $false }
  try {
    $g = Get-Content $GpuRestoreFile -Raw -ErrorAction Stop | ConvertFrom-Json
    $p = $null; if ($g.Pid) { $p = Get-Process -Id ([int]$g.Pid) -ErrorAction SilentlyContinue }
    if ($p -and $p.ProcessName -eq 'powershell') { return $false }   # testen kører stadig
    if ($g.Overlay) {
      if (-not (Set-PowerMode $g.Overlay)) { ModeLog "GPU-testen blev afbrudt, men strømtilstanden kunne ikke bekræftes sat tilbage. Prøver igen senere."; return $false }
      Remove-Item $GpuRestoreFile -Force -ErrorAction SilentlyContinue
      ModeLog "GPU-testen blev afbrudt. Strømtilstanden er sat tilbage til $(PowerMode-Name $g.Overlay) (bekræftet)."
      return $true
    }
    if (-not (Restore-GpuPl $g.Watts)) {   # behold filen, så det prøves igen
      ModeLog "GPU-testen blev afbrudt, men strømgrænsen kunne ikke bekræftes sat tilbage til $($g.Watts) W. Prøver igen senere."
      return $false
    }
    Remove-Item $GpuRestoreFile -Force -ErrorAction SilentlyContinue
    ModeLog "GPU-testen blev afbrudt. Strømgrænsen er sat tilbage til $($g.Watts) W (bekræftet)."
    return $true
  } catch { return $false }
}
# Ved opstart: ryd op efter alt, der blev afbrudt
function Repair-Modes {
  [void](Repair-GpuRestore)
  Retry-Pending
  if ((Test-Path $ModeEnding) -and -not (Test-Path $ModeFile)) { try { Move-Item $ModeEnding $ModeFile -Force } catch {} }
  $m = Get-ModeState
  if (-not $m) { return $null }
  if ($m.Mode -eq 'Fokus' -and $m.Until -and (Get-Date) -gt [datetime]$m.Until) { return (Stop-Mode 'tiden var gået') }
  if ($m.Mode -eq 'Spil' -and -not (Get-Process -Name (Exe-Key $m.Exe) -ErrorAction SilentlyContinue)) { return (Stop-Mode 'spillet var lukket') }
  return $null
}

# Sæt ALT tilbage nu (bruges, når Vagten slås fra, og før afinstallation)
function Restore-Everything($reason) {
  $s = $null
  if ((Test-Path $ModeEnding) -and -not (Test-Path $ModeFile)) { try { Move-Item $ModeEnding $ModeFile -Force } catch {} }
  if (Test-Path $ModeFile) { $s = Stop-Mode $reason }
  if (Test-Path $GpuRestoreFile) {
    try { $g = Get-Content $GpuRestoreFile -Raw | ConvertFrom-Json; $ok = if ($g.Overlay) { Set-PowerMode $g.Overlay } else { Restore-GpuPl $g.Watts }; if ($ok) { Remove-Item $GpuRestoreFile -Force -ErrorAction SilentlyContinue } } catch {}
  }
  Retry-Pending
  return $s
}
# Afinstallation: sæt aktive tilstande, grafikkort og blokeringer tilbage, og stop her (ingen vindue)
if ($RestoreOnly) {
  try { $r = Restore-Everything 'Opticon blev afinstalleret'; Log "Gendannet før afinstallation$(if ($r) { ": $(@($r.Done) -join ' · ')" })" } catch { Log "Gendannelse før afinstallation fejlede: $_" }
  $left = @()
  if (Test-Path $ModeFile) { $left += 'en aktiv Spil-/Fokus-tilstand' }
  if (Test-Path $GpuRestoreFile) { $left += 'grafikkortets indstilling' }
  if (Test-Path $ModePending) { try { $left += @(Get-Content $ModePending -Raw | ConvertFrom-Json | ForEach-Object { $_.Text }) } catch { $left += 'noget, der ikke kunne sættes tilbage' } }
  if ($left.Count) { [Console]::Out.WriteLine('MANGLER: ' + ($left -join '; ')); exit 1 }
  exit 0
}
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
  $BadArgs      = '(?i)(\s-e(nc?|c)\b|-enc|base64|-w(indowstyle)?\s+hidden|\biex\b|invoke-ex|download|http[s]?://)'

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

  # ---------- Diskens helbred (advar i god tid) ----------
  try {
    foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
      $rc = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
      $dn = "$($pd.FriendlyName)"
      $errs = 0; if ($rc) { $errs = [int64]$rc.ReadErrorsUncorrected + [int64]$rc.WriteErrorsUncorrected }
      if ($pd.HealthStatus -and $pd.HealthStatus -ne 'Healthy') {
        Add-Find 4 'Disk' "Disken melder fejl: $dn" "Status: $($pd.HealthStatus) · $($pd.OperationalStatus)" 'Disken selv melder, at den har problemer. Den kan gå i stykker når som helst.' '' 'info' $null 'Tag backup af dine vigtige filer NU (fx til OneDrive eller et USB-drev), og udskift disken.'
      } elseif ($rc -and $null -ne $rc.Wear -and [int]$rc.Wear -ge 80) {
        Add-Find 3 'Disk' "SSD'en er næsten slidt op: $dn" "Slid: $([int]$rc.Wear) %" 'En SSD kan kun skrives et vist antal gange. Over 80 % slid stiger risikoen for at den pludselig dør.' '' 'info' $null 'Tag backup, og planlæg at skifte disken. Se detaljer under Ydelse og helbred.'
      } elseif ($errs -gt 0) {
        Add-Find 3 'Disk' "Disken har læse-/skrivefejl: $dn" "$errs fejl, der ikke kunne rettes" 'Data er gået tabt ved læsning eller skrivning. Det er ofte et tidligt tegn på, at disken er ved at dø.' '' 'info' $null 'Tag backup, og hold øje under Ydelse og helbred. Stiger tallet, så udskift disken.'
      }
    }
  } catch {}

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
      # Opticons egen opgave (fra installeren): kendt sti + kendt handling -> ikke et fund
      if ($t.TaskPath -eq '\' -and $t.TaskName -eq 'PC-Tjek Vagt' -and ($exe -ieq "$env:SystemRoot\System32\conhost.exe" -or $exe -ieq "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe") -and $a.Arguments -like "*$env:ProgramFiles\PC-Tjek\PC-Tjek-Vagt.ps1*") {
        Add-Find 0 'Planlagt opgave' 'PC-Tjek Vagt (denne app)' 'Starter vagten, når du logger ind' 'Oprettet af Opticon.' $full 'self' $null
        continue
      }
      if ($t.TaskPath -eq '\' -and $t.TaskName -eq 'PC-Tjek' -and ($exe -ieq "$env:SystemRoot\System32\conhost.exe" -or $exe -ieq "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe") -and ($a.Arguments -like "*$env:ProgramFiles\PC-Tjek\PC-Tjek-App.ps1*" -or $a.Arguments -like "*$env:ProgramFiles\PC-Tjek\PC-Tjek-Start.ps1*")) {
        Add-Find 0 'Planlagt opgave' 'PC-Tjek (denne app)' 'Starter Opticon, når du klikker på ikonet' 'Oprettet af Opticons installer.' $full 'self' $null
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
    if ($pp.CommandLine -and $pp.CommandLine -match $LolBins -and $pp.CommandLine -match $BadArgs -and $pp.ProcessId -ne $PID -and $pp.CommandLine -notmatch '(?i)\\PC-Tjek\\(PC-Tjek-App\.ps1|PC-Tjek-Start\.ps1|Opticon-Vagt\.ps1|jobs\\)') {
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

  # Valgfrit: slå usignerede filers fingeraftryk (SHA256) op i MalwareBazaar (kun hashen sendes, aldrig filen)
  if ($arg -and $arg.MbKey) {
    $mbList = @($AllFinds | Where-Object { $_.Kategori -eq 'Ny fil' -and $_.SHA256 } | Select-Object -First 60)
    if ($mbList.Count) {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      Status "MalwareBazaar tjekker $($mbList.Count) usignerede filer"
      $mi = 0; $mbFail = 0; $mbHits = 0
      foreach ($x in $mbList) {
        $mi++; Sub (0.95 + 0.05 * $mi / $mbList.Count) "MalwareBazaar: fil $mi af $($mbList.Count)"
        try {
          $mr = Invoke-RestMethod -Uri 'https://mb-api.abuse.ch/api/v1/' -Method Post -Body @{ query = 'get_info'; hash = $x.SHA256 } -Headers @{ 'Auth-Key' = [string]$arg.MbKey } -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
          if ($mr.query_status -eq 'ok' -and $mr.data) {
            $d0 = @($mr.data)[0]; $mbHits++
            $fam = [string]$d0.signature
            $x.Niveau = 4; $x.Risiko = 'Kritisk'; $x.Kategori = 'Trussel'
            $x.Titel = "Kendt malware: $(Split-Path $x.Sti -Leaf)$(if ($fam) { " ($fam)" })"
            $x.Hvorfor = "Filens fingeraftryk findes i MalwareBazaar, en database med over 1 million bekræftede malware-filer.$(if ($fam) { " Familie: $fam." }) Først set: $($d0.first_seen)."
            $x.Raad = 'Brug trinnet "Fjern virus" på Overblik, eller kør en Defender Offline-scanning. Har filen kørt, så skift dine vigtigste adgangskoder fra en anden enhed.'
            Add-Time (Get-Date) 'MalwareBazaar' "Kendt malware fundet: $(Split-Path $x.Sti -Leaf)" $x.Sti
          } elseif ($mr.query_status -eq 'hash_not_found') {
            $x.Detalje = '✓ Ukendt for MalwareBazaar · ' + $x.Detalje
          } else { $mbFail++ }
        } catch { $mbFail++ }
        if ($mbFail -ge 3 -and $mbHits -eq 0 -and $mi -le 3) { break }
        Start-Sleep -Milliseconds 150
      }
      if ($arg.LogFile) { try { [IO.File]::AppendAllText($arg.LogFile, ("{0:yyyy-MM-dd HH:mm:ss}  MalwareBazaar: {1} tjekket, {2} kendt malware, {3} fejl`r`n" -f (Get-Date), $mi, $mbHits, $mbFail), [Text.Encoding]::UTF8) } catch {} }
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
  # 1) Microsofts eget PowerShell-modul (Microsoft.WinGet.Client): giver pakkerne som rigtige objekter.
  #    Hentes fra PowerShell Gallery første gang. Virker det ikke, bruges winget-kommandoen som før.
  try {
    if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
      $sync.Status = 'Henter Microsofts WinGet-modul (kun første gang, ca. 30 sek)...'
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      $ProgressPreference = 'SilentlyContinue'
      if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -Confirm:$false -ErrorAction Stop | Out-Null
      }
      Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope AllUsers -Force -AllowClobber -Confirm:$false -ErrorAction Stop | Out-Null
    }
    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    $sync.Status = 'Spørger WinGet om opdateringer...'
    $pk = @(Get-WinGetPackage -ErrorAction Stop | Where-Object { $_.IsUpdateAvailable })
    return @($pk | ForEach-Object { [pscustomobject]@{ Navn = [string]$_.Name; Id = [string]$_.Id; Version = [string]$_.InstalledVersion; Ny = [string](@($_.AvailableVersions)[0]); Via = 'modul' } })
  } catch {
    if ($arg -and $arg.LogFile) { try { [IO.File]::AppendAllText([string]$arg.LogFile, ("{0:yyyy-MM-dd HH:mm:ss}  WinGet-modul kunne ikke bruges, bruger winget direkte: {1}`r`n" -f (Get-Date), $_.Exception.Message), [Text.Encoding]::UTF8) } catch {} }
  }
  # 2) Reserve: winget-kommandoen (læser tabellen)
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
    $done = $false
    if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) {
      try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        $u = Update-WinGetPackage -Id $id -MatchOption Equals -Mode Silent -ErrorAction Stop
        $st = [string]$u.Status
        $res[$id] = if ($st -eq 'Ok') { $(if ($u.RebootRequired) { 'OK (genstart pc''en)' } else { 'OK' }) } else { "Fejl ($st)" }
        $done = $true
      } catch {}
    }
    if (-not $done) {
      $o = & winget upgrade --id $id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { [string]$_ }
      $res[$id] = if ($LASTEXITCODE -eq 0) { 'OK' } else { "Fejl ($LASTEXITCODE)" }
    }
  }
  return $res
}
$RestorePointScript = {
  param($sync, $arg)
  $sync.Status = 'Opretter gendannelsespunkt (kan tage op til et minut)...'
  Checkpoint-Computer -Description "Opticon $($arg.Why)" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
  return 'ok'
}


# =====================================================================
#  Sikkerhedstjek: Windows' egne beskyttelser (kører i baggrunden)
# =====================================================================
$SecScript = {
  param($sync, $arg)
  $sync.Status = 'Tjekker Windows-beskyttelse...'
  $out = New-Object System.Collections.ArrayList
  function Add-Sec($id, $ok, $name, $val, $note, $how, $fix, $uri) {
    [void]$out.Add([pscustomobject]@{ Id = $id; Ok = $ok; Navn = $name; Info = [string]$val; Note = $note; How = $how; Fix = $fix; Uri = $uri })
  }
  $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
  $laptop = $cs -and ($cs.PCSystemType -eq 2)
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
  $build = 0; [void][int]::TryParse([string]$cv.CurrentBuild, [ref]$build)
  $disp = [string]$cv.DisplayVersion; $ed = [string]$cv.EditionID

  # 1. Windows-version
  try {
    if ($build -gt 0 -and $build -lt 22000) {
      Add-Sec 'winver' 0 'Windows-version' "Windows 10 $disp" 'Windows 10 fik sin sidste almindelige sikkerhedsopdatering i oktober 2025. Nye huller bliver kun lukket, hvis pc''en er tilmeldt ESU.' 'Opgradér til Windows 11, hvis pc''en kan. Ellers: Windows Update → tilmeld "Udvidede sikkerhedsopdateringer" (ESU).' '' 'ms-settings:windowsupdate'
    } elseif ($build -gt 0 -and $build -lt 26200 -and $ed -notmatch 'Enterprise|Education|IoT|Server') {
      Add-Sec 'winver' 0 'Windows-version' "Windows 11 $disp" "Version $disp af Home/Pro får ikke længere sikkerhedsopdateringer." 'Windows Update → installér den nyeste version af Windows 11 (25H2 eller nyere). Det er gratis og beholder dine filer og programmer.' '' 'ms-settings:windowsupdate'
    } else {
      Add-Sec 'winver' 2 'Windows-version' "Windows $(if ($build -ge 22000) { '11' } else { '' }) $disp" 'Får stadig sikkerhedsopdateringer' '' '' ''
    }
  } catch {}

  # 2. Opdateringer sat på pause?
  try {
    $pz = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name PauseUpdatesExpiryTime -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime
    $pd = $null
    if ($pz) { try { $pd = [datetime]::Parse([string]$pz, [Globalization.CultureInfo]::InvariantCulture).ToLocalTime() } catch {} }
    if ($pd -and $pd -gt (Get-Date)) {
      Add-Sec 'wupause' 1 'Windows Update' "På pause til $($pd.ToString('d. MMM'))" 'Mens opdateringer er sat på pause, bliver nye sikkerhedshuller ikke lukket.' 'Windows Update → "Genoptag opdateringer".' '' 'ms-settings:windowsupdate'
    } else { Add-Sec 'wupause' 2 'Windows Update' 'Kører' 'Ikke sat på pause' '' '' '' }
  } catch {}

  # 3. Antivirus + Defender
  $defActive = $true
  try {
    $st = Get-MpComputerStatus -ErrorAction Stop
    $other = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
      Where-Object { $_.displayName -notmatch 'Defender' -and ((([int]$_.productState) -shr 12) -band 0xF) -eq 1 })
    if ($other.Count -and -not $st.RealTimeProtectionEnabled) {
      $defActive = $false
      Add-Sec 'av' 2 'Antivirus' $other[0].displayName 'Et andet antivirusprogram passer på pc''en' '' '' ''
    } elseif (-not $st.RealTimeProtectionEnabled) {
      Add-Sec 'av' 0 'Antivirus' 'Realtidsbeskyttelse er FRA' 'Pc''en er ubeskyttet mod nye virus. Malware slår den ofte selv fra.' 'Windows Sikkerhed → Virus- og trusselsbeskyttelse → slå Realtidsbeskyttelse til. Kør derefter en fuld scanning.' '' 'windowsdefender://threatsettings'
    } else {
      $age = [int]$st.AntivirusSignatureAge
      if ($age -gt 3) { Add-Sec 'av' 1 'Antivirus' "Defender · virusdefinitioner $age dage gamle" 'Defender kender ikke de nyeste virus.' 'Opticon kan hente de nyeste definitioner nu.' 'sigs' 'windowsdefender://threat' }
      else { Add-Sec 'av' 2 'Antivirus' 'Microsoft Defender · opdateret' 'Realtidsbeskyttelse er til' '' '' '' }
    }
    if ($defActive) {
      if ($st.IsTamperProtected) { Add-Sec 'tamper' 2 'Manipulationsbeskyttelse' 'Til' 'Programmer kan ikke slå Defender fra bag din ryg' '' '' '' }
      else { Add-Sec 'tamper' 1 'Manipulationsbeskyttelse' 'Fra' 'Uden den kan malware slå Defender fra.' 'Windows Sikkerhed → Virus- og trusselsbeskyttelse → Administrer indstillinger → Manipulationsbeskyttelse: Til. (Kan kun slås til af dig selv, så malware ikke kan gøre det.)' '' 'windowsdefender://threatsettings' }
      $pua = (Get-MpPreference -ErrorAction SilentlyContinue).PUAProtection
      if ($pua -eq 1) { Add-Sec 'pua' 2 'Bloker uønskede programmer' 'Til' 'Stopper adware og skjulte cryptominere i installere' '' '' '' }
      else { Add-Sec 'pua' 1 'Bloker uønskede programmer' 'Fra' 'Gratis programmer har ofte adware, værktøjslinjer eller cryptominere med i installeren. Defender kan stoppe dem.' 'Opticon kan slå det til for dig. Det ændrer ikke dine programmer.' 'pua' 'windowsdefender://appbrowser' }
      # Microsofts "standardbeskyttelse": 3 ASR-regler, som Microsoft anbefaler at slå til uden test
      $asrStd = @('56a863a9-875e-4185-98a7-b882c64b5ce5', '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2', 'e6db77e5-3df2-4cf1-b95a-636979351e5b')
      $mpp = Get-MpPreference -ErrorAction SilentlyContinue
      $ids = @($mpp.AttackSurfaceReductionRules_Ids | ForEach-Object { ([string]$_).ToLowerInvariant() }); $acts = @($mpp.AttackSurfaceReductionRules_Actions)
      $asrOn = 0
      foreach ($g in $asrStd) { $ix = [array]::IndexOf($ids, $g); if ($ix -ge 0 -and $ix -lt $acts.Count -and @(1, 6) -contains [int]$acts[$ix]) { $asrOn++ } }
      if ($asrOn -eq $asrStd.Count) { Add-Sec 'asr' 2 'Ekstra Defender-regler (ASR)' 'Til (3 af 3)' 'Stopper misbrug af sårbare drivere, tyveri af adgangskoder fra hukommelsen og skjult autostart via WMI' '' '' '' }
      else { Add-Sec 'asr' 1 'Ekstra Defender-regler (ASR)' "$asrOn af 3 slået til" 'Tre regler, som Microsoft anbefaler alle at slå til: de stopper misbrug af sårbare drivere, tyveri af adgangskoder fra hukommelsen og skjult autostart via WMI. De mærkes normalt ikke i hverdagen.' 'Opticon kan slå de tre regler til. Et meget gammelt RGB-, blæser- eller overclock-værktøj kan blive blokeret, indtil du opdaterer det. Bliver noget blokeret, viser Windows Sikkerhed en besked om det.' 'asr' '' }
    }
  } catch { Add-Sec 'av' 3 'Antivirus' 'Kunne ikke læses' '' '' '' 'windowsdefender://threat' }

  # 4. Firewall
  try {
    $off = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled } | ForEach-Object { switch ($_.Name) { 'Domain' { 'domæne' } 'Private' { 'privat' } 'Public' { 'offentlig' } default { $_.Name } } })
    $fwOther = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName FirewallProduct -ErrorAction SilentlyContinue | Where-Object { ((([int]$_.productState) -shr 12) -band 0xF) -eq 1 })
    if (-not $off.Count) { Add-Sec 'fw' 2 'Firewall' 'Til på alle netværk' 'Blokerer ubudne forbindelser udefra' '' '' '' }
    elseif ($fwOther.Count) { Add-Sec 'fw' 2 'Firewall' $fwOther[0].displayName 'Et andet program styrer firewallen' '' '' '' }
    else { Add-Sec 'fw' 0 'Firewall' ("Fra på " + ($off -join ', ') + ' netværk') 'Andre på samme netværk (fx på en café eller skole) kan nå tjenester på din pc.' 'Opticon kan slå Windows Firewall til igen på alle netværk.' 'fw' 'windowsdefender://network' }
  } catch {}

  # 5. SmartScreen
  try {
    $ss = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name SmartScreenEnabled -ErrorAction SilentlyContinue).SmartScreenEnabled
    $ssPol = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name EnableSmartScreen -ErrorAction SilentlyContinue).EnableSmartScreen
    if ($ss -eq 'Off' -or $ssPol -eq 0) { Add-Sec 'smartscreen' 1 'SmartScreen' 'Fra' 'SmartScreen advarer, før du åbner kendte falske installere og phishing-sider.' 'Windows Sikkerhed → App- og browserkontrol → Omdømmebaseret beskyttelse → slå det hele til.' '' 'windowsdefender://appbrowser' }
    else { Add-Sec 'smartscreen' 2 'SmartScreen' 'Til' 'Advarer mod kendte falske programmer og sider' '' '' '' }
  } catch {}

  # 6. Brugerkontokontrol (UAC)
  try {
    $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
    if ($pol.EnableLUA -eq 0) { Add-Sec 'uac' 0 'Brugerkontokontrol (UAC)' 'Slået helt fra' 'Alle programmer får fuld adgang til pc''en uden at spørge. Det gør det meget let for malware.' 'Opticon kan slå den til igen. Kræver genstart.' 'uac' '' }
    elseif ($pol.ConsentPromptBehaviorAdmin -eq 0 -or $pol.PromptOnSecureDesktop -eq 0) { Add-Sec 'uac' 1 'Brugerkontokontrol (UAC)' 'Til, men spørger ikke ordentligt' 'Programmer kan få administrator-rettigheder uden at du bliver spurgt, eller uden den mørke sikre skærm.' 'Opticon kan sætte den tilbage til Windows-standard.' 'uac' '' }
    else { Add-Sec 'uac' 2 'Brugerkontokontrol (UAC)' 'Til' 'Programmer skal spørge, før de ændrer pc''en' '' '' '' }
  } catch {}

  # 7. Hukommelsesintegritet (HVCI)
  $hvciOn = $false
  try {
    $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    $hvciOn = $dg -and (@($dg.SecurityServicesRunning) -contains 2)
    $hvReg = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name Enabled -ErrorAction SilentlyContinue).Enabled
    if ($hvciOn) { Add-Sec 'hvci' 2 'Hukommelsesintegritet' 'Til' 'Forhindrer, at ondsindede drivere får adgang til Windows'' kerne' '' '' '' }
    elseif ($hvReg -eq 1) { Add-Sec 'hvci' 1 'Hukommelsesintegritet' 'Slået til, venter på genstart' 'Træder i kraft efter næste genstart' 'Genstart pc''en.' '' 'windowsdefender://coreisolation' }
    else { Add-Sec 'hvci' 1 'Hukommelsesintegritet' 'Fra' 'Stopper drivere med kendte huller og malware i kernen. Koster typisk 0-5 % FPS i nogle spil.' 'Windows Sikkerhed → Enhedssikkerhed → Kerneisolering → Hukommelsesintegritet: Til. Kræver genstart. Står der "inkompatible drivere", så opdatér eller fjern de programmer først.' '' 'windowsdefender://coreisolation' }
  } catch {}

  # 8. Microsofts blokeringsliste over sårbare drivere
  try {
    $bl = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' -Name VulnerableDriverBlocklistEnable -ErrorAction SilentlyContinue).VulnerableDriverBlocklistEnable
    $blOn = $hvciOn -or ($bl -eq 1) -or ($null -eq $bl -and $build -ge 22621)
    if ($blOn) { Add-Sec 'blocklist' 2 'Blokér sårbare drivere' 'Til' 'Windows nægter at indlæse drivere med kendte huller' '' '' '' }
    else { Add-Sec 'blocklist' 1 'Blokér sårbare drivere' 'Fra' 'Angribere bruger gamle drivere med kendte huller til at slå antivirus fra. Windows har en liste, den kan blokere.' 'Opticon kan slå den til. Kræver genstart. Et meget gammelt RGB-, blæser- eller overclock-værktøj kan holde op med at virke, indtil du opdaterer det.' 'blocklist' 'windowsdefender://coreisolation' }
  } catch {}

  # 9. Secure Boot
  try {
    $sb = $null
    try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop } catch { $sb = $null }
    if ($sb -eq $true) { Add-Sec 'secureboot' 2 'Secure Boot' 'Til' 'Stopper skadelig kode, der vil starte før Windows' '' '' '' }
    elseif ($sb -eq $false) { Add-Sec 'secureboot' 1 'Secure Boot' 'Fra' 'Uden Secure Boot kan "bootkits" starte før Windows og gemme sig for antivirus. Nogle spil med anti-cheat kræver det også.' 'Slås til i BIOS/UEFI: genstart, tryk Del/F2, find Boot → Secure Boot → Enabled. Rør ikke ved andet, hvis du er i tvivl.' '' '' }
    else { Add-Sec 'secureboot' 3 'Secure Boot' 'Ikke tilgængelig' 'Pc''en starter i gammel BIOS-tilstand' 'Kræver at Windows er installeret i UEFI-tilstand. Ikke noget, du skal ændre uden hjælp.' '' '' }
  } catch {}

  # 10. TPM
  try {
    $tpm = Get-Tpm -ErrorAction Stop
    $tv = ''
    try { $tv = ((Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction SilentlyContinue).SpecVersion -split ',')[0].Trim() } catch {}
    if ($tpm.TpmPresent -and $tpm.TpmReady) { Add-Sec 'tpm' 2 'TPM-sikkerhedschip' "Klar$(if ($tv) { " (version $tv)" })" 'Beskytter krypteringsnøgler og Windows Hello' '' '' '' }
    elseif ($tpm.TpmPresent) { Add-Sec 'tpm' 1 'TPM-sikkerhedschip' 'Fundet, men ikke klar' 'Kryptering og Windows Hello virker ikke optimalt' 'Åbn tpm.msc og vælg "Forbered TPM", eller nulstil den i BIOS.' '' '' }
    else { Add-Sec 'tpm' 1 'TPM-sikkerhedschip' 'Ikke fundet' 'Uden TPM kan disken ikke krypteres automatisk' 'Slå fTPM (AMD) eller PTT (Intel) til i BIOS/UEFI under Security eller Advanced.' '' '' }
  } catch {}

  # 11. Diskkryptering (BitLocker / Enhedskryptering)
  try {
    $ev = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='C:'" -ErrorAction Stop
    if ($ev.ProtectionStatus -eq 1) { Add-Sec 'crypt' 2 'Diskkryptering (C:)' 'Til' 'Hvis pc''en bliver stjålet, kan ingen læse dine filer' 'Sørg for at have gendannelsesnøglen: den ligger på account.microsoft.com/devices/recoverykey. Uden den kan du miste alt, hvis noget går galt.' '' '' }
    else { Add-Sec 'crypt' $(if ($laptop) { 1 } else { 3 }) 'Diskkryptering (C:)' 'Fra' $(if ($laptop) { 'En stjålen bærbar kan læses af hvem som helst, også uden din adgangskode.' } else { 'Mindre vigtigt på en stationær, men beskytter dine filer ved tyveri.' }) 'Indstillinger → Beskyttelse af personlige oplysninger og sikkerhed → Enhedskryptering (eller BitLocker på Pro). Gem gendannelsesnøglen på din Microsoft-konto.' '' 'ms-settings:deviceencryption' }
  } catch { Add-Sec 'crypt' 3 'Diskkryptering (C:)' 'Ikke tilgængelig' 'Denne udgave af Windows har ikke kryptering' '' '' '' }

  # 12. SMBv1 (gammel fildeling, brugt af WannaCry)
  try {
    $smb1 = $false
    try { $smb1 = [bool](Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol } catch {}
    try { if ((Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction Stop).State -eq 'Enabled') { $smb1 = $true } } catch {}
    if ($smb1) { Add-Sec 'smb1' 0 'Gammel fildeling (SMBv1)' 'Til' 'En 30 år gammel protokol med kendte huller. Det var den, WannaCry spredte sig med.' 'Opticon kan slå den fra. Kun meget gamle NAS-drev og printere bruger den.' 'smb1' '' }
    else { Add-Sec 'smb1' 2 'Gammel fildeling (SMBv1)' 'Fra' 'Godt: den gamle, usikre protokol er slået fra' '' '' '' }
  } catch {}

  # 13. Fjernskrivebord
  try {
    $ts = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
    if ($ts -and $ts.fDenyTSConnections -eq 0) {
      $nla = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -ErrorAction SilentlyContinue).UserAuthentication
      if ($nla -eq 0) { Add-Sec 'rdp' 0 'Fjernskrivebord' 'Åben uden ekstra login-tjek' 'Andre kan forsøge at logge på din pc over netværket, og det tjek, der skulle bremse dem, er slået fra.' 'Bruger du det ikke selv, så lad Opticon lukke det.' 'rdp' 'ms-settings:remotedesktop' }
      else { Add-Sec 'rdp' 1 'Fjernskrivebord' 'Åben' 'Andre kan forsøge at logge på din pc over netværket. Et yndet mål for angreb.' 'Bruger du det ikke selv, så lad Opticon lukke det.' 'rdp' 'ms-settings:remotedesktop' }
    } else { Add-Sec 'rdp' 2 'Fjernskrivebord' 'Lukket' 'Ingen kan logge på pc''en udefra' '' '' '' }
  } catch {}

  # 14. Gæstekonto
  try {
    $g = Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID.Value -like '*-501' }
    if ($g -and $g.Enabled) { Add-Sec 'guest' 1 'Gæstekonto' 'Til' 'Alle kan logge på pc''en uden adgangskode' 'Opticon kan slå gæstekontoen fra.' 'guest' '' }
    else { Add-Sec 'guest' 2 'Gæstekonto' 'Fra' 'Man skal have en konto for at logge på' '' '' '' }
  } catch {}

  # 15. Automatisk login med gemt adgangskode i klartekst
  try {
    $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    if ([string]$wl.AutoAdminLogon -eq '1' -and $wl.DefaultPassword) { Add-Sec 'autologon' 0 'Automatisk login' 'Adgangskode gemt i klartekst' 'Din Windows-adgangskode ligger ukrypteret i registreringsdatabasen, hvor ethvert program kan læse den.' 'Opticon kan fjerne den gemte adgangskode og slå automatisk login fra. Skift derefter adgangskoden, hvis den også bruges andre steder.' 'autologon' '' }
    elseif ([string]$wl.AutoAdminLogon -eq '1') { Add-Sec 'autologon' 1 'Automatisk login' 'Til' 'Pc''en logger selv på, så alle med adgang til den kan bruge den' 'netplwiz → sæt flueben i "Brugerne skal angive brugernavn og adgangskode".' '' '' }
  } catch {}

  return [pscustomobject]@{ Rows = @($out); Laptop = $laptop; Build = $build }
}

$SecFixScript = {
  param($sync, $arg)
  $id = [string]$arg.Id
  $sync.Status = 'Retter: ' + $arg.Name + '...'
  switch ($id) {
    'sigs'      { Update-MpSignature -ErrorAction Stop; return 'Virusdefinitioner opdateret.' }
    'pua'       { Set-MpPreference -PUAProtection Enabled -ErrorAction Stop; return 'Blokering af uønskede programmer er slået til.' }
    'asr'       {
      foreach ($g in '56a863a9-875e-4185-98a7-b882c64b5ce5', '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2', 'e6db77e5-3df2-4cf1-b95a-636979351e5b') {
        Add-MpPreference -AttackSurfaceReductionRules_Ids $g -AttackSurfaceReductionRules_Actions Enabled -ErrorAction Stop
      }
      return 'De 3 ekstra Defender-regler er slået til.'
    }
    'fw'        { Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -ErrorAction Stop; return 'Firewall er slået til på alle netværk.' }
    'uac'       {
      $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
      $was = (Get-ItemProperty $k -Name EnableLUA -ErrorAction SilentlyContinue).EnableLUA
      Set-ItemProperty $k -Name EnableLUA -Value 1 -Type DWord -ErrorAction Stop
      Set-ItemProperty $k -Name ConsentPromptBehaviorAdmin -Value 5 -Type DWord -ErrorAction Stop
      Set-ItemProperty $k -Name PromptOnSecureDesktop -Value 1 -Type DWord -ErrorAction Stop
      return $(if ($was -eq 0) { 'Brugerkontokontrol er slået til. Genstart pc''en, så den træder i kraft.' } else { 'Brugerkontokontrol er sat til Windows-standard.' })
    }
    'blocklist' {
      $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'
      if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
      Set-ItemProperty $k -Name VulnerableDriverBlocklistEnable -Value 1 -Type DWord -ErrorAction Stop
      return 'Blokering af sårbare drivere er slået til. Træder i kraft efter genstart.'
    }
    'smb1'      {
      try { Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop } catch {}
      try { Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction Stop | Out-Null } catch {}
      return 'SMBv1 er slået fra. Genstart for at fjerne den helt.'
    }
    'rdp'       {
      Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 1 -Type DWord -ErrorAction Stop
      try { Disable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue } catch {}
      try { Disable-NetFirewallRule -DisplayGroup 'Fjernskrivebord' -ErrorAction SilentlyContinue } catch {}
      return 'Fjernskrivebord er lukket.'
    }
    'guest'     { Get-LocalUser | Where-Object { $_.SID.Value -like '*-501' } | Disable-LocalUser -ErrorAction Stop; return 'Gæstekontoen er slået fra.' }
    'autologon' {
      $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
      Remove-ItemProperty $k -Name DefaultPassword -ErrorAction SilentlyContinue
      Set-ItemProperty $k -Name AutoAdminLogon -Value '0' -ErrorAction Stop
      return 'Den gemte adgangskode er fjernet, og automatisk login er slået fra.'
    }
    default     { throw "Ukendt rettelse: $id" }
  }
}

# =====================================================================
#  Mål i mit spil: Intel PresentMon (github.com/GameTechDev/PresentMon, MIT)
# =====================================================================
$GameMeasureScript = {
  param($sync, $arg)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $tools = [string]$arg.Tools
  if (-not (Test-Path $tools)) { New-Item -ItemType Directory -Force $tools | Out-Null }
  $pm = Join-Path $tools 'PresentMon.exe'
  function Test-IntelSigned($p) {
    if (-not (Test-Path $p)) { return $false }
    $sig = Get-AuthenticodeSignature -FilePath $p
    return ($sig.Status -eq 'Valid' -and [string]$sig.SignerCertificate.Subject -match 'Intel')
  }
  if (-not (Test-IntelSigned $pm)) {
    $sync.Status = 'Henter Intel PresentMon (kun første gang)...'
    $url = $null
    try {
      $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/GameTechDev/PresentMon/releases?per_page=15' -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'Opticon' }
      foreach ($r in @($rel)) {
        if ($r.prerelease -or $r.draft) { continue }
        $a = @($r.assets | Where-Object { $_.name -match '^PresentMon-[\d.]+-x64\.exe$' })
        if ($a.Count) { $url = $a[0].browser_download_url; break }
      }
    } catch {}
    if (-not $url) { $url = 'https://github.com/GameTechDev/PresentMon/releases/download/v2.3.1/PresentMon-2.3.1-x64.exe' }
    $tmp = Join-Path $tools 'PresentMon-ny.exe'
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 120 -UserAgent 'Opticon' -ErrorAction Stop
    if (-not (Test-IntelSigned $tmp)) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; throw 'PresentMon-filen var ikke gyldigt signeret af Intel, så Opticon brugte den ikke.' }
    Move-Item $tmp $pm -Force
  }

  $dur = [int]$arg.Seconds
  for ($i = 10; $i -gt 0; $i--) { $sync.Status = "Skift til dit spil nu. Målingen starter om $i sek..."; $sync.Progress = -1.0; Start-Sleep 1 }
  Get-ChildItem $tools -Filter 'capture-*.csv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 2 | Remove-Item -Force -ErrorAction SilentlyContinue
  $csv = Join-Path $tools ('capture-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
  try { [Media.SystemSounds]::Asterisk.Play() } catch {}
  $pmArgs = @('--output_file', ('"' + $csv + '"'), '--timed', [string]$dur, '--terminate_after_timed', '--stop_existing_session', '--session_name', 'Opticon', '--no_console_stats', '--no_track_input')
  # Grafikkortets strøm, temperatur og clock undervejs (NVIDIA), så før/efter-tests kan vise watt
  $smi = "$env:SystemRoot\System32\nvidia-smi.exe"; if (-not (Test-Path $smi)) { $smi = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe" }
  $hasSmi = Test-Path $smi; $gid = if ($arg.GpuId) { [string]$arg.GpuId } else { '0' }
  $inv0 = [Globalization.CultureInfo]::InvariantCulture
  $ctxDrv = $null; $ctxPl = $null
  if ($hasSmi) { try { $q0 = ([string](& $smi -i $gid --query-gpu=driver_version,power.limit --format=csv,noheader,nounits 2>$null | Select-Object -First 1)) -split ',\s*'; $ctxDrv = $q0[0].Trim(); $ctxPl = [math]::Round([double]::Parse($q0[1].Trim(), $inv0)) } catch {} }
  $wS = New-Object System.Collections.ArrayList; $tS = New-Object System.Collections.ArrayList; $nextS = Get-Date
  $p = Start-Process -FilePath $pm -ArgumentList $pmArgs -WindowStyle Hidden -PassThru
  $t0 = Get-Date
  while (-not $p.HasExited) {
    if ($hasSmi -and (Get-Date) -ge $nextS) {
      $nextS = (Get-Date).AddSeconds(1)
      try { $q1 = ([string](& $smi -i $gid --query-gpu=power.draw,temperature.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1)) -split ',\s*'; $wv = 0.0; $tv = 0.0
            if ([double]::TryParse($q1[0].Trim(), [Globalization.NumberStyles]::Float, $inv0, [ref]$wv)) { [void]$wS.Add($wv) }
            if ([double]::TryParse($q1[1].Trim(), [Globalization.NumberStyles]::Float, $inv0, [ref]$tv)) { [void]$tS.Add($tv) } } catch {}
    }
    $el = ((Get-Date) - $t0).TotalSeconds
    $sync.Status = "Måler dit spil... $([math]::Max(0, [int]($dur - $el))) sek tilbage"
    $sync.Progress = [double][math]::Min(1.0, $el / $dur)
    if ($el -gt $dur + 30) { try { $p.Kill() } catch {}; break }
    Start-Sleep -Milliseconds 500
  }
  try { [Media.SystemSounds]::Exclamation.Play() } catch {}
  Start-Sleep -Milliseconds 500
  if (-not (Test-Path $csv)) { throw "PresentMon gemte ingen måling (kode $($p.ExitCode))." }

  $sync.Status = 'Regner resultatet ud...'
  $lines = [IO.File]::ReadAllLines($csv)
  if ($lines.Count -lt 30) { throw 'Fandt næsten ingen billeder. Var spillet i gang og i forgrunden, mens den målte?' }
  $hdr = $lines[0].Split(',')
  function Find-Col([string[]]$names) { foreach ($nm in $names) { $ix = [array]::IndexOf($hdr, $nm); if ($ix -ge 0) { return $ix } }; return -1 }
  $iApp = Find-Col @('Application', 'ProcessName')
  $iFt = Find-Col @('MsBetweenPresents', 'FrameTime', 'MsBetweenAppStart')
  $iGpu = Find-Col @('MsGPUBusy', 'GPUBusy')
  $iCpu = Find-Col @('MsCPUBusy', 'CPUBusy')
  $iMode = Find-Col @('PresentMode')
  $iSync = Find-Col @('SyncInterval')
  $iRt = Find-Col @('PresentRuntime')
  if ($iApp -lt 0 -or $iFt -lt 0) { throw 'Kunne ikke læse PresentMons resultat (ukendte kolonner).' }
  $skip = '(?i)^(dwm|explorer|powershell|pwsh|conhost|msedge|msedgewebview2|chrome|firefox|opera|brave|discord|steamwebhelper|steam|epicgameslauncher|eadesktop|battle\.net|overwolf|nvcontainer|nvidia overlay|nvidia app|applicationframehost|searchhost|searchapp|startmenuexperiencehost|textinputhost|shellexperiencehost|ms-teams|teams|spotify|obs64|code|windowsterminal|gamebar|xboxgamebar|xboxpcapp|presentmon.*|lghub|rtss|widgets|photos|mspaint|notepad|claude|chatgpt|codex)(\.exe)?$'
  $count = @{}
  for ($i = 1; $i -lt $lines.Count; $i++) {
    $c = $lines[$i].Split(',')
    if ($c.Count -le $iFt) { continue }
    $a = $c[$iApp]
    if ($a -match $skip) { continue }
    $count[$a] = 1 + [int]$count[$a]
  }
  if (-not $count.Count) { throw 'Fandt intet spil i målingen. Var spillet i forgrunden, mens den målte?' }
  $game = ($count.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key

  $inv = [Globalization.CultureInfo]::InvariantCulture
  $ft = New-Object 'System.Collections.Generic.List[double]'
  $gb = 0.0; $ng = 0; $cb = 0.0; $nc = 0; $vs = 0; $nAll = 0; $modes = @{}; $rt = ''
  for ($i = 1; $i -lt $lines.Count; $i++) {
    $c = $lines[$i].Split(',')
    if ($c.Count -le $iFt -or $c[$iApp] -ne $game) { continue }
    $v = 0.0
    if (-not [double]::TryParse($c[$iFt], [Globalization.NumberStyles]::Float, $inv, [ref]$v) -or $v -le 0 -or $v -gt 2000) { continue }
    $ft.Add($v); $nAll++
    $w = 0.0
    if ($iGpu -ge 0 -and $c.Count -gt $iGpu -and [double]::TryParse($c[$iGpu], [Globalization.NumberStyles]::Float, $inv, [ref]$w)) { $gb += $w; $ng++ }
    if ($iCpu -ge 0 -and $c.Count -gt $iCpu -and [double]::TryParse($c[$iCpu], [Globalization.NumberStyles]::Float, $inv, [ref]$w)) { $cb += $w; $nc++ }
    if ($iSync -ge 0 -and $c.Count -gt $iSync -and $c[$iSync] -match '^[1-9]') { $vs++ }
    if ($iMode -ge 0 -and $c.Count -gt $iMode) { $modes[$c[$iMode]] = 1 + [int]$modes[$c[$iMode]] }
    if (-not $rt -and $iRt -ge 0 -and $c.Count -gt $iRt) { $rt = $c[$iRt] }
  }
  if ($ft.Count -lt 30) { throw "For få billeder fra $game til en måling. Prøv igen, og bliv inde i spillet hele tiden." }
  # FPS pr. 10 sekunder (i målingens rækkefølge): viser, hvor meget FPS svinger af sig selv
  $seg = New-Object System.Collections.ArrayList; $acc = 0.0; $cnt = 0
  foreach ($v in $ft) { $acc += $v; $cnt++; if ($acc -ge 10000) { [void]$seg.Add([math]::Round(1000.0 * $cnt / $acc, 1)); $acc = 0.0; $cnt = 0 } }
  $arr = $ft.ToArray(); [array]::Sort($arr)
  $total = 0.0; foreach ($v in $arr) { $total += $v }
  $avgFt = $total / $arr.Count
  $med = $arr[[int][math]::Floor(0.5 * ($arr.Count - 1))]
  $p99 = $arr[[int][math]::Floor(0.99 * ($arr.Count - 1))]
  $p999 = $arr[[int][math]::Floor(0.999 * ($arr.Count - 1))]
  $hakLim = [math]::Max(2.5 * $med, $med + 12)
  $hak = 0; foreach ($v in $arr) { if ($v -ge $hakLim) { $hak++ } }
  $secs = $total / 1000.0
  $gpuShare = if ($ng) { ($gb / $ng) / $avgFt } else { $null }
  $cpuShare = if ($nc) { ($cb / $nc) / $avgFt } else { $null }
  $vsShare = if ($nAll) { $vs / $nAll } else { 0 }
  $limit = if ($null -eq $gpuShare) { 'ukendt' } elseif ($gpuShare -ge 0.9) { 'gpu' } elseif ($null -ne $cpuShare -and $cpuShare -ge 0.85) { 'cpu' } elseif ($gpuShare -lt 0.8) { 'cap' } else { 'mixed' }
  $mode = if ($modes.Count) { ($modes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key } else { '' }
  return [pscustomobject]@{
    Date = (Get-Date).ToString('o'); Game = ($game -replace '(?i)\.exe$', ''); Seconds = [math]::Round($secs, 1); Frames = $arr.Count
    Fps = [math]::Round(1000.0 / $avgFt, 1); Low1 = [math]::Round(1000.0 / $p99, 1); Low01 = [math]::Round(1000.0 / $p999, 1)
    Hak = $hak; HakMin = [math]::Round($hak / [math]::Max(0.1, $secs / 60.0), 1)
    Limit = $limit; GpuShare = $(if ($null -ne $gpuShare) { [math]::Round($gpuShare * 100) } else { $null }); CpuShare = $(if ($null -ne $cpuShare) { [math]::Round($cpuShare * 100) } else { $null })
    VSync = [math]::Round($vsShare * 100); Mode = $mode; Runtime = $rt
    Seg = @($seg); W = $(if ($wS.Count) { [math]::Round((($wS | Measure-Object -Average).Average), 1) } else { $null }); Tmax = $(if ($tS.Count) { ($tS | Measure-Object -Maximum).Maximum } else { $null })
    Driver = $ctxDrv; PowerLimit = $ctxPl
  }
}

$MbLookupScript = {
  param($sync, $arg)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $out = New-Object System.Collections.ArrayList
  foreach ($h in @($arg.Hashes)) {
    $sync.Status = 'Spørger MalwareBazaar...'
    $o = [ordered]@{ Hash = $h; Status = ''; Signature = ''; FileName = ''; FirstSeen = ''; Tags = '' }
    try {
      $r = Invoke-RestMethod -Uri 'https://mb-api.abuse.ch/api/v1/' -Method Post -Body @{ query = 'get_info'; hash = $h } -Headers @{ 'Auth-Key' = [string]$arg.Key } -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
      $o.Status = [string]$r.query_status
      if ($r.query_status -eq 'ok' -and $r.data) {
        $d = @($r.data)[0]
        $o.Signature = [string]$d.signature; $o.FileName = [string]$d.file_name; $o.FirstSeen = [string]$d.first_seen; $o.Tags = (@($d.tags) -join ', ')
      }
    } catch {
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      $o.Status = if ($code -eq 401 -or $code -eq 403) { 'auth' } else { 'net: ' + $_.Exception.Message }
    }
    [void]$out.Add([pscustomobject]$o)
  }
  return [pscustomobject]@{ Results = @($out) }
}

# =====================================================================
#  Hvad fylder siden sidst? Måler drev og de mapper, der typisk vokser (kører i baggrunden)
# =====================================================================
$SpaceScanScript = {
  param($sync, $arg)
  $sync.Status = 'Måler, hvad der fylder...'
  $t0 = Get-Date; $budget = 120
  $uprof = [Environment]::GetFolderPath('UserProfile')
  function Get-DirSize([string]$path) {
    $size = [int64]0; $n = 0
    $stack = New-Object System.Collections.Stack; $stack.Push($path)
    while ($stack.Count) {
      if (((Get-Date) - $t0).TotalSeconds -gt $budget) { return @($size, $n, $true) }
      $d = [string]$stack.Pop()
      try { $di = New-Object IO.DirectoryInfo $d; foreach ($f in $di.GetFiles()) { if (([int]$f.Attributes -band 0x400000) -eq 0) { $size += $f.Length }; $n++ } } catch {}   # 0x400000 = kun i skyen (fylder ikke på disken)
      try { foreach ($s in (New-Object IO.DirectoryInfo $d).GetDirectories()) { if (([int]$s.Attributes -band 0x400) -eq 0) { $stack.Push($s.FullName) } } } catch {}   # spring genveje (reparse points) over
    }
    return @($size, $n, $false)
  }
  $roots = New-Object System.Collections.ArrayList
  function Add-Root($p, $label, $kind) { if ($p -and (Test-Path -LiteralPath $p)) { [void]$roots.Add(@{ P = (Resolve-Path -LiteralPath $p).Path; L = $label; K = $kind }) } }
  Add-Root (Join-Path $uprof 'Downloads') 'Overførsler' 'user'
  Add-Root ([Environment]::GetFolderPath('MyVideos')) 'Videoer' 'user'
  Add-Root ([Environment]::GetFolderPath('MyPictures')) 'Billeder' 'user'
  Add-Root ([Environment]::GetFolderPath('MyDocuments')) 'Dokumenter' 'user'
  Add-Root ([Environment]::GetFolderPath('Desktop')) 'Skrivebord' 'user'
  Add-Root ([Environment]::GetFolderPath('MyMusic')) 'Musik' 'user'
  Add-Root $env:TEMP 'Midlertidige filer' 'temp'
  Add-Root "$env:SystemRoot\SoftwareDistribution\Download" 'Windows Update-filer' 'temp'
  foreach ($x in @($arg.Extra)) { Add-Root $x (Split-Path $x -Leaf) 'user' }
  # Spilbiblioteker: Steam (alle biblioteker), Epic, Xbox, EA, Ubisoft, Battle.net
  $libs = New-Object System.Collections.ArrayList
  try {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
    if ($steam) {
      $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
      [void]$libs.Add((Join-Path $steam 'steamapps\common'))
      if (Test-Path $vdf) { foreach ($m in [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) { [void]$libs.Add((Join-Path ($m.Groups[1].Value -replace '\\\\', '\') 'steamapps\common')) } }
    }
  } catch {}
  foreach ($p in "$env:ProgramFiles\Epic Games", "$env:SystemDrive\XboxGames", "$env:ProgramFiles\EA Games", "${env:ProgramFiles(x86)}\Ubisoft\Ubisoft Game Launcher\games", "${env:ProgramFiles(x86)}\Battle.net") { [void]$libs.Add($p) }
  foreach ($l in @($libs | Select-Object -Unique)) { Add-Root $l "Spil ($(Split-Path (Split-Path $l -Parent) -Leaf))" 'games' }

  $folders = New-Object System.Collections.ArrayList
  $i = 0
  foreach ($r in $roots) {
    $i++; $sync.Progress = [double](100 * $i / [math]::Max(1, $roots.Count)); $sync.Status = "Måler $($r.L)..."
    $total = [int64]0
    $kids = @(); try { $kids = @((New-Object IO.DirectoryInfo $r.P).GetDirectories() | Where-Object { ([int]$_.Attributes -band 0x400) -eq 0 }) } catch {}
    foreach ($k in $kids) {
      $res = Get-DirSize $k.FullName
      $total += $res[0]
      if ($res[0] -ge 200MB) { [void]$folders.Add([pscustomobject]@{ Path = $k.FullName; Label = "$($r.L)\$($k.Name)"; Size = $res[0]; Kind = $r.K; Parent = $r.P }) }
    }
    try { foreach ($f in (New-Object IO.DirectoryInfo $r.P).GetFiles()) { if (([int]$f.Attributes -band 0x400000) -eq 0) { $total += $f.Length } } } catch {}
    [void]$folders.Add([pscustomobject]@{ Path = $r.P; Label = $r.L; Size = $total; Kind = $r.K; Parent = '' })
  }
  $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Name = $_.DeviceID; Size = [int64]$_.Size; Free = [int64]$_.FreeSpace } })
  $rb = [int64]0
  foreach ($d in $drives) { $p = "$($d.Name)\`$Recycle.Bin"; if (Test-Path -LiteralPath $p) { $rb += (Get-DirSize $p)[0] } }
  return [pscustomobject]@{ Date = (Get-Date).ToString('s'); Drives = $drives; Folders = @($folders); RecycleBin = $rb; Partial = (((Get-Date) - $t0).TotalSeconds -gt $budget) }
}

$UpdateCheckScript = {
  param($sync, $arg)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $sync.Status = 'Søger efter app-opdatering...'
  # Find den nyeste udgave (commit) via GitHubs API, og hent filerne fra netop den. Så rammer vi aldrig en forældet kopi.
  $m = [regex]::Match($arg.Url, '^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/(.+)$')
  if ($m.Success) {
    try {
      $c = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/{1}/commits/{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value) -UseBasicParsing -TimeoutSec 15 -Headers @{ 'User-Agent' = 'Opticon'; 'Accept' = 'application/vnd.github+json' }
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
    # Sikring: et script med en skrivefejl kan slet ikke starte. Tjek, at PowerShell kan læse det, FØR det installeres.
    if ($f.name -like '*.ps1') {
      $perr = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($out, [ref]$null, [ref]$perr)
      if ($perr -and $perr.Count) { throw "Den nye version af $($f.name) indeholder en fejl (linje $($perr[0].Extent.StartLineNumber): $($perr[0].Message)). Opdateringen er afbrudt, og intet er ændret." }
    }
  }
  $sync.Status = 'Installerer opdatering...'
  # Hele pakken er hentet og tjekket. Nu: sikkerhedskopi af ALLE filer først, så skift ALLE. Fejler én, sættes ALLE tilbage.
  $backup = Join-Path $arg.Dest ("backup-v" + $arg.OldVersion)
  New-Item -ItemType Directory -Force $backup | Out-Null
  $existed = @{}
  foreach ($f in $arg.Files) { $target = Join-Path $arg.Dest $f.name; $existed[$f.name] = Test-Path $target; if ($existed[$f.name]) { Copy-Item -Force $target $backup -ErrorAction Stop } }
  $done = New-Object System.Collections.ArrayList
  try {
    foreach ($f in $arg.Files) {
      $target = Join-Path $arg.Dest $f.name
      $ok = $false
      for ($try = 0; $try -lt 5 -and -not $ok; $try++) {
        try { Copy-Item -Force (Join-Path $tmp $f.name) $target -ErrorAction Stop; $ok = $true } catch { Start-Sleep -Milliseconds 600 }
      }
      if (-not $ok) { throw "Kunne ikke erstatte $($f.name) (filen er i brug). Luk appen, og kør installeren i stedet." }
      [void]$done.Add($f.name)
      Unblock-File $target -ErrorAction SilentlyContinue
    }
  } catch {
    foreach ($n in $done) {   # rul hele pakken tilbage
      $target = Join-Path $arg.Dest $n
      if ($existed[$n]) { Copy-Item -Force (Join-Path $backup $n) $target -ErrorAction SilentlyContinue } else { Remove-Item -Force $target -ErrorAction SilentlyContinue }
    }
    throw "$($_.Exception.Message) Alle filer er sat tilbage til den gamle version."
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


$GpuLibScript = {
  param($sync, $arg)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $sync.Status = 'Henter GPU-eksempler...'
  $j = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/iBlessi/gpu-undervolt-db/main/data/undervolt_results.json' -UseBasicParsing -TimeoutSec 15
  return @($j.results)
}


$GpuBenchHtml = @'
<!doctype html>
<html lang="da"><head><meta charset="utf-8"><title>Opticon GPU-test</title>
<style>
html,body{margin:0;height:100%;background:#000;overflow:hidden;cursor:none}
canvas{width:100vw;height:100vh;display:block}
#o{position:fixed;left:28px;top:22px;font:600 17px "Segoe UI",sans-serif;color:#fff;text-shadow:0 0 8px #000;opacity:.9;line-height:1.5}
#o small{font-weight:400;opacity:.75}
#f{position:fixed;inset:0;display:none;align-items:center;justify-content:center;font:600 30px "Segoe UI",sans-serif;color:#fff;background:#0D0F14}
</style></head>
<body><canvas id="c"></canvas><div id="o">Opticon GPU-test<br><small>Starter…</small></div><div id="f">✓ Færdig. Du kan gå tilbage til Opticon.</div>
<script>
const q = new URLSearchParams(location.search);
let work = parseFloat(q.get('work')) || 0;
const resMode = q.get('res') === '1';   // fast opløsning (1080p/1440p/4K), uafhængig af skærmen
if (resMode) work = 1.0;
const fixed = resMode || work > 0; if (!fixed) work = 1.0;
let remain = null;
const fmtR = x => x == null ? '' : ` · ⏱ ${Math.floor(x / 60)}:${String(x % 60).padStart(2, '0')} tilbage`;
const post = (p, d) => fetch(p, { method: 'POST', body: JSON.stringify(d || {}) }).catch(() => {});
const c = document.getElementById('c'), o = document.getElementById('o');
const gl = c.getContext('webgl2', { antialias: false, powerPreference: 'high-performance', desynchronized: true });
if (!gl) { post('/error', { e: 'WebGL2 er ikke tilgængeligt' }); }
const vs = `#version 300 es
in vec2 p; void main(){ gl_Position = vec4(p, 0., 1.); }`;
const fs = `#version 300 es
precision highp float; uniform vec2 R; uniform float T; out vec4 col;
mat2 rot(float a){ float s = sin(a), c = cos(a); return mat2(c, -s, s, c); }
float map(vec3 p){
  p.xz *= rot(T * .21); p.xy *= rot(T * .13);
  float d = length(max(abs(p) - 1., 0.)); float s = 1.;
  for (int i = 0; i < 5; i++) {
    vec3 a = mod(p * s, 2.) - 1.; s *= 3.;
    vec3 r = abs(1. - 3. * abs(a));
    float da = max(r.x, r.y), db = max(r.y, r.z), dc = max(r.z, r.x);
    d = max(d, (min(da, min(db, dc)) - 1.) / s);
  }
  return d;
}
vec3 nrm(vec3 p){ vec2 e = vec2(.0007, 0.); return normalize(vec3(map(p+e.xyy)-map(p-e.xyy), map(p+e.yxy)-map(p-e.yxy), map(p+e.yyx)-map(p-e.yyx))); }
float shadow(vec3 ro, vec3 rd){ float r = 1., t = .02; for (int i = 0; i < 48; i++) { float h = map(ro + rd * t); r = min(r, 10. * h / t); t += clamp(h, .01, .2); if (h < .0005 || t > 6.) break; } return clamp(r, 0., 1.); }
void main(){
  vec2 uv = (gl_FragCoord.xy * 2. - R) / R.y;
  vec3 ro = vec3(0., 0., 3.0 + sin(T * .3) * .5), rd = normalize(vec3(uv, -1.7));
  float t = 0.; int i;
  for (i = 0; i < 220; i++) { float d = map(ro + rd * t); if (d < .0004 || t > 12.) break; t += d; }
  vec3 c = mix(vec3(.05, .06, .09), vec3(.02, .02, .03), uv.y * .5 + .5);
  if (t < 12.) {
    vec3 p = ro + rd * t, n = nrm(p), l = normalize(vec3(.6, .8, .5));
    float dif = clamp(dot(n, l), 0., 1.) * shadow(p + n * .002, l);
    float ao = 1. - float(i) / 220.;
    vec3 base = mix(vec3(.55, .36, .96), vec3(.23, .62, 1.), .5 + .5 * n.y);
    c = base * (.18 + .82 * dif) * ao + pow(clamp(dot(reflect(rd, n), l), 0., 1.), 24.) * .4;
  }
  col = vec4(pow(c, vec3(.4545)), 1.);
}`;
function sh(t, s){ const x = gl.createShader(t); gl.shaderSource(x, s); gl.compileShader(x); if (!gl.getShaderParameter(x, gl.COMPILE_STATUS)) post('/error', { e: gl.getShaderInfoLog(x) }); return x; }
const pr = gl.createProgram(); gl.attachShader(pr, sh(gl.VERTEX_SHADER, vs)); gl.attachShader(pr, sh(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(pr); gl.useProgram(pr);
const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
const loc = gl.getAttribLocation(pr, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
const uR = gl.getUniformLocation(pr, 'R'), uT = gl.getUniformLocation(pr, 'T');
function resize(){ c.width = Math.max(320, Math.round(innerWidth * devicePixelRatio * work)); c.height = Math.max(180, Math.round(innerHeight * devicePixelRatio * work)); gl.viewport(0, 0, c.width, c.height); }
resize(); addEventListener('resize', resize);
addEventListener('error', e => post('/jserr', { e: String(e.message || e) }));
c.addEventListener('webglcontextlost', e => { e.preventDefault(); post('/lost'); o.innerHTML = 'Opticon GPU-test<br><small>⛔ Grafikdriveren gik ned eller genstartede</small>'; });
addEventListener('keydown', e => { if (e.key === 'Escape') { post('/abort'); o.innerHTML = 'Opticon GPU-test<br><small>Stopper…</small>'; } });
let t0 = performance.now(), last = t0, frames = 0, win = [], winStart = t0, calibUntil = fixed ? 0 : t0 + 7000, done = false, label = '';
// Opløsningstest: scenen tegnes i præcis den valgte opløsning (lærredet får den størrelse og skaleres til skærmen).
// Edge startes uden skærmens Hz-loft, så tallet er rigtige viste billeder pr. sekund (FPS).
let fw = 0, fh = 0, warmUntil = 0;
// Skærmen låser normalt billedet til sin Hz (fx 60). For at måle grafikkortet og ikke skærmen tegnes scenen K gange
// i træk, og der ventes, til grafikkortet er færdigt. (gl.finish venter ikke rigtigt i Edge, så vi læser én pixel
// tilbage, hvilket tvinger browseren til at vente.) Tiden pr. billede giver FPS uden V-Sync, ligesom et spil med
// V-Sync slået fra. K justeres, så hver omgang tager ca. 10 ms, så siden aldrig hænger.
let K = 1, rafs = 0, draws = 0, gpuMs = 0; const px = new Uint8Array(4);
function setRes(str){
  const m = /^(\d+)x(\d+)$/.exec(str || ''); if (!m) return;
  const w = +m[1], h = +m[2]; if (w === fw && h === fh) return;
  fw = w; fh = h; c.width = w; c.height = h; gl.viewport(0, 0, w, h);
  warmUntil = performance.now() + 2500; win = []; rafs = 0; draws = 0; gpuMs = 0; winStart = performance.now();
}
if (resMode) {
  c.style.objectFit = 'contain';
  removeEventListener('resize', resize);
  setRes(q.get('r0') || '1920x1080');
  post('/calib', { work: 0 });
}
try { const dbg = gl.getExtension('WEBGL_debug_renderer_info'); post('/renderer', { r: dbg ? String(gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL)) : String(gl.getParameter(gl.RENDERER)) }); } catch (e) {}
function frame(now){
  if (done) return;
  const dt = now - last; last = now; frames++;
  gl.uniform2f(uR, c.width, c.height);
  rafs++;
  if (resMode) {
    const ts = performance.now();
    for (let k = 0; k < K; k++) { gl.uniform1f(uT, (now - t0) / 1000 + k * 0.004); gl.drawArrays(gl.TRIANGLES, 0, 3); }
    gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);   // venter, til grafikkortet har tegnet alle K billeder
    const g = Math.max(0.01, performance.now() - ts);
    draws += K; gpuMs += g; win.push(g / K);
    if (g < 6 && K < 64) K = Math.min(64, Math.ceil(K * 1.3)); else if (g > 14 && K > 1) K = Math.max(1, Math.floor(K * 0.6));
  } else {
    gl.uniform1f(uT, (now - t0) / 1000); gl.drawArrays(gl.TRIANGLES, 0, 3); win.push(dt);
  }
  if (!resMode && now - winStart >= 1000) {
    const ms = now - winStart, f = win.length, fps = 1000 * f / ms;
    const s = win.slice().sort((a, b) => a - b), p99 = s[Math.min(s.length - 1, Math.floor(s.length * .99))];
    if (calibUntil && now < calibUntil) { calibrate(fps); }
    else { if (calibUntil) { calibUntil = 0; post('/calib', { work }); } post('/fps', { f, ms, p99 }); }
    o.innerHTML = `Opticon GPU-test · ${fps.toFixed(0)} fps<br><small>${calibUntil ? 'Kalibrerer belastning…' : label}${fmtR(remain)} · Esc for at stoppe</small>`;
    win = []; rafs = 0; winStart = now;
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
// Opløsningstest: målingerne sendes hvert sekund af et ur, der ikke afhænger af skærmopdateringerne
if (resMode) setInterval(() => {
  if (done) return;
  const now = performance.now(), f = draws, ms = gpuMs, fps = ms > 0 ? 1000 * f / ms : 0;
  const s = win.slice().sort((a, b) => a - b), p99 = s.length ? s[Math.min(s.length - 1, Math.floor(s.length * .99))] : 0;
  post('/dbg', { K, rafs, f, ms: Math.round(ms), w: fw, h: fh, warm: now < warmUntil });
  if (now >= warmUntil && f > 0) post('/fps', { f, ms, p99 });
  o.innerHTML = `Opticon GPU-test · ${fw}×${fh} · ${fps.toFixed(0)} fps<br><small>${label}${fmtR(remain)} · Esc for at stoppe</small>`;
  win = []; rafs = 0; draws = 0; gpuMs = 0; winStart = now;
}, 1000);
setInterval(() => fetch('/state').then(r => r.json()).then(s => {
  label = s.Label || ''; remain = (typeof s.Remain === 'number' && s.Step > 0) ? s.Remain : null; if (resMode && s.Res) setRes(s.Res); if (s.Done && !done) { done = true; document.getElementById('f').style.display = 'flex'; }
}).catch(() => {}), resMode ? 400 : 1000);
</script></body></html>
'@
# Indbygget GPU-test: lokal webside med 3D-scene (WebGL2) i fuld skærm + målinger via nvidia-smi.
# arg: Html, Steps (watt pr. trin, eller $null = rør ikke strømgrænsen), Work (0 = kalibrer), StepSec, Dir
$GpuBenchScript = {
  param($sync, $arg)
  $ErrorActionPreference = 'Stop'
  $smi = "$env:SystemRoot\System32\nvidia-smi.exe"
  if (-not (Test-Path $smi)) { $smi = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe" }
  $hasSmi = Test-Path $smi   # NVIDIA: alt måles. AMD/Intel: FPS og belastning, og watt for hele pc'en på batteri.
  $inv = [Globalization.CultureInfo]::InvariantCulture
  function Num($x) { $v = 0.0; if ([double]::TryParse(([string]$x).Trim(), [Globalization.NumberStyles]::Float, $inv, [ref]$v)) { $v } else { $null } }
  $gid = if ($arg.GpuId) { [string]$arg.GpuId } else { '0' }   # samme fysiske kort hele vejen (UUID)
  function Q($fields) { @((& $smi -i $gid "--query-gpu=$fields" --format=csv,noheader,nounits 2>$null | Select-Object -First 1) -split ',\s*' | ForEach-Object { Num $_ }) }
  function Sample {
    if ($hasSmi) { $v = Q 'power.draw,temperature.gpu,fan.speed,clocks.gr,utilization.gpu'; return [pscustomobject]@{ W = $v[0]; T = $v[1]; F = $v[2]; C = $v[3]; U = $v[4] } }
    $u = $null; try { $u = [math]::Min(100, [math]::Round((@(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop | Where-Object { $_.Name -like '*engtype_3D*' }) | Measure-Object UtilizationPercentage -Sum).Sum)) } catch {}
    $w = $null; try { $bt = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1; if ($bt -and -not $bt.PowerOnline -and $bt.DischargeRate -gt 0) { $w = [math]::Round($bt.DischargeRate / 1000, 1) } } catch {}
    return [pscustomobject]@{ W = $w; T = $null; F = $null; C = $null; U = $u }
  }
  # Appens egen PcTjek.PowerMode findes allerede (jobbet kører inde i appen), så der skal intet oversættes
  $pmType = 'PcTjek.PowerMode' -as [type]
  if (-not $pmType) { if (-not ('PcTjek.PowerModeB' -as [type])) { try { Add-Type -Namespace PcTjek -Name PowerModeB -MemberDefinition '[DllImport("powrprof.dll")] public static extern uint PowerSetActiveOverlayScheme(Guid g); [DllImport("powrprof.dll")] public static extern uint PowerGetEffectiveOverlayScheme(out Guid g);' } catch {} }; $pmType = 'PcTjek.PowerModeB' -as [type] }
  function Get-PM { try { $g = [guid]::Empty; if ($pmType::PowerGetEffectiveOverlayScheme([ref]$g) -eq 0) { return $g.ToString() } } catch {}; return $null }
  function Set-PM($g) { try { [void]$pmType::PowerSetActiveOverlayScheme([guid]$g) } catch {}; Start-Sleep -Milliseconds 300; return ((Get-PM) -eq ([guid]$g).ToString()) }
  $modeNames = @{ '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'Bedste energieffektivitet'; '00000000-0000-0000-0000-000000000000' = 'Balanceret'; 'ded574b5-45a0-4f42-8737-46345c09c238' = 'Bedste ydeevne' }
  $origMode = Get-PM; $changedMode = $false
  $lim = if ($hasSmi) { Q 'power.limit,power.default_limit,power.min_limit,power.max_limit' } else { @($null, $null, $null, $null) }
  $orig = $lim[0]; $def = $lim[1]
  $browser = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
               "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $browser) { throw 'Hverken Edge eller Chrome blev fundet.' }
  $listener = New-Object Net.HttpListener
  $port = 8760
  while ($true) { try { $listener.Prefixes.Clear(); $listener.Prefixes.Add("http://localhost:$port/"); $listener.Start(); break } catch { $port++; if ($port -gt 8799) { throw 'Ingen ledig port til testen.' } } }
  $resList = @($arg.Res | Where-Object { $_ })
  $script:BState = @{ Step = 0; Total = @($arg.Steps).Count; Label = 'Klargør'; Done = $false; Res = $(if ($resList.Count) { [string]$resList[0] } else { '' }) }
  $script:BFps = New-Object System.Collections.ArrayList
  $script:BAbort = $false; $script:BErr = $null; $script:BLost = $false; $script:BJsErr = ''; $script:BRenderer = ''
  $script:BCur = -1; $script:BMeas = $false; $script:BDiag = New-Object System.Collections.ArrayList
  $script:BStepStart = $null; $script:BLeftAfter = 0; $script:BPerStep = 5 + [double]$arg.StepSec
  function Remain { if (-not $script:BStepStart) { return [int]((@($arg.Steps).Count) * $script:BPerStep) }; [int][math]::Max(0, $script:BLeftAfter + $script:BPerStep - ((Get-Date) - $script:BStepStart).TotalSeconds) }
  function Fmt-Rem([int]$x) { '{0}:{1:00}' -f [math]::Floor($x / 60), ($x % 60) }
  $script:BWork = [double]$arg.Work; $script:BCalib = ($script:BWork -gt 0)
  $script:BTask = $listener.GetContextAsync()
  $htmlBytes = [Text.Encoding]::UTF8.GetBytes([string]$arg.Html)
  function Pump {
    while ($script:BTask.IsCompleted) {
      $ctx = $script:BTask.Result
      $script:BTask = $listener.GetContextAsync()
      $path = $ctx.Request.Url.AbsolutePath; $body = ''
      if ($ctx.Request.HasEntityBody) { $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8); $body = $sr.ReadToEnd(); $sr.Close() }
      $out = [Text.Encoding]::UTF8.GetBytes('ok'); $type = 'text/plain'
      switch ($path) {
        '/'      { $out = $htmlBytes; $type = 'text/html; charset=utf-8' }
        '/state' { $script:BState.Remain = Remain; $out = [Text.Encoding]::UTF8.GetBytes(($script:BState | ConvertTo-Json -Compress)); $type = 'application/json' }
        '/fps'   { try { $j = $body | ConvertFrom-Json; [void]$script:BFps.Add([pscustomobject]@{ Time = [datetime]::Now; Step = [int]$script:BCur; Meas = [bool]$script:BMeas; F = [double]$j.f; Ms = [double]$j.ms; P99 = [double]$j.p99 }) } catch { $script:BJsErr = 'fps-svar: ' + $_.Exception.Message } }
        '/calib' { try { $script:BWork = [double]($body | ConvertFrom-Json).work; $script:BCalib = $true } catch {} }
        '/dbg'   { $script:BDbg = [string]$body; if ($script:BMeas) { $script:BDbgN++; try { $dj = $body | ConvertFrom-Json; if ($null -eq $script:BRafMin -or [int]$dj.rafs -lt $script:BRafMin) { $script:BRafMin = [int]$dj.rafs } } catch {} } }
        '/abort' { $script:BAbort = $true }
        '/lost'  { $script:BLost = $true; $script:BAbort = $true }
        '/renderer' { try { $script:BRenderer = [string]($body | ConvertFrom-Json).r } catch {} }
        '/jserr' { try { $script:BJsErr = [string]($body | ConvertFrom-Json).e } catch {} }
        '/error' { try { $script:BErr = [string]($body | ConvertFrom-Json).e } catch { $script:BErr = 'Fejl i testsiden' }; $script:BAbort = $true }
      }
      try { $ctx.Response.ContentType = $type; $ctx.Response.Headers.Add('Cache-Control', 'no-store'); $ctx.Response.OutputStream.Write($out, 0, $out.Length); $ctx.Response.Close() } catch {}
    }
  }
  function WaitPump([double]$sec) { $end = (Get-Date).AddSeconds($sec); while ((Get-Date) -lt $end -and -not $script:BAbort) { Pump; Start-Sleep -Milliseconds 80 } }
  # Browserens profil skal ligge i din egen mappe: Edge/Chrome kan ikke arbejde i den låste ProgramData-mappe
  $prof = Join-Path $env:LOCALAPPDATA 'PC-Tjek\bench-browser'
  New-Item -ItemType Directory -Force $prof | Out-Null
  $url = "http://localhost:$port/?work=$(([double]$arg.Work).ToString($inv))$(if ($resList.Count) { "&res=1&r0=$($resList[0])" })"
  $bargs = if ($browser -like '*msedge*') { "--kiosk `"$url`" --edge-kiosk-type=fullscreen --user-data-dir=`"$prof`" --no-first-run --no-default-browser-check --disable-features=Translate,CalculateNativeWinOcclusion --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling --disable-gpu-vsync --disable-frame-rate-limit" }
           else { "--kiosk --user-data-dir=`"$prof`" --no-first-run --no-default-browser-check --disable-features=Translate,CalculateNativeWinOcclusion --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling --disable-gpu-vsync --disable-frame-rate-limit `"$url`"" }
  $results = New-Object System.Collections.ArrayList
  $changedPl = $false
  try {
    $sync.Status = 'Starter testscenen...'
    Start-Process -FilePath $browser -ArgumentList $bargs | Out-Null
    $tw = (Get-Date).AddSeconds(25)
    while ($script:BFps.Count -eq 0 -and -not $script:BCalib -and (Get-Date) -lt $tw -and -not $script:BAbort) { Pump; Start-Sleep -Milliseconds 100 }
    if (-not $script:BCalib) { $sync.Status = 'Kalibrerer belastning...'; $tw = (Get-Date).AddSeconds(15); while (-not $script:BCalib -and (Get-Date) -lt $tw -and -not $script:BAbort) { Pump; Start-Sleep -Milliseconds 100 } }
    if ($script:BErr) { throw "Testsiden fejlede: $($script:BErr)" }
    if (-not $script:BCalib -and $script:BFps.Count -eq 0) { throw 'Testscenen startede ikke. Er Edge eller Chrome blokeret?' }
    $steps = @($arg.Steps); $total = $steps.Count
    for ($i = 0; $i -lt $total; $i++) {
      if ($script:BAbort) { break }
      $pl = $steps[$i]
      $script:BState.Step = $i + 1
      $script:BStepStart = Get-Date; $script:BLeftAfter = ($total - $i - 1) * $script:BPerStep
      $rs = if ($resList.Count) { [string]$arg.Res[$i] } else { '' }
      $script:BState.Res = $rs
      $resTxt = if ($rs) { " · $($rs -replace 'x', '×')" } else { '' }
      $applied = $true
      $md = if ($arg.Modes) { [string]@($arg.Modes)[$i] } else { '' }
      if ($md) {
        if (-not $changedMode -and $arg.RestoreFile -and $origMode) { [IO.File]::WriteAllText([string]$arg.RestoreFile, (@{ Overlay = $origMode; Pid = $PID; Date = (Get-Date).ToString('s') } | ConvertTo-Json -Compress)) }
        $applied = Set-PM $md; $changedMode = $true   # bekræftet ved at læse tilstanden tilbage
      }
      $script:BState.Label = if ($md) { "Trin $($i + 1)/$total · $($modeNames[$md])" } elseif ($pl -and $rs) { "Trin $($i + 1)/$total$resTxt · $([math]::Round($pl)) W" } elseif ($rs) { "Trin $($i + 1)/$total$resTxt" } elseif ($pl) { "Trin $($i + 1)/$total · strømgrænse $([math]::Round($pl / $def * 100)) %" } else { 'Måler' }
      if ($pl) {
        if (-not $changedPl -and $arg.RestoreFile -and $orig) {   # gem den oprindelige værdi FØR første ændring
          [IO.File]::WriteAllText([string]$arg.RestoreFile, (@{ Watts = [int][math]::Round($orig); Uuid = $gid; Pid = $PID; Date = (Get-Date).ToString('s') } | ConvertTo-Json -Compress))
        }
        & $smi -i $gid -pl ([math]::Round($pl)) 2>&1 | Out-Null; $changedPl = $true
        Start-Sleep -Milliseconds 300; $nowPl = (Q 'power.limit')[0]
        $applied = ($null -ne $nowPl -and [math]::Abs($nowPl - [math]::Round($pl)) -le 2)   # bekræftet ved at læse grænsen tilbage
      }
      $sync.Status = "$($script:BState.Label): stabiliserer... · ⏱ $(Fmt-Rem (Remain)) tilbage"
      WaitPump 5
      Pump   # alt, der kom under stabiliseringen, tæller ikke med
      $script:BCur = $i; $script:BMeas = $true; $script:BDbgN = 0; $script:BRafMin = $null
      $t0 = Get-Date; $samples = New-Object System.Collections.ArrayList; $nextS = $t0
      while (((Get-Date) - $t0).TotalSeconds -lt [double]$arg.StepSec -and -not $script:BAbort) {
        Pump
        if ((Get-Date) -ge $nextS) {
          $sm = Sample
          [void]$samples.Add($sm)
          $nextS = $nextS.AddSeconds(1)
          $el = ((Get-Date) - $t0).TotalSeconds
          $sync.Progress = [double](100 * ($i + [math]::Min(1, $el / [double]$arg.StepSec)) / $total)
          $lastF = $script:BFps | Select-Object -Last 1
          $sync.Status = "$($script:BState.Label) · $(if ($lastF) { [math]::Round(1000 * $lastF.F / [math]::Max(1, $lastF.Ms)) } else { '–' }) fps$(if ($null -ne $sm.W) { " · $([int]$sm.W) W" })$(if ($null -ne $sm.T) { " · $([int]$sm.T) °C" })$(if ($null -ne $sm.U -and -not $hasSmi) { " · belastning $($sm.U) %" }) · ⏱ $(Fmt-Rem (Remain)) tilbage"
        }
        Start-Sleep -Milliseconds 80
      }
      Pump; $script:BMeas = $false
      $t1 = Get-Date
      # Målingerne fra dette trin (mærket med trinnummer, ikke tid, så urets opløsning ikke kan drille)
      $fw = @($script:BFps | Where-Object { $_.Meas -and $_.Step -eq $i -and $_.Ms -gt 0 })
      if (-not $fw.Count) { $fw = @($script:BFps | Where-Object { $_.Time -ge $t0.AddSeconds(-1) -and $_.Ms -gt 0 }) }   # reserve
      $avg = { param($prop) $x = @($samples | ForEach-Object { $_.$prop } | Where-Object { $null -ne $_ }); if ($x.Count) { [math]::Round(($x | Measure-Object -Average).Average, 1) } else { $null } }
      $fps = if ($fw.Count) { [math]::Round(1000 * ($fw | Measure-Object F -Sum).Sum / [math]::Max(1, ($fw | Measure-Object Ms -Sum).Sum), 1) } else { $null }
      $p1 = if ($fw.Count) { [math]::Round(1000 / [math]::Max(0.1, ($fw | Measure-Object P99 -Average).Average), 1) } else { $null }
      $tx = @($samples | ForEach-Object { $_.T } | Where-Object { $null -ne $_ }); $cx = @($samples | ForEach-Object { $_.C } | Where-Object { $_ })
      $secF = @($fw | Where-Object { $_.Ms -gt 0 } | ForEach-Object { 1000 * $_.F / $_.Ms })
      [void]$script:BDiag.Add("trin $($i + 1): $($fw.Count) af $($script:BFps.Count) målinger, $([math]::Round(($t1 - $t0).TotalSeconds)) sek, fps=$fps, sidesignaler=$($script:BDbgN), færrest billeder/s=$($script:BRafMin), sidst: $($script:BDbg)")
      [void]$results.Add([pscustomobject]@{ Tmax = $(if ($tx.Count) { ($tx | Measure-Object -Maximum).Maximum } else { $null }); Cmin = $(if ($cx.Count) { ($cx | Measure-Object -Minimum).Minimum } else { $null }); FpsMin = $(if ($secF.Count) { [math]::Round(($secF | Measure-Object -Minimum).Minimum, 1) } else { $null }); Res = $rs; Mode = $md; Applied = $applied; Pl = $pl; Pct = $(if ($pl -and $def) { [math]::Round($pl / $def * 100) } else { $null }); W = (& $avg 'W'); T = (& $avg 'T'); F = (& $avg 'F'); C = (& $avg 'C'); U = (& $avg 'U'); Fps = $fps; P1 = $p1 })
    }
  } finally {
    # Gendan altid det oprindelige, og fjern først gendannelsesfilen, når det er BEKRÆFTET
    $okRestore = $true
    if ($changedPl -and $orig) {
      & $smi -i $gid -pl ([math]::Round($orig)) 2>&1 | Out-Null; Start-Sleep -Milliseconds 300
      $now = (Q 'power.limit')[0]; if ($null -eq $now -or [math]::Abs($now - $orig) -gt 2) { $okRestore = $false }
    }
    if ($changedMode -and $origMode) { if (-not (Set-PM $origMode)) { $okRestore = $false } }
    if ($arg.RestoreFile -and $okRestore) { Remove-Item -LiteralPath ([string]$arg.RestoreFile) -Force -ErrorAction SilentlyContinue }
    $script:BState.Done = $true
    try { WaitPump 1.5 } catch {}
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$prof*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
    try { $listener.Stop(); $listener.Close() } catch {}
  }
  return @{ Steps = @($results); Diag = (@($script:BDiag) -join ' · ') + " · trin i alt: $(@($arg.Steps).Count)"; FpsPosts = $script:BFps.Count; Renderer = $script:BRenderer; Calib = $script:BCalib; JsErr = $script:BJsErr; Browser = (Split-Path $browser -Leaf); Work = $script:BWork; Aborted = $script:BAbort; Lost = $script:BLost; HasSmi = $hasSmi; OrigMode = $origMode; RestoreOk = $okRestore; Orig = $orig; Default = $def; Min = $lim[2]; Max = $lim[3] }
}

# =====================================================================
#  GUI
# =====================================================================

# =====================================================================
#  DEN STORE TEST (CPU, RAM, disk). Grafikdelen kører bagefter med testscenen.
# =====================================================================
$BenchCs = @'
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;

namespace OptiBench
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
'@
$BenchScript = {
  param($sync, $arg)
  $ErrorActionPreference = 'Stop'
  if (-not ('OptiBench.Cpu' -as [type])) { Add-Type -TypeDefinition $arg.Code -Language CSharp }
  $sync.Status = 'Læser hardware...'; $sync.Progress = 1
  $cpuO = Get-CimInstance Win32_Processor | Select-Object -First 1
  $cpuName = (([string]$cpuO.Name) -replace '\((R|TM|tm)\)', '' -replace '\s+CPU\s*@.*$', '' -replace '\s+\d+-Core Processor', '' -replace '\s+', ' ').Trim()
  $vids = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch '(?i)basic|virtual|remote|parsec|meta|mirage|displaylink' })
  $gpuO = $vids | Where-Object { $_.Name -match '(?i)nvidia|radeon rx|radeon pro|arc a|arc b' } | Select-Object -First 1
  if (-not $gpuO) { $gpuO = $vids | Select-Object -First 1 }
  $cs = Get-CimInstance Win32_ComputerSystem
  $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB)
  $ramMHz = (Get-CimInstance Win32_PhysicalMemory | Measure-Object ConfiguredClockSpeed -Maximum).Maximum
  $diskName = ''; try { $pn = Get-Partition -DriveLetter ($env:SystemDrive.Substring(0, 1)) | Select-Object -First 1; $diskName = (Get-Disk -Number $pn.DiskNumber).FriendlyName } catch {}
  $laptop = ($cs.PCSystemType -eq 2)
  $onBattery = $false; try { $bt = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1; if ($bt) { $onBattery = -not $bt.PowerOnline } } catch {}
  $threads = [Environment]::ProcessorCount
  $hw = [ordered]@{ Cpu = $cpuName; Cores = [int]$cpuO.NumberOfCores; Threads = $threads; Gpu = [string]$gpuO.Name; RamGB = $ramGB; RamMHz = [int]$ramMHz; Disk = [string]$diskName; Laptop = $laptop; OnBattery = $onBattery }

  # CPU: én kerne
  $sync.Status = "CPU · én kerne (10 sek.)"; $sync.Progress = 3
  [void][OptiBench.Cpu]::Run(1, 1.0)   # opvarmning
  $one = [OptiBench.Cpu]::Run(1, 10.0)
  $sync.Progress = 16
  # CPU: alle kerner i 60 sek. Første 10 sek. = topydelse, sidste 10 sek. = varm pc
  $buckets = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt 12; $i++) {
    $sync.Status = "CPU · alle $threads tråde · $([int](60 - $i * 5)) sek. tilbage (holder den farten, når den bliver varm?)"
    [void]$buckets.Add([OptiBench.Cpu]::Run($threads, 5.0))
    $sync.Progress = 16 + ($i + 1) * 5
  }
  $multi = ($buckets[0] + $buckets[1]) / 2
  $hot = ($buckets[10] + $buckets[11]) / 2
  $sustain = [math]::Round(100 * $hot / [math]::Max(1, $multi))
  # RAM
  $sync.Status = 'RAM · kopierer store blokke...'; $sync.Progress = 77
  $ram = [OptiBench.Mem]::CopyGBs([math]::Min(4, $threads), 3.0)
  # Disk
  $sync.Status = 'Disk · skriver og læser en testfil på 512 MB (uden Windows-cache)...'; $sync.Progress = 82
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('opticon-disktest-' + [guid]::NewGuid().ToString('N') + '.tmp')
  $d = @(0, 0, 0)
  try { $d = [OptiBench.Disk]::Test($tmp, 512, 3.0) } catch { $sync.Status = "Disktesten fejlede: $($_.Exception.Message)" } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  $sync.Progress = 100
  return @{ Hw = $hw; Cpu1 = [math]::Round($one); CpuN = [math]::Round($multi); Sustain = $sustain; Ram = [math]::Round($ram, 1)
            DiskW = [math]::Round($d[0]); DiskR = [math]::Round($d[1]); Iops = [math]::Round($d[2]) }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Opticon" Width="1280" Height="820" MinWidth="1050" MinHeight="650" WindowStartupLocation="CenterScreen"
        Foreground="#E7E9EE" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13">
  <Window.Background>
    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#0C0E14" Offset="0"/><GradientStop Color="#110F1B" Offset="1"/></LinearGradientBrush>
  </Window.Background>
  <Window.Resources>
    <SolidColorBrush x:Key="Card" Color="#141823"/>
    <SolidColorBrush x:Key="Line" Color="#20263A"/>
    <SolidColorBrush x:Key="Muted" Color="#8C95A9"/>
    <LinearGradientBrush x:Key="Accent" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#8B5CF6" Offset="0"/><GradientStop Color="#6D7CFF" Offset="0.55"/><GradientStop Color="#3B9EFF" Offset="1"/>
    </LinearGradientBrush>

    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#E7E9EE"/><Setter Property="Background" Value="#1E2433"/>
      <Setter Property="Padding" Value="14,8"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid x:Name="root">
              <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="10"/>
              <Border x:Name="hv" CornerRadius="10" Background="#16FFFFFF" Visibility="Hidden"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="hv" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="hv" Property="Background" Value="#26000000"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="root" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource Accent}"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="White"/>
      <Setter Property="Effect"><Setter.Value><DropShadowEffect Color="#7C5CFF" BlurRadius="16" ShadowDepth="0" Opacity="0.35"/></Setter.Value></Setter>
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
              <Border x:Name="bd" Background="Transparent" CornerRadius="10" Padding="14,10">
                <ContentPresenter/>
              </Border>
              <Border x:Name="bar" Width="3" CornerRadius="2" HorizontalAlignment="Left" Margin="0,9" Background="{StaticResource Accent}" Visibility="Collapsed"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#151925"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#2A2152" Offset="0"/><GradientStop Color="#161B28" Offset="1"/></LinearGradientBrush></Setter.Value></Setter>
                <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CardB" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Card}"/><Setter Property="CornerRadius" Value="16"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="18"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock"><Setter Property="FontSize" Value="26"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
    <Style x:Key="Sub" TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="TextWrapping" Value="Wrap"/></Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#10131A"/><Setter Property="Foreground" Value="#E7E9EE"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/><Setter Property="Padding" Value="8,5"/><Setter Property="CaretBrush" Value="#E7E9EE"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E7E9EE"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
        <StackPanel x:Name="root" Orientation="Horizontal" Background="Transparent">
          <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" BorderBrush="#3A4358" Background="#0F1219" VerticalAlignment="Center">
            <Path x:Name="mark" Data="M3.2,8.6 L6.8,12.2 L13.2,4.8" Stroke="White" StrokeThickness="2.2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
          </Border>
          <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="#6B74A0"/></Trigger>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/><Setter TargetName="box" Property="BorderBrush" Value="Transparent"/><Setter TargetName="mark" Property="Visibility" Value="Visible"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="root" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E7E9EE"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <StackPanel x:Name="root" Orientation="Horizontal" Background="Transparent">
          <Grid Width="18" Height="18" VerticalAlignment="Center">
            <Ellipse x:Name="ring" Stroke="#3A4358" StrokeThickness="1.5" Fill="#0F1219"/>
            <Ellipse x:Name="dot" Width="8" Height="8" Fill="White" Visibility="Collapsed"/>
          </Grid>
          <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ring" Property="Stroke" Value="#6B74A0"/></Trigger>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="ring" Property="Fill" Value="{StaticResource Accent}"/><Setter TargetName="ring" Property="Stroke" Value="Transparent"/><Setter TargetName="dot" Property="Visibility" Value="Visible"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="root" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#1C2130"/><Setter Property="Foreground" Value="#E7E9EE"/><Setter Property="BorderBrush" Value="#2E3546"/><Setter Property="Padding" Value="10,6"/>
    </Style>
    <Style x:Key="ThumbS" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
        <Border x:Name="t" Background="#2C3344" CornerRadius="4"/>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="#465070"/></Trigger>
          <Trigger Property="IsDragging" Value="True"><Setter TargetName="t" Property="Background" Value="#7C5CFF"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Width" Value="10"/><Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
        <Grid Background="Transparent" Margin="2"><Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True"><Track.Thumb><Thumb Style="{StaticResource ThumbS}"/></Track.Thumb></Track></Grid>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/><Setter Property="Height" Value="10"/><Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent" Margin="2"><Track x:Name="PART_Track" Orientation="Horizontal"><Track.Thumb><Thumb Style="{StaticResource ThumbS}"/></Track.Thumb></Track></Grid>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="DataGridRow">
      <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#181D2A"/></Trigger></Style.Triggers>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="#E7E9EE"/>
      <Setter Property="RowBackground" Value="Transparent"/><Setter Property="AlternatingRowBackground" Value="#111520"/>
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
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#2B2555"/><Setter Property="Foreground" Value="White"/></Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="236"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

    <!-- ===== Sidemenu ===== -->
    <Border BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
      <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#0A0B11" Offset="0"/><GradientStop Color="#0E0C19" Offset="1"/></LinearGradientBrush></Border.Background>
      <Grid Margin="14,20,14,16">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Orientation="Horizontal" Margin="8,0,0,22">
          <Grid Width="40" Height="40">
            <Border Name="LogoTile" CornerRadius="10" Background="{StaticResource Accent}" Margin="3">
              <TextBlock Text="✓" FontSize="19" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="White"/>
            </Border>
            <Image Name="LogoImg" RenderOptions.BitmapScalingMode="HighQuality"/>
          </Grid>
          <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="Opticon" FontSize="19" FontWeight="SemiBold"/>
            <TextBlock Name="VerText" Text="v2.0" FontSize="11" Foreground="{StaticResource Muted}"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Row="1">
          <RadioButton Name="NavHome"    Style="{StaticResource Nav}" GroupName="nav" IsChecked="True" Content="🏠   Overblik"/>
          <RadioButton Name="NavTweaks"  Style="{StaticResource Nav}" GroupName="nav" Content="⚡   Optimering"/>
          <RadioButton Name="NavBench"   Style="{StaticResource Nav}" GroupName="nav" Content="🏁   Benchmark"/>
          <RadioButton Name="NavHelped"  Style="{StaticResource Nav}" GroupName="nav" Content="✅   Hjalp det?"/>
          <RadioButton Name="NavModes"   Style="{StaticResource Nav}" GroupName="nav" Content="🎮   Tilstande"/>
          <RadioButton Name="NavVagt"    Style="{StaticResource Nav}" GroupName="nav" Content="🛡   Vagt"/>
          <RadioButton Name="NavSecure"  Style="{StaticResource Nav}" GroupName="nav" Content="🔐   Sikkerhedstjek"/>
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
          <Border Name="ModeSide" Visibility="Collapsed" CornerRadius="12" Background="#1B1630" BorderBrush="#8B5CF6" BorderThickness="1" Padding="12,10" Margin="0,0,0,10" Cursor="Hand" ToolTip="Klik for at se, hvad Opticon har gjort">
            <StackPanel>
              <TextBlock Name="ModeSideTitle" FontWeight="SemiBold" TextWrapping="Wrap"/>
              <TextBlock Name="ModeSideSub" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,8"/>
              <Button Name="BtnModeStopSide" Content="⏹  Afslut og gendan" Padding="10,6" Margin="0" FontSize="12"/>
            </StackPanel>
          </Border>
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
            <Button Name="BtnScan" Style="{StaticResource Primary}" Content="🔍   Scan pc'en" Padding="18,11" FontSize="14"/>
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



      <!-- HJALP DET? -->
      <Grid Name="PageHelped" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <StackPanel Margin="0,0,0,14">
          <TextBlock Style="{StaticResource H1}" Text="Hjalp det?"/>
          <TextBlock Style="{StaticResource Sub}" Text="Alle dine ændringer samlet med en måling før og efter. Opstart måles ved de næste opstarter, oprydning som ledig plads, GPU-profiler med samme test, og alt andet med den store test."/>
        </StackPanel>
        <Border Grid.Row="1" Style="{StaticResource CardB}" Padding="18,14" Margin="0,0,0,14">
          <DockPanel>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
              <Button Name="BtnHelpedGame" Content="🔬  Test en ændring i et spil" Margin="12,0,8,0"/>
              <Button Name="BtnHelpedBench" Content="📌  Jeg har ændret noget: hjalp det?" Style="{StaticResource Primary}" Margin="0"/>
            </StackPanel>
            <StackPanel>
              <TextBlock Name="HelpedSummary" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap" Text="Ingen ændringer registreret endnu."/>
              <TextBlock Name="HelpedSub" Style="{StaticResource Sub}" FontSize="12" Margin="0,4,0,0" Text="Har du fx ændret noget i BIOS, Afterburner eller Windows? Tryk på knappen. Opticon kører den store test og sammenligner med testen før ændringen."/>
            </StackPanel>
          </DockPanel>
        </Border>
        <Border Grid.Row="2" Style="{StaticResource CardB}" Padding="6">
          <DataGrid Name="GridHelped" IsReadOnly="True">
            <DataGrid.Columns>
              <DataGridTextColumn Header="DATO" Binding="{Binding Navn}" Width="105"/>
              <DataGridTextColumn Header="ÆNDRING" Binding="{Binding Info}" Width="2.2*"/>
              <DataGridTextColumn Header="FØR" Binding="{Binding Note}" Width="1.3*"/>
              <DataGridTextColumn Header="EFTER" Binding="{Binding Gruppe}" Width="1.3*"/>
              <DataGridTextColumn Header="HJALP DET?" Binding="{Binding Status}" Width="2.6*">
                <DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style></DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
            </DataGrid.Columns>
          </DataGrid>
        </Border>
      </Grid>
      <!-- BENCHMARK -->
      <Grid Name="PageBench" Visibility="Collapsed">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="0,0,8,0">
          <TextBlock Style="{StaticResource H1}" Text="Benchmark"/>
          <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,16" Text="Én stor test af hele pc'en: processor, hukommelse, disk og grafik (1080p, din skærm og 4K). Ca. 4 minutter. Resultaterne gemmes, så du kan følge din pc over tid og sammenligne med andre med samme hardware."/>
          <Border Style="{StaticResource CardB}" Padding="22,18" Margin="0,0,0,14">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <StackPanel VerticalAlignment="Center">
                <TextBlock Text="OPTICON-SCORE" FontSize="11" Foreground="{StaticResource Muted}"/>
                <TextBlock Name="BenchScore" Text="–" FontSize="48" FontWeight="Bold" Foreground="#A78BFA"/>
                <TextBlock Name="BenchScoreSub" Text="ikke testet endnu" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap"/>
              </StackPanel>
              <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                <TextBlock Name="BenchHw" Foreground="#C3CAD6" TextWrapping="Wrap" Margin="0,0,0,10"/>
                <StackPanel Orientation="Horizontal">
                  <Button Name="BtnBench" Content="🏁  Kør den store test (ca. 4 min)" Style="{StaticResource Primary}" Padding="18,11"/>
                </StackPanel>
                <ProgressBar Name="BenchBar" Height="6" Maximum="100" Margin="0,12,0,0" Foreground="{StaticResource Accent}" Background="#242A39" BorderThickness="0" Visibility="Collapsed"/>
                <TextBlock Name="BenchStatus" Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0"/>
              </StackPanel>
            </Grid>
          </Border>
          <UniformGrid Columns="3" Margin="0,0,-10,4">
              <Border Style="{StaticResource CardB}" Margin="0,0,10,10" Padding="16,14"><StackPanel>
                <TextBlock Text="CPU · ÉN KERNE" FontSize="11" Foreground="{StaticResource Muted}"/>
                <TextBlock Name="BCpu1" Text="–" FontSize="24" FontWeight="Bold" Margin="0,4,0,0"/>
                <TextBlock Name="BCpu1Sub" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,0"/>
              </StackPanel></Border>
              <Border Style="{StaticResource CardB}" Margin="0,0,10,10" Padding="16,14"><StackPanel>
                <TextBlock Text="CPU · ALLE KERNER" FontSize="11" Foreground="{StaticResource Muted}"/>
                <TextBlock Name="BCpuN" Text="–" FontSize="24" FontWeight="Bold" Margin="0,4,0,0"/>
                <TextBlock Name="BCpuNSub" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,0"/>
              </StackPanel></Border>
              <Border Style="{StaticResource CardB}" Margin="0,0,10,10" Padding="16,14"><StackPanel>
                <TextBlock Text="HOLDER FARTEN (VARM)" FontSize="11" Foreground="{StaticResource Muted}"/>
                <TextBlock Name="BSus" Text="–" FontSize="24" FontWeight="Bold" Margin="0,4,0,0"/>
                <TextBlock Name="BSusSub" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,0"/>
              </StackPanel></Border>
              <Border Style="{StaticResource CardB}" Margin="0,0,10,10" Padding="16,14"><StackPanel>
                <TextBlock Text="HUKOMMELSE" FontSize="11" Foreground="{StaticResource Muted}"/>
                <TextBlock Name="BRam" Text="–" FontSize="24" FontWeight="Bold" Margin="0,4,0,0"/>
                <TextBlock Name="BRamSub" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,0"/>
              </StackPanel></Border>
              <Border Style="{StaticResource CardB}" Margin="0,0,10,10" Padding="16,14"><StackPanel>
                <TextBlock Text="DISK" FontSize="11" Foreground="{StaticResource Muted}"/>
                <TextBlock Name="BDisk" Text="–" FontSize="24" FontWeight="Bold" Margin="0,4,0,0"/>
                <TextBlock Name="BDiskSub" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,0"/>
              </StackPanel></Border>
              <Border Style="{StaticResource CardB}" Margin="0,0,10,10" Padding="16,14"><StackPanel>
                <TextBlock Name="BGpuTitle" Text="GRAFIK · FPS" FontSize="11" Foreground="{StaticResource Muted}"/>
                <TextBlock Name="BGpu" Text="–" FontSize="24" FontWeight="Bold" Margin="0,4,0,0"/>
                <TextBlock Name="BGpuSub" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,0"/>
              </StackPanel></Border>
          </UniformGrid>
          <Border Name="BenchAdviceBox" Visibility="Collapsed" CornerRadius="16" Background="#141B2A" BorderBrush="#2C4A7A" BorderThickness="1" Padding="20,16" Margin="0,0,0,14">
            <StackPanel>
              <TextBlock Text="🩺  Hvad betyder dine tal?" FontSize="16" FontWeight="SemiBold"/>
              <TextBlock Name="BenchAdvice" TextWrapping="Wrap" Margin="0,8,0,0" LineHeight="21" Foreground="#C3CAD6"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource CardB}" Padding="20,16" Margin="0,0,0,14">
            <StackPanel>
              <DockPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top">
                  <ComboBox Name="GameDur" Width="110" Margin="0,0,8,0" SelectedIndex="1">
                    <ComboBoxItem Content="30 sek"/><ComboBoxItem Content="60 sek"/><ComboBoxItem Content="2 min"/>
                  </ComboBox>
                  <Button Name="BtnGameAb" Content="🔬  Hjalp det i mit spil?" Margin="0,0,8,0"/>
                  <Button Name="BtnGameMeasure" Content="🎮  Mål i mit spil" Style="{StaticResource Primary}" Margin="0"/>
                </StackPanel>
                <StackPanel>
                  <TextBlock Text="🎮  Mål i mit spil" FontSize="16" FontWeight="SemiBold"/>
                  <TextBlock Name="GameSub" Style="{StaticResource Sub}" Margin="0,4,0,0" Text="Rigtig FPS, 1 % low og hak i dit eget spil, målt med Intels gratis PresentMon. Start spillet, tryk på knappen, og skift til spillet. Du hører et bip, når målingen starter, og igen når den stopper."/>
                </StackPanel>
              </DockPanel>
              <Border Name="GameAbBox" Visibility="Collapsed" CornerRadius="10" Background="#1B1630" BorderBrush="#8B5CF6" BorderThickness="1" Padding="14,12" Margin="0,12,0,0">
                <DockPanel>
                  <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button Name="BtnGameAbNext" Content="Mål EFTER" Style="{StaticResource Primary}" Margin="12,0,8,0"/>
                    <Button Name="BtnGameAbCancel" Content="Annullér" Margin="0"/>
                  </StackPanel>
                  <StackPanel>
                    <TextBlock Name="GameAbTitle" FontWeight="SemiBold" TextWrapping="Wrap"/>
                    <TextBlock Name="GameAbText" Style="{StaticResource Sub}" Margin="0,4,0,0" LineHeight="20"/>
                  </StackPanel>
                </DockPanel>
              </Border>
              <UniformGrid Name="GameTiles" Columns="4" Margin="0,12,0,0" Visibility="Collapsed">
                <StackPanel Margin="0,0,10,0"><TextBlock Text="GENNEMSNIT" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GameFps" FontSize="24" FontWeight="Bold"/><TextBlock Name="GameFpsSub" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/></StackPanel>
                <StackPanel Margin="0,0,10,0"><TextBlock Text="1 % LOW" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GameLow" FontSize="24" FontWeight="Bold"/><TextBlock Name="GameLowSub" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/></StackPanel>
                <StackPanel Margin="0,0,10,0"><TextBlock Text="HAK PR. MINUT" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GameHak" FontSize="24" FontWeight="Bold"/><TextBlock Name="GameHakSub" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/></StackPanel>
                <StackPanel><TextBlock Text="HVAD BREMSER?" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GameLimit" FontSize="18" FontWeight="Bold" TextWrapping="Wrap" Margin="0,4,0,0"/></StackPanel>
              </UniformGrid>
              <TextBlock Name="GameAdvice" Visibility="Collapsed" TextWrapping="Wrap" Margin="0,12,0,0" LineHeight="21" Foreground="#C3CAD6"/>
              <DataGrid Name="GridGameHist" IsReadOnly="True" Margin="0,12,0,0" MaxHeight="220" Visibility="Collapsed">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="DATO" Binding="{Binding Navn}" Width="1.1*"/>
                  <DataGridTextColumn Header="SPIL" Binding="{Binding Gruppe}" Width="1.3*"/>
                  <DataGridTextColumn Header="FPS" Binding="{Binding Info}" Width="0.8*"/>
                  <DataGridTextColumn Header="1 % LOW" Binding="{Binding Status}" Width="0.8*"/>
                  <DataGridTextColumn Header="HAK/MIN" Binding="{Binding Sti}" Width="0.7*"/>
                  <DataGridTextColumn Header="MOD SIDST" Binding="{Binding Note}" Width="1.6*"/>
                </DataGrid.Columns>
              </DataGrid>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource CardB}" Padding="20,16" Margin="0,0,0,14">
            <StackPanel>
              <DockPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top">
                  <Button Name="BtnBenchGb" Content="🔎  Se andre i Geekbench"/>
                  <Button Name="BtnBenchShare" Content="🌍  Del mit resultat" Style="{StaticResource Primary}" Margin="0" IsEnabled="False"/>
                </StackPanel>
                <TextBlock Text="🌍  Andre med samme hardware" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center"/>
              </DockPanel>
              <TextBlock Style="{StaticResource Sub}" FontSize="11.5" Margin="0,6,0,0" Text="🔓 Del mit resultat: deles offentligt som et opslag under din GitHub-konto. Kun hardware og testtal, ingen navne eller filer. Kun fulde tests tilsluttet strøm kan deles."/>
              <TextBlock Name="BenchCmpText" Style="{StaticResource Sub}" Margin="0,8,0,0" Text="Kør testen for at se, hvordan din pc klarer sig mod andre med samme processor og grafikkort."/>
              <DataGrid Name="GridBenchCmp" IsReadOnly="True" Margin="0,10,0,0" Visibility="Collapsed">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="TEST" Binding="{Binding Navn}" Width="1.6*"/>
                  <DataGridTextColumn Header="DIG" Binding="{Binding Info}" Width="1*"/>
                  <DataGridTextColumn Header="ANDRE (MEDIAN)" Binding="{Binding Note}" Width="1.2*"/>
                  <DataGridTextColumn Header="FORSKEL" Binding="{Binding Status}" Width="1*"/>
                  <DataGridTextColumn Header="SAMMENLIGNET MED" Binding="{Binding Gruppe}" Width="2.2*"/>
                </DataGrid.Columns>
              </DataGrid>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource CardB}" Padding="20,16" Margin="0,0,0,14">
            <StackPanel>
              <TextBlock Text="📈  Din historik" FontSize="16" FontWeight="SemiBold"/>
              <TextBlock Name="BenchHistEmpty" Style="{StaticResource Sub}" Margin="0,8,0,0" Text="Ingen tests endnu."/>
              <DataGrid Name="GridBenchHist" IsReadOnly="True" Margin="0,10,0,0" MaxHeight="260" Visibility="Collapsed">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="DATO" Binding="{Binding Navn}" Width="1.2*"/>
                  <DataGridTextColumn Header="SCORE" Binding="{Binding Info}" Width="0.8*"/>
                  <DataGridTextColumn Header="CPU 1 / ALLE" Binding="{Binding Note}" Width="1.3*"/>
                  <DataGridTextColumn Header="GRAFIK" Binding="{Binding Status}" Width="0.8*"/>
                  <DataGridTextColumn Header="DISK LÆS" Binding="{Binding Gruppe}" Width="0.9*"/>
                  <DataGridTextColumn Header="PC" Binding="{Binding Sti}" Width="2*"/>
                </DataGrid.Columns>
              </DataGrid>
            </StackPanel>
          </Border>
        </StackPanel>
        </ScrollViewer>
      </Grid>
      <!-- TILSTANDE -->
      <Grid Name="PageModes" Visibility="Collapsed">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="0,0,8,0">
          <TextBlock Style="{StaticResource H1}" Text="Tilstande"/>
          <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,16" Text="Midlertidige indstillinger til spil og fokus. Alt bliver sat tilbage, når du er færdig, også hvis pc'en går ned undervejs. Du kan altid se, hvad Opticon har gjort."/>
          <Border Name="ModeActiveCard" Visibility="Collapsed" CornerRadius="14" Background="#1B1630" BorderBrush="#8B5CF6" BorderThickness="1" Padding="20,16" Margin="0,0,0,14">
            <DockPanel>
              <Button Name="BtnModeStop" DockPanel.Dock="Right" Content="⏹  Afslut og gendan" Style="{StaticResource Primary}" VerticalAlignment="Center" Padding="16,10" Margin="12,0,0,0"/>
              <StackPanel>
                <TextBlock Name="ModeActiveTitle" FontSize="18" FontWeight="SemiBold"/>
                <TextBlock Name="ModeActiveSub" Style="{StaticResource Sub}" Margin="0,4,0,0"/>
              </StackPanel>
            </DockPanel>
          </Border>
          <TextBlock Name="ModeLastText" Style="{StaticResource Sub}" FontSize="12" Margin="2,0,0,14" Visibility="Collapsed"/>

          <Border Style="{StaticResource CardB}" Padding="20,18" Margin="0,0,0,14">
            <StackPanel>
              <DockPanel>
                <Button Name="BtnGameAdd" DockPanel.Dock="Right" Content="➕  Tilføj spil" Style="{StaticResource Primary}" VerticalAlignment="Top" Margin="0"/>
                <StackPanel>
                  <TextBlock Text="🎮  Spil" FontSize="17" FontWeight="SemiBold"/>
                  <TextBlock Style="{StaticResource Sub}" Margin="0,4,12,0" Text="Starter af sig selv, når et af dine spil åbner, og slutter, når du lukker det: lukker de baggrundsapps, du har valgt, dæmper beskeder og bruger evt. din GPU-profil. Bagefter startes alt igen."/>
                </StackPanel>
              </DockPanel>
              <TextBlock Name="GamesEmpty" Style="{StaticResource Sub}" Margin="0,14,0,0" Text="Ingen spil endnu. Start dit spil, og tryk så på Tilføj spil. Så finder Opticon det selv."/>
              <DataGrid Name="GridGames" IsReadOnly="True" Margin="0,12,0,0" MaxHeight="200" Visibility="Collapsed">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="SPIL" Binding="{Binding Navn}" Width="2*"/>
                  <DataGridTextColumn Header="LUKKER" Binding="{Binding Info}" Width="3*"/>
                  <DataGridTextColumn Header="GPU" Binding="{Binding Note}" Width="110"/>
                  <DataGridTextColumn Header="BESKEDER" Binding="{Binding Gruppe}" Width="100"/>
                </DataGrid.Columns>
              </DataGrid>
              <StackPanel Name="GameBtns" Orientation="Horizontal" Margin="0,10,0,0" Visibility="Collapsed">
                <Button Name="BtnGameEdit" Content="✏  Ret valgt" IsEnabled="False"/>
                <Button Name="BtnGameRemove" Content="🗑  Fjern valgt" IsEnabled="False"/>
              </StackPanel>

              <Border Name="GamePick" Visibility="Collapsed" CornerRadius="12" Background="#141821" BorderBrush="#2A3142" BorderThickness="1" Padding="16,14" Margin="0,14,0,0">
                <StackPanel>
                  <TextBlock Text="Hvilket spil?" FontWeight="SemiBold" FontSize="15"/>
                  <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,10" Text="Her er de programmer med et vindue, der kører lige nu. Vælg dit spil, eller find programfilen selv."/>
                  <DataGrid Name="GridGamePick" IsReadOnly="True" MaxHeight="220">
                    <DataGrid.Columns>
                      <DataGridTextColumn Header="VINDUE" Binding="{Binding Navn}" Width="3*"/>
                      <DataGridTextColumn Header="PROGRAM" Binding="{Binding Info}" Width="2*"/>
                    </DataGrid.Columns>
                  </DataGrid>
                  <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <Button Name="BtnGamePickOk" Content="Vælg" Style="{StaticResource Primary}" IsEnabled="False"/>
                    <Button Name="BtnGameBrowse" Content="📂  Find programfil..."/>
                    <Button Name="BtnGamePickCancel" Content="Annullér"/>
                  </StackPanel>
                </StackPanel>
              </Border>

              <Border Name="GameSetup" Visibility="Collapsed" CornerRadius="12" Background="#141821" BorderBrush="#2A3142" BorderThickness="1" Padding="16,14" Margin="0,14,0,0">
                <StackPanel>
                  <TextBlock Name="GameSetupTitle" FontWeight="SemiBold" FontSize="15"/>
                  <TextBlock Name="GameSetupSub" Style="{StaticResource Sub}" Margin="0,4,0,10"/>
                  <DataGrid Name="GridModeApps" MaxHeight="300">
                    <DataGrid.Columns>
                      <DataGridTemplateColumn Header="LUK" Width="48">
                        <DataGridTemplateColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding Valgt, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center"/></DataTemplate></DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                      <DataGridTextColumn Header="PROGRAM" Binding="{Binding Navn}" Width="2*" IsReadOnly="True"/>
                      <DataGridTextColumn Header="CPU" Binding="{Binding Info}" Width="70" IsReadOnly="True"/>
                      <DataGridTextColumn Header="DISK/NET" Binding="{Binding Gruppe}" Width="90" IsReadOnly="True"/>
                      <DataGridTextColumn Header="RAM" Binding="{Binding Status}" Width="75" IsReadOnly="True"/>
                      <DataGridTextColumn Header="BEMÆRKNING" Binding="{Binding Note}" Width="3*" IsReadOnly="True"/>
                    </DataGrid.Columns>
                  </DataGrid>
                  <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,8,0,0" Text="Windows, Defender, Windows Update, drivere og anti-cheat vises ikke. Dem rører Opticon aldrig."/>
                  <CheckBox Name="ChkGameMute" Content="Dæmp Windows-beskeder, mens jeg spiller" IsChecked="True" Margin="0,12,0,0"/>
                  <CheckBox Name="ChkGameGpu" Content="Brug min GPU-profil" Margin="0,6,0,0" IsEnabled="False"/>
                  <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                    <Button Name="BtnGameSave" Content="💾  Gem" Style="{StaticResource Primary}"/>
                    <Button Name="BtnGameRemeasure" Content="↻  Mål igen"/>
                    <Button Name="BtnGameCancel" Content="Annullér"/>
                  </StackPanel>
                </StackPanel>
              </Border>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource CardB}" Padding="20,18" Margin="0,0,0,14">
            <StackPanel>
              <TextBlock Text="🔕  Fokus" FontSize="17" FontWeight="SemiBold"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,0" Text="Et stykke tid uden forstyrrelser. Slutter af sig selv, og alt sættes tilbage."/>
              <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                <RadioButton Name="Foc25" GroupName="foc" Content="25 min" IsChecked="True" Foreground="#E7E9EE" Margin="0,0,22,0"/>
                <RadioButton Name="Foc50" GroupName="foc" Content="50 min" Foreground="#E7E9EE" Margin="0,0,22,0"/>
                <RadioButton Name="Foc90" GroupName="foc" Content="90 min" Foreground="#E7E9EE"/>
              </StackPanel>
              <CheckBox Name="ChkFocMute" Content="Dæmp beskeder (Windows og Opticon)" IsChecked="True" Margin="0,14,0,0"/>
              <CheckBox Name="ChkFocBlock" Content="Skjul distraktioner: bloker disse sider i alle browsere" Margin="0,8,0,0"/>
              <TextBox Name="FocSites" Text="facebook.com, reddit.com, youtube.com, tiktok.com, instagram.com" Margin="26,6,0,0" Padding="8,6" Background="#141821" Foreground="#E7E9EE" BorderBrush="#2A3142" IsEnabled="{Binding IsChecked, ElementName=ChkFocBlock}"/>
              <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                <Button Name="BtnFocStart" Content="▶  Start fokus" Style="{StaticResource Primary}" Padding="16,10"/>
                <Button Name="BtnFocNotif" Content="🔔  Er det kun ét websteds beskeder, der generer?"/>
              </StackPanel>
            </StackPanel>
          </Border>
          <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="2,0,0,8" Text="På vej: Mødetilstand (test mikrofon og kamera) og 'Hvorfor hakkede mit spil?' med en 60-sekunders måling."/>
        </StackPanel>
        </ScrollViewer>
      </Grid>
      <Grid Name="PageSecure" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <StackPanel Margin="0,0,0,14">
          <TextBlock Style="{StaticResource H1}" Text="Sikkerhedstjek"/>
          <TextBlock Style="{StaticResource Sub}" Text="Er Windows' egne beskyttelser slået til? Og har pc'en drivere, som angribere kan misbruge? Vælg en linje for at se, hvad du skal gøre."/>
        </StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <Border Style="{StaticResource CardB}" Padding="20,16" Margin="0,0,0,12">
              <StackPanel>
                <DockPanel>
                  <TextBlock Name="WinSecBig" DockPanel.Dock="Right" FontSize="24" FontWeight="Bold" Foreground="#A78BFA" VerticalAlignment="Center" Text="–"/>
                  <StackPanel><TextBlock Text="🔐  Windows-beskyttelse" FontSize="15.5" FontWeight="SemiBold"/><TextBlock Name="WinSecSub" Style="{StaticResource Sub}" Margin="0,3,0,0" Text="Tjekker..."/></StackPanel>
                </DockPanel>
                <DataGrid Name="GridSecure" IsReadOnly="True" Margin="0,12,0,0" MaxHeight="420" SelectionMode="Single">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="" Binding="{Binding Status}" Width="40"/>
                    <DataGridTextColumn Header="BESKYTTELSE" Binding="{Binding Navn}" Width="2*"/>
                    <DataGridTextColumn Header="NU" Binding="{Binding Info}" Width="2*"/>
                    <DataGridTextColumn Header="HVAD BETYDER DET" Binding="{Binding Note}" Width="4*"/>
                  </DataGrid.Columns>
                </DataGrid>
                <Border Name="SecHintBox" Visibility="Collapsed" CornerRadius="10" Background="#1B1630" BorderBrush="#3B3366" BorderThickness="1" Padding="14,10" Margin="0,10,0,0">
                  <StackPanel>
                    <TextBlock Name="SecHintTitle" FontWeight="SemiBold" TextWrapping="Wrap"/>
                    <TextBlock Name="SecHint" Style="{StaticResource Sub}" Margin="0,4,0,0"/>
                  </StackPanel>
                </Border>
                <WrapPanel Margin="0,12,0,0">
                  <Button Name="BtnSecFix" Content="🔧  Ret det for mig" Style="{StaticResource Primary}" IsEnabled="False"/>
                  <Button Name="BtnSecOpen" Content="⚙  Åbn indstillingen" IsEnabled="False"/>
                  <Button Name="BtnSecRefresh" Content="⟳  Tjek igen"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource CardB}" Padding="20,16">
              <StackPanel>
                <DockPanel>
                  <TextBlock Name="DrvBig" DockPanel.Dock="Right" FontSize="24" FontWeight="Bold" Foreground="#A78BFA" VerticalAlignment="Center" Text="–"/>
                  <StackPanel><TextBlock Text="🧩  Sårbare drivere" FontSize="15.5" FontWeight="SemiBold"/><TextBlock Name="DrvSub" Style="{StaticResource Sub}" Margin="0,3,0,0" Text="Tjekker..."/></StackPanel>
                </DockPanel>
                <TextBlock Style="{StaticResource Sub}" Margin="0,10,0,0" LineHeight="20" Text="Angribere misbruger gamle drivere med kendte huller til at slå antivirus fra. Microsoft vedligeholder selv en liste over dem, og Windows kan blokere dem automatisk. Med Hukommelsesintegritet slået til stopper Windows også ukendte, farlige drivere. Det er den sikreste løsning, fordi den virker hele tiden og ikke kun, når du scanner."/>
                <WrapPanel Margin="0,12,0,0">
                  <Button Name="BtnDrvOpen" Content="⚙  Åbn Kerneisolering"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource CardB}" Padding="20,16" Margin="0,12,0,0">
              <StackPanel>
                <DockPanel>
                  <TextBlock Name="MbBig" DockPanel.Dock="Right" FontSize="24" FontWeight="Bold" Foreground="#6B7488" VerticalAlignment="Center" Text="Fra"/>
                  <StackPanel><TextBlock Text="🦠  Ekstra virustjek med MalwareBazaar (valgfrit)" FontSize="15.5" FontWeight="SemiBold"/><TextBlock Name="MbSub" Style="{StaticResource Sub}" Margin="0,3,0,0" Text="Slået fra. Alt andet i Opticon virker fint uden."/></StackPanel>
                </DockPanel>
                <TextBlock Style="{StaticResource Sub}" Margin="0,10,0,0" LineHeight="20" Text="MalwareBazaar er en gratis database med over 1 million bekræftede malware-filer, drevet af den schweiziske non-profit abuse.ch. Over 500 sikkerhedsteams bruger den hver dag. Med en nøgle tjekker Opticon op til 60 nye, usignerede programfiler ved hver scanning, og du kan tjekke en enkelt fil, du er i tvivl om. Kun filens fingeraftryk (SHA256) sendes, aldrig selve filen eller dit navn."/>
                <Border CornerRadius="10" Background="#1B1630" BorderBrush="#3B3366" BorderThickness="1" Padding="14,10" Margin="0,12,0,0">
                  <StackPanel>
                    <TextBlock Text="🔑  Sådan får du din gratis nøgle (ca. 2 min)" FontWeight="SemiBold"/>
                    <TextBlock Style="{StaticResource Sub}" Margin="0,6,0,0" LineHeight="20" Text="1. Tryk Åbn abuse.ch herunder.&#x0a;2. Log ind med Google, GitHub eller LinkedIn. Det er gratis, og der skal ikke bruges kort.&#x0a;3. På din kontoside står din Auth-Key: en lang række bogstaver og tal. Kopiér den.&#x0a;4. Sæt den ind i feltet herunder, og tryk Gem. Opticon tester den med det samme.&#x0a;&#x0a;Nøglen gemmes krypteret og kun på denne pc. Del den ikke med andre."/>
                  </StackPanel>
                </Border>
                <DockPanel Margin="0,12,0,0">
                  <Button Name="BtnMbOpen" DockPanel.Dock="Left" Content="🌐  Åbn abuse.ch"/>
                  <Button Name="BtnMbSave" DockPanel.Dock="Right" Content="💾  Gem og test" Style="{StaticResource Primary}" Margin="8,0,0,0"/>
                  <PasswordBox Name="MbKeyBox" Height="34" VerticalContentAlignment="Center" Padding="8,0" Background="#141823" Foreground="#E6E9F0" BorderBrush="#2A3142" CaretBrush="#E6E9F0" ToolTip="Sæt din Auth-Key ind her"/>
                </DockPanel>
                <WrapPanel Margin="0,10,0,0">
                  <Button Name="BtnMbFile" Content="🔎  Tjek en fil" IsEnabled="False"/>
                  <Button Name="BtnMbRemove" Content="🗑  Fjern nøglen" IsEnabled="False"/>
                </WrapPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </Grid>
      <Grid Name="PageVagt" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <StackPanel Margin="0,0,0,16">
          <TextBlock Style="{StaticResource H1}" Text="Vagt"/>
          <TextBlock Style="{StaticResource Sub}" Text="Passer på din pc i baggrunden, også når Opticon er lukket. Du får en lille besked nederst til højre, hvis der sker noget."/>
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
                  <TextBlock Text="Grafikkort" FontSize="17" FontWeight="SemiBold" VerticalAlignment="Center"/>
                  <Border CornerRadius="10" Padding="10,3" Margin="12,0,0,0" Background="#3B2C6E" VerticalAlignment="Center"><TextBlock Text="Avanceret" FontSize="12" FontWeight="SemiBold" Foreground="#C4B5FD"/></Border>
                </StackPanel>
                <TextBlock Name="GpuName" Foreground="#AEB6C6" Margin="0,4,0,0"/>
                <TextBlock Style="{StaticResource Sub}" Margin="0,8,0,0" Text="Vælg herunder, hvad du vil opnå. Opticon måler før og efter i sin egen testscene, så du kan se, om det hjalp."/>
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
            <Border Background="#10131A" BorderBrush="#20263A" BorderThickness="1" CornerRadius="10" Padding="14,10" Margin="0,14,0,0">
              <StackPanel>
                <TextBlock Text="GRAFIKKORTET LIGE NU · opdateres hvert 3. sekund · bare til orientering, du skal ikke gøre noget her" FontSize="11" Foreground="{StaticResource Muted}"/>
                <UniformGrid Columns="5" Margin="0,8,0,0">
                  <StackPanel><TextBlock Text="Strøm nu / maks" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GpuLiveW" Text="–" FontSize="16" FontWeight="SemiBold"/></StackPanel>
                  <StackPanel><TextBlock Text="Temperatur" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GpuLiveT" Text="–" FontSize="16" FontWeight="SemiBold"/></StackPanel>
                  <StackPanel><TextBlock Text="Blæser" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GpuLiveF" Text="–" FontSize="16" FontWeight="SemiBold"/></StackPanel>
                  <StackPanel><TextBlock Text="Hastighed (clock)" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GpuLiveC" Text="–" FontSize="16" FontWeight="SemiBold"/></StackPanel>
                  <StackPanel><TextBlock Text="Belastning" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="GpuLiveU" Text="–" FontSize="16" FontWeight="SemiBold"/></StackPanel>
                </UniformGrid>
              </StackPanel>
            </Border>
            <!-- vælger: hvad vil du? -->
            <Border Background="#121726" BorderBrush="#2A3142" BorderThickness="1" CornerRadius="12" Padding="14,12" Margin="0,16,0,0">
              <StackPanel>
                <TextBlock Text="Hvad vil du opnå?" FontWeight="SemiBold" FontSize="14"/>
                <WrapPanel Margin="0,10,0,0">
                  <Button Name="ChoosePower" Content="🔋  Mindre strøm, varme og larm"/>
                  <Button Name="ChooseFps" Content="⚡  Flere FPS"/>
                  <Button Name="ChooseOwn" Content="📏  Test mine egne indstillinger"/>
                  <Button Name="ChooseAll" Content="Vis alt" Background="Transparent" Foreground="#8C95A9"/>
                </WrapPanel>
                <TextBlock Name="ChooseHelp" Style="{StaticResource Sub}" FontSize="12" Margin="0,8,0,0"/>
              </StackPanel>
            </Border>
            <!-- automatisk test -->
            <Border Name="SecAuto" Background="#10131A" BorderBrush="#3B2C6E" BorderThickness="1" CornerRadius="12" Padding="16,14" Margin="0,16,0,0">
              <StackPanel>
                <DockPanel>
                  <Button Name="BtnGpuAuto" DockPanel.Dock="Right" Content="🚀  Find det bedste punkt (ca. 4 min)" Style="{StaticResource Primary}" Padding="16,9" Margin="0"/>
                  <StackPanel Margin="0,0,12,0">
                    <TextBlock Text="🚀  Automatisk: mindre strøm, næsten samme ydelse" FontSize="15" FontWeight="SemiBold"/>
                    <TextBlock Name="GpuAutoInfo" Style="{StaticResource Sub}" Margin="0,4,0,0" Text="Opticon viser en 3D-testscene i fuld skærm og prøver selv 4 strømgrænser (100, 90, 80 og 70 %). Bagefter får du en anbefaling. Den oprindelige indstilling gendannes altid."/>
                  </StackPanel>
                </DockPanel>
                <ProgressBar Name="GpuAutoBar" Height="6" Maximum="100" Margin="0,12,0,0" Foreground="{StaticResource Accent}" Background="#242A39" BorderThickness="0" Visibility="Collapsed"/>
                <DataGrid Name="GridGpuAuto" IsReadOnly="True" Margin="0,12,0,0" Visibility="Collapsed">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="" Binding="{Binding Status}" Width="34"/>
                    <DataGridTextColumn Header="STRØMGRÆNSE" Binding="{Binding Navn}" Width="1.4*"/>
                    <DataGridTextColumn Header="EFFEKT" Binding="{Binding Info}" Width="1.2*"/>
                    <DataGridTextColumn Header="FPS" Binding="{Binding Note}" Width="1.3*"/>
                    <DataGridTextColumn Header="TEMP · BLÆSER · CLOCK" Binding="{Binding Gruppe}" Width="2.4*"/>
                  </DataGrid.Columns>
                </DataGrid>
                <Border Name="GpuRecBox" Visibility="Collapsed" CornerRadius="10" Background="#173325" BorderBrush="#22C55E" BorderThickness="1" Padding="14,12" Margin="0,12,0,0">
                  <StackPanel>
                    <TextBlock Name="GpuRecTitle" FontSize="15.5" FontWeight="SemiBold" TextWrapping="Wrap"/>
                    <TextBlock Name="GpuRecText" Foreground="#C3E8D0" TextWrapping="Wrap" Margin="0,4,0,10"/>
                    <WrapPanel>
                      <Button Name="BtnGpuApply" Content="✅  Brug anbefalingen" Style="{StaticResource Primary}"/>
                      <Button Name="BtnGpuReset" Content="↩  Tilbage til standard"/>
                      <Button Name="BtnGpuAbHow" Content="🎚  Hellere med Afterburner?"/>
                    </WrapPanel>
                    <!-- illustration af Afterburner-skyderen (egen tegning) -->
                    <Border Name="GpuAbBox" Visibility="Collapsed" Background="#0B0D12" CornerRadius="10" Padding="16,12" Margin="0,12,0,0">
                      <StackPanel>
                        <TextBlock Text="Sådan i MSI Afterburner:" FontWeight="SemiBold"/>
                        <Grid Margin="0,10,0,4" Width="340" HorizontalAlignment="Left">
                          <Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="*"/><ColumnDefinition Width="50"/></Grid.ColumnDefinitions>
                          <TextBlock Text="Power Limit (%)" Foreground="#AEB6C6" VerticalAlignment="Center"/>
                          <Grid Grid.Column="1" Height="10" VerticalAlignment="Center">
                            <Border Background="#242A39" CornerRadius="5"/>
                            <Border Name="GpuAbFill" Background="{StaticResource Accent}" CornerRadius="5" HorizontalAlignment="Left" Width="120"/>
                          </Grid>
                          <TextBlock Name="GpuAbVal" Grid.Column="2" Text="80" FontWeight="Bold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                        </Grid>
                        <TextBlock Name="GpuAbSteps" Foreground="#AEB6C6" TextWrapping="Wrap" LineHeight="21" Margin="0,6,0,0"/>
                      </StackPanel>
                    </Border>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Border>
            <!-- FPS ved forskellige opløsninger -->
            <Border Name="SecRes" Background="#10131A" BorderBrush="#1E3A5F" BorderThickness="1" CornerRadius="12" Padding="16,14" Margin="0,12,0,0">
              <StackPanel>
                <DockPanel>
                  <Button Name="BtnGpuRes" DockPanel.Dock="Right" Content="📺  Mål FPS" Style="{StaticResource Primary}" Padding="16,9" Margin="0" VerticalAlignment="Top"/>
                  <StackPanel Margin="0,0,12,0">
                    <TextBlock Text="📺  FPS ved Full HD, 2K og 4K" FontSize="15" FontWeight="SemiBold"/>
                    <TextBlock Name="GpuResInfo" Style="{StaticResource Sub}" Margin="0,4,0,0" Text="Samme testscene i 1920×1080, 2560×1440 og 3840×2160, uden skærmens Hz-loft og uanset hvilken skærm du har. Rigtige FPS uden din skærms Hz-loft, så du ser, hvad grafikkortet kan. Du ser FPS, laveste 1 %, strøm og FPS pr. watt for hver opløsning. Ca. 1½ minut."/>
                    <CheckBox Name="ChkGpuResCmp" Content="Sammenlign med min GPU-profil (ca. 3 minutter)" Margin="0,8,0,0" IsEnabled="False"/>
                  </StackPanel>
                </DockPanel>
                <ProgressBar Name="GpuResBar" Height="6" Maximum="100" Margin="0,12,0,0" Foreground="#60A5FA" Background="#242A39" BorderThickness="0" Visibility="Collapsed"/>
                <DataGrid Name="GridGpuRes" IsReadOnly="True" Margin="0,12,0,0" Visibility="Collapsed">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="OPLØSNING" Binding="{Binding Navn}" Width="1.5*"/>
                    <DataGridTextColumn Header="STRØM" Binding="{Binding Info}" Width="1.2*"/>
                    <DataGridTemplateColumn Header="FPS" Width="2.2*">
                      <DataGridTemplateColumn.CellTemplate><DataTemplate>
                        <StackPanel Orientation="Horizontal">
                          <Border Width="{Binding Tal}" Height="10" CornerRadius="5" Background="#60A5FA" VerticalAlignment="Center"/>
                          <TextBlock Text="{Binding Note}" Margin="8,0,0,0" FontWeight="SemiBold" VerticalAlignment="Center"/>
                        </StackPanel>
                      </DataTemplate></DataGridTemplateColumn.CellTemplate>
                    </DataGridTemplateColumn>
                    <DataGridTextColumn Header="LAVESTE 1 %" Binding="{Binding Gruppe}" Width="1*"/>
                    <DataGridTextColumn Header="WATT · TEMP" Binding="{Binding Status}" Width="1.3*"/>
                    <DataGridTextColumn Header="FPS PR. WATT" Binding="{Binding Id}" Width="1*"/>
                  </DataGrid.Columns>
                </DataGrid>
                <TextBlock Name="GpuResVerdict" TextWrapping="Wrap" Margin="0,10,0,0" Visibility="Collapsed"/>
              </StackPanel>
            </Border>
            <!-- OC-tjek -->
            <Border Name="SecOc" Background="#10131A" BorderBrush="#5F3A1E" BorderThickness="1" CornerRadius="12" Padding="16,14" Margin="0,12,0,0">
              <StackPanel>
                <TextBlock Text="⚡  OC-tjek: flere FPS, og holder det?" FontSize="15" FontWeight="SemiBold"/>
                <TextBlock Name="GpuOcInfo" Style="{StaticResource Sub}" Margin="0,4,0,0" Text="Lad NVIDIAs egen automatiske tuning finde dit overclock, og lad Opticon måle, om det giver flere FPS og kører stabilt. Testen kører i 2K, så det er grafikkortet, der bliver presset."/>
                <WrapPanel Margin="0,12,0,0">
                  <Button Name="BtnOcBase" Content="1 · Mål udgangspunkt (1 min)" Style="{StaticResource Primary}"/>
                  <Button Name="BtnOcTune" Content="2 · Find overclock automatisk"/>
                  <Button Name="BtnOcCheck" Content="3 · Tjek OC (5 min)" IsEnabled="False"/>
                </WrapPanel>
                <ProgressBar Name="GpuOcBar" Height="6" Maximum="100" Margin="0,12,0,0" Foreground="#F59E0B" Background="#242A39" BorderThickness="0" Visibility="Collapsed"/>
                <TextBlock Name="GpuOcBase" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,10,0,0" Visibility="Collapsed"/>
                <Border Name="GpuOcBox" Visibility="Collapsed" CornerRadius="10" BorderThickness="1" Padding="14,12" Margin="0,10,0,0">
                  <StackPanel>
                    <TextBlock Name="GpuOcTitle" FontSize="15.5" FontWeight="SemiBold" TextWrapping="Wrap"/>
                    <TextBlock Name="GpuOcText" TextWrapping="Wrap" Margin="0,4,0,0" LineHeight="20"/>
                  </StackPanel>
                </Border>
                <Border Name="GpuOcEstBox" Visibility="Collapsed" CornerRadius="10" Background="Transparent" BorderBrush="#2A3142" BorderThickness="1" Padding="12,10" Margin="0,10,0,0">
                  <StackPanel>
                    <TextBlock Name="GpuOcEstTitle" FontSize="13" FontWeight="SemiBold" Foreground="#AEB6C6" TextWrapping="Wrap"/>
                    <UniformGrid Columns="4" Margin="0,10,0,6">
                      <StackPanel><TextBlock Text="FPS" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="OcEstFps" FontSize="14" FontWeight="SemiBold" Foreground="#C3CAD6"/><TextBlock Name="OcEstFpsSub" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/></StackPanel>
                      <StackPanel><TextBlock Text="STRØM" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="OcEstW" FontSize="14" FontWeight="SemiBold" Foreground="#C3CAD6"/><TextBlock Name="OcEstWSub" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/></StackPanel>
                      <StackPanel><TextBlock Text="VARME" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="OcEstT" FontSize="14" FontWeight="SemiBold" Foreground="#C3CAD6"/><TextBlock Name="OcEstTSub" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/></StackPanel>
                      <StackPanel><TextBlock Text="LARM" FontSize="11" Foreground="{StaticResource Muted}"/><TextBlock Name="OcEstN" FontSize="14" FontWeight="SemiBold" Foreground="#C3CAD6"/><TextBlock Name="OcEstNSub" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/></StackPanel>
                    </UniformGrid>
                    <TextBlock Name="GpuOcEstText" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" LineHeight="18"/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Border>
            <!-- mål før/efter (egne indstillinger) -->
            <Border Name="SecOwn" Background="#10131A" BorderBrush="#242A39" BorderThickness="1" CornerRadius="12" Padding="16,14" Margin="0,12,0,0">
              <StackPanel>
                <TextBlock Text="📏  Test dine egne indstillinger (før/efter)" FontSize="15" FontWeight="SemiBold"/>
                <TextBlock Name="GpuMeasureInfo" Style="{StaticResource Sub}" Margin="0,4,0,10" Text="Til undervolt i fx Afterburner: 1) Tryk 'Mål FØR'. Testscenen kører 1 minut. 2) Lav ÉN ændring i Afterburner. 3) Tryk 'Mål EFTER'. Begge målinger bruger præcis samme belastning."/>
                <WrapPanel>
                  <Button Name="BtnGpuBefore" Content="①  Mål FØR (1 min)" Style="{StaticResource Primary}"/>
                  <Button Name="BtnGpuAfter" Content="②  Mål EFTER (1 min)" IsEnabled="False"/>
                </WrapPanel>
                <ProgressBar Name="GpuMeasureBar" Height="6" Maximum="100" Margin="0,12,0,0" Foreground="{StaticResource Accent}" Background="#242A39" BorderThickness="0" Visibility="Collapsed"/>
                <TextBlock Name="GpuResult" TextWrapping="Wrap" FontSize="15" FontWeight="SemiBold" Margin="0,12,0,0"/>
                <TextBlock Name="GpuVerdict" TextWrapping="Wrap" Margin="0,6,0,0" Foreground="#AEB6C6"/>
                <DockPanel Name="GpuSavePanel" Margin="0,10,0,0" Visibility="Collapsed">
                  <Button Name="BtnGpuSave" DockPanel.Dock="Right" Content="💾  Gem som 'Testet på min pc'" Margin="8,0,0,0"/>
                  <TextBox Name="TxtGpuNote" ToolTip="Hvad ændrede du? Fx 'Afterburner: 900 mV @ 2600 MHz'"/>
                </DockPanel>
              </StackPanel>
            </Border>
            <StackPanel Name="SecExtra" Visibility="Collapsed">
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
        <StackPanel Margin="0,0,0,14"><TextBlock Style="{StaticResource H1}" Text="Filer"/><TextBlock Style="{StaticResource Sub}" Text="Hvor pladsen er blevet af, dubletter, gamle installere og de største filer i dine mapper. Slettede filer flyttes til papirkurven, så du kan fortryde."/>
          <Border Style="{StaticResource CardB}" Padding="18,14" Margin="0,12,0,0">
            <StackPanel>
              <DockPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top">
                  <Button Name="BtnSpaceOpen" Content="📂  Åbn mappen" IsEnabled="False"/>
                  <Button Name="BtnSpaceScan" Content="📊  Mål nu" Style="{StaticResource Primary}" Margin="0"/>
                </StackPanel>
                <StackPanel>
                  <TextBlock Text="📊  Hvad fylder siden sidst?" FontSize="15.5" FontWeight="SemiBold"/>
                  <TextBlock Name="SpaceSummary" Style="{StaticResource Sub}" Margin="0,4,0,0" Text="Opticon måler dine drev og de mapper, der typisk vokser (overførsler, videoer, spil), og viser næste gang, hvor pladsen er blevet af."/>
                </StackPanel>
              </DockPanel>
              <DataGrid Name="GridSpace" IsReadOnly="True" Margin="0,10,0,0" MaxHeight="220" SelectionMode="Single" Visibility="Collapsed">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="MAPPE" Binding="{Binding Navn}" Width="3*"/>
                  <DataGridTextColumn Header="FYLDER NU" Binding="{Binding Info}" Width="1*"/>
                  <DataGridTextColumn Header="SIDEN SIDST" Binding="{Binding Status}" Width="1*"/>
                  <DataGridTextColumn Header="HVAD" Binding="{Binding Note}" Width="2*"/>
                </DataGrid.Columns>
              </DataGrid>
            </StackPanel>
          </Border>
        </StackPanel>
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
        <StackPanel Margin="0,0,0,14"><TextBlock Style="{StaticResource H1}" Text="Opdateringer"/><TextBlock Style="{StaticResource Sub}" Text="Gamle programmer er en af de største sikkerhedsrisici. Bruger Windows' egen pakkehåndtering (winget) til at opdatere i baggrunden."/>
          <Border Name="VendorCard" Visibility="Collapsed" CornerRadius="14" Background="#141B2A" BorderBrush="#2C4A7A" BorderThickness="1" Padding="16,14" Margin="0,14,0,0">
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center" Margin="12,0,0,0">
                <Button Name="BtnVendorOpen" Style="{StaticResource Primary}" Margin="0"/>
              </StackPanel>
              <StackPanel>
                <TextBlock Name="VendorTitle" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap"/>
                <TextBlock Name="VendorText" Style="{StaticResource Sub}" Margin="0,4,0,0"/>
              </StackPanel>
            </DockPanel>
          </Border>
        </StackPanel>
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
          <Button Name="BtnDvrOff" Content="🎥  Slå baggrundsoptagelse fra" IsEnabled="False"/>
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
# Logo i sidemenuen: den største udgave fra ikonfilen
if (Test-Path $icoPath) {
  try {
    $ms2 = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($icoPath))
    $dec = New-Object Windows.Media.Imaging.IconBitmapDecoder($ms2, 'None', 'OnLoad')
    $big = $dec.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1
    if ($big) { $ui.LogoImg.Source = $big; $ui.LogoTile.Visibility = 'Collapsed' }
  } catch {}
}
$win.Add_SourceInitialized({ try { [PcTjek.Win]::Dark((New-Object System.Windows.Interop.WindowInteropHelper $win).Handle) } catch {} })
$win.Dispatcher.Add_UnhandledException({
  param($s, $e)
  Log "FEJL: $($e.Exception)"
  [Windows.MessageBox]::Show("Der skete en fejl:`n`n$($e.Exception.Message)`n`nDetaljer er gemt i pc-tjek.log.", 'Opticon', 'OK', 'Error') | Out-Null
  $e.Handled = $true
})
$Brush = New-Object Windows.Media.BrushConverter
function Msg($text, $title = 'Opticon', $buttons = 'OK', $icon = 'Information') { [Windows.MessageBox]::Show($text, $title, $buttons, $icon) }
function Fmt-GB($bytes) { if ($bytes -ge 1GB) { '{0:N1} GB' -f ($bytes / 1GB) } elseif ($bytes -ge 1MB) { '{0:N0} MB' -f ($bytes / 1MB) } else { '{0:N0} KB' -f ($bytes / 1KB) } }

# =====================================================================
#  Baggrundsjob: én timer holder øje med alle job
# =====================================================================
# Baggrundsjob kører i en separat runspace INDE i appen (ingen ekstra PowerShell-processer).
# Det er både hurtigere og ser ikke mistænkeligt ud for antivirus.
$script:Jobs = New-Object System.Collections.ArrayList
function Invoke-Bg([scriptblock]$Work, $Arg, [scriptblock]$Done, $Ctx) {
  try {
    if ($null -eq $Arg) { $Arg = @{} }
    $s = [hashtable]::Synchronized(@{ Status = ''; Detail = ''; Progress = -1.0 })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($Work.ToString()).AddArgument($s).AddArgument($Arg)
    $h = $ps.BeginInvoke()
    [void]$script:Jobs.Add(@{ S = $s; PS = $ps; RS = $rs; H = $h; Done = $Done; Ctx = $Ctx; T0 = Get-Date })
    $ui.Busy.Visibility = 'Visible'
    Log 'Job startet'
  } catch {
    Log "Invoke-Bg FEJL: $($_.Exception.Message)"
    Msg "Kunne ikke starte baggrundsjob:`n$($_.Exception.Message)" 'Opticon' 'OK' 'Error' | Out-Null
  }
}
function Get-JobResult($j) {
  $res = $null; $err = $null
  try {
    $out = $j.PS.EndInvoke($j.H)
    $items = @(foreach ($o in $out) {
      if ($null -eq $o) { continue }
      if ($o -is [psobject] -and $null -ne $o.BaseObject -and $o.BaseObject -isnot [Management.Automation.PSCustomObject]) { $o.BaseObject } else { $o }
    })
    if ($items.Count -eq 1) { $res = $items[0] } elseif ($items.Count -gt 1) { $res = $items }
    # Samme form som før (da jobbene var separate processer): en kopi af resultatet, uafhængig af jobbets runspace
    if ($null -ne $res) { try { $res = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($res, 8)) } catch { Log "Resultat-kopi fejlede: $_" } }
  } catch {
    $e = $_.Exception
    while ($e.InnerException -and ($e -is [Management.Automation.MethodInvocationException] -or $e -is [Management.Automation.CmdletInvocationException] -or $e.Message -match '^Exception calling')) { $e = $e.InnerException }
    $err = [string]$e.Message
    if (-not $err) { $err = 'Jobbet stoppede uventet.' }
  }
  try { $j.PS.Dispose() } catch {}; try { $j.RS.Dispose() } catch {}
  return @{ Res = $res; Err = $err }
}
$jobTimer = New-Object Windows.Threading.DispatcherTimer
$jobTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$jobTimer.Add_Tick({
  if ($script:Jobs.Count -eq 0) { return }
  $last = $script:Jobs[$script:Jobs.Count - 1]
  if ($last.S.Status) { $ui.StatusText.Text = $last.S.Status }
  if ([double]$last.S.Progress -ge 0) { $ui.Busy.IsIndeterminate = $false; $ui.Busy.Value = [double]$last.S.Progress } else { $ui.Busy.IsIndeterminate = $true }
  $sj = $script:Jobs | Where-Object { $_.Ctx -is [hashtable] -and $_.Ctx.Kind -eq 'scan' } | Select-Object -First 1
  if ($sj) { try { Update-ScanProgress $sj.S } catch { if (-not $script:ProgErrLogged) { Log "Fremdrift-fejl: $_"; $script:ProgErrLogged = $true } } }
  foreach ($j in @($script:Jobs)) {
    if (-not $j.H.IsCompleted) { continue }
    [void]$script:Jobs.Remove($j)
    $r = Get-JobResult $j
    $res = $r.Res; $err = $r.Err
    if ($err) { Log "Job-fejl: $err" }
    try { & $j.Done $res $err $j.Ctx } catch { Log "Done-fejl: $_"; Msg "Fejl: $($_.Exception.Message)" 'Opticon' 'OK' 'Error' | Out-Null }
  }
  if ($script:Jobs.Count -eq 0) { $ui.Busy.Visibility = 'Hidden' }
})
$jobTimer.Start()
# Luk evt. kørende job-processer, når appen lukkes
$win.Add_Closed({
  foreach ($j in @($script:Jobs)) { try { if (-not $j.H.IsCompleted) { $st = $j.PS.BeginStop($null, $null); [void]$st.AsyncWaitHandle.WaitOne(3000) } } catch {} }
  try { if (Repair-GpuRestore) { Log 'GPU-test afbrudt ved lukning: strømgrænsen er gendannet' } } catch {}   # en afbrudt GPU-test må aldrig efterlade kortet ændret
})

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
$pages = @{ NavHelped = 'PageHelped'; NavBench = 'PageBench'; NavModes = 'PageModes'; NavVagt = 'PageVagt'; NavSecure = 'PageSecure'; NavTweaks = 'PageTweaks'; NavHome = 'PageHome'; NavFind = 'PageFind'; NavTime = 'PageTime'; NavStart = 'PageStart'; NavClean = 'PageClean'; NavFiles = 'PageFiles'; NavUpdates = 'PageUpdates'; NavHealth = 'PageHealth' }
foreach ($nav in $pages.Keys) {
  $ui[$nav].Add_Checked({
    param($sender, $e)
    foreach ($k in $pages.Keys) { $ui[$pages[$k]].Visibility = $(if ($ui[$k].IsChecked) { 'Visible' } else { 'Collapsed' }) }
    if ($sender.Name -eq 'NavHealth' -and -not $script:HealthLoaded) { Load-Health; try { Show-Reboot; Show-Boot } catch { Log "Boot-fejl: $_" }; Show-Crashes }
    if ($sender.Name -eq 'NavUpdates') { try { Show-Reboot } catch {}; try { Show-VendorCard } catch { Log "Producent-fejl: $_" } }
    if ($sender.Name -eq 'NavVagt') { try { Load-Vagt } catch { Log "Vagt-fejl: $_" } }
    if ($sender.Name -eq 'NavSecure') { try { Show-MbState; if (-not $script:SecLoaded) { Load-Secure } } catch { Log "Sikkerhed-fejl: $_" } }
    if ($sender.Name -eq 'NavHelped') { try { Update-Changes; Show-Changes } catch { Log "Hjalp det-fejl: $_" } }
    if ($sender.Name -eq 'NavBench') { try { Load-Bench } catch { Log "Benchmark-fejl: $_" } }
    if ($sender.Name -eq 'NavModes') { try { Load-Games; Update-ModeUi } catch { Log "Tilstand-fejl: $_" } }
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
      foreach ($item in $n) { if ($item -and ([string]$item) -match '(?i)\\PC.Tjek\\|PC.Tjek-(App|Start|Vagt)\.ps1|\(denne app\)') { continue }   # Opticon selv
        if ($item -and $o -notcontains $item) { $new += [pscustomobject]@{ Type = $k; Item = $item; Siden = $prev.LastWriteTime } } }
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
  if (-not (Confirm-ModeFree 'En scanning')) { return }
  $ui.BtnScan.IsEnabled = $false; $ui.BtnScan.Content = '⏳   Scanner...'
  $ui.NavHome.IsChecked = $true
  $script:ScanStart = Get-Date; $script:EtaSmooth = $null; $ui.ScanBar.Value = 0
  $script:PrevTimes = $null
  if (Test-Path $TimesFile) { try { $script:PrevTimes = Get-Content $TimesFile -Raw | ConvertFrom-Json } catch {} }
  $ui.ScanCard.Visibility = 'Visible'; $ui.StoryCard.Visibility = 'Collapsed'; $ui.PlanCard.Visibility = 'Hidden'; $script:ShowDetails = $false
  $ui.ScoreLabel.Text = 'scanner...'
  Log 'Scan startet'
  Invoke-Bg $ScanScript @{ LogFile = $LogFile; MbKey = (Get-MbKey) } {
    param($res, $err, $c)
    $ui.ScanCard.Visibility = 'Collapsed'; $ui.PlanCard.Visibility = 'Visible'; $ui.BtnDetails.Content = 'Vis detaljer'
    $ui.BtnScan.IsEnabled = $true; $ui.BtnScan.Content = "🔍   Scan igen"
    if ($res -is [array]) { $res = @($res | Where-Object { $_ -is [hashtable] })[-1] }   # sikkerhed mod løst output
    if ($err -or -not $res) { Msg "Scanningen fejlede: $err" 'Opticon' 'OK' 'Error' | Out-Null; return }
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
    if ($n) { $ui.StatusText.Text = "Deaktiveret: $($s.Titel)" } else { Msg 'Det lykkedes ikke at deaktivere den. Se pc-tjek.log.' 'Opticon' 'OK' 'Error' | Out-Null }
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
    } catch { Msg "Det lykkedes ikke: $($_.Exception.Message)" 'Opticon' 'OK' 'Error' | Out-Null }
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
  } catch { Msg "Det lykkedes ikke: $($_.Exception.Message)" 'Opticon' 'OK' 'Error' | Out-Null }
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
    try { Note-StartupChange "$($it.Navn) slået $(if ($it.Aktiv) { 'fra' } else { 'til' })" } catch {}
    Load-Startup
    $ui.StatusText.Text = "$($it.Navn) er slået $(if ($it.Aktiv) { 'FRA' } else { 'TIL' }). Gælder fra næste login."
    Log "Opstart $($it.Navn) -> $(-not $it.Aktiv)"
  } catch { Msg "Det lykkedes ikke: $($_.Exception.Message)" 'Opticon' 'OK' 'Error' | Out-Null }
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
  try { Note-StartupChange "$($targets.Count - $fail.Count) programmer slået fra" } catch {}
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
  $freeBefore = $null; try { $freeBefore = (Get-PSDrive ($env:SystemDrive.Substring(0, 1))).Free } catch {}
  Invoke-Bg $CleanRunScript @{ Cats = @($sel | ForEach-Object { $_.Tag }) } {
    param($res, $err, $c)
    $ui.BtnCleanRun.IsEnabled = $true
    try { Note-CleanResult $c.FreeBefore } catch {}
    if ($res -is [array]) { $res = @($res | Where-Object { $_ -is [hashtable] })[-1] }
    $total = 0
    foreach ($r in $script:CleanRows) { if ($res -and $res.ContainsKey($r.Id)) { $r.Status = "✓ " + (Fmt-GB $res[$r.Id]); $total += $res[$r.Id] } }
    $ui.StatusText.Text = "Oprydning færdig: $(Fmt-GB $total) frigjort."
    Log "Oprydning: $total bytes"
    Msg "Færdig! $(Fmt-GB $total) frigjort.`n`n(Filer i brug er sprunget over.)" 'Oprydning' | Out-Null
  } @{ FreeBefore = $freeBefore }
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
  Invoke-Bg $WingetListScript @{ LogFile = $LogFile } {
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
      if ($rc.Temperature) {
        $t = [int]$rc.Temperature; $tm = [int]$rc.TemperatureMax
        $hot = if ($tm -gt 40) { $tm - 8 } else { 70 }
        [void]$rows.Add((HRow $(if ($t -lt 55) { 2 } elseif ($t -lt $hot) { 1 } else { 0 }) '   Temperatur' "$t °C$(if ($tm -gt 40) { " (maks. $tm °C)" })" $(if ($t -lt 55) { 'Fin' } elseif ($t -lt $hot) { 'Varm. Tjek at der kommer luft til disken (NVMe: overvej en køleplade)' } else { 'For varm! Disken sænker farten for at beskytte sig selv' })))
      }
      if ($null -ne $rc.Wear) { $w = [int]$rc.Wear; [void]$rows.Add((HRow $(if ($w -lt 50) { 2 } elseif ($w -lt 80) { 1 } else { 0 }) '   Slid (SSD)' "$w % brugt" $(if ($w -lt 50) { 'Masser af levetid tilbage' } elseif ($w -lt 80) { 'Over halvvejs. Hold øje, og hav backup' } else { 'Tæt på slidt op: tag backup, og planlæg en ny disk' }))) }
      $ue = [int64]$rc.ReadErrorsUncorrected + [int64]$rc.WriteErrorsUncorrected
      if ($null -ne $rc.ReadErrorsUncorrected -or $null -ne $rc.WriteErrorsUncorrected) { [void]$rows.Add((HRow $(if ($ue -eq 0) { 2 } else { 0 }) '   Fejl der ikke kunne rettes' "$ue" $(if ($ue -eq 0) { 'Ingen. Godt' } else { 'Tidligt tegn på, at disken er ved at dø. Tag backup nu' }))) }
      if ($rc.PowerOnHours) { $h = [int64]$rc.PowerOnHours; [void]$rows.Add((HRow 3 '   Tændt i alt' ("{0:N0} timer" -f $h) $(if ($h -ge 8760) { "Ca. $([math]::Round($h / 8760, 1)) år i drift" } else { "Ca. $([math]::Round($h / 730)) måneder i drift" }))) }
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
  $script:DvrOn = Test-BgRecording
  [void]$rows.Add((HRow $(if ($script:DvrOn) { 1 } else { 2 }) 'Optagelse i baggrunden (Game Bar)' $(if ($script:DvrOn) { 'Til' } else { 'Fra' }) $(if ($script:DvrOn) { 'Optager hele tiden de sidste minutter af dine spil. Det holder grafikkortets videochip i gang og kan give små hak. Slå den fra, hvis du ikke bruger "Optag hvad der skete"' } else { 'Godt: intet optages i baggrunden, mens du spiller' })))
  $boot = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction SilentlyContinue |
    ForEach-Object { (([xml]$_.ToXml()).Event.EventData.Data | Where-Object Name -eq 'BootTime').'#text' }
  if ($boot) { $bs = [math]::Round([int]$boot / 1000); [void]$rows.Add((HRow $(if ($bs -lt 40) { 2 } elseif ($bs -lt 90) { 1 } else { 0 }) 'Seneste opstartstid' "$bs sek" $(if ($bs -lt 40) { 'Hurtig' } else { 'Langsom: slå opstartsprogrammer fra under Opstart' }))) }
  $ui.GridHealth.ItemsSource = @($rows)
  $ui.BtnPowerHigh.IsEnabled = -not $script:PlanIsHigh
  $ui.BtnGameMode.IsEnabled = -not $script:GameModeOn
  $ui.BtnDvrOff.IsEnabled = [bool]$script:DvrOn
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
function Test-BgRecording {
  $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name HistoricalCaptureEnabled -ErrorAction SilentlyContinue).HistoricalCaptureEnabled
  return ($v -eq 1)
}
$ui.BtnDvrOff.Add_Click({
  try {
    New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name HistoricalCaptureEnabled -Value 0 -Type DWord -ErrorAction Stop
    Log 'Baggrundsoptagelse slået fra'
    $ui.StatusText.Text = 'Baggrundsoptagelse er slået fra. Du kan stadig optage med Win+Alt+R.'
  } catch { Msg "Det lykkedes ikke: $($_.Exception.Message)" | Out-Null }
  Load-Health
})
$ui.BtnOfflineScan.Add_Click({ Start-Process 'windowsdefender://threatsettings' })

# =====================================================================
#  Sikkerhedstjek
# =====================================================================
$script:SecLoaded = $false
# Gammel driver-scanning er fjernet (antivirus forvekslede den med et angrebsværktøj): ryd dens filer op
foreach ($old in (Join-Path $JobBase 'loldrivers'), (Join-Path $JobBase 'drivers-last.xml')) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
function Load-Secure {
  $ui.WinSecSub.Text = 'Tjekker Windows-beskyttelse...'; $ui.WinSecBig.Text = '…'
  $ui.BtnSecRefresh.IsEnabled = $false
  Invoke-Bg $SecScript @{} {
    param($res, $err, $c)
    $ui.BtnSecRefresh.IsEnabled = $true
    if ($res -is [array]) { $res = @($res | Where-Object { $_.Rows })[-1] }
    if ($err -or -not $res) { $ui.WinSecSub.Text = "Kunne ikke tjekke: $err"; $ui.WinSecBig.Text = '–'; return }
    $rows = foreach ($x in @($res.Rows | Sort-Object @{ e = { @{ 0 = 0; 1 = 1; 3 = 2; 2 = 3 }[[int]$_.Ok] } })) {
      $r = HRow ([int]$x.Ok) $x.Navn $x.Info $x.Note
      $r.Id = $x.Id; $r.Tag = $x; $r
    }
    $ui.GridSecure.ItemsSource = @($rows)
    try { Show-DriverProtection @($res.Rows) } catch {}
    $counted = @($res.Rows | Where-Object { [int]$_.Ok -ne 3 })
    $good = @($counted | Where-Object { [int]$_.Ok -eq 2 }).Count
    $bad = @($counted | Where-Object { [int]$_.Ok -eq 0 }).Count
    $warn = @($counted | Where-Object { [int]$_.Ok -eq 1 }).Count
    $ui.WinSecBig.Text = "$good/$($counted.Count)"
    $ui.WinSecBig.Foreground = $Brush.ConvertFromString($(if ($bad) { '#F87171' } elseif ($warn) { '#F6C344' } else { '#34D399' }))
    $ui.WinSecSub.Text = if ($bad) { "$bad vigtig$(if ($bad -ne 1) { 'e' }) ting at rette og $warn at overveje. Start med de røde." }
                      elseif ($warn) { "Ingen alvorlige huller. $warn ting kan gøre pc'en endnu sikrere." }
                      else { 'Alle Windows'' beskyttelser er slået til. Flot!' }
    $script:SecLoaded = $true
    Log "Sikkerhedstjek: $good/$($counted.Count) ok, $bad røde, $warn gule"
    Update-SecButtons
  } $null
}
function Update-SecButtons {
  $sel = $ui.GridSecure.SelectedItem
  $x = if ($sel) { $sel.Tag } else { $null }
  $needs = $x -and ([int]$x.Ok -ne 2)
  $ui.BtnSecFix.IsEnabled = [bool]($needs -and $x.Fix)
  $ui.BtnSecOpen.IsEnabled = [bool]($x -and $x.Uri)
  if ($x -and ($x.How -or $x.Note)) {
    $ui.SecHintBox.Visibility = 'Visible'
    $ui.SecHintTitle.Text = "$($sel.Status)  $($x.Navn): $($x.Info)"
    $ui.SecHint.Text = $(if ($x.How) { "Gør sådan: $($x.How)" } else { $x.Note })
  } else { $ui.SecHintBox.Visibility = 'Collapsed' }
}
$ui.GridSecure.Add_SelectionChanged({ Update-SecButtons })
$ui.BtnSecRefresh.Add_Click({ Load-Secure })
$ui.BtnSecOpen.Add_Click({
  $x = $ui.GridSecure.SelectedItem.Tag
  if ($x -and $x.Uri) { try { Start-Process $x.Uri } catch { Msg "Kunne ikke åbne indstillingen: $($_.Exception.Message)" | Out-Null } }
})
$ui.BtnSecFix.Add_Click({
  $x = $ui.GridSecure.SelectedItem.Tag
  if (-not $x -or -not $x.Fix) { return }
  $ask = "$($x.Navn): $($x.Info)`n`n$($x.Note)`n`n$($x.How)`n`nVil du have Opticon til at rette det nu?"
  if ((Msg $ask 'Ret sikkerhedsindstilling' 'YesNo' 'Question') -ne 'Yes') { return }
  $ui.BtnSecFix.IsEnabled = $false
  Invoke-Bg $SecFixScript @{ Id = $x.Fix; Name = $x.Navn } {
    param($res, $err, $c)
    if ($res -is [array]) { $res = @($res | Where-Object { $_ -is [string] })[-1] }
    if ($err) { Log "Sikkerhed-ret $($c.Fix) FEJL: $err"; Msg "Det lykkedes ikke:`n$err`n`nDu kan i stedet gøre det selv: $($c.How)" 'Ret sikkerhedsindstilling' 'OK' 'Warning' | Out-Null }
    else { Log "Sikkerhed-ret $($c.Fix): $res"; $ui.StatusText.Text = [string]$res; if ($res -match 'genstart|Genstart') { Msg ([string]$res) 'Klaret' 'OK' 'Information' | Out-Null } }
    Load-Secure
  } @{ Fix = $x.Fix; How = $x.How }
})

# ---------- Sårbare drivere: Windows' egen beskyttelse ----------
function Show-DriverProtection($rows) {
  $bl = @($rows | Where-Object { $_.Id -eq 'blocklist' })[0]; $hv = @($rows | Where-Object { $_.Id -eq 'hvci' })[0]
  $blOn = $bl -and [int]$bl.Ok -eq 2; $hvOn = $hv -and [int]$hv.Ok -eq 2
  if ($blOn -and $hvOn) { $ui.DrvBig.Text = '✓'; $ui.DrvBig.Foreground = $Brush.ConvertFromString('#34D399'); $ui.DrvSub.Text = 'Fuld beskyttelse: Windows blokerer kendte sårbare drivere, og Hukommelsesintegritet er slået til.' }
  elseif ($blOn) { $ui.DrvBig.Text = '½'; $ui.DrvBig.Foreground = $Brush.ConvertFromString('#F6C344'); $ui.DrvSub.Text = 'Kendte sårbare drivere blokeres. Slå også Hukommelsesintegritet til for fuld beskyttelse (se listen ovenfor).' }
  else { $ui.DrvBig.Text = '!'; $ui.DrvBig.Foreground = $Brush.ConvertFromString('#F87171'); $ui.DrvSub.Text = 'Windows blokerer ikke kendte sårbare drivere. Vælg "Blokér sårbare drivere" i listen ovenfor, og tryk Ret det for mig.' }
}
$ui.BtnDrvOpen.Add_Click({ Start-Process 'windowsdefender://coreisolation' })
# ---------- MalwareBazaar-nøgle (valgfri, gemt krypteret med Windows DPAPI for denne bruger) ----------
$MbKeyFile = Join-Path $JobBase 'abusech-key.dat'
Add-Type -AssemblyName System.Security
function Get-MbKey {
  if (-not (Test-Path $MbKeyFile)) { return $null }
  try {
    $raw = [IO.File]::ReadAllText($MbKeyFile).Trim()
    if ($raw -like 'v2:*') {   # Windows DPAPI for denne bruger (kan kun læses af dig på denne pc)
      $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($raw.Substring(3)), [Text.Encoding]::UTF8.GetBytes('Opticon-MB'), 'CurrentUser')
      return [Text.Encoding]::UTF8.GetString($bytes)
    }
    $ss = ConvertTo-SecureString $raw -ErrorAction Stop   # gammelt format (2.38-2.42)
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
  } catch {
    if (-not $script:MbErrLogged) { Log "MalwareBazaar-nøgle kunne ikke læses: $($_.Exception.Message)"; $script:MbErrLogged = $true }
    return $null
  }
}
function Save-MbKey([string]$plain) {
  $enc = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($plain), [Text.Encoding]::UTF8.GetBytes('Opticon-MB'), 'CurrentUser')
  $tmp = "$MbKeyFile.tmp"
  [IO.File]::WriteAllText($tmp, 'v2:' + [Convert]::ToBase64String($enc))
  if (Test-Path -LiteralPath $MbKeyFile) { Remove-Item -LiteralPath $MbKeyFile -Force -ErrorAction Stop }
  Move-Item -LiteralPath $tmp -Destination $MbKeyFile -Force -ErrorAction Stop
  $script:MbErrLogged = $false
  if ((Get-MbKey) -ne $plain) { throw 'Nøglen blev gemt, men kunne ikke læses tilbage.' }
}
function Show-MbState {
  $has = [bool](Get-MbKey)
  $ui.BtnMbFile.IsEnabled = $has; $ui.BtnMbRemove.IsEnabled = $has
  if ($has) {
    $ui.MbBig.Text = 'Til'; $ui.MbBig.Foreground = $Brush.ConvertFromString('#34D399')
    if (-not $script:MbMsg) { $ui.MbSub.Text = 'Slået til. Nye usignerede filer tjekkes ved hver scanning, og du kan tjekke en enkelt fil.' }
  } else {
    $ui.MbBig.Text = 'Fra'; $ui.MbBig.Foreground = $Brush.ConvertFromString('#6B7488')
    if (-not $script:MbMsg) { $ui.MbSub.Text = 'Slået fra. Alt andet i Opticon virker fint uden.' }
  }
  $script:MbMsg = $false
}
function Invoke-MbLookup($key, [string[]]$hashes, [scriptblock]$then, $ctx) {
  Invoke-Bg $MbLookupScript @{ Key = $key; Hashes = $hashes } {
    param($res, $err, $c)
    if ($res -is [array]) { $res = @($res | Where-Object { $_.Results })[-1] }
    $list = @(); if ($res) { $list = @($res.Results) }
    & $c.Then $list $err $c.Ctx
  } @{ Then = $then; Ctx = $ctx }
}
$ui.BtnMbOpen.Add_Click({ Start-Process 'https://auth.abuse.ch/' })
$ui.BtnMbSave.Add_Click({
  $plain = $ui.MbKeyBox.Password.Trim()
  if ($plain.Length -lt 20 -or $plain -match '\s') { Msg 'Det ligner ikke en Auth-Key. Den er en lang række bogstaver og tal uden mellemrum. Kopiér den igen fra din kontoside på abuse.ch.' 'MalwareBazaar' 'OK' 'Warning' | Out-Null; return }
  $ui.BtnMbSave.IsEnabled = $false; $ui.MbSub.Text = 'Tester nøglen...'
  # Test med et tilfældigt fingeraftryk: "ikke fundet" betyder, at nøglen virker
  $probe = -join ((1..64) | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
  Invoke-MbLookup $plain @($probe) {
    param($results, $err, $ctx)
    $ui.BtnMbSave.IsEnabled = $true
    $results = @($results)
    $st = if ($results.Count) { [string]$results[0].Status } elseif ($err) { "fejl: $err" } else { 'intet svar' }
    if ($st -eq 'hash_not_found' -or $st -eq 'ok') {
      try {
        Save-MbKey $ctx.Key
        $ui.MbKeyBox.Clear()
        Log 'MalwareBazaar-nøgle gemt (krypteret)'
        $ui.MbSub.Text = '✓ Nøglen virker og er gemt krypteret. Nye usignerede filer tjekkes nu ved hver scanning.'; $script:MbMsg = $true
      } catch { Log "MalwareBazaar-nøgle kunne ikke gemmes: $($_.Exception.Message)"; $ui.MbSub.Text = "Nøglen virker, men kunne ikke gemmes: $($_.Exception.Message)"; $script:MbMsg = $true }
    } elseif ($st -eq 'auth' -or $st -match '(?i)auth|key') {
      $ui.MbSub.Text = '✗ abuse.ch kender ikke nøglen. Tjek at du har kopieret hele Auth-Key fra din kontoside.'; $script:MbMsg = $true
    } else {
      $ui.MbSub.Text = "✗ Kunne ikke teste nøglen lige nu ($st). Tjek internettet, og prøv igen."; $script:MbMsg = $true
    }
    Show-MbState
  } @{ Key = $plain }
})
$ui.BtnMbRemove.Add_Click({
  if ((Msg 'Fjern MalwareBazaar-nøglen fra denne pc? Det ekstra virustjek slås fra.' 'MalwareBazaar' 'YesNo' 'Question') -ne 'Yes') { return }
  Remove-Item $MbKeyFile -Force -ErrorAction SilentlyContinue; Log 'MalwareBazaar-nøgle fjernet'; Show-MbState
})
$ui.BtnMbFile.Add_Click({
  $dlg = New-Object Microsoft.Win32.OpenFileDialog
  $dlg.Title = 'Vælg en fil, du vil tjekke'; $dlg.InitialDirectory = (Join-Path $env:USERPROFILE 'Downloads')
  if (-not $dlg.ShowDialog()) { return }
  $f = $dlg.FileName
  try { $sha = (Get-FileHash -LiteralPath $f -Algorithm SHA256 -ErrorAction Stop).Hash } catch {
    Msg "Kunne ikke læse filen. Hvis Windows nægter at åbne den, har Defender sandsynligvis allerede blokeret den som virus.`n`n$($_.Exception.Message)" 'Tjek en fil' 'OK' 'Warning' | Out-Null; return
  }
  $sig = $null; try { $sig = Get-AuthenticodeSignature -LiteralPath $f } catch {}
  $ui.MbSub.Text = "Tjekker $(Split-Path $f -Leaf)..."; $script:MbMsg = $true
  Invoke-MbLookup (Get-MbKey) @($sha) {
    param($results, $err, $ctx)
    $results = @($results)
    $r = if ($results.Count) { $results[0] } else { $null }
    $name = Split-Path $ctx.File -Leaf
    $signed = if ($ctx.Sig -and $ctx.Sig.Status -eq 'Valid') { "Signeret af: $(([string]$ctx.Sig.SignerCertificate.Subject -replace '^CN=([^,]+).*$', '$1'))" } else { 'Ikke digitalt signeret' }
    if ($r -and $r.Status -eq 'ok') {
      Log "MalwareBazaar: KENDT MALWARE $name ($($r.Signature))"
      $ui.MbSub.Text = "⚠ $name er kendt malware."; $script:MbMsg = $true
      Msg "⚠  KENDT MALWARE`n`n$name findes i MalwareBazaar.`n`nFamilie: $(if ($r.Signature) { $r.Signature } else { 'ukendt' })`nFørst set: $($r.FirstSeen)`nMærker: $($r.Tags)`n`nÅbn den IKKE. Slet den, og kør en Defender-scanning. Har du allerede åbnet den, så kør Defender Offline-scan (under Ydelse og helbred), og skift dine vigtigste adgangskoder fra en anden enhed." 'Tjek en fil' 'OK' 'Error' | Out-Null
    } elseif ($r -and $r.Status -eq 'hash_not_found') {
      $ui.MbSub.Text = "✓ $name er ikke kendt malware."; $script:MbMsg = $true
      Msg "✓  Ikke kendt malware`n`n$name findes ikke blandt de over 1 million kendte malware-filer.`n$signed`n`nGod at vide: helt ny malware er ikke altid nået ind i databasen endnu. Er du stadig i tvivl, så tjek den også på VirusTotal, eller lad være med at åbne den." 'Tjek en fil' 'OK' 'Information' | Out-Null
    } else {
      $why = if ($r) { $r.Status } else { $err }
      $ui.MbSub.Text = "Kunne ikke tjekke filen ($why)."; $script:MbMsg = $true
    }
    Show-MbState
  } @{ File = $f; Sig = $sig }
})

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
    try { $cc = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"; $ui.SpaceSub.Text = "kan ryddes · $([math]::Round($cc.FreeSpace / 1GB)) GB ledig på C:$(if ($script:SpaceDeltaTxt) { ' · ' + $script:SpaceDeltaTxt })" } catch {}
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
      if ($ok) { Mark-StartupChange; try { Note-StartupChange "$ok programmer slået fra (planen)" } catch {} }
      Load-Startup
      if ($fail.Count) { Set-StepState 'startup' 'fail' "$ok af $($t.Count) slået fra · ikke: $($fail -join ', ')" } else { Set-StepState 'startup' 'done' "$ok slået fra" }
      Log "Plan: opstart $ok/$($t.Count)"
    }
    'clean' {
      Set-StepState 'clean' 'busy' 'Rydder op...'
      $cats = @($CleanCats | Where-Object { $_.Default })
      $freeBefore = $null; try { $freeBefore = (Get-PSDrive ($env:SystemDrive.Substring(0, 1))).Free } catch {}
      Invoke-Bg $CleanRunScript @{ Cats = $cats } {
        param($res, $err, $c)
        try { Note-CleanResult $c.FreeBefore } catch {}
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
      Invoke-Bg $WingetListScript @{ LogFile = $LogFile } {
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
      shutdown.exe /r /t 30 /c "Opticon genstarter pc'en om 30 sekunder."
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
    $ui.RamStepsText.Text = "Avanceret: gør det kun, hvis du er tryg ved at ændre i BIOS.`n`n1.  Tryk på 'Genstart til BIOS' (eller genstart, og tryk gentagne gange på Del, mens pc'en starter).`n2.  $bios`n3.  Tryk F10 for at gemme og genstarte.`n4.  Åbn Opticon igen, og tryk 'Tjek igen'. Nu bør der stå $($r.Rated) MT/s.`n`nStarter pc'en ikke bagefter, venter den typisk lidt og nulstiller selv. Ellers så slå $($r.Prof) fra igen."
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
    $vi = $null; try { $vi = Get-VendorInfo } catch {}
    if ($vi -and $vi.Tool -and $vi.Tool.Name -ne 'Windows Update') {
      $vn = if ($vi.App) { $vi.App.Name } else { $vi.Tool.Name }
      $ui.DrvAction2.Content = "💻  BIOS og drivere: $(if ($vi.App) { 'åbn' } else { 'hent' }) $vn"
      $ui.DrvStepsText.Text += "`n`nPå din $($vi.Man): brug hellere $vn. $($vi.Tool.Where)"
    } else { $ui.DrvAction2.Content = '🔎  Find BIOS-opdatering' }
    $ui.DrvAction2.Visibility = 'Visible'
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
  if ((Msg "Pc'en genstarter om 10 sekunder og åbner BIOS'en direkte.`n`nGem dit arbejde først. Guiden står i Opticon under 'Sådan gør du'. Tag gerne et billede af den med telefonen.`n`nGenstart nu?" 'Genstart til BIOS' 'YesNo' 'Question') -ne 'Yes') { return }
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
  $vi = $null; try { $vi = Get-VendorInfo } catch {}
  if ($vi -and $vi.Tool -and $vi.Tool.Name -ne 'Windows Update') { Open-VendorTool; return }
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
  # Fire uafhængige tegn: Vagtens lås, opgavens status, processen og hjerteslaget. Ét er nok.
  $why = @()
  try { $mx = [Threading.Mutex]::OpenExisting('Global\PCTjekVagt'); $mx.Dispose(); return $true } catch [Threading.WaitHandleCannotBeOpenedException] { $why += 'ingen lås' } catch { return $true }   # adgang nægtet = låsen findes
  try { if ((Get-VagtTask).State -eq 'Running') { return $true } else { $why += "opgave: $((Get-VagtTask).State)" } } catch {}
  if ((Get-VagtProc).Count) { return $true } else { $why += 'ingen proces' }
  try { $st = Get-Content (Join-Path $JobBase 'vagt-status.json') -Raw -ErrorAction Stop | ConvertFrom-Json; $age = ((Get-Date) - [datetime]$st.Heartbeat).TotalSeconds; if ($age -lt 90) { return $true }; $why += "hjerteslag $([int]$age) s gammelt" } catch { $why += "status: $($_.Exception.Message)" }
  if ($script:LastVagtWhy -ne ($why -join ', ')) { $script:LastVagtWhy = ($why -join ', '); Log "Vagt ikke fundet: $($script:LastVagtWhy)" }
  return $false
}
# Opgaver starter PowerShell direkte og med RemoteSigned,
# så antivirus som Bitdefender ikke forveksler Opticon med et angreb.
function New-PsTaskAction([string]$file) {
  $sys = Join-Path $env:SystemRoot 'System32'
  New-ScheduledTaskAction -Execute "$sys\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy RemoteSigned -STA -WindowStyle Hidden -File `"$file`"" -WorkingDirectory $PSScriptRoot
}
function New-VagtAction { New-PsTaskAction $VagtScript }
function Test-OldTaskAction($t) {
  $a = @($t.Actions)[0]
  return ($a -and (([string]$a.Execute) -match '(?i)conhost' -or ([string]$a.Arguments) -notmatch '(?i)RemoteSigned'))
}
# Flyt eksisterende opgaver over på den nye, rolige startmåde (én gang)
function Update-TaskActions {
  if ($PSScriptRoot -notlike "$env:ProgramFiles\*") { return }
  try {
    $vt = Get-ScheduledTask -TaskName 'PC-Tjek Vagt' -ErrorAction SilentlyContinue
    if ($vt -and (Test-OldTaskAction $vt) -and (Test-Path $VagtScript)) {
      Set-ScheduledTask -TaskName 'PC-Tjek Vagt' -TaskPath '\' -Action (New-VagtAction) -ErrorAction Stop | Out-Null
      Log 'Vagtens opgave bruger nu den nye startmåde'
    }
  } catch { Log "Kunne ikke opdatere Vagtens opgave: $_" }
}
function Install-Vagt {
  if ($PSScriptRoot -notlike "$env:ProgramFiles\*") { Msg "Vagten kan kun slås til, når Opticon er installeret med installeren (i Program Files).`n`nKør 'Installer Opticon.cmd' først." 'Vagt' 'OK' 'Warning' | Out-Null; return $false }
  if (-not (Test-Path $VagtScript)) { Msg "Filen PC-Tjek-Vagt.ps1 mangler. Opdatér Opticon, eller kør installeren igen." 'Vagt' 'OK' 'Warning' | Out-Null; return $false }
  try {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $sys = Join-Path $env:SystemRoot 'System32'
    $action = New-VagtAction
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName 'PC-Tjek Vagt' -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Opticon Vagt: tjekker downloads og nye opstartsprogrammer. Starter ved login.' -Force | Out-Null
    Save-VagtCfg
    Restart-Vagt
    Log 'Vagt slået til'
    return $true
  } catch { Msg "Kunne ikke slå vagten til: $($_.Exception.Message)" 'Vagt' 'OK' 'Error' | Out-Null; return $false }
}
function Remove-Vagt {
  # Sæt en aktiv tilstand tilbage FØR Vagten stoppes, så intet bliver hængende
  try { $s = Restore-Everything 'Vagten blev slået fra'; if ($s) { Show-ModeSummary $s } } catch { Log "Gendannelse før vagt-stop fejlede: $_" }
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
  if (Test-Path $VagtCfg) { try { $j = Get-Content $VagtCfg -Raw -ErrorAction Stop | ConvertFrom-Json; $script:VagtLoading = $true; $ui.ChkDl.IsChecked = ($j.Downloads -ne $false); $ui.ChkWd.IsChecked = ($j.Watchdog -ne $false); $script:VagtLoading = $false } catch { $script:VagtLoading = $false; Log "Vagt-indstillinger kunne ikke læses: $($_.Exception.Message)" } }
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
  shutdown.exe /r /t 30 /c "Opticon genstarter for at færdiggøre en opdatering."
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
  [void]$lines.Add("Opticon – pc-oplysninger ($(Get-Date -Format 'dd-MM-yyyy HH:mm'))")
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
  if (-not $smi) {
    # AMD/Intel: belastning fra Windows; watt for hele pc'en, når den kører på batteri
    $u = $null; try { $u = [math]::Min(100, [math]::Round((@(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop | Where-Object { $_.Name -like '*engtype_3D*' }) | Measure-Object UtilizationPercentage -Sum).Sum)) } catch {}
    $bt = $null; try { $bt = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1 } catch {}
    $ui.GpuLiveU.Text = $(if ($null -ne $u) { "$u %" } else { 'n/a' })
    $ui.GpuLiveW.Text = $(if ($bt -and -not $bt.PowerOnline -and $bt.DischargeRate -gt 0) { "$([math]::Round($bt.DischargeRate / 1000)) W (pc)" } elseif ($bt) { 'på strøm' } else { 'n/a' })
    $ui.GpuLiveT.Text = 'n/a'; $ui.GpuLiveF.Text = 'n/a'; $ui.GpuLiveC.Text = 'n/a'
    return
  }
  $q = & $smi -i (Get-GpuId) --query-gpu=power.draw,power.limit,temperature.gpu,fan.speed,clocks.gr,utilization.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1
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

$GpuPlFile = Join-Path $JobBase 'gpu-pl.json'
function Smi-Q($fields) {
  $smi = Get-Smi; if (-not $smi) { return @() }
  $inv = [Globalization.CultureInfo]::InvariantCulture
  @((& $smi -i (Get-GpuId) "--query-gpu=$fields" --format=csv,noheader,nounits 2>$null | Select-Object -First 1) -split ',\s*' | ForEach-Object { $v = 0.0; if ([double]::TryParse(([string]$_).Trim(), [Globalization.NumberStyles]::Float, $inv, [ref]$v)) { $v } else { $null } })
}
function Pct-Str($a, $b) { if (-not $a -or $null -eq $b) { return '' }; $d = [math]::Round(($b - $a) / $a * 100); return " ($(if ($d -gt 0) { '+' })$d %)" }
function Start-GpuBench($mode) {
  if ($mode -ne 'bench' -and -not (Confirm-ModeFree 'GPU-testen')) { return }
  if ($mode -eq 'auto' -and -not (Get-Smi)) {
    # AMD/Intel: afprøv Windows' tre strømtilstande i stedet for strømgrænser
    $cur = Get-PowerMode
    if (-not $cur) { Msg "Windows' strømtilstande kan ikke styres på denne pc (det sker fx, hvis en anden strømplan end 'Balanceret' er valgt i Kontrolpanel)." 'GPU' | Out-Null; return }
    $bt = $null; try { $bt = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1 } catch {}
    $battTxt = if ($bt -and $bt.PowerOnline) { "`n`n🔌 Tip: Tag laderen ud før testen. Så kan Opticon også måle, hvor mange watt pc'en bruger i hver tilstand. Med laderen i måles kun FPS." } elseif ($bt) { "`n`n🔋 Du kører på batteri, så Opticon måler også, hvor mange watt pc'en bruger." } else { '' }
    if ((Msg "Testen tager ca. 3 minutter:`n`n•  En 3D-testscene vises i fuld skærm.`n•  Opticon prøver Windows' 3 strømtilstande: Bedste energieffektivitet, Balanceret og Bedste ydeevne.`n•  Rør ikke musen, og luk tunge programmer først.`n•  Tryk Esc for at stoppe.$battTxt`n`nDin nuværende tilstand ($(PowerMode-Name $cur)) sættes tilbage bagefter.`n`nStart testen?" 'Find den bedste strømtilstand' 'YesNo' 'Question') -ne 'Yes') { return }
    $arg = @{ Html = $GpuBenchHtml; Steps = @($null, $null, $null); Modes = @($PowerModeList | ForEach-Object { $_.Guid }); Work = 0; StepSec = 40; Dir = (Join-Path $JobRoot ('bench-' + [guid]::NewGuid().ToString('N'))); RestoreFile = $GpuRestoreFile; GpuId = (Get-GpuId) }
    $ui.GridGpuAuto.Visibility = 'Collapsed'; $ui.GpuRecBox.Visibility = 'Collapsed'; $ui.GpuAutoBar.Visibility = 'Visible'; $ui.GpuAutoBar.Value = 0
  } elseif ($mode -eq 'auto') {
    $l = Smi-Q 'power.default_limit,power.min_limit,power.max_limit'
    $def = $l[0]; $min = $l[1]
    if (-not $def) { Msg 'Dit grafikkort tillader ikke, at strømgrænsen ændres (det er fx tilfældet på mange bærbare). Brug i stedet "Test dine egne indstillinger".' 'GPU' | Out-Null; return }
    $steps = @(100, 90, 80, 70 | ForEach-Object { [math]::Max($min, $def * $_ / 100) } | Select-Object -Unique)
    if ((Msg "Testen tager ca. 4 minutter:`n`n•  En 3D-testscene vises i fuld skærm.`n•  Opticon prøver strømgrænserne 100, 90, 80 og 70 %.`n•  Rør ikke musen, og luk spil og tunge programmer først.`n•  Tryk Esc for at stoppe.`n`nDin oprindelige indstilling gendannes bagefter. Hvis du bruger MSI Afterburner, så luk den først.`n`nStart testen?" 'Find det bedste punkt' 'YesNo' 'Question') -ne 'Yes') { return }
    $arg = @{ Html = $GpuBenchHtml; Steps = $steps; Work = 0; StepSec = 40; Dir = (Join-Path $JobRoot ('bench-' + [guid]::NewGuid().ToString('N'))); RestoreFile = $GpuRestoreFile; GpuId = (Get-GpuId) }
    $ui.GridGpuAuto.Visibility = 'Collapsed'; $ui.GpuRecBox.Visibility = 'Collapsed'; $ui.GpuAutoBar.Visibility = 'Visible'; $ui.GpuAutoBar.Value = 0
  } elseif ($mode -eq 'bench') {
    $nat = Get-NativeRes; $script:BenchNativeRes = $(if ($nat -and $nat -ne '1920x1080') { $nat } else { $null })
    # 1080p (til sammenligning) + din skærm + 4K (mange spiller på 4K-tv eller -skærm)
    $resL = @('1920x1080'); if ($script:BenchNativeRes -and $script:BenchNativeRes -ne '3840x2160') { $resL += $script:BenchNativeRes }; $resL += '3840x2160'
    $arg = @{ Html = $GpuBenchHtml; Steps = @($resL | ForEach-Object { $null }); Res = $resL; Work = 0; StepSec = 25; Dir = (Join-Path $JobRoot ('bench-' + [guid]::NewGuid().ToString('N'))); RestoreFile = $GpuRestoreFile; GpuId = (Get-GpuId) }
  } elseif ($mode -in 'ocbase', 'occheck') {
    if ($mode -eq 'occheck' -and -not $script:OcBase) { Msg 'Mål udgangspunktet først (trin 1), før du overclocker.' 'OC-tjek' | Out-Null; return }
    if ($mode -eq 'occheck') {
      if ((Msg "OC-tjekket kører testscenen i 2K i 5 minutter og holder øje med:`n`n•  om grafikdriveren går ned eller genstarter`n•  om Windows logger fejl fra grafikkortet`n•  pludselige FPS-fald, clock og temperatur`n`nBliver skærmen sort et øjeblik, er det driveren, der genstarter. Det er netop det, testen leder efter. Gem dit arbejde først, og rør ikke musen.`n`nStart?" 'OC-tjek' 'YesNo' 'Question') -ne 'Yes') { return }
    }
    $arg = @{ Html = $GpuBenchHtml; Steps = @($null); Res = @('2560x1440'); Work = 0; StepSec = $(if ($mode -eq 'ocbase') { 50 } else { 300 }); Dir = (Join-Path $JobRoot ('bench-' + [guid]::NewGuid().ToString('N'))); RestoreFile = $GpuRestoreFile; GpuId = (Get-GpuId) }
    $script:OcStart = Get-Date
    $ui.GpuOcBar.Visibility = 'Visible'; $ui.GpuOcBar.Value = 0; $ui.GpuOcBox.Visibility = 'Collapsed'
  } elseif ($mode -eq 'res') {
    $cur = (Smi-Q 'power.limit')[0]
    $prof = Get-GpuProfileW
    $cmp = [bool]$ui.ChkGpuResCmp.IsChecked -and $prof -gt 0 -and $cur -and [math]::Abs($prof - $cur) -gt 5
    $resList = '1920x1080', '2560x1440', '3840x2160'
    $st = New-Object System.Collections.ArrayList; $rl = New-Object System.Collections.ArrayList
    foreach ($r in $resList) { [void]$st.Add($null); [void]$rl.Add($r) }
    if ($cmp) { foreach ($r in $resList) { [void]$st.Add([double]$prof); [void]$rl.Add($r) } }
    $mins = if ($cmp) { 3 } else { '1½' }
    if ((Msg "Testen tager ca. $mins minut$(if ($cmp) { 'ter' }):`n`n•  Testscenen vises i fuld skærm i Full HD, 2K og 4K$(if ($cmp) { ", først som nu og så med din GPU-profil ($prof W)" }).`n•  Billedet skaleres til din skærm, så det kan se lidt sløret eller småt ud. Det er meningen.`n•  Rør ikke musen, og luk spil og tunge programmer først.`n•  Tryk Esc for at stoppe.`n`nStart testen?" 'FPS ved forskellige opløsninger' 'YesNo' 'Question') -ne 'Yes') { return }
    $arg = @{ Html = $GpuBenchHtml; Steps = @($st); Res = @($rl); Work = 0; StepSec = 20; Dir = (Join-Path $JobRoot ('bench-' + [guid]::NewGuid().ToString('N'))); RestoreFile = $GpuRestoreFile; GpuId = (Get-GpuId) }
    $ui.GridGpuRes.Visibility = 'Collapsed'; $ui.GpuResVerdict.Visibility = 'Collapsed'; $ui.GpuResBar.Visibility = 'Visible'; $ui.GpuResBar.Value = 0
  } else {
    if ($mode -eq 'after' -and -not $script:GpuWork) { Msg 'Mål FØR først.' 'GPU' | Out-Null; return }
    $arg = @{ Html = $GpuBenchHtml; Steps = @($null); Work = $(if ($mode -eq 'after') { $script:GpuWork } else { 0 }); StepSec = 45; Dir = (Join-Path $JobRoot ('bench-' + [guid]::NewGuid().ToString('N'))); RestoreFile = $GpuRestoreFile; GpuId = (Get-GpuId) }
    $ui.GpuMeasureBar.Visibility = 'Visible'; $ui.GpuMeasureBar.Value = 0
    $ui.GpuResult.Text = "Måler $(if ($mode -eq 'before') { 'FØR' } else { 'EFTER' })... Testscenen åbner i fuld skærm om et øjeblik. Rør ikke musen."
    $ui.GpuVerdict.Text = ''
  }
  $script:GpuMeasuring = $true
  try { $win.WindowState = 'Minimized' } catch {}   # testscenen skal ligge forrest, ellers holder Edge op med at tegne
  $ui.BtnGpuAuto.IsEnabled = $false; $ui.BtnGpuBefore.IsEnabled = $false; $ui.BtnGpuAfter.IsEnabled = $false; $ui.BtnGpuRes.IsEnabled = $false; $ui.BtnOcBase.IsEnabled = $false; $ui.BtnOcCheck.IsEnabled = $false
  Invoke-Bg $GpuBenchScript $arg {
    param($res, $err, $c)
    $script:GpuMeasuring = $false
    try { $win.WindowState = 'Normal' } catch {}
    if ($res -and -not ($res -is [array])) { Log "GPU-test ($($c.GpuMode)): fps-målinger=$($res.FpsPosts) · kalibreret=$($res.Calib) · stoppet=$($res.Aborted) · driver nulstillet=$($res.Lost) · browser=$($res.Browser) · grafik=$($res.Renderer) · $($res.Diag)$(if ($res.JsErr) { " · sidefejl: $($res.JsErr)" })" }
    $ui.BtnGpuAuto.IsEnabled = $true; $ui.BtnGpuBefore.IsEnabled = $true; $ui.BtnGpuAfter.IsEnabled = [bool]$script:GpuWork; $ui.BtnGpuRes.IsEnabled = $true; $ui.BtnOcBase.IsEnabled = $true; $ui.BtnOcCheck.IsEnabled = [bool]$script:OcBase
    $ui.GpuAutoBar.Visibility = 'Collapsed'; $ui.GpuMeasureBar.Visibility = 'Collapsed'; $ui.GpuResBar.Visibility = 'Collapsed'; $ui.GpuOcBar.Visibility = 'Collapsed'
    try { $win.Activate() | Out-Null } catch {}
    if ($res -is [array]) { $res = @($res | Where-Object { $_ -is [Collections.IDictionary] })[-1] }
    $steps = @(); if ($res) { foreach ($st in @($res.Steps)) { if ($null -ne $st -and $st.Fps) { $steps += $st } } }
    if ($res -and -not ($res -is [array])) { Log "GPU-test resultat: $(@($res.Steps).Count) trin, $($steps.Count) med FPS$(if (@($res.Steps).Count) { ' · første: fps=' + @($res.Steps)[0].Fps + ' p1=' + @($res.Steps)[0].P1 })" }
    if ($c.GpuMode -eq 'occheck' -and $res -and $res.Lost) { Show-OcCheck $res $steps; return }   # et nedbrud ER resultatet
    if ($c.GpuMode -eq 'bench') {
      $script:LastGpuRenderer = if ($res -and -not ($res -is [array])) { [string]$res.Renderer } else { '' }
      $why = if ($err) { $err } elseif ($steps.Count) { $null } elseif ($res -and $res.Lost) { 'grafikdriveren nulstillede testscenen' } elseif ($res -and $res.Aborted) { 'testen blev stoppet' } elseif ($res -and -not $res.FpsPosts) { 'testscenen tegnede ingen billeder (lå den bag et andet vindue?)' } else { 'ingen målinger' }
      $s1080 = @($steps | Where-Object { $_.Res -eq '1920x1080' })[0]; $s4k = @($steps | Where-Object { $_.Res -eq '3840x2160' })[0]
      $sNat = if ($script:BenchNativeRes) { @($steps | Where-Object { $_.Res -eq $script:BenchNativeRes })[0] } else { $null }
      $script:Bench4k = $s4k
      if (-not $s1080 -and $steps.Count) { $why = 'grafikdelen (1080p) fejlede' }
      Finish-Bench $s1080 $why $sNat; return
    }
    # Anbefal kun noget, hvis det er det samme NVIDIA-kort, der tegnede testscenen, som Opticon ville ændre på
    if (-not $err -and $res -and $res.HasSmi -and $res.Renderer -and [string]$res.Renderer -notmatch '(?i)nvidia') {
      $msg = "Testscenen blev tegnet af $($res.Renderer) og ikke af dit NVIDIA-kort, så Opticon anbefaler ingen ændring. Indstillinger → System → Skærm → Grafik → Microsoft Edge → Høj ydeevne. Prøv derefter igen."
      Log "GPU-test: forkert grafikkort tegnede scenen ($($res.Renderer))"
      if ($c.GpuMode -eq 'auto') { $ui.GpuAutoInfo.Text = "⚠ $msg" } elseif ($c.GpuMode -eq 'res') { $ui.GpuResInfo.Text = "⚠ $msg" } elseif ($c.GpuMode -like 'oc*') { $ui.GpuOcInfo.Text = "⚠ $msg" } else { $ui.GpuResult.Text = "⚠ $msg" }
      return
    }
    if ($err -or -not $steps.Count) {
      $msg = if ($err) { $err } elseif ($res -and $res.Lost) { 'Grafikdriveren nulstillede testscenen undervejs.' } elseif ($res -and $res.Aborted) { 'Testen blev stoppet.' } elseif ($res -and -not $res.FpsPosts) { "Testscenen tegnede ingen billeder. Det sker typisk, hvis testvinduet lå bag et andet vindue. Prøv igen, og klik på testscenen, hvis den ikke kommer forrest.$(if ($res.JsErr) { " (Sidefejl: $($res.JsErr))" })" } else { 'Testscenen gav ingen målinger.' }
      if ($c.GpuMode -eq 'auto') { $ui.GpuAutoInfo.Text = "⚠ $msg" } elseif ($c.GpuMode -eq 'res') { $ui.GpuResInfo.Text = "⚠ $msg" } elseif ($c.GpuMode -like 'oc*') { $ui.GpuOcInfo.Text = "⚠ $msg" } else { $ui.GpuResult.Text = "⚠ $msg" }
      return
    }
    try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
    if ($c.GpuMode -eq 'auto' -and -not $res.HasSmi) { Show-PowerModes $res $steps }
    elseif ($c.GpuMode -eq 'auto') { Show-GpuAuto $res $steps }
    elseif ($c.GpuMode -eq 'res') { Show-GpuRes $steps }
    elseif ($c.GpuMode -eq 'ocbase') {
      $script:OcBase = $steps[0]
      try { [IO.File]::WriteAllText((Join-Path $OutDir 'gpu-oc-udgangspunkt.json'), ($steps[0] | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch {}
      Show-OcBase; try { Show-OcEstimate } catch { Log "OC-skøn fejl: $_" }; $ui.BtnOcCheck.IsEnabled = $true
      $ui.GpuOcInfo.Text = "✓ Udgangspunktet er gemt. Overclock nu (trin 2), og tryk så '3 · Tjek OC'."
    }
    elseif ($c.GpuMode -eq 'occheck') { Show-OcCheck $res $steps }
    elseif ($c.GpuMode -eq 'before') {
      $script:GpuBefore = $steps[0]; $script:GpuAfter = $null; $script:GpuWork = $res.Work
      $b = $steps[0]
      $ui.GpuResult.Text = "FØR: $($b.Fps) fps$(if ($b.P1) { " · laveste 1 % $([math]::Round($b.P1))" })$(if ($null -ne $b.W) { " · $([math]::Round($b.W)) W" })$(if ($null -ne $b.T) { " · $([math]::Round($b.T)) °C" })$(if ($null -ne $b.F) { " · blæser $([math]::Round($b.F)) %" })$(if ($b.C) { " · $([math]::Round($b.C)) MHz" })"
      $ui.GpuVerdict.Text = "Lav nu ÉN ændring i Afterburner (fx en spændingskurve eller et lavere power limit), og tryk så 'Mål EFTER'."
      $ui.BtnGpuAfter.IsEnabled = $true
    } else { $script:GpuAfter = $steps[0]; Show-GpuCompare }
  } @{ GpuMode = $mode }
  if (-not $script:GpuProgTimer) {
    $script:GpuProgTimer = New-Object Windows.Threading.DispatcherTimer
    $script:GpuProgTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:GpuProgTimer.Add_Tick({
      if (-not $script:GpuMeasuring) { $script:GpuProgTimer.Stop(); return }
      $j = $script:Jobs | Where-Object { $_.Ctx -is [hashtable] -and $_.Ctx.GpuMode } | Select-Object -First 1
      if (-not $j) { return }
      $p = [double]$j.S.Progress
      if ($j.Ctx.GpuMode -eq 'auto') { if ($p -ge 0) { $ui.GpuAutoBar.Value = $p }; if ($j.S.Status) { $ui.GpuAutoInfo.Text = $j.S.Status } }
      elseif ($j.Ctx.GpuMode -eq 'bench') { if ($p -ge 0) { $ui.BenchBar.Value = 75 + $p / 4 }; $ui.BenchStatus.Text = "Grafik · testscenen i 1080p$(if ($script:BenchNativeRes -and $script:BenchNativeRes -ne '3840x2160') { ", $(($script:BenchNativeRes) -replace 'x', '×')" }) og 4K$(Bench-Remain (75 + [math]::Max(0, $p) / 4))" }
      elseif ($j.Ctx.GpuMode -like 'oc*') { if ($p -ge 0) { $ui.GpuOcBar.Value = $p }; if ($j.S.Status) { $ui.GpuOcInfo.Text = $j.S.Status } }
      elseif ($j.Ctx.GpuMode -eq 'res') { if ($p -ge 0) { $ui.GpuResBar.Value = $p }; if ($j.S.Status) { $ui.GpuResInfo.Text = $j.S.Status } }
      else { if ($p -ge 0) { $ui.GpuMeasureBar.Value = $p }; if ($j.S.Status) { $ui.GpuMeasureInfo.Text = $j.S.Status } }
    })
  }
  $script:GpuProgTimer.Start()
}
$ResNames = @{ '1920x1080' = 'Full HD · 1080p'; '2560x1440' = '2K · 1440p'; '3840x2160' = '4K · 2160p' }
$ResShort = @{ '1920x1080' = 'Full HD'; '2560x1440' = '2K'; '3840x2160' = '4K' }
function Show-GpuRes($steps) {
  $max = [double](@($steps) | Measure-Object Fps -Maximum).Maximum; if ($max -le 0) { $max = 1 }
  $rows = @(foreach ($s in $steps) {
    $r = New-Object PcTjek.Row
    $r.Navn = $(if ($ResNames.ContainsKey([string]$s.Res)) { $ResNames[[string]$s.Res] } else { [string]$s.Res })
    $r.Info = $(if ($s.Pl) { "profil · $([math]::Round($s.Pl)) W" } else { 'som nu' })
    $r.Note = "$([math]::Round($s.Fps)) fps$(if (Test-HzCap $s) { ' (skærm-loft?)' })"
    $r.Gruppe = $(if ($s.P1) { "$([math]::Round($s.P1)) fps" } else { '–' })
    $r.Status = "$(if ($s.W) { [math]::Round($s.W) } else { '–' }) W · $(if ($s.T) { [math]::Round($s.T) } else { '–' }) °C"
    $r.Id = $(if ($s.W) { '{0:N2}' -f ($s.Fps / $s.W) } else { '–' })
    $r.Tal = [math]::Max(4, 150 * [double]$s.Fps / $max)
    $r })
  $ui.GridGpuRes.ItemsSource = $rows; $ui.GridGpuRes.Visibility = 'Visible'
  $now = @{}; $pro = @{}
  foreach ($s in $steps) { if ($s.Pl) { $pro[[string]$s.Res] = $s } else { $now[[string]$s.Res] = $s } }
  $lines = @()
  $fhd = $now['1920x1080']
  if ($fhd -and $fhd.Fps) {
    $bits = @()
    foreach ($k in '2560x1440', '3840x2160') { if ($now[$k]) { $bits += "$($ResShort[$k]) giver $([math]::Round(100 * $now[$k].Fps / $fhd.Fps)) %" } }
    if ($bits.Count) { $lines += "📉  I forhold til Full HD: $($bits -join ', ') af FPS'en." }
  }
  if ($pro.Count) {
    $d = @(); $wd = @()
    foreach ($k in '1920x1080', '2560x1440', '3840x2160') {
      if ($now[$k] -and $pro[$k] -and $now[$k].Fps -and $now[$k].W) {
        $d += "$($ResShort[$k]) $('{0:+0;-0;0}' -f (100 * ($pro[$k].Fps - $now[$k].Fps) / $now[$k].Fps)) %"
        $wd += 100 * ($pro[$k].W - $now[$k].W) / $now[$k].W
      }
    }
    if ($d.Count) { $lines += "🔋  Med din GPU-profil: $([math]::Round(-($wd | Measure-Object -Average).Average)) % mindre strøm. FPS: $($d -join ' · ')." }
  }
  $lines += "ℹ  Tallene er fra Opticons testscene og ikke fra et bestemt spil. Brug dem til at sammenligne opløsninger og indstillinger på din egen pc."
  $ui.GpuResVerdict.Text = $lines -join "`n"; $ui.GpuResVerdict.Visibility = 'Visible'
  $ui.GpuResInfo.Text = "Målt $(Get-Date -Format 'HH:mm'). Kør igen efter en ændring i Afterburner for at se forskellen."
  try { [IO.File]::WriteAllText((Join-Path $OutDir 'gpu-oploesning.json'), (ConvertTo-Json -InputObject @($steps) -Depth 3), (New-Object Text.UTF8Encoding $false)) } catch {}
}
$ui.BtnGpuRes.Add_Click({ Start-GpuBench 'res' })
# ---------- OC-tjek ----------
function Show-OcBase {
  $b = $script:OcBase; if (-not $b) { return }
  $ui.GpuOcBase.Text = "Udgangspunkt (2K): $([math]::Round($b.Fps)) fps$(if ($b.P1) { " · laveste 1 % $([math]::Round($b.P1))" })$(if ($null -ne $b.W) { " · $([math]::Round($b.W)) W" })$(if ($b.C) { " · $([math]::Round($b.C)) MHz" })$(if ($null -ne $b.T) { " · $([math]::Round($b.T)) °C" })$(if ($null -ne $b.U -and $null -eq $b.T) { " · belastning $([math]::Round($b.U)) %" })"
  $ui.GpuOcBase.Visibility = 'Visible'
}
function Set-OcBox($kind, $title, $text) {
  $c = @{ ok = @('#173325', '#22C55E', '#C3E8D0'); warn = @('#2A2210', '#F6C344', '#EBDDB0'); bad = @('#2E1418', '#FF5D6C', '#F2C4C9') }[$kind]
  $ui.GpuOcBox.Background = $Brush.ConvertFromString($c[0]); $ui.GpuOcBox.BorderBrush = $Brush.ConvertFromString($c[1])
  $ui.GpuOcText.Foreground = $Brush.ConvertFromString($c[2])
  $ui.GpuOcTitle.Text = $title; $ui.GpuOcText.Text = $text; $ui.GpuOcBox.Visibility = 'Visible'
}

# Typiske OC-resultater fra anmeldelser (FPS-gevinst %, ekstra strøm %, kilde)
$KnownOc = @(
  @{ Match = '3070\s*TI'; Gain = 7.5; Pw = 9; Src = "The FPS Review fik ca. 7-8 % flere FPS for 9 % mere strøm med +130 MHz på et RTX 3070 Ti Founders Edition." }
)
function Show-OcEstimate {
  $b = $script:OcBase; if (-not $b -or -not $b.Fps) { return }
  if (-not (Get-Smi)) {   # AMD/Intel: ingen strøm-/clockdata at regne på
    $gn = [string](Get-GpuName)
    $igpu = $gn -match '(?i)\b\d{3,4}M\b|Radeon\(TM\) Graphics|Radeon Graphics|Vega \d|UHD|Iris|Intel\(R\) Graphics|Arc\(TM\) Graphics'
    foreach ($n in 'OcEstFps', 'OcEstW', 'OcEstT', 'OcEstN') { $ui[$n].Text = '–' }
    foreach ($n in 'OcEstFpsSub', 'OcEstWSub', 'OcEstTSub', 'OcEstNSub') { $ui[$n].Text = '' }
    if ($igpu) {
      $ui.OcEstFps.Text = 'lidt'; $ui.OcEstFpsSub.Text = 'sjældent mærkbart'
      $ui.GpuOcEstTitle.Text = "Skøn, ikke målt · 👎 Giver sjældent mening på integreret grafik ($gn)"
      $ui.GpuOcEstText.Text = "Integreret grafik deler strøm og køling med processoren og bruger din RAM som grafikhukommelse. Overclock giver derfor sjældent meget. Mere effektivt: kør 'Find den bedste strømtilstand' ovenfor, og brug 'Bedste ydeevne' på strøm, når du spiller. Hurtigere RAM hjælper også integreret grafik."
    } else {
      $ui.OcEstFps.Text = 'ca. +3-7 %'; $ui.OcEstFpsSub.Text = "ca. $([math]::Round($b.Fps)) → $([math]::Round($b.Fps * 1.05)) fps"
      $ui.GpuOcEstTitle.Text = 'Skøn, ikke målt · 🤷 Måske'
      $ui.GpuOcEstText.Text = "Nyere grafikkort giver typisk 3-7 % ved overclock, fordi de allerede udnytter det meste fra fabrikken. Opticon kan ikke læse strøm og temperatur på dette kort, så skønnet er groft. Kun trin 3 måler det rigtige tal."
    }
    $ui.GpuOcEstBox.Visibility = 'Visible'; $script:OcEstGain = $null
    return
  }
  $l = Smi-Q 'power.limit,power.max_limit'
  $pl = $l[0]; $plMax = $l[1]
  $mine = Parse-Gpu (Get-GpuName)
  $ref = $null; if ($mine) { $ref = $KnownOc | Where-Object { $mine.Key -match $_.Match } | Select-Object -First 1 }
  $g = if ($ref) { [double]$ref.Gain } else { 5.0 }       # typisk for nyere NVIDIA-kort: ca. 3-8 %
  $pw = if ($ref) { [double]$ref.Pw } else { 7.0 }
  $why = @()
  $W = [double]$b.W; $T = [double]$b.T; $F = if ($null -ne $b.F) { [double]$b.F } else { $null }
  # Rammer kortet allerede sin strømgrænse? Så kan et højere clock ikke holdes uden mere strøm
  if ($pl -and $W -ge 0.95 * $pl) {
    $head = if ($plMax -and $pl) { ($plMax - $pl) / $pl } else { 0 }
    if ($head -lt 0.05) { $g *= 0.5; $why += "⚡ Kortet bruger allerede hele sin strømgrænse ($([math]::Round($W)) af $([math]::Round($pl)) W), og den kan kun hæves $([math]::Round($head * 100)) %. Så er der ikke meget plads til højere clock." }
    else { $why += "⚡ Kortet rammer sin strømgrænse ($([math]::Round($pl)) W). Den skal hæves (op til $([math]::Round($plMax)) W) for at få gevinsten." }
  }
  if ($T -ge 83) { $g *= 0.4; $why += "🌡 Kortet er allerede ved varmegrænsen ($([math]::Round($T)) °C). Så skruer det selv ned, og et overclock giver næsten intet." }
  elseif ($T -ge 78) { $g *= 0.7; $why += "🌡 Kortet er varmt ($([math]::Round($T)) °C). Mere varme kan få det til at skrue ned igen." }
  $pw = $pw * ($g / $(if ($ref) { [double]$ref.Gain } else { 5.0 }))
  $fpsNew = [double]$b.Fps * (1 + $g / 100)
  $wAdd = $W * $pw / 100
  $tAdd = [math]::Max(1, ($T - 25) * $pw / 100)
  $ui.OcEstFps.Text = "+$([math]::Round($g, 1)) %"; $ui.OcEstFpsSub.Text = "ca. $([math]::Round($b.Fps)) → $([math]::Round($fpsNew)) fps i testen"
  $ui.OcEstW.Text = "+$([math]::Round($wAdd)) W"; $ui.OcEstWSub.Text = "ca. $([math]::Round($W)) → $([math]::Round($W + $wAdd)) W (+$([math]::Round($pw)) %)"
  $ui.OcEstT.Text = "+$([math]::Round($tAdd)) °C"; $ui.OcEstTSub.Text = "ca. $([math]::Round($T)) → $([math]::Round($T + $tAdd)) °C"
  if ($null -eq $F -or $F -eq 0) { $ui.OcEstN.Text = 'lidt mere'; $ui.OcEstNSub.Text = 'blæseren stod stille eller kunne ikke læses' }
  elseif ($F -ge 70) { $ui.OcEstN.Text = 'mærkbart'; $ui.OcEstNSub.Text = "blæseren kører allerede $([math]::Round($F)) %" }
  else { $ui.OcEstN.Text = "+$([math]::Round([math]::Max(2, $tAdd * 2))) %"; $ui.OcEstNSub.Text = "blæser ca. $([math]::Round($F)) → $([math]::Round([math]::Min(100, $F + [math]::Max(2, $tAdd * 2)))) %" }
  $verdict = if ($g -lt 3) { "👎 Giver næppe mening: ca. +$([math]::Round($g, 1)) % FPS" } elseif ($g -lt 6) { "🤷 Måske: ca. +$([math]::Round($g, 1)) % FPS" } else { "👍 Værd at prøve: ca. +$([math]::Round($g, 1)) % FPS" }
  $ui.GpuOcEstTitle.Text = "Skøn, ikke målt · $verdict"
  $tail = if ($g -lt 3) { "Brug hellere 'Find det bedste punkt' til mindre strøm, varme og larm. Det mærker du mere." }
          elseif ($g -lt 6) { "Det er svært at mærke i spil (fx 60 → $([math]::Round(60 * (1 + $g / 100))) fps). Det kan være værd det, hvis du ligger lige under din skærms Hz." }
          else { "Det kan mærkes lidt i tunge spil (fx 60 → $([math]::Round(60 * (1 + $g / 100))) fps). Til gengæld bliver kortet varmere og lidt mere højlydt." }
  $src = if ($ref) { $ref.Src } else { 'Skønnet bygger på, at nyere NVIDIA-kort typisk giver 3-8 % ved overclock, fordi GPU Boost allerede udnytter det meste fra fabrikken.' }
  $ui.GpuOcEstText.Text = (@($why) + @($tail, "", "ℹ  $src Det er et skøn ud fra din måling og andres tests. Din chip kan være bedre eller dårligere. Kun trin 3 måler det rigtige tal.")) -join "`n"
  $ui.GpuOcEstBox.Visibility = 'Visible'
  $script:OcEstGain = $g
}
function Show-OcCheck($res, $steps) {
  $s = @($steps)[0]; $b = $script:OcBase
  $ev = @(); try { $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $script:OcStart } -ErrorAction Stop | Where-Object { $_.ProviderName -match '^(nvlddmkm|amdkmdag|amdkmdap|amdwddmg|igfx|igfxn)$' -or $_.Id -eq 4101 }) } catch {}
  $probs = @()
  if ($res.Lost) { $probs += 'Grafikdriveren gik ned under testen.' }
  if ($ev.Count) { $probs += "Windows loggede $($ev.Count) fejl fra grafikdriveren." }
  if ($s -and $s.FpsMin -and $s.Fps -and [double]$s.FpsMin -lt 0.5 * [double]$s.Fps) { $probs += "FPS faldt pludselig til $([math]::Round($s.FpsMin)) (normalt $([math]::Round($s.Fps)))." }
  $nums = ''; $dF = $null
  if ($s -and $s.Fps -and $b -and $b.Fps) {
    $dF = 100 * ([double]$s.Fps - [double]$b.Fps) / [double]$b.Fps
    $dW = if ($b.W) { 100 * ([double]$s.W - [double]$b.W) / [double]$b.W } else { 0 }
    $bits = @("FPS $([math]::Round($b.Fps)) → $([math]::Round($s.Fps)) ($('{0:+0.0;-0.0;0}' -f $dF) %)")
    if ($null -ne $b.W -and $null -ne $s.W -and $b.W) { $bits += "strøm $([math]::Round($b.W)) → $([math]::Round($s.W)) W ($('{0:+0;-0;0}' -f $dW) %)" }
    if ($b.C -and $s.C) { $bits += "clock $([math]::Round($b.C)) → $([math]::Round($s.C)) MHz$(if ($s.Cmin) { " (laveste $([math]::Round($s.Cmin)))" })" }
    if ($null -ne $s.Tmax) { $bits += "højeste temp $([math]::Round($s.Tmax)) °C" }
    $nums = $bits -join ' · '
  }
  $hot = if ($s -and $s.Tmax -ge 83) { "`n🌡  Højeste temperatur var $([math]::Round($s.Tmax)) °C. Det er varmt: giv blæserkurven lidt mere fart, eller skru lidt ned." } else { '' }
  $note = "`n`nMålt i Opticons testscene (2K, 5 minutter), ikke i et bestemt spil. 5 minutter fanger de værste fejl, men ikke alle. Opticon kan heller ikke se grafikfejl. Så du blinkende prikker, striber eller flimmer i testscenen, er overclocket heller ikke stabilt."
  if ($probs.Count) {
    Set-OcBox 'bad' '⛔ Fejl registreret i den 5-minutters test' ("$($probs -join ' ')`n`nSkru core clock 15-30 MHz ned (eller memory 100-200 MHz) i Afterburner, eller kør NVIDIAs automatiske tuning igen. Tryk så '3 · Tjek OC' igen.$(if ($nums) { "`n`n$nums" })$hot")
    Log "OC-tjek: ustabilt ($($probs -join ' '))"
  } elseif ($res.Aborted) {
    Set-OcBox 'warn' 'Stoppet før tid' "Testen skal køre alle 5 minutter, før du kan stole på, at overclocket holder.$(if ($nums) { "`n`n$nums" })"
  } elseif ($null -eq $dF) {
    Set-OcBox 'warn' 'Ingen sammenligning' 'Testen gav ingen brugbare tal at sammenligne med. Mål udgangspunktet igen (trin 1).'
  } elseif ($dF -ge 2) {
    Set-OcBox 'ok' "✅ Ingen fejl registreret i den 5-minutters test · $('{0:+0.0}' -f $dF) % FPS" ("$nums$(if ($script:OcEstGain) { "`nSkønnet var ca. +$([math]::Round($script:OcEstGain, 1)) %." })$hot`n`nNæste skridt: gem profilen (NVIDIA App gemmer selv; i Afterburner trykker du Save og et nummer). Spil et par timer. Går et spil ned, så skru 15 MHz ned.$note")
    Log "OC-tjek: stabilt, $('{0:+0.0}' -f $dF) % FPS"
  } else {
    Set-OcBox 'warn' "Ingen fejl registreret, men kun $('{0:+0.0;-0.0;0}' -f $dF) % FPS" ("$nums$hot`n`nOverclocket giver næsten ingenting her. Det er ofte smartere at gå tilbage til standard og bruge 'Find det bedste punkt' til mindre strøm og støj i stedet.$note")
  }
  $ui.GpuOcInfo.Text = "Tjekket kl. $(Get-Date -Format 'HH:mm'). Ændr noget, og tjek igen for at sammenligne med udgangspunktet."
  $ui.GpuOcEstBox.Visibility = 'Collapsed'   # det målte resultat erstatter skønnet
}
$ui.BtnOcBase.Add_Click({ Start-GpuBench 'ocbase' })
$ui.BtnOcCheck.Add_Click({ Start-GpuBench 'occheck' })
$ui.BtnOcTune.Add_Click({
  if (-not (Get-Smi)) {   # AMD / Intel
    $amd = "$env:ProgramFiles\AMD\CNext\CNext\RadeonSoftware.exe"
    $gn = [string](Get-GpuName)
    if ($gn -match '(?i)radeon|amd') {
      $t = "Opticon overclocker ikke selv. Brug AMDs eget program:`n`nAMD Software (Adrenalin):`n1.  Gå til Ydeevne → Tuning.`n2.  Vælg 'Automatisk: Overclock GPU' (eller 'Undervolt GPU' for mindre strøm).`n3.  Kom tilbage, og tryk '3 · Tjek OC'.`n`nPå integreret grafik (fx Radeon 860M) er der ofte få eller ingen tuning-muligheder. Så er 'Find den bedste strømtilstand' den bedste vej."
      if ((Msg "$t`n`nÅbn AMD Software nu?" 'Find overclock automatisk' 'YesNo' 'Information') -ne 'Yes') { return }
      if (Test-Path $amd) { Start-Process $amd } else { Start-Process 'https://www.amd.com/en/support/download/drivers.html' }
    } else {
      Msg "Intel-grafik har næsten ingen overclock-muligheder. Brug i stedet 'Find den bedste strømtilstand' ovenfor." 'OC-tjek' | Out-Null
    }
    return
  }
  $nv = @("$env:ProgramFiles\NVIDIA Corporation\NVIDIA App\CEF\NVIDIA App.exe", "$env:ProgramFiles\NVIDIA Corporation\NVIDIA App\NVIDIA App.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  $ab = @("${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe", "$env:ProgramFiles\MSI Afterburner\MSIAfterburner.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $script:OcBase) { if ((Msg "Mål udgangspunktet først (trin 1), så Opticon kan se, hvad overclocket giver.`n`nVil du alligevel fortsætte?" 'OC-tjek' 'YesNo' 'Question') -ne 'Yes') { return } }
  $t = "Opticon overclocker ikke selv. Det kræver NVIDIAs lukkede værktøjer, og et forkert gæt kan give nedbrud. Lad NVIDIAs egen scanner finde et sikkert overclock til netop dit kort:`n`n"
  if ($nv) { $t += "NVIDIA App (anbefalet):`n1.  Gå til System → Performance.`n2.  Slå 'Automatic Tuning' til. Den scanner i ca. 10-20 minutter. Brug ikke pc'en imens.`n3.  Kom tilbage, og tryk '3 · Tjek OC'.`n`n" }
  if ($ab) { $t += "MSI Afterburner:`n1.  Tryk Ctrl+F, og klik 'OC Scanner'.`n2.  Klik 'Scan' (ca. 15-20 min.) og derefter 'Apply'.`n3.  Klik Save og et profilnummer. Tryk så '3 · Tjek OC'.`n`n" }
  if (-not $nv -and -not $ab) { $t += "Hverken NVIDIA App eller MSI Afterburner er installeret. Hent NVIDIA App fra NVIDIAs side, og kom tilbage hertil.`n`n" }
  $t += "Luk Afterburner under Opticons egne tests, så de ikke kæmper om indstillingerne."
  $open = if ($nv) { 'NVIDIA App' } elseif ($ab) { 'MSI Afterburner' } else { 'NVIDIAs side' }
  if ((Msg "$t`n`nÅbn $open nu?" 'Find overclock automatisk' 'YesNo' 'Information') -ne 'Yes') { return }
  if ($nv) { Start-Process $nv } elseif ($ab) { Start-Process $ab } else { Start-Process 'https://www.nvidia.com/en-us/software/nvidia-app/' }
})


# ---------- AMD/Intel: den bedste strømtilstand ----------
function Show-PowerModes($res, $steps) {
  $st = @($steps | Where-Object { $_.Mode })
  $max = [double](($st | Measure-Object Fps -Maximum).Maximum); if ($max -le 0) { $max = 1 }
  $ok = @($st | Where-Object { $_.Applied -ne $false })   # kun tilstande, Windows faktisk skiftede til
  $max = [double](($ok | Measure-Object Fps -Maximum).Maximum); if ($max -le 0) { $max = 1 }
  $rec = $ok | Where-Object { [double]$_.Fps -ge 0.97 * $max } | Select-Object -First 1   # rækkefølgen er mest sparsom først
  $hasW = @($st | Where-Object { $null -ne $_.W }).Count -gt 0
  $rows = @(foreach ($x in $st) {
    $r = New-Object PcTjek.Row
    $r.Status = $(if ($x.Applied -eq $false) { '✗' } elseif ($x -eq $rec) { '⭐' } else { '' })
    $r.Navn = "$(PowerMode-Name $x.Mode)$(if ($x.Applied -eq $false) { ' (kunne ikke aktiveres)' })"
    $r.Info = $(if ($null -ne $x.W) { "$([math]::Round($x.W)) W (hele pc'en)" } else { '– (på strøm)' })
    $r.Note = "$([math]::Round($x.Fps)) fps$(if ($x.P1) { " · laveste $([math]::Round($x.P1))" })"
    $r.Gruppe = $(if ($null -ne $x.U) { "belastning $([math]::Round($x.U)) %" } else { '' })
    $r })
  $ui.GridGpuAuto.ItemsSource = $rows; $ui.GridGpuAuto.Visibility = 'Visible'
  $ui.GpuRecBox.Visibility = 'Visible'; $ui.GpuAbBox.Visibility = 'Collapsed'; $ui.BtnGpuAbHow.Visibility = 'Collapsed'
  $script:GpuRec = $null; $script:GpuRecMode = $null
  $script:GpuModeTo = $rec; $script:GpuModeFrom = ($st | Where-Object { $_.Mode -eq $res.OrigMode } | Select-Object -First 1); if (-not $script:GpuModeFrom) { $script:GpuModeFrom = $st | Where-Object { $_.Mode -eq '00000000-0000-0000-0000-000000000000' } | Select-Object -First 1 }
  if (-not $rec) { $ui.GpuRecTitle.Text = 'Testen gav ingen klare tal'; $ui.GpuRecText.Text = "Kør testen igen, og rør ikke pc'en imens."; $ui.BtnGpuApply.Visibility = 'Collapsed'; return }
  $best = $ok | Sort-Object Fps -Descending | Select-Object -First 1
  $script:GpuRecMode = $rec.Mode
  $name = PowerMode-Name $rec.Mode
  $dF = [math]::Round(100 * ([double]$rec.Fps - [double]$best.Fps) / [math]::Max(1, [double]$best.Fps))
  $ui.GpuRecTitle.Text = "⭐ Anbefalet: $name"
  $txt = if ($rec -eq $best) { "Den giver flest FPS ($([math]::Round($rec.Fps))). De andre tilstande koster mere end 3 % FPS." }
         else { "Næsten samme ydelse som $(PowerMode-Name $best.Mode) ($dF % FPS)$(if ($hasW -and $null -ne $rec.W -and $null -ne $best.W) { ", men $([math]::Round($best.W - $rec.W)) W mindre for hele pc'en. Det giver længere batteritid og et køligere, mere stille kabinet" })." }
  if (-not $hasW) { $txt += "`n`nTag laderen ud, og kør testen igen, hvis du også vil se, hvor mange watt hver tilstand bruger." }
  $txt += "`n`nTallene er fra Opticons testscene. På bærbare kan producentens eget program (fx Lenovo Vantage eller G-Helper) også have tilstande, der overstyrer Windows."
  $ui.GpuRecText.Text = $txt
  $ui.BtnGpuApply.Content = "✅  Brug $name"; $ui.BtnGpuApply.Visibility = 'Visible'
  $ui.BtnGpuReset.Content = '↩  Tilbage til Balanceret'
}
function Show-GpuAuto($res, $steps) {
  $script:GpuRecMode = $null; $ui.BtnGpuReset.Content = '↩  Tilbage til standard'
  $base = $steps[0]
  $rec = $base
  foreach ($s in $steps) { if ($s.Applied -ne $false -and $s.Fps -ge 0.97 * $base.Fps -and $s.W -lt $rec.W) { $rec = $s } }   # kun bekræftede trin
  $ui.GridGpuAuto.ItemsSource = @($steps | ForEach-Object {
    $r = New-Object PcTjek.Row
    $r.Status = $(if ($_.Applied -eq $false) { '✗' } elseif ($_ -eq $rec -and $rec -ne $base) { '⭐' } else { '' })
    $r.Navn = "$($_.Pct) %  ·  $([math]::Round($_.Pl)) W"
    $r.Info = "$([math]::Round($_.W)) W$(if ($_ -ne $base) { Pct-Str $base.W $_.W })"
    $r.Note = $(if ($_.Applied -eq $false) { 'kunne ikke aktiveres' } else { "$($_.Fps) fps$(if ($_ -ne $base) { Pct-Str $base.Fps $_.Fps })" })
    $r.Gruppe = "$([math]::Round($_.T)) °C · $(if ($null -ne $_.F) { "$([math]::Round($_.F)) %" } else { 'n/a' }) · $([math]::Round($_.C)) MHz"
    $r })
  $ui.GridGpuAuto.Visibility = 'Visible'; $ui.GpuRecBox.Visibility = 'Visible'; $ui.GpuAbBox.Visibility = 'Collapsed'
  $script:GpuRec = $rec; $script:GpuBaseStep = $base
  if ($rec -ne $base -and $rec.Pl) { try { [IO.File]::WriteAllText((Join-Path $JobBase 'gpu-best.json'), ([ordered]@{ Watts = [int][math]::Round($rec.Pl); Pct = $rec.Pct; Date = (Get-Date).ToString('s') } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch {} }
  if ($rec -eq $base) {
    $ui.GpuRecTitle.Text = '👍 Dit grafikkort er allerede effektivt'
    $ui.GpuRecText.Text = "Selv en lavere strømgrænse kostede mere end 3 % FPS i testen. Der er ikke meget at hente her uden at miste ydelse."
    $ui.BtnGpuApply.Visibility = 'Collapsed'; $ui.BtnGpuAbHow.Visibility = 'Collapsed'
  } else {
    $dW = [math]::Round(($rec.W - $base.W) / $base.W * 100); $dF = [math]::Round(($rec.Fps - $base.Fps) / $base.Fps * 100)
    $dT = [math]::Round($base.T - $rec.T)
    $ui.GpuRecTitle.Text = "⭐ Anbefalet: $($rec.Pct) % strømgrænse ($([math]::Round($rec.Pl)) W)"
    $fan = if ($null -ne $base.F -and $null -ne $rec.F) { ", blæser $([math]::Round($base.F)) → $([math]::Round($rec.F)) %" } else { '' }
    $ui.GpuRecText.Text = "$([math]::Abs($dW)) % mindre strøm ($([math]::Round($base.W)) → $([math]::Round($rec.W)) W), $(if ($dF -le 0) { "$([math]::Abs($dF)) % lavere FPS" } else { "$dF % højere FPS" }), $dT °C køligere$fan. Det er den laveste grænse, hvor du beholdt mindst 97 % af ydelsen i testen."
    $ui.BtnGpuApply.Content = "✅  Brug $($rec.Pct) % fremover"; $ui.BtnGpuApply.Visibility = 'Visible'; $ui.BtnGpuAbHow.Visibility = 'Visible'
    $ui.GpuAbVal.Text = "$($rec.Pct)"; $ui.GpuAbFill.Width = [math]::Round(230 * $rec.Pct / 120)
    $ui.GpuAbSteps.Text = "1.  Åbn MSI Afterburner.`n2.  Træk 'Power Limit' ned til $($rec.Pct).`n3.  Tryk ✓ (Apply).`n4.  Slå 'Startup' til (Windows-ikonet), så den bruges ved opstart.`n`nBrug enten Afterburner ELLER Opticons knap, ikke begge."
  }
  $ui.GpuAutoInfo.Text = "Test færdig $(Get-Date -Format 'HH:mm'). Samme 3D-scene og belastning ved alle trin$(if ($res.Aborted) { ' (stoppet før tid, så ikke alle trin blev målt)' })."
  Log "GPU-test: anbefalet $($rec.Pct) %"
}
function Show-GpuCompare {
  $a = $script:GpuBefore; $b = $script:GpuAfter
  $parts = @("FPS $($a.Fps) → $($b.Fps)$(Pct-Str $a.Fps $b.Fps)")
  if ($null -eq $a.W -or $null -eq $b.W) {   # AMD/Intel på strøm: kun FPS
    $ui.GpuResult.Text = ($parts -join '  ·  ') + $(if ($a.P1 -and $b.P1) { "  ·  laveste 1 % $([math]::Round($a.P1)) → $([math]::Round($b.P1))" })
    $fPct = ($b.Fps - $a.Fps) / [math]::Max(1, $a.Fps) * 100
    $ui.GpuVerdict.Text = "FPS ændrede sig $([math]::Round($fPct)) %. Tag laderen ud, og mål igen, hvis du også vil se strømforbruget."
    $ui.GpuSavePanel.Visibility = 'Visible'; return
  }
  $parts = @("FPS $($a.Fps) → $($b.Fps)$(Pct-Str $a.Fps $b.Fps)", "Effekt $([math]::Round($a.W)) → $([math]::Round($b.W)) W$(Pct-Str $a.W $b.W)", "Temp $([math]::Round($a.T)) → $([math]::Round($b.T)) °C")
  if ($null -ne $a.F -and $null -ne $b.F) { $parts += "Blæser $([math]::Round($a.F)) → $([math]::Round($b.F)) %" }
  $parts += "Clock $([math]::Round($a.C)) → $([math]::Round($b.C)) MHz"
  $ui.GpuResult.Text = $parts -join '  ·  '
  $wPct = ($b.W - $a.W) / [math]::Max(1, $a.W) * 100; $fPct = ($b.Fps - $a.Fps) / [math]::Max(1, $a.Fps) * 100
  $ui.GpuVerdict.Text = if ($wPct -le -8 -and $fPct -ge -3) { "👍 Værd at beholde: $([math]::Abs([math]::Round($wPct))) % mindre strøm, og FPS ændrede sig kun $([math]::Round($fPct)) %. Spil et par timer i dine egne spil for at sikre, at det er stabilt." }
                        elseif ($fPct -lt -5) { "⚠ Ydelsen faldt mærkbart ($([math]::Round($fPct)) % FPS). Prøv en mildere indstilling." }
                        elseif ($wPct -gt -3) { 'Næsten ingen forskel i strømforbrug. Ændringen gjorde ikke meget.' }
                        else { "Lidt mindre strøm ($([math]::Round($wPct)) %). Sammenlign, om det er det værd for dig." }
  $ui.GpuSavePanel.Visibility = 'Visible'
}
$ui.BtnGpuAuto.Add_Click({ Start-GpuBench 'auto' })
$ui.BtnGpuBefore.Add_Click({ Start-GpuBench 'before' })
$ui.BtnGpuAfter.Add_Click({ Start-GpuBench 'after' })
$ui.BtnGpuAbHow.Add_Click({ $ui.GpuAbBox.Visibility = $(if ($ui.GpuAbBox.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }) })
$ui.BtnGpuApply.Add_Click({
  if ($script:GpuRecMode) {
    if (Set-PowerMode $script:GpuRecMode) {
      Log "Strømtilstand sat til $(PowerMode-Name $script:GpuRecMode)"
      try { Note-GpuChange "Strømtilstand: $(PowerMode-Name $script:GpuRecMode)" $script:GpuModeFrom $script:GpuModeTo } catch {}
      Msg "✓ Strømtilstanden er nu '$(PowerMode-Name $script:GpuRecMode)'.`n`nWindows husker den selv, men separat for strøm og batteri. Kør testen igen med eller uden lader for at vælge til den anden." 'GPU' | Out-Null
    } else { Msg "Windows ville ikke skifte strømtilstand. Prøv i Indstillinger → System → Strøm og batteri." 'GPU' 'OK' 'Warning' | Out-Null }
    return
  }
  $r = $script:GpuRec; $smi = Get-Smi
  if (-not $r -or -not $smi) { return }
  $o = & $smi -i (Get-GpuId) -pl ([math]::Round($r.Pl)) 2>&1
  if ($LASTEXITCODE -ne 0) { Msg "Kunne ikke sætte strømgrænsen:`n$($o -join ' ')" 'GPU' 'OK' 'Error' | Out-Null; return }
  $cfg = [ordered]@{ Watts = [math]::Round($r.Pl); Pct = $r.Pct; Gpu = (Get-GpuName); Uuid = (Get-GpuId); Date = (Get-Date).ToString('s') }
  try { [IO.File]::WriteAllText($GpuPlFile, ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch {}
  Log "GPU-strømgrænse sat til $($cfg.Watts) W"
  try { Note-GpuChange "GPU-strømgrænse $($r.Pct) % ($($cfg.Watts) W)" $script:GpuBaseStep $r } catch {}
  if (Get-ScheduledTask -TaskName 'PC-Tjek Vagt' -ErrorAction SilentlyContinue) {
    Msg "✓ Strømgrænsen er sat til $($r.Pct) % ($($cfg.Watts) W).`n`nVagten sætter den automatisk igen, hver gang du logger ind. Du kan altid gå tilbage til standard." 'GPU' | Out-Null
  } elseif ((Msg "✓ Strømgrænsen er sat til $($r.Pct) % nu.`n`nWindows nulstiller den ved genstart. Skal Opticons Vagt sætte den automatisk ved hvert login? (Vagten passer også på dine downloads.)" 'GPU' 'YesNo' 'Question') -eq 'Yes') { [void](Install-Vagt) }
  Load-Gpu
})
$ui.BtnGpuReset.Add_Click({
  if (-not (Get-Smi)) {
    if (Set-PowerMode '00000000-0000-0000-0000-000000000000') { Msg 'Strømtilstanden er tilbage på Balanceret.' 'GPU' | Out-Null } else { Msg 'Kunne ikke skifte strømtilstand.' 'GPU' 'OK' 'Warning' | Out-Null }
    return
  }
  $smi = Get-Smi
  $def = (Smi-Q 'power.default_limit')[0]
  if ($def) { & $smi -i (Get-GpuId) -pl ([math]::Round($def)) 2>&1 | Out-Null }
  Remove-Item $GpuPlFile -Force -ErrorAction SilentlyContinue
  Log 'GPU-strømgrænse nulstillet'
  Msg "Strømgrænsen er tilbage på standard ($([math]::Round($def)) W)." 'GPU' | Out-Null
  Load-Gpu
})

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

# Tolker et GPU-navn til producent-familie, nummer, endelse og generation (fx RTX 4080 Super -> RTX/4080/SUPER/4)
function Parse-Gpu([string]$n) {
  $n = ($n -replace '(?i)\(R\)|\(TM\)|nvidia|geforce|amd|radeon|intel|graphics|laptop gpu', '').Trim()
  $m = [regex]::Match($n, '(?i)\b(RTX|GTX|RX|ARC\s*[AB]?)\s*([A-Z]?\d{3,4})\s*((?:TI\s*SUPER)|TI|SUPER|XTX|XT|GRE|S)?\b')
  if (-not $m.Success) { return $null }
  $fam = ($m.Groups[1].Value -replace '\s', '').ToUpper()
  $num = $m.Groups[2].Value.ToUpper()
  $suf = ($m.Groups[3].Value -replace '\s', '').ToUpper()
  $digits = $num -replace '\D', ''
  $gen = if ($digits.Length -eq 4) { $digits.Substring(0, 1) } elseif ($digits.Length -eq 3) { $digits.Substring(0, 1) } else { '' }
  return [pscustomobject]@{ Fam = $fam; Num = $num; Suf = $suf; Gen = $gen; Key = "$fam $num $suf".Trim() }
}
# Tal fra anmeldelser, når datasættet ikke har kortet (navn · indstilling · resultat · kilde)
$KnownGpu = @(
  @{ Match = '3070\s*TI'; Tip = "Godt startpunkt i MSI Afterburner (Ctrl+F): lås kurven ved ca. 1.850-1.900 MHz og 0,875-0,900 V, og test i dine spil. Det er et almindeligt udgangspunkt fra brugere, ikke en garanti. Går et spil ned, så giv 25 mV mere."
     Rows = @(
       @('RTX 3070 Ti · Igor''s Lab', 'Sænket frekvenskurve (undervolt)', 'ca. −50 til −60 W · samme ydelse', 'https://www.igorslab.de/en/3070-ti-undervolting-can-we-also-deny-the-most-unpopular-of-all-tis-binge-drinking/5/'),
       @('RTX 3070 Ti · Igor''s Lab', 'Kun lavere strømgrænse', 'mindre strøm, men lidt lavere ydelse', 'https://www.igorslab.de/en/3070-ti-undervolting-can-we-also-deny-the-most-unpopular-of-all-tis-binge-drinking/5/'),
       @('RTX 3070 Ti FE · TechPowerUp', 'Fabriksindstilling i spil (til sammenligning)', '1.770-1.935 MHz ved 0,93-1,08 V', 'https://www.techpowerup.com/review/nvidia-geforce-rtx-3070-ti-founders-edition/35.html')
     ) }
)
function Load-GpuLib {
  Invoke-Bg $GpuLibScript $null {
    param($res, $err, $c)
    if ($err -or -not $res) { $ui.GpuLibInfo.Text = "Kunne ikke hente eksempler lige nu. $err"; return }
    $mineName = Get-GpuName
    $mine = Parse-Gpu $mineName
    $srcType = @{ 'editorial-firstparty' = 'Redaktionel'; 'review-measured' = 'Målt i test'; 'community-verified' = 'Bruger (verificeret)'; 'community-consensus' = 'Brugere (konsensus)' }
    $rows = @($res | ForEach-Object {
      $it = $_
      $pg = Parse-Gpu ([string]$it.gpu)
      $r = New-Object PcTjek.Row
      $r.Navn = "$($it.gpu)$(if ($it.board) { " · $($it.board)" })"
      $set = @($it.method, $it.setting) | Where-Object { $_ }
      $r.Info = ($set -join ': ')
      $bits = @()
      if ($it.power_saved_w) { $bits += "−$($it.power_saved_w) W" }
      if ("$($it.fps_delta_pct)" -ne '') { $bits += "FPS $(if ([double]$it.fps_delta_pct -gt 0) { '+' })$($it.fps_delta_pct) %" }
      if ($it.temp_drop_c) { $bits += "−$($it.temp_drop_c) °C" }
      if ($it.stability_hours) { $bits += "stabil $($it.stability_hours) t" }
      $r.Note = $(if ($bits.Count) { $bits -join ' · ' } else { '(ingen tal)' })
      $t = [string]$it.source_type; $r.Gruppe = $(if ($srcType.ContainsKey($t)) { $srcType[$t] } else { $t })
      $r.Sti = [string]$it.source_url
      $r.Status = ''
      if ($mine -and $pg) {
        if ($pg.Fam -eq $mine.Fam -and $pg.Num -eq $mine.Num -and $pg.Suf -eq $mine.Suf) { $r.Status = 'same' }
        elseif ($pg.Fam -eq $mine.Fam -and $pg.Gen -and $pg.Gen -eq $mine.Gen) { $r.Status = 'similar' }
      }
      $r })
    $same = @($rows | Where-Object { $_.Status -eq 'same' })
    $sim  = @($rows | Where-Object { $_.Status -eq 'similar' })
    if ($same.Count) {
      $ui.GridGpuLib.ItemsSource = $same; $ui.GridGpuLib.Visibility = 'Visible'
      $ui.GpuLibInfo.Text = "✓ $($same.Count) måling$(if ($same.Count -ne 1) { 'er' }) med dit kort ($($mine.Key)). Brug dem som udgangspunkt, men mål selv. Køler og chip varierer fra kort til kort."
    } elseif ($sim.Count) {
      foreach ($x in $sim) { $x.Navn = "≈ $($x.Navn)" }
      $ui.GridGpuLib.ItemsSource = $sim; $ui.GridGpuLib.Visibility = 'Visible'
      $ui.GpuLibInfo.Text = "Ingen har delt målinger med præcis dit kort ($($mine.Key)) endnu. Her er lignende kort fra samme generation. De er IKKE dit kort, så tallene giver kun en fornemmelse af, hvad der er muligt."
    } elseif ($mine -and ($known = @($KnownGpu | Where-Object { $mine.Key -match $_.Match })).Count) {
      $kr = @(foreach ($k in $known) { foreach ($x in $k.Rows) { $r = New-Object PcTjek.Row; $r.Navn = $x[0]; $r.Info = $x[1]; $r.Note = $x[2]; $r.Gruppe = 'Målt i test'; $r.Sti = $x[3]; $r } })
      $ui.GridGpuLib.ItemsSource = $kr; $ui.GridGpuLib.Visibility = 'Visible'
      $ui.GpuLibInfo.Text = "Fællesskabets datasæt har ikke dit kort endnu, men her er tal fra kendte anmeldelser af dit kort ($($mine.Key)). $($known[0].Tip)"
    } else {
      $ui.GridGpuLib.ItemsSource = @(); $ui.GridGpuLib.Visibility = 'Collapsed'
      $ui.GpuLibInfo.Text = if ($mine) { "Ingen har delt målinger med dit kort ($($mine.Key)) eller lignende kort endnu. Din egen før/efter-måling ovenfor er den bedste guide. Datasættet har $($rows.Count) eksempler i alt." } else { "Kunne ikke genkende dit grafikkort ($mineName), så der vises ingen eksempler. Brug din egen før/efter-måling." }
    }
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

# ---------- Optimering: vis kun det, du vil opnå ----------
function Set-GpuChoice($k) {
  $script:GpuChoice = $k
  $vis = @{ power = @('SecAuto'); fps = @('SecOc', 'SecRes'); own = @('SecOwn'); all = @('SecAuto', 'SecRes', 'SecOc', 'SecOwn', 'SecExtra') }[$k]
  foreach ($n in 'SecAuto', 'SecRes', 'SecOc', 'SecOwn', 'SecExtra') { $ui[$n].Visibility = $(if ($vis -contains $n) { 'Visible' } else { 'Collapsed' }) }
  $norm = $win.FindResource([Windows.Controls.Button]); $prim = $win.FindResource('Primary')
  foreach ($b in @{ power = 'ChoosePower'; fps = 'ChooseFps'; own = 'ChooseOwn' }.GetEnumerator()) { $ui[$b.Value].Style = $(if ($b.Key -eq $k) { $prim } else { $norm }) }
  $nv = [bool](Get-Smi)
  $ui.ChooseHelp.Text = switch ($k) {
    'power' { if ($nv) { "Opticon prøver selv 4 strømgrænser i testscenen og finder den laveste, hvor du beholder næsten al ydelse. Ét klik, ca. 4 minutter." } else { "Opticon prøver Windows' 3 strømtilstande i testscenen og anbefaler den mest sparsomme, der stadig yder godt. Ét klik, ca. 3 minutter." } }
    'fps'   { "1) Mål udgangspunkt. 2) Lad $(if ($nv) { 'NVIDIA App eller Afterburner' } else { 'AMD Software' }) finde et overclock automatisk. 3) Tjek, at det giver flere FPS og holder i 5 minutter. 'FPS ved Full HD, 2K og 4K' viser forskellen mellem opløsninger." }
    'own'   { "Til ændringer, du selv laver i $(if ($nv) { 'MSI Afterburner eller NVIDIA App' } else { 'AMD Software' }): 1) Tryk Mål FØR. 2) Lav ÉN ændring, og tryk Anvend/Apply. 3) Tryk Mål EFTER. Opticon viser forskellen i FPS, strøm og temperatur." }
    default { "Alle værktøjer vises, også dine gemte målinger og andres resultater med samme kort." }
  }
}
$ui.ChoosePower.Add_Click({ Set-GpuChoice 'power' })
$ui.ChooseFps.Add_Click({ Set-GpuChoice 'fps' })
$ui.ChooseOwn.Add_Click({ Set-GpuChoice 'own' })
$ui.ChooseAll.Add_Click({ Set-GpuChoice 'all' })
function Load-Gpu {
  if (-not $script:GpuChoice) { Set-GpuChoice 'power' }
  $n = Get-GpuName
  $hasSmi = [bool](Get-Smi)
  $ui.GpuName.Text = "$n$(if (-not $hasSmi) { " · FPS og belastning måles · watt for hele pc'en på batteri" })"
  if (-not $hasSmi) {
    $ui.BtnGpuAuto.Content = '🚀  Find den bedste strømtilstand (ca. 3 min)'
    if (-not $script:GpuMeasuring -and $ui.GpuRecBox.Visibility -ne 'Visible') { $ui.GpuAutoInfo.Text = "Opticon viser en 3D-testscene i fuld skærm og prøver Windows' 3 strømtilstande. Bagefter får du en anbefaling: mindst strøm uden at miste mærkbar ydelse. Din nuværende tilstand sættes altid tilbage." }
  }
  $ab = @("${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe", "$env:ProgramFiles\MSI Afterburner\MSIAfterburner.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  $ui.BtnGpuAb.Content = $(if ($ab) { '🎚  Åbn MSI Afterburner' } else { '⬇  Hent MSI Afterburner' })
  try { Update-GpuLive } catch {}
  if (-not $script:GpuMeasuring -and (Test-Path $GpuPlFile)) {
    try { $g = Get-Content $GpuPlFile -Raw | ConvertFrom-Json; $ui.GpuAutoInfo.Text = "✓ Aktiv: strømgrænse $($g.Pct) % ($($g.Watts) W) siden $(([datetime]$g.Date).ToString('dd-MM')). Kør testen igen for at genberegne, eller nulstil efter en test." } catch {}
  }
  if (-not $script:OcBase) { $f = Join-Path $OutDir 'gpu-oc-udgangspunkt.json'; if (Test-Path $f) { try { $script:OcBase = Get-Content $f -Raw | ConvertFrom-Json } catch {} } }
  if ($script:OcBase) { Show-OcBase; try { Show-OcEstimate } catch {}; if (-not $script:GpuMeasuring) { $ui.BtnOcCheck.IsEnabled = $true } }
  $pw = Get-GpuProfileW
  $ui.ChkGpuResCmp.IsEnabled = ($pw -gt 0)
  $ui.ChkGpuResCmp.Content = $(if ($pw -gt 0) { "Sammenlign med min GPU-profil ($pw W) · ca. 3 minutter" } else { "Sammenlign med min GPU-profil (kør 'Find det bedste punkt' først)" })
  Load-GpuMine
  if (-not $script:GpuLibLoaded) { $script:GpuLibLoaded = $true; Load-GpuLib }
  $gpuTimer.Start()
}


# =====================================================================
#  TILSTANDE: Spil og Fokus (selve ændringerne og gendannelsen ligger i den fælles del)
# =====================================================================
function Confirm-ModeFree($what) {
  $m = Get-ModeState; if (-not $m) { return $true }
  return ((Msg "$($m.Mode)-tilstand er aktiv lige nu. $what bruger kræfter og kan forstyrre.`n`nVil du gøre det alligevel?" 'Tilstand' 'YesNo' 'Question') -eq 'Yes')
}
function Mode-Text($m) {
  $bits = @()
  if ($m.Mode -eq 'Spil') {
    $t = "🎮 Spil er aktiv · $($m.Name)"
    $n = @($m.Paused).Count; $nc = @($m.NotClosed).Count
    if ($n) { $bits += "lukket: $((@($m.Paused) | ForEach-Object { $_.Name }) -join ', ')" } else { $bits += 'intet lukket' }
    if ($nc) { $bits += "kunne ikke lukkes: $(@($m.NotClosed) -join ', ')" }
    if ($null -ne $m.PrevToast) { $bits += 'beskeder dæmpet' }
    if ($m.NewPl) { $bits += "grafikkort $($m.NewPl) W (før $($m.PrevPl) W)" }
    $bits += "startet kl. $(([datetime]$m.Started).ToString('HH:mm'))"
    $short = if ($n) { "$n lukket$(if ($nc) { " · $nc kunne ikke lukkes" })" } elseif ($nc) { "$nc kunne ikke lukkes" } else { 'beskeder venter' }
  } else {
    $left = [math]::Max(0, [math]::Ceiling(([datetime]$m.Until - (Get-Date)).TotalMinutes))
    $t = "🔕 Fokus · $left min tilbage"
    if ($null -ne $m.PrevToast) { $bits += 'beskeder dæmpet' }
    if (@($m.Sites).Count) { $bits += "blokerer $(@($m.Sites) -join ', ')" }
    $bits += "slutter kl. $(([datetime]$m.Until).ToString('HH:mm'))"
    $short = "slutter kl. $(([datetime]$m.Until).ToString('HH:mm'))"
  }
  return @($t, ($bits -join ' · '), $short)
}
function Show-ModeSummary($s) {
  if (-not $s) { return }
  $d = (@($s.Done) | ForEach-Object { "✓  $_" }) -join "`n"
  $f = (@($s.Failed) | ForEach-Object { "⚠  $_. Opticon prøver igen ved næste start." }) -join "`n"
  $txt = (@($d, $f) | Where-Object { $_ }) -join "`n"
  Msg "$(if ($s.Mode -eq 'Spil') { "Spil-tilstand ($($s.Name))" } else { 'Fokus' }) er slut.`n`n$(if ($txt) { $txt } else { 'Der var intet at sætte tilbage.' })" 'Tilstand' 'OK' $(if (@($s.Failed).Count) { 'Warning' } else { 'Information' }) | Out-Null
}
function Update-ModeUi {
  $m = Get-ModeState
  if ($m) {
    $tx = Mode-Text $m
    $ui.ModeSideTitle.Text = $tx[0]; $ui.ModeSideSub.Text = $tx[2]
    $ui.ModeActiveTitle.Text = $tx[0]; $ui.ModeActiveSub.Text = $tx[1]
    $ui.ModeSide.Visibility = 'Visible'; $ui.ModeActiveCard.Visibility = 'Visible'
    # Fokus må ikke hænge fast, hvis Vagten ikke kører
    if ($m.Mode -eq 'Fokus' -and $m.Until -and (Get-Date) -gt [datetime]$m.Until -and -not $script:StopPending -and -not (Test-VagtAlive)) { $s = Stop-Mode 'tiden er gået'; Update-ModeUi; Show-ModeSummary $s; return }
  } else { $ui.ModeSide.Visibility = 'Collapsed'; $ui.ModeActiveCard.Visibility = 'Collapsed' }
  if (Test-Path $ModeLast) {
    try { $l = Get-Content $ModeLast -Raw -ErrorAction Stop | ConvertFrom-Json
      $ui.ModeLastText.Text = "Seneste: $(if ($l.Mode -eq 'Spil') { "🎮 $($l.Name)" } else { "🔕 Fokus $($l.Name)" }) sluttede $(([datetime]$l.Ended).ToString('dd-MM HH:mm')), fordi $($l.Reason). $(@($l.Done) -join ' · ')$(if (@($l.Failed).Count) { ' · ⚠ ' + (@($l.Failed) -join ' · ') })"
      $ui.ModeLastText.Visibility = 'Visible' } catch {}
  }
}
$modeTimer = New-Object Windows.Threading.DispatcherTimer
$modeTimer.Interval = [TimeSpan]::FromSeconds(3)
$modeTimer.Add_Tick({ try { Update-ModeUi } catch {} })
$stopTimer = New-Object Windows.Threading.DispatcherTimer
$stopTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$stopTimer.Add_Tick({
  $script:StopWait++
  if (-not (Test-Path $ModeFile)) { $stopTimer.Stop(); $script:StopPending = $false; Update-ModeUi; return }
  if ($script:StopWait -ge 6) {   # Vagten nåede det ikke: gør det selv
    $stopTimer.Stop(); $script:StopPending = $false
    Remove-Item $ModeStopFlag -Force -ErrorAction SilentlyContinue
    $s = Stop-Mode 'du afsluttede den'; Update-ModeUi; Show-ModeSummary $s
  }
})
function Request-ModeStop {
  if (-not (Get-ModeState)) { Update-ModeUi; return }
  if (Test-VagtAlive) {
    # Vagten gør det, så den også kan vise de beskeder, der ventede, og ikke starter Spil igen med det samme
    try { [IO.File]::WriteAllText($ModeStopFlag, 'stop') } catch {}
    $script:StopPending = $true; $script:StopWait = 0
    $ui.ModeSideSub.Text = 'Sætter alt tilbage...'; $ui.ModeActiveSub.Text = 'Sætter alt tilbage...'
    $stopTimer.Start()
  } else { $s = Stop-Mode 'du afsluttede den'; Update-ModeUi; Show-ModeSummary $s }
}
$ui.BtnModeStop.Add_Click({ Request-ModeStop })
$ui.BtnModeStopSide.Add_Click({ Request-ModeStop })
$ui.ModeSide.Add_MouseLeftButtonUp({ param($s, $e) if ($e.OriginalSource -isnot [Windows.Controls.Button]) { $ui.NavModes.IsChecked = $true } })

# ---------- Spil ----------
$ModeScanScript = {
  param($sync, $arg)
  $sync.Status = "Måler, hvad der bruger pc'en lige nu (3 sek.)..."
  function Snap { $h = @{}; foreach ($p in Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) { $h[[int]$p.ProcessId] = $p }; $h }
  $a = Snap; $t0 = Get-Date
  Start-Sleep -Seconds 3
  $b = Snap; $sec = [math]::Max(0.5, ((Get-Date) - $t0).TotalSeconds)
  $cores = [Environment]::ProcessorCount
  $agg = @{}
  foreach ($id in $b.Keys) {
    $p = $b[$id]; $path = [string]$p.ExecutablePath
    if (-not $path -or -not $a.ContainsKey($id)) { continue }
    $q = $a[$id]
    $name = [IO.Path]::GetFileNameWithoutExtension([string]$p.Name)
    $cpu = (([double]$p.KernelModeTime + [double]$p.UserModeTime) - ([double]$q.KernelModeTime + [double]$q.UserModeTime)) / 1e7 / $sec / $cores * 100
    $io = (([double]$p.ReadTransferCount + [double]$p.WriteTransferCount + [double]$p.OtherTransferCount) - ([double]$q.ReadTransferCount + [double]$q.WriteTransferCount + [double]$q.OtherTransferCount)) / $sec / 1MB
    $k = $name.ToLower()
    if (-not $agg.ContainsKey($k)) { $agg[$k] = [pscustomobject]@{ Name = $name; Path = $path; Cpu = 0.0; Io = 0.0; Mem = 0.0 } }
    $o = $agg[$k]; $o.Cpu += [math]::Max(0, $cpu); $o.Io += [math]::Max(0, $io); $o.Mem += [double]$p.WorkingSetSize / 1MB
  }
  $sync.Progress = 100
  return @($agg.Values)
}
function Get-GpuProfileW {
  foreach ($f in 'gpu-best.json', 'gpu-pl.json') { $p = Join-Path $JobBase $f; if (Test-Path $p) { try { $w = [int](Get-Content $p -Raw | ConvertFrom-Json).Watts; if ($w -gt 0) { return $w } } catch {} } }
  return 0
}
function Load-Games {
  $gs = @(Get-Games)
  $rows = @(foreach ($g in $gs) {
    $r = New-Object PcTjek.Row
    $r.Navn = [string]$g.Name
    $r.Info = $(if (@($g.Close).Count) { @($g.Close) -join ', ' } else { '(ingenting)' })
    $r.Note = $(if ([int]$g.GpuWatts -gt 0) { "$($g.GpuWatts) W" } else { 'uændret' })
    $r.Gruppe = $(if ($g.Mute) { 'dæmpes' } else { 'som altid' })
    $r.Sti = [string]$g.Exe
    $r })
  $ui.GridGames.ItemsSource = $rows
  $has = $rows.Count -gt 0
  $ui.GridGames.Visibility = $(if ($has) { 'Visible' } else { 'Collapsed' }); $ui.GameBtns.Visibility = $ui.GridGames.Visibility
  $ui.GamesEmpty.Visibility = $(if ($has) { 'Collapsed' } else { 'Visible' })
}
$ui.GridGames.Add_SelectionChanged({ $on = [bool]$ui.GridGames.SelectedItem; $ui.BtnGameEdit.IsEnabled = $on; $ui.BtnGameRemove.IsEnabled = $on })
$ui.BtnGameRemove.Add_Click({
  $it = $ui.GridGames.SelectedItem; if (-not $it) { return }
  Save-Games @(Get-Games | Where-Object { (Exe-Key $_.Exe) -ne (Exe-Key $it.Sti) })
  Log "Spil fjernet: $($it.Navn)"; Load-Games
})
$ui.BtnGameAdd.Add_Click({
  $skip = 'explorer', 'applicationframehost', 'textinputhost', 'systemsettings', 'powershell', 'pwsh', 'conhost', 'windowsterminal', 'taskmgr', 'searchhost', 'startmenuexperiencehost', 'shellexperiencehost', 'lockapp'
  $rows = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -and $_.Path -and ($skip -notcontains $_.ProcessName.ToLower()) -and $_.Path -notlike "$env:SystemRoot\*" -and $_.Id -ne $PID } |
    Sort-Object WorkingSet64 -Descending | ForEach-Object { $r = New-Object PcTjek.Row; $r.Navn = $_.MainWindowTitle; $r.Info = "$($_.ProcessName).exe"; $r.Sti = $_.Path; $r })
  $ui.GridGamePick.ItemsSource = $rows
  $ui.GameSetup.Visibility = 'Collapsed'; $ui.GamePick.Visibility = 'Visible'
})
$ui.GridGamePick.Add_SelectionChanged({ $ui.BtnGamePickOk.IsEnabled = [bool]$ui.GridGamePick.SelectedItem })
$ui.BtnGamePickCancel.Add_Click({ $ui.GamePick.Visibility = 'Collapsed' })
function Game-NiceName($exe, $fallback) {
  try { $vi = (Get-Item -LiteralPath $exe).VersionInfo; foreach ($n in $vi.ProductName, $vi.FileDescription) { if ($n -and $n.Trim().Length -gt 1) { return $n.Trim() } } } catch {}
  if ($fallback) { return $fallback }; return [IO.Path]::GetFileNameWithoutExtension($exe)
}
$ui.BtnGamePickOk.Add_Click({ $it = $ui.GridGamePick.SelectedItem; if ($it) { Begin-GameSetup (Game-NiceName $it.Sti $it.Navn) $it.Sti } })
$ui.BtnGameBrowse.Add_Click({
  $d = New-Object Microsoft.Win32.OpenFileDialog
  $d.Title = 'Vælg spillets programfil (.exe)'; $d.Filter = 'Programmer (*.exe)|*.exe'
  foreach ($dir in "${env:ProgramFiles(x86)}\Steam\steamapps\common", "$env:ProgramFiles\Epic Games", "${env:ProgramFiles(x86)}") { if (Test-Path $dir) { $d.InitialDirectory = $dir; break } }
  if ($d.ShowDialog()) { Begin-GameSetup (Game-NiceName $d.FileName $null) $d.FileName }
})
$ui.BtnGameEdit.Add_Click({ $it = $ui.GridGames.SelectedItem; if ($it) { Begin-GameSetup $it.Navn $it.Sti } })
function Begin-GameSetup($name, $exe) {
  $prev = Get-Games | Where-Object { (Exe-Key $_.Exe) -eq (Exe-Key $exe) } | Select-Object -First 1
  $script:GameEdit = @{ Name = $name; Exe = $exe; Prev = $prev }
  $ui.GamePick.Visibility = 'Collapsed'; $ui.GameSetup.Visibility = 'Visible'
  $ui.GameSetupTitle.Text = "Hvad må lukkes, når $name starter?"
  $ui.GameSetupSub.Text = "Måler i 3 sekunder, hvad der bruger CPU, disk og netværk lige nu..."
  $ui.GridModeApps.ItemsSource = @(); $ui.BtnGameSave.IsEnabled = $false
  $ui.ChkGameMute.IsChecked = $(if ($prev) { [bool]$prev.Mute } else { $true })
  $w = Get-GpuProfileW
  if ($w -gt 0) { $ui.ChkGameGpu.IsEnabled = $true; $ui.ChkGameGpu.Content = "Brug min GPU-profil ($w W fra GPU-testen), og sæt den tilbage bagefter"; $ui.ChkGameGpu.IsChecked = $(if ($prev) { [int]$prev.GpuWatts -gt 0 } else { $false }) }
  else { $ui.ChkGameGpu.IsEnabled = $false; $ui.ChkGameGpu.IsChecked = $false; $ui.ChkGameGpu.Content = "Brug min GPU-profil (kør først 'Find det bedste punkt' under Optimering)" }
  Measure-ModeApps
}
function Measure-ModeApps {
  $g = $script:GameEdit; if (-not $g) { return }
  $ui.BtnGameRemeasure.IsEnabled = $false
  Invoke-Bg $ModeScanScript $null {
    param($res, $err, $c)
    $ui.BtnGameRemeasure.IsEnabled = $true
    $g = $script:GameEdit; if (-not $g) { return }
    if ($err) { $ui.GameSetupSub.Text = "Kunne ikke måle: $err"; return }
    $exeKey = Exe-Key $g.Exe
    $prevClose = @(); if ($g.Prev) { $prevClose = @(@($g.Prev.Close) | ForEach-Object { ([string]$_).ToLower() }) }
    $seen = @{}
    $rows = New-Object System.Collections.ArrayList
    foreach ($p in (@($res) | Sort-Object { - ([double]$_.Cpu * 2 + [double]$_.Io * 3) })) {
      $k = ([string]$p.Name).ToLower()
      if ($ModeNever -contains $k -or $k -eq $exeKey -or $k -like 'pc-tjek*' -or $k -like 'claude*') { continue }
      if ([string]$p.Path -like "$env:SystemRoot\*") { continue }
      $seen[$k] = $true
      $r = New-Object PcTjek.Row
      $desc = ''; try { $desc = (Get-Item -LiteralPath $p.Path -ErrorAction Stop).VersionInfo.FileDescription } catch {}
      $r.Navn = $(if ($desc -and $desc.Trim() -and $desc.Trim() -ne $p.Name) { "$($desc.Trim())  ($($p.Name))" } else { [string]$p.Name })
      $r.Id = [string]$p.Name; $r.Sti = [string]$p.Path
      $r.Info = '{0:N1} %' -f [double]$p.Cpu
      $r.Gruppe = $(if ([double]$p.Io -ge 0.05) { '{0:N1} MB/s' -f [double]$p.Io } else { '–' })
      $r.Status = '{0:N0} MB' -f [double]$p.Mem
      $busy = ([double]$p.Cpu -ge 3 -or [double]$p.Io -ge 1)
      $note = @()
      if ($ModeLaunchers -contains $k -and [double]$p.Io -ge 1) { $note += '⬇ Henter sikkert en opdatering. Sæt overførslen på pause i launcheren, mens du spiller.' }
      elseif ($k -eq 'onedrive' -and [double]$p.Io -ge 0.3) { $note += '☁ Synkroniserer. Lukkes OneDrive, holder den pause og fortsætter bagefter.' }
      if ($ModeUsual -contains $k) { $note += 'Bruges tit under spil (launcher, chat, stream).' }
      elseif ($busy) { $note += 'Bruger meget lige nu.' }
      $r.Note = $note -join ' '
      $r.Valgt = $(if ($g.Prev) { $prevClose -contains $k } else { $false })   # intet er valgt på forhånd: du bestemmer
      $r.Tal = [double]$p.Cpu * 2 + [double]$p.Io * 3
      [void]$rows.Add($r)
    }
    foreach ($k in $prevClose) { if (-not $seen.ContainsKey($k)) { $r = New-Object PcTjek.Row; $r.Navn = "$k  (kører ikke lige nu)"; $r.Id = $k; $r.Valgt = $true; $r.Info = '–'; $r.Gruppe = '–'; $r.Status = '–'; [void]$rows.Add($r) } }
    $ui.GridModeApps.ItemsSource = $rows
    $busyN = @($rows | Where-Object { $_.Tal -ge 6 }).Count
    $ui.GameSetupSub.Text = "Sæt hak ved det, der må lukkes, når spillet starter. Opticon beder dem lukke pænt, som når du trykker på krydset, og tvinger aldrig noget. Beder et program om at gemme, bliver det bare åbent. Bagefter startes det igen. Øverst står det, der bruger mest lige nu$(if ($busyN) { " ($busyN program$(if ($busyN -ne 1) { 'mer' }) er travle)" })."
    $ui.BtnGameSave.IsEnabled = $true
  } $null
}
$ui.BtnGameRemeasure.Add_Click({ Measure-ModeApps })
$ui.BtnGameCancel.Add_Click({ $script:GameEdit = $null; $ui.GameSetup.Visibility = 'Collapsed' })
$ui.BtnGameSave.Add_Click({
  $g = $script:GameEdit; if (-not $g) { return }
  $sel = @($ui.GridModeApps.ItemsSource | Where-Object { $_.Valgt } | ForEach-Object { $_.Id })
  $new = [ordered]@{ Name = $g.Name; Exe = $g.Exe; Close = @($sel); Mute = [bool]$ui.ChkGameMute.IsChecked; GpuWatts = $(if ($ui.ChkGameGpu.IsChecked) { Get-GpuProfileW } else { 0 }) }
  $list = @(@(Get-Games | Where-Object { (Exe-Key $_.Exe) -ne (Exe-Key $g.Exe) }) + @(,$new))
  Save-Games $list
  Log "Spil gemt: $($g.Name) · lukker $($sel -join ', ')"
  $script:GameEdit = $null; $ui.GameSetup.Visibility = 'Collapsed'
  Load-Games
  $txt = "✓ Gemt.`n`nNår $($g.Name) starter, sætter Opticon selv Spil-tilstand i gang$(if ($sel.Count) { " og lukker $($sel -join ', ')" }). Når du lukker spillet, bliver alt sat tilbage."
  if (-not (Get-VagtTask)) {
    if ((Msg "$txt`n`nDet kræver, at Vagten er slået til (den holder øje med, hvornår spillet starter). Slå Vagten til nu?" 'Spil' 'YesNo' 'Question') -eq 'Yes') { [void](Install-Vagt) }
  } else {
    if (Get-Process -Name (Exe-Key $g.Exe) -ErrorAction SilentlyContinue) { $txt += "`n`nSpillet kører allerede, så det går i gang om et øjeblik." }
    Msg $txt 'Spil' | Out-Null
  }
})

# ---------- Fokus ----------
$ui.BtnFocStart.Add_Click({
  if (Get-ModeState) { Msg 'En tilstand er allerede aktiv. Afslut den først.' 'Fokus' | Out-Null; return }
  $min = if ($ui.Foc90.IsChecked) { 90 } elseif ($ui.Foc50.IsChecked) { 50 } else { 25 }
  $sites = @(); if ($ui.ChkFocBlock.IsChecked) { $sites = @($ui.FocSites.Text -split '[,;\s]+' | Where-Object { $_ }) }
  if (-not $ui.ChkFocMute.IsChecked -and -not $sites.Count) { Msg 'Vælg mindst én ting: dæmp beskeder eller bloker sider.' 'Fokus' | Out-Null; return }
  try { $m = Start-FocusMode $min ([bool]$ui.ChkFocMute.IsChecked) $sites } catch { Msg "Kunne ikke starte fokus:`n$($_.Exception.Message)" 'Fokus' 'OK' 'Error' | Out-Null; try { [void](Stop-Mode 'fejl ved start') } catch {}; return }
  Update-ModeUi
  $notes = @()
  if ($sites.Count -and (Get-Process msedge, chrome, firefox, brave, opera -ErrorAction SilentlyContinue)) { $notes += 'Sider, der allerede er åbne, kan virke et lille stykke tid endnu. Luk fanen, og åbn den igen.' }
  if (-not (Test-VagtAlive)) { $notes += 'Vagten kører ikke, så fokus slutter først, når Opticon er åben (eller næste gang du åbner den).' }
  $ui.StatusText.Text = "🔕 Fokus i $min min. Slutter kl. $(([datetime]$m.Until).ToString('HH:mm'))."
  if ($notes.Count) { Msg ("Fokus er startet.`n`n" + ($notes -join "`n`n")) 'Fokus' | Out-Null }
})
$ui.BtnFocNotif.Add_Click({
  $prog = ''; try { $prog = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction Stop).ProgId } catch {}
  $isChrome = $prog -like 'ChromeHTML*'
  $name = if ($isChrome) { 'Chrome' } else { 'Edge' }
  $a = Msg "Generer fx kun Facebooks beskeder, kan du slå netop det websteds beskeder fra i browseren og beholde resten.`n`nI $($name): find webstedet under 'Tilladt' eller 'Allowed', og vælg Bloker.`n`nÅbn indstillingen i $name nu?" 'Websteders beskeder' 'YesNo' 'Question'
  if ($a -ne 'Yes') { return }
  try { if ($isChrome) { Start-Process 'chrome.exe' 'chrome://settings/content/notifications' } else { Start-Process 'msedge.exe' 'edge://settings/content/notifications' } } catch {}
})


# =====================================================================
#  PRODUCENTENS EGET PROGRAM (bærbare og færdigbyggede pc'er)
#  Drivere, BIOS og firmware fra producenten finder ting, Windows Update kan overse.
# =====================================================================
$VendorTools = @(
  @{ Match = 'lenovo'; Name = 'Lenovo Vantage'; Apps = 'Lenovo Vantage|Lenovo Commercial Vantage|Lenovo PC Manager'; Get = 'ms-windows-store://pdp/?productid=9WZDNCRFJ4MV'; GetBiz = 'ms-windows-store://pdp/?productid=9NR5B8GVVM13'; BizName = 'Lenovo Commercial Vantage'; Biz = '(?i)think'; Where = "Gå til Enhed → Systemopdatering (System Update), og tryk 'Søg efter opdateringer'." }
  @{ Match = 'dell|alienware'; Name = 'Dell SupportAssist'; Apps = 'SupportAssist|Dell Command \| Update|Dell Update|Alienware Update'; Get = 'https://www.dell.com/support/home'; Where = "Vælg 'Opdatér software' / 'Check for updates', og installer det, den finder." }
  @{ Match = '^hp|hewlett'; Name = 'HP Support Assistant'; Apps = 'HP Support Assistant'; Get = 'https://support.hp.com/drivers'; Where = "Vælg Opdateringer, og tryk 'Søg efter opdateringer og meddelelser'." }
  @{ Match = 'asus'; Name = 'G-Helper'; Apps = 'G-Helper|GHelper'; Proc = 'GHelper'; Alt = 'MyASUS|Armoury Crate'; Get = 'https://github.com/seerge/g-helper/releases/latest'; Where = "Tryk 'Updates' nederst i G-Helper. Nye BIOS- og driverversioner står med rødt."; AltWhere = 'G-Helper er et lille gratis open source-alternativ til Armoury Crate (ca. 5 MB), der også finder BIOS- og driveropdateringer. Kan du hellere lide ASUS egne programmer, så brug MyASUS → Live-opdatering.'; Mobile = $true }
  @{ Match = 'micro-star|msi'; Name = 'MSI Center'; Apps = 'MSI Center|Dragon Center'; Get = 'https://www.msi.com/Landing/MSI-Center'; Where = "Gå til Support → Live Update, og søg efter opdateringer."; Mobile = $true }
  @{ Match = 'acer'; Name = 'Acer Care Center'; Apps = 'Care Center|Acer Purified'; Get = 'https://www.acer.com/support'; Where = "Vælg Opdatering, og tryk 'Søg efter opdateringer'."; Mobile = $true }
  @{ Match = 'microsoft'; Name = 'Windows Update'; Apps = ''; Get = 'ms-settings:windowsupdate'; Where = 'Surface-drivere og firmware kommer via Windows Update. Husk også Valgfrie opdateringer.' }
)
function Get-VendorInfo {
  if ($script:VendorInfo) { return $script:VendorInfo }
  try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $pr = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
    $man = [string]$cs.Manufacturer
    $model = if ($man -match '(?i)lenovo' -and $pr.Version) { [string]$pr.Version } elseif ($cs.SystemFamily -and $cs.SystemFamily -notmatch '(?i)default|to be filled') { "$($cs.SystemFamily) $($cs.Model)".Trim() } else { [string]$cs.Model }
    $mobile = ($cs.PCSystemType -eq 2)
    $t = $VendorTools | Where-Object { $man -match "(?i)$($_.Match)" } | Select-Object -First 1
    if ($t -and $t.Mobile -and -not $mobile) { $t = $null }   # selvbyggede stationære: bundkortets program er ikke det rigtige sted
    $app = $null
    if ($t -and $t.Proc) { $gp = Get-Process -Name $t.Proc -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1; if ($gp) { $app = [pscustomobject]@{ Name = $t.Name; AppID = $null; Path = $gp.Path } } }   # bærbare programmer som G-Helper står ikke i Start
    if (-not $app -and $t -and $t.Apps) { try { $app = Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -match "(?i)^($($t.Apps))" } | Select-Object -First 1 } catch {} }
    $alt = $null; if (-not $app -and $t -and $t.Alt) { try { $alt = Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -match "(?i)^($($t.Alt))" } | Select-Object -First 1 } catch {} }
    $biz = $t -and $t.Biz -and ($model -match $t.Biz)
    $script:VendorInfo = [pscustomobject]@{ Man = $man; Model = $model; Mobile = $mobile; Tool = $t; App = $app; Alt = $alt; Biz = [bool]$biz }
  } catch { $script:VendorInfo = [pscustomobject]@{ Man = ''; Model = ''; Mobile = $false; Tool = $null; App = $null; Biz = $false } }
  return $script:VendorInfo
}
function Open-VendorTool {
  $v = Get-VendorInfo; if (-not $v.Tool) { return }
  if ($v.App -and $v.App.Path) { Start-Process "$env:SystemRoot\explorer.exe" "`"$($v.App.Path)`""; return }
  if ($v.App) { Start-Process "$env:SystemRoot\explorer.exe" "shell:AppsFolder\$($v.App.AppID)"; return }
  $url = if ($v.Biz -and $v.Tool.GetBiz) { $v.Tool.GetBiz } else { $v.Tool.Get }
  Start-Process $url
}
function Show-VendorCard {
  $v = Get-VendorInfo
  if (-not $v.Tool) { $ui.VendorCard.Visibility = 'Collapsed'; return }
  $name = if ($v.App) { $v.App.Name } elseif ($v.Biz -and $v.Tool.BizName) { $v.Tool.BizName } else { $v.Tool.Name }
  $brand = ($v.Man -replace '(?i)\s*(inc\.?|corporation|co\.,? ltd\.?|computer|technologies)\s*', ' ').Trim()
  if ($brand.Length -gt 3 -and $brand -ceq $brand.ToUpper()) { $brand = (Get-Culture).TextInfo.ToTitleCase($brand.ToLower()) }   # LENOVO -> Lenovo
  $ui.VendorTitle.Text = "💻  Drivere og BIOS til din $brand$(if ($v.Model) { " ($($v.Model))" })"
  if ($v.Tool.Name -eq 'Windows Update') {
    $ui.VendorText.Text = $v.Tool.Where
    $ui.BtnVendorOpen.Content = '⬆  Åbn Windows Update'
  } elseif ($v.App) {
    $ui.VendorText.Text = "Brug $name til drivere, BIOS og firmware. Producentens eget program kender netop din model og finder opdateringer, som Windows Update kan overse. $($v.Tool.Where)"
    $ui.BtnVendorOpen.Content = "Åbn $name"
  } else {
    $ui.VendorText.Text = if ($v.Tool.AltWhere) { "$($v.Tool.AltWhere)$(if ($v.Alt) { " Du har allerede $($v.Alt.Name)." })" } else { "$name er $($brand)s gratis program til drivere, BIOS og firmware til netop din model. Det finder opdateringer, som Windows Update kan overse. Det ser ikke ud til at være installeret." }
    $ui.BtnVendorOpen.Content = $(if (($(if ($v.Biz -and $v.Tool.GetBiz) { $v.Tool.GetBiz } else { $v.Tool.Get })) -like 'ms-windows-store:*') { "⬇  Hent $name (Microsoft Store)" } else { "⬇  Hent $name" })
  }
  $ui.VendorCard.Visibility = 'Visible'
}
$ui.BtnVendorOpen.Add_Click({ Open-VendorTool })


# =====================================================================
#  BENCHMARK: den store test, historik, sammenligning og deling
# =====================================================================
$BenchTestVersion = 3   # 3: grafik måles som rigtige FPS uden skærmens Hz-loft; delvise tests får ingen samlet score
$BenchHistFile = Join-Path $OutDir 'benchmark-historik.json'
$BenchRef = @{ Cpu1 = 1000; CpuN = 8000; Ram = 15; DiskR = 2000; Gpu = 1000 }   # Gpu: FPS uden V-Sync i 1080p (målemetode 2)
$BenchGpuV = 2   # grafikkens målemetode: 2 = uden skærmlås (fra 2.45)   # faste pejlemærker: 1000 point i alt
function Bench-Total($r) {
  if ([int]$r.GpuV -ne $BenchGpuV) { return $null }   # grafik målt med den gamle metode (låst til skærmen): ingen samlet score
  $parts = @(); foreach ($k in 'Cpu1', 'CpuN', 'Ram', 'DiskR', 'Gpu') { if ($r.$k -and [double]$r.$k -gt 0) { $parts += [math]::Log([double]$r.$k / $BenchRef[$k]) } else { return $null } }   # mangler en del: ingen samlet score
  return [int][math]::Round(1000 * [math]::Exp(($parts | Measure-Object -Average).Average))
}
function Norm-Hw($n) { (([string]$n).ToLower() -replace '\((r|tm)\)', '' -replace '\b(processor|cpu|with radeon graphics|w/ radeon.*|graphics|gpu)\b', '' -replace '[^a-z0-9]+', ' ').Trim() }
function Bench-Remain($p) {
  if (-not $script:BenchStart -or $p -lt 4) { return '' }
  $el = ((Get-Date) - $script:BenchStart).TotalSeconds; $rem = [int]($el * (100 - $p) / $p)
  return " · ⏱ ca. $([math]::Floor($rem / 60)):$('{0:00}' -f ($rem % 60)) tilbage"
}
function Get-RepoInfo {
  if ($UpdateUrl -match 'raw\.githubusercontent\.com/([^/]+)/([^/]+)/') { return @{ Owner = $matches[1]; Repo = $matches[2]; Results = "https://raw.githubusercontent.com/$($matches[1])/$($matches[2])/results/results.json" } }
  return $null
}
function Get-BenchHist { if (Test-Path $BenchHistFile) { try { return @(Get-Content $BenchHistFile -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) } catch {} }; return @() }
function Load-Bench {
  $h = @(Get-BenchHist)
  if ($h.Count -and -not $script:BenchLast) { $script:BenchLast = $h[-1]; Show-Bench $script:BenchLast; Load-BenchCompare }
  Show-BenchHist
  try { Show-GameHist } catch { Log "Spil-historik: $_" }
}
function Show-BenchHist {
  $h = @(Get-BenchHist)
  [array]::Reverse($h)
  $rows = @(foreach ($x in $h) { $r = New-Object PcTjek.Row; $r.Navn = ([datetime]$x.Date).ToString('dd-MM-yyyy HH:mm'); $r.Info = $(if ($x.Score) { [string]$x.Score } else { 'delvis' }); $r.Note = "$($x.Cpu1) / $($x.CpuN)"; $r.Status = $(if ($x.Gpu) { "$($x.Gpu) fps" } else { '–' }); $r.Gruppe = "$($x.DiskR) MB/s"; $r.Sti = "$($x.Hw.Cpu)$(if ($x.Hw.Laptop) { ' · bærbar' })$(if ($x.Hw.OnBattery) { ' · på batteri' })"; $r })
  $ui.GridBenchHist.ItemsSource = $rows
  $ui.GridBenchHist.Visibility = $(if ($rows.Count) { 'Visible' } else { 'Collapsed' }); $ui.BenchHistEmpty.Visibility = $(if ($rows.Count) { 'Collapsed' } else { 'Visible' })
}

# ---------- Mål i mit spil ----------
$GameHistFile = Join-Path $OutDir 'spil-maalinger.json'
function Get-GameHist { if (Test-Path $GameHistFile) { try { return @(Get-Content $GameHistFile -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) } catch {} }; return @() }
function Save-GameHist($r) {
  $h = @(Get-GameHist) + @($r)
  if ($h.Count -gt 200) { $h = $h[($h.Count - 200)..($h.Count - 1)] }
  try { if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }; [IO.File]::WriteAllText($GameHistFile, (ConvertTo-Json -InputObject @($h) -Depth 4), (New-Object Text.UTF8Encoding $false)) } catch { Log "Spil-historik FEJL: $_" }
}
function Fmt-Delta($now, $before, $unit) {
  if ($null -eq $before -or [double]$before -eq 0) { return '' }
  $d = [double]$now - [double]$before; $pct = 100 * $d / [double]$before
  $sign = if ($d -ge 0) { '+' } else { '' }
  return "$sign$([math]::Round($d))$unit ($sign$([math]::Round($pct)) %)"
}
function Show-GameHist {
  $h = @(Get-GameHist)
  $rows = New-Object System.Collections.ArrayList
  for ($i = $h.Count - 1; $i -ge 0; $i--) {
    $x = $h[$i]
    $prev = $null
    for ($k = $i - 1; $k -ge 0; $k--) { if ($h[$k].Game -eq $x.Game) { $prev = $h[$k]; break } }
    $r = New-Object PcTjek.Row
    $r.Navn = ([datetime]$x.Date).ToString('dd-MM HH:mm'); $r.Gruppe = [string]$x.Game
    $r.Info = "$($x.Fps)"; $r.Status = "$($x.Low1)"; $r.Sti = "$($x.HakMin)"
    $r.Note = if ($prev) { "FPS $(Fmt-Delta $x.Fps $prev.Fps '') · 1 % low $(Fmt-Delta $x.Low1 $prev.Low1 '')" } else { 'første måling' }
    [void]$rows.Add($r)
  }
  $ui.GridGameHist.ItemsSource = @($rows)
  $ui.GridGameHist.Visibility = $(if ($rows.Count) { 'Visible' } else { 'Collapsed' })
  if ($h.Count -and -not $script:GameShown) { $script:GameShown = $true; Show-GameResult $h[-1] $null }
}
function Show-GameResult($r, $prev) {
  $ui.GameTiles.Visibility = 'Visible'
  $ui.GameFps.Text = "$($r.Fps)"; $ui.GameLow.Text = "$($r.Low1)"; $ui.GameHak.Text = "$($r.HakMin)"
  $ui.GameFpsSub.Text = "$($r.Game) · $($r.Seconds) sek$(if ($prev) { ' · ' + (Fmt-Delta $r.Fps $prev.Fps ' fps') + ' mod sidst' })"
  $ui.GameLowSub.Text = $(if ($prev) { (Fmt-Delta $r.Low1 $prev.Low1 ' fps') + ' mod sidst' } else { 'de langsomste 1 % af billederne' })
  $ui.GameHakSub.Text = $(if ([double]$r.HakMin -lt 3) { 'jævnt' } elseif ([double]$r.HakMin -lt 12) { 'enkelte hak' } else { 'mange hak' })
  $ui.GameHak.Foreground = $Brush.ConvertFromString($(if ([double]$r.HakMin -lt 3) { '#34D399' } elseif ([double]$r.HakMin -lt 12) { '#F6C344' } else { '#F87171' }))
  $capAt = $null
  foreach ($cv in 30, 48, 60, 72, 75, 90, 100, 120, 141, 144, 160, 165, 170, 180, 200, 237, 240, 280, 360) { if ([math]::Abs([double]$r.Fps - $cv) -le $cv * 0.03 -and [double]$r.Low1 -ge 0.8 * $cv) { $capAt = $cv; break } }
  $ui.GameLimit.Text = switch ($r.Limit) { 'gpu' { "Grafikkortet ($($r.GpuShare) % travlt)" } 'cpu' { 'Processoren' } 'cap' { $(if ($capAt) { "FPS-loft ($capAt)" } else { 'Ingen af dem fuldt' }) } 'mixed' { 'Lidt af begge' } default { 'Ukendt' } }
  $adv = New-Object System.Collections.ArrayList
  switch ($r.Limit) {
    'gpu'   { [void]$adv.Add('🎯  Grafikkortet arbejder for fuld kraft. Det er normalt i krævende spil. Vil du have flere FPS: slå DLSS/FSR/XeSS til, sænk opløsning eller de tungeste grafikindstillinger (skygger, ray tracing), eller prøv din GPU-profil under Optimering.') }
    'cpu'   { [void]$adv.Add('🎯  Processoren sætter grænsen, mens grafikkortet venter. Grafikindstillinger hjælper næsten ikke her. Prøv: luk programmer i baggrunden (Spil-tilstand under Tilstande), slå XMP/EXPO til hvis Benchmark foreslår det, og sænk indstillinger der rammer processoren (sigtbarhed, antal personer, fysik).') }
    'cap'   { [void]$adv.Add($(if ($capAt) { "🎯  FPS ligger fast omkring $capAt. Det er et FPS-loft: V-Sync, en FPS-grænse i spillet eller driveren, eller skærmens Hz. Er det med vilje, er det fint: det giver mindre strøm, varme og larm." } else { "🎯  Hverken processor eller grafikkort er fuldt brugt (grafikkortet $($r.GpuShare) %), og FPS ligger ikke fast ved en bestemt grænse. Spillet venter måske på noget andet, fx en enkelt processorkerne, netværk eller disk. Prøv at måle et andet sted i spillet." })) }
    'mixed' { [void]$adv.Add('🎯  Processor og grafikkort deles om at bremse. Spillet er ret godt afstemt til din pc.') }
  }
  if ([double]$r.Low1 -lt 0.5 * [double]$r.Fps) { [void]$adv.Add("〰  Stor forskel på gennemsnit ($($r.Fps)) og 1 % low ($($r.Low1)). Spillet føles mindre jævnt, end gennemsnittet siger.") }
  if ([double]$r.HakMin -ge 12) {
    $dvr = $false; try { $dvr = Test-BgRecording } catch {}
    [void]$adv.Add("⚠  Mange hak ($($r.HakMin) pr. minut). Ofte skyldes det, at spillet bygger shadere første gang: spil et par minutter mere, og mål igen. Ellers: programmer i baggrunden, en næsten fuld disk eller for lidt RAM.$(if ($dvr) { ' Baggrundsoptagelse er slået til: slå den fra under Ydelse og helbred.' })")
  }
  if ($r.Mode -match 'Copy with (CPU|GPU) GDI') { [void]$adv.Add("🪟  Spillet kører i en gammeldags vinduestilstand ($($r.Mode)), som koster FPS og forsinkelse. Vælg fuldskærm eller kantløs fuldskærm i spillet, og slå 'Optimeringer for spil i vinduer' til (Indstillinger → System → Skærm → Grafik).") }
  if ([int]$r.VSync -ge 50 -and $r.Limit -ne 'gpu') { [void]$adv.Add('ℹ  V-Sync er slået til i spillet. Har du en G-Sync/FreeSync-skærm, giver det ofte lavere forsinkelse at slå V-Sync fra i spillet og sætte en FPS-grænse lige under skærmens Hz.') }
  [void]$adv.Add('💡  Lav en ændring, mål igen samme sted i spillet, og se forskellen under "Mod sidst".')
  $ui.GameAdvice.Text = $adv -join "`n`n"; $ui.GameAdvice.Visibility = 'Visible'
}
function Start-GameMeasure([int]$secs, [string]$abPhase) {
  $first = -not (Test-Path (Join-Path (Join-Path $JobBase 'tools') 'PresentMon.exe'))
  $head = if ($abPhase -eq 'before') { "Måling FØR din ændring ($($script:Ab.Title))`n`n" } elseif ($abPhase -eq 'after') { "Måling EFTER din ændring ($($script:Ab.Title))`n`nGå samme sted hen i spillet som sidst, og spil på samme måde.`n`n" } else { '' }
  $ok = Msg "$($head)Sådan gør du:`n`n1. Start dit spil, og gå ind et sted, hvor du kan spille normalt.`n2. Tryk OK. Opticon gemmer sig, og du har 10 sek til at skifte til spillet.`n3. Bip = målingen starter. Spil normalt i $secs sek.`n4. Nyt bip = færdig. Kig i Opticon bagefter.$(if ($first) { "`n`nFørste gang henter Opticon Intels gratis PresentMon (ca. 5 MB) fra GitHub." })" 'Mål i mit spil' 'OKCancel' 'Information'
  if ($ok -ne 'OK') { return }
  $ui.BtnGameMeasure.IsEnabled = $false; $ui.BtnGameAb.IsEnabled = $false; $ui.BtnGameAbNext.IsEnabled = $false
  $ui.GameSub.Text = "Måler i $secs sek. Skift til dit spil..."
  try { $win.WindowState = 'Minimized' } catch {}
  $pmName = $null; try { $pmName = PowerMode-Name (Get-PowerMode) } catch {}
  Invoke-Bg $GameMeasureScript @{ Tools = (Join-Path $JobBase 'tools'); Seconds = $secs; GpuId = (Get-GpuId) } {
    param($res, $err, $c)
    $ui.BtnGameMeasure.IsEnabled = $true; $ui.BtnGameAb.IsEnabled = $true; $ui.BtnGameAbNext.IsEnabled = $true
    if ($res -is [array]) { $res = @($res | Where-Object { $_.Fps })[-1] }
    if ($err -or -not $res) {
      $ui.GameSub.Text = "Målingen lykkedes ikke: $err"; Log "Spilmåling FEJL: $err"
      try { $win.WindowState = 'Normal'; [void]$win.Activate() } catch {}
      return
    }
    try { $res | Add-Member -NotePropertyName PowerMode -NotePropertyValue $c.PowerMode -Force; $res | Add-Member -NotePropertyName Ab -NotePropertyValue $c.Ab -Force } catch {}
    $prev = @(Get-GameHist | Where-Object { $_.Game -eq $res.Game })
    $prev = if ($prev.Count) { $prev[-1] } else { $null }
    Save-GameHist $res
    Log "Spilmåling: $($res.Game) $($res.Fps) fps, 1% low $($res.Low1), hak/min $($res.HakMin), bremse $($res.Limit), GPU $($res.GpuShare) %, CPU $($res.CpuShare) %, $(if ($res.W) { "$($res.W) W, " })mode $($res.Mode)$(if ($c.Ab) { ", A/B: $($c.Ab)" })"
    $ui.GameSub.Text = "Målt $($res.Frames) billeder i $($res.Game)."
    Show-GameResult $res $prev
    $script:GameShown = $true
    Show-GameHist
    if ($c.Ab -eq 'before' -and $script:Ab) { $script:Ab.Before = $res; $script:Ab.Secs = $c.Secs; Show-AbState }
    elseif ($c.Ab -eq 'after' -and $script:Ab -and $script:Ab.Before) { Finish-Ab $res }
  } @{ Ab = $abPhase; Secs = $secs; PowerMode = $pmName }
}
$ui.BtnGameMeasure.Add_Click({ Start-GameMeasure (@(30, 60, 120)[[math]::Max(0, $ui.GameDur.SelectedIndex)]) $null })

# ---------- Hjalp det i mit spil? (før/efter med samme spil og samme sted) ----------
function Show-AbState {
  $ab = $script:Ab
  if (-not $ab) { $ui.GameAbBox.Visibility = 'Collapsed'; return }
  $ui.GameAbBox.Visibility = 'Visible'
  if (-not $ab.Before) {
    $ui.GameAbTitle.Text = "🔬  Test: $($ab.Title)"
    $ui.GameAbText.Text = "Trin 1 af 3: Mål FØR ændringen. Gå et sted hen i spillet, du kan finde igen, og hvor der sker nogenlunde det samme hver gang."
    $ui.BtnGameAbNext.Content = 'Mål FØR'
  } else {
    $b = $ab.Before
    $ui.GameAbTitle.Text = "🔬  Test: $($ab.Title) · FØR er målt ($($b.Fps) fps i $($b.Game))"
    $ui.GameAbText.Text = "Trin 2 af 3: Lav nu din ændring ($($ab.Title)), fx i spillets indstillinger, i NVIDIA/AMD-appen eller i Afterburner. Gå samme sted hen i spillet igen.`nTrin 3 af 3: Tryk Mål EFTER. Opticon måler lige så længe som før ($($ab.Secs) sek) og sammenligner."
    $ui.BtnGameAbNext.Content = 'Mål EFTER'
  }
}
function Start-Ab {
  $t = [Microsoft.VisualBasic.Interaction]::InputBox("Hvad vil du afprøve?`n`nFx 'DLSS Kvalitet → Balanceret', 'Undervolt 900 mV', 'Strømgrænse 80 %', 'Ny driver', 'XMP slået til'.`n`nOpticon måler i dit spil FØR, du laver ændringen, og igen EFTER, og fortæller, om det hjalp.", 'Hjalp det i mit spil?', '')
  if (-not $t -or -not $t.Trim()) { return }
  $script:Ab = @{ Title = $t.Trim(); Before = $null; Secs = (@(30, 60, 120)[[math]::Max(0, $ui.GameDur.SelectedIndex)]) }
  $ui.NavBench.IsChecked = $true
  Show-AbState
}
$ui.BtnGameAb.Add_Click({ Start-Ab })
$ui.BtnHelpedGame.Add_Click({ Start-Ab })
$ui.BtnGameAbCancel.Add_Click({ $script:Ab = $null; Show-AbState })
$ui.BtnGameAbNext.Add_Click({
  if (-not $script:Ab) { Start-Ab; return }
  if (-not $script:Ab.Before) { Start-GameMeasure ([int]$script:Ab.Secs) 'before' } else { Start-GameMeasure ([int]$script:Ab.Secs) 'after' }
})
# Hvor meget FPS svinger af sig selv inden for én måling (spredning mellem 10-sekunders bidder), i %
function Get-SegNoise($r) {
  $x = @($r.Seg | ForEach-Object { [double]$_ } | Where-Object { $_ -gt 0 })
  if ($x.Count -lt 2) { return 3.0 }
  $m = ($x | Measure-Object -Average).Average
  $sd = [math]::Sqrt((($x | ForEach-Object { ($_ - $m) * ($_ - $m) } | Measure-Object -Sum).Sum) / ($x.Count - 1))
  return [math]::Max(2.0, [math]::Min(15.0, 100 * $sd / $m))
}
function Finish-Ab($after) {
  $ab = $script:Ab; $b = $ab.Before; $a = $after
  $pc = { param($n, $o) if (-not $o -or [double]$o -le 0) { return $null }; 100 * ([double]$n - [double]$o) / [double]$o }
  $noise = [math]::Round([math]::Max((Get-SegNoise $b), (Get-SegNoise $a)), 1)
  $dF = & $pc $a.Fps $b.Fps; $dL = & $pc $a.Low1 $b.Low1
  $parts = @(); $gain = 0; $loss = 0
  if ($null -ne $dF) {
    if ([math]::Abs($dF) -le $noise) { $parts += "samme billedhastighed ($($b.Fps) → $($a.Fps) fps, inden for den normale udsving på ±$noise %)" }
    elseif ($dF -gt 0) { $parts += "$([math]::Round($dF)) % flere fps ($($b.Fps) → $($a.Fps))"; $gain += 2 }
    else { $parts += "$([math]::Round(-$dF)) % færre fps ($($b.Fps) → $($a.Fps))"; $loss += 2 }
  }
  if ($null -ne $dL -and [math]::Abs($dL) -gt [math]::Max(5, 1.5 * $noise)) {
    if ($dL -gt 0) { $parts += "1 % low $([math]::Round($dL)) % bedre ($($b.Low1) → $($a.Low1))"; $gain++ } else { $parts += "1 % low $([math]::Round(-$dL)) % dårligere ($($b.Low1) → $($a.Low1))"; $loss++ }
  }
  $hb = [double]$b.HakMin; $ha = [double]$a.HakMin
  if ([math]::Max($hb, $ha) -ge 3 -and [math]::Abs($ha - $hb) -ge 2 -and [math]::Abs($ha - $hb) -ge 0.25 * [math]::Max($hb, $ha)) {
    if ($ha -lt $hb) { $parts += "færre lange billeder/hak ($hb → $ha pr. minut)"; $gain++ } else { $parts += "flere lange billeder/hak ($hb → $ha pr. minut)"; $loss++ }
  }
  if ($null -ne $b.W -and $null -ne $a.W) {
    $dW = [double]$a.W - [double]$b.W
    if ([math]::Abs($dW) -ge 5) { if ($dW -lt 0) { $parts += "$([math]::Round(-$dW)) W lavere strømforbrug på grafikkortet"; $gain++ } else { $parts += "$([math]::Round($dW)) W højere strømforbrug på grafikkortet"; if ($loss -or ($null -ne $dF -and $dF -le $noise)) { $loss++ } } }
  }
  if ($null -ne $b.Tmax -and $null -ne $a.Tmax -and [math]::Abs([double]$a.Tmax - [double]$b.Tmax) -ge 3) { $parts += "maks. temperatur $($b.Tmax) → $($a.Tmax) °C" }
  # Hvad ellers var anderledes (så du kan se, om noget andet også har ændret sig)
  $ctx = @()
  if ($a.Game -ne $b.Game) { $ctx += "OBS: før blev målt i $($b.Game) og efter i $($a.Game)" }
  if ($b.Driver -and $a.Driver -and $b.Driver -ne $a.Driver) { $ctx += "driver $($b.Driver) → $($a.Driver)" }
  if ($b.PowerLimit -and $a.PowerLimit -and [math]::Abs([double]$a.PowerLimit - [double]$b.PowerLimit) -ge 2) { $ctx += "strømgrænse $($b.PowerLimit) → $($a.PowerLimit) W" }
  if ($b.PowerMode -and $a.PowerMode -and $b.PowerMode -ne $a.PowerMode) { $ctx += "Windows' strømtilstand $($b.PowerMode) → $($a.PowerMode)" }
  $good = if ($gain -gt $loss) { $true } elseif ($loss -gt $gain) { $false } else { $null }
  $head = if ($good -eq $true) { '✅ Det hjalp' } elseif ($good -eq $false) { '⚠ Det blev værre' } else { '➖ Ingen klar forskel' }
  $verdict = "$($head): " + ($parts -join ', ') + '.'
  if ($noise -ge 8) { $verdict += " FPS svingede meget undervejs (±$noise %), så mål gerne en gang til samme sted." }
  if ($ctx.Count) { $verdict += " Andet, der også var anderledes: $($ctx -join '; ')." }
  $fmt = { param($r) [pscustomobject]@{ Fps = $r.Fps; Low1 = $r.Low1; HakMin = $r.HakMin; W = $r.W; Game = $r.Game; Date = $r.Date } }
  try { [void](Add-Change 'spil' "$($ab.Title) ($($a.Game))" (& $fmt $b) (& $fmt $a) 'færdig' $verdict $good) } catch { Log "Hjalp det-fejl: $_" }
  $ui.GameAbBox.Visibility = 'Visible'
  $ui.GameAbTitle.Text = "🔬  $($ab.Title): $head"
  $ui.GameAbText.Text = ($parts -join ' · ') + $(if ($ctx.Count) { "`nAndet, der var anderledes: $($ctx -join '; ')" }) + "`nGemt under Hjalp det?."
  $ui.BtnGameAbNext.Content = 'Ny test'
  $script:Ab = $null
  $script:AbDone = $true
  try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
}

# ---------- Hvad fylder siden sidst? ----------
$SpaceHistFile = Join-Path $OutDir 'plads-historik.json'
function Get-SpaceHist { if (Test-Path $SpaceHistFile) { try { return @(Get-Content $SpaceHistFile -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) } catch {} }; return @() }
function Fmt-SpaceDelta([double]$b) {
  if ([math]::Abs($b) -lt 50MB) { return '≈ uændret' }
  $s = if ($b -gt 0) { '+' } else { '−' }
  return "$s$(Fmt-GB ([math]::Abs($b)))"
}
function Show-Space($cur, $prev) {
  if (-not $cur) { return }
  $prevF = @{}; if ($prev) { foreach ($f in @($prev.Folders)) { $prevF[[string]$f.Path] = [double]$f.Size } }
  $rows = New-Object System.Collections.ArrayList
  foreach ($f in @($cur.Folders)) {
    $d = if ($prev) { if ($prevF.ContainsKey([string]$f.Path)) { [double]$f.Size - $prevF[[string]$f.Path] } else { [double]$f.Size } } else { 0 }
    $note = switch ([string]$f.Kind) { 'games' { 'Spil' } 'temp' { 'Kan ryddes under Oprydning' } default { 'Dine filer' } }
    if ($prev -and -not $prevF.ContainsKey([string]$f.Path)) { $note += ' · ny siden sidst' }
    [void]$rows.Add([pscustomobject]@{ F = $f; D = $d; Note = $note; Child = [bool]$f.Parent })
  }
  # Vis det, der er vokset mest. Første gang: det, der fylder mest.
  $pick = if ($prev) { @($rows | Where-Object { $_.Child -and [math]::Abs($_.D) -ge 100MB } | Sort-Object { -[double]$_.D } | Select-Object -First 12) } else { @() }
  if (-not $pick.Count) { $pick = @($rows | Where-Object { $_.Child } | Sort-Object { -[double]$_.F.Size } | Select-Object -First 12) }
  $grid = foreach ($x in $pick) {
    $r = New-Object PcTjek.Row
    $r.Navn = [string]$x.F.Label; $r.Info = Fmt-GB ([double]$x.F.Size); $r.Status = $(if ($prev) { Fmt-SpaceDelta $x.D } else { '–' }); $r.Note = $x.Note; $r.Sti = [string]$x.F.Path
    $r
  }
  $ui.GridSpace.ItemsSource = @($grid); $ui.GridSpace.Visibility = $(if (@($grid).Count) { 'Visible' } else { 'Collapsed' })
  # Opsummering for systemdrevet
  $sys = $env:SystemDrive
  $cd = @($cur.Drives | Where-Object { $_.Name -eq $sys })[0]
  $txt = @()
  if ($prev -and $cd) {
    $pd = @($prev.Drives | Where-Object { $_.Name -eq $sys })[0]
    $since = ([datetime]$prev.Date).ToString('d. MMM HH:mm')
    if ($pd) {
      $lost = [double]$pd.Free - [double]$cd.Free
      $top = @($rows | Where-Object { $_.Child -and $_.D -ge 500MB -and ([string]$_.F.Path).StartsWith($sys, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object { -[double]$_.D } | Select-Object -First 3)
      if ($lost -ge 1GB) {
        $txt += "$sys har mistet $(Fmt-GB $lost) ledig plads siden $since (nu $(Fmt-GB ([double]$cd.Free)) ledig)."
        if ($top.Count) { $txt += 'Mest i: ' + (($top | ForEach-Object { "$($_.F.Label) (+$(Fmt-GB $_.D))" }) -join ', ') + '.' }
        $expl = ($top | Measure-Object -Property D -Sum).Sum
        if ($lost - $expl -ge 3GB) { $txt += "Ca. $(Fmt-GB ($lost - $expl)) ligger andre steder, fx i programmer, Windows-opdateringer eller mapper, Opticon ikke måler." }
        $script:SpaceDeltaTxt = "$sys −$(Fmt-GB $lost) siden $(([datetime]$prev.Date).ToString('d. MMM'))"
      } elseif ($lost -le -1GB) {
        $txt += "$sys har fået $(Fmt-GB (-$lost)) mere ledig plads siden $since (nu $(Fmt-GB ([double]$cd.Free)) ledig)."
        $script:SpaceDeltaTxt = "$sys +$(Fmt-GB (-$lost)) ledig siden $(([datetime]$prev.Date).ToString('d. MMM'))"
      } else {
        $txt += "Næsten ingen ændring på $sys siden $since ($(Fmt-GB ([double]$cd.Free)) ledig)."
        $script:SpaceDeltaTxt = $null
      }
    }
  } elseif ($cd) {
    $txt += "Første måling er gemt ($(Fmt-GB ([double]$cd.Free)) ledig på $sys). Næste gang kan Opticon vise, hvor pladsen er blevet af. Her er det, der fylder mest nu:"
  }
  if ([double]$cur.RecycleBin -ge 1GB) { $txt += "Papirkurven fylder $(Fmt-GB ([double]$cur.RecycleBin)). Tøm den under Oprydning for at få pladsen tilbage." }
  if ($cur.Partial) { $txt += '(Målingen stoppede efter 2 minutter, så nogle store mapper er ikke talt helt med.)' }
  $ui.SpaceSummary.Text = $txt -join ' '
  if ($script:SpaceDeltaTxt -and $ui.SpaceSub.Text -notlike "*$($script:SpaceDeltaTxt)*") { $ui.SpaceSub.Text = "$($script:SpaceDeltaTxt) · se Filer" }
}
function Start-SpaceScan([bool]$quiet) {
  if ($script:SpaceRunning) { return }
  $script:SpaceRunning = $true; $ui.BtnSpaceScan.IsEnabled = $false
  if (-not $quiet) { $ui.SpaceSummary.Text = 'Måler... Det tager typisk 10-60 sekunder.' }
  Invoke-Bg $SpaceScanScript @{ Extra = @() } {
    param($res, $err, $c)
    $script:SpaceRunning = $false; $ui.BtnSpaceScan.IsEnabled = $true
    if ($res -is [array]) { $res = @($res | Where-Object { $_.Drives })[-1] }
    if ($err -or -not $res) { if (-not $c.Quiet) { $ui.SpaceSummary.Text = "Målingen lykkedes ikke: $err" }; Log "Pladsmåling FEJL: $err"; return }
    $h = @(Get-SpaceHist)
    # Sammenlign med den nyeste måling, der er mindst en time gammel (så to målinger lige efter hinanden ikke viser 0)
    $prev = @($h | Where-Object { ((Get-Date) - [datetime]$_.Date).TotalHours -ge 1 } | Select-Object -Last 1)[0]
    if (-not $prev -and $h.Count) { $prev = $h[0] }
    $h = @($h) + @($res); if ($h.Count -gt 15) { $h = $h[($h.Count - 15)..($h.Count - 1)] }
    try { [IO.File]::WriteAllText($SpaceHistFile, (ConvertTo-Json -InputObject @($h) -Depth 5), (New-Object Text.UTF8Encoding $false)) } catch { Log "Pladshistorik FEJL: $_" }
    Show-Space $res $prev
    Log "Pladsmåling: $(@($res.Folders).Count) mapper$(if ($script:SpaceDeltaTxt) { ' · ' + $script:SpaceDeltaTxt })"
  } @{ Quiet = $quiet }
}
$ui.BtnSpaceScan.Add_Click({ Start-SpaceScan $false })
$ui.GridSpace.Add_SelectionChanged({ $ui.BtnSpaceOpen.IsEnabled = [bool]$ui.GridSpace.SelectedItem })
$ui.BtnSpaceOpen.Add_Click({ $p = $ui.GridSpace.SelectedItem.Sti; if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe "`"$p`"" } })
$ui.GridSpace.Add_MouseDoubleClick({ $p = $ui.GridSpace.SelectedItem.Sti; if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe "`"$p`"" } })
function Load-SpaceLast {
  $h = @(Get-SpaceHist); if (-not $h.Count) { return }
  $cur = $h[-1]
  $prev = @($h | Where-Object { ([datetime]$cur.Date - [datetime]$_.Date).TotalHours -ge 1 } | Select-Object -Last 1)[0]
  try { Show-Space $cur $prev } catch { Log "Plads-visning: $_" }
}
# Mål automatisk i baggrunden ca. et minut efter start, hvis det er over 12 timer siden sidst
$spaceTimer = New-Object Windows.Threading.DispatcherTimer
$spaceTimer.Interval = [TimeSpan]::FromSeconds(60)
$spaceTimer.Add_Tick({
  $spaceTimer.Stop()
  try {
    $h = @(Get-SpaceHist)
    $old = (-not $h.Count) -or (((Get-Date) - [datetime]$h[-1].Date).TotalHours -ge 12)
    if ($old -and -not $script:GpuMeasuring -and $ui.BtnBench.IsEnabled) { Start-SpaceScan $true }
  } catch {}
})

# ---------- "Hvad betyder dine tal?" ----------
function Test-HzCap($s) {
  if (-not $s -or -not $s.Fps) { return $false }
  foreach ($hz in 60, 75, 90, 100, 120, 144, 160, 165, 170, 180, 200, 240, 280, 360) { if ([math]::Abs([double]$s.Fps - $hz) -le $hz * 0.02 -and (-not $s.P1 -or [double]$s.P1 -ge 0.85 * $hz)) { return $true } }
  return $false
}
function Get-BenchAdvice($r) {
  $out = New-Object System.Collections.ArrayList
  $add = { param($t, $why, $fix) [void]$out.Add("⚠  $t`n     Mulig årsag: $why`n     Det kan du gøre: $fix") }
  $hw = $r.Hw
  if ($hw.OnBattery) { & $add 'Testen kørte på batteri.' 'De fleste bærbare skruer ned for at spare batteri.' 'Sæt laderen i, og kør testen igen.' }
  try { $plan = (powercfg /getactivescheme 2>$null) -join ' '; if ($plan -match '(?i)strømbesparelse|power saver|energisparer') { & $add "Windows' strømplan står på strømbesparelse." 'Strømbesparelse holder processoren nede.' "Kontrolpanel → Strømstyring → vælg 'Balanceret' (eller 'Høj ydelse')." } } catch {}
  try { $pm = Get-PowerMode; if ($pm -eq '961cc777-2547-4f9d-8174-7d86181b8a7a') { & $add "Windows' strømtilstand står på 'Bedste energieffektivitet'." 'Den sparer strøm på bekostning af ydelse.' "Indstillinger → System → Strøm og batteri → Strømtilstand → 'Balanceret' eller 'Bedste ydeevne'." } } catch {}
  if ($r.Sustain -and $r.Sustain -lt 88) { & $add "Processoren taber $([math]::Round(100 - $r.Sustain)) % fart, når den bliver varm." 'For varm: støv, en træt køler, tør kølepasta eller blokeret luft (fx en bærbar på en dyne).' "Rens støv af køler og blæsere, giv luft omkring pc'en, og vælg 'Bedste ydeevne'. Hjælper det ikke, så kig på køleren eller kølepastaen." }
  if ($r.Cpu1 -and $r.CpuN -and $hw.Cores) {
    $ratio = [double]$r.CpuN / [double]$r.Cpu1; $exp = [double]$hw.Cores * 0.55
    if ($ratio -lt $exp) { & $add "Alle kerner tilsammen yder kun $([math]::Round($ratio, 1))× én kerne (forventet mindst $([math]::Round($exp, 1))× med $($hw.Cores) kerner)." "Noget i baggrunden bruger processoren, eller den får for lidt strøm (meget almindeligt på bærbare i stille tilstand)." "Luk tunge programmer, og vælg 'Bedste ydeevne'. På en bærbar: vælg også ydelsestilstand i producentens program (fx Lenovo Vantage eller G-Helper)." }
  }
  try {
    $mods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
    $rated = ($mods | ForEach-Object { Get-RamRated ([string]$_.PartNumber) } | Where-Object { $_ } | Measure-Object -Maximum).Maximum
    if ($rated -and $hw.RamMHz -and $rated -gt [double]$hw.RamMHz * 1.12) { & $add "Hukommelsen kører $($hw.RamMHz) MHz, men er lavet til $rated MHz." 'XMP (Intel) eller EXPO (AMD) er ikke slået til i BIOS.' "Gå i BIOS (tryk Del eller F2 ved opstart), og slå XMP/EXPO til. Det giver ofte mærkbart flere FPS i CPU-tunge spil." }
  } catch {}
  try {
    $free = (Get-PSDrive ($env:SystemDrive.Substring(0, 1))); $pct = 100 * $free.Free / ($free.Free + $free.Used)
    if ($pct -lt 10) { & $add "Systemdisken er næsten fuld ($([math]::Round($pct)) % ledig)." 'En fuld SSD bliver langsommere, og Windows mangler plads til opdateringer.' "Brug 'Oprydning' og 'Filer' i Opticon, og flyt store filer væk." }
  } catch {}
  if ($r.DiskR -and $hw.Disk -match '(?i)nvme|\b9[789]0\b|sn[5-8]\d0|kc3000|mp600|p[35]\b|firecuda 5|990|980|970' -and $r.DiskR -lt 1200) { & $add "Din NVMe-disk læser kun $($r.DiskR) MB/s." 'Den sidder måske i en langsommere M.2-plads, er meget fuld, eller bliver for varm.' "Tjek i bundkortets manual, at disken sidder i en M.2-plads med fuld PCIe-hastighed, og frigør plads." }
  elseif ($r.DiskR -and $r.DiskR -lt 250 -and $r.Iops -and $r.Iops -lt 400) { & $add "Windows ligger på en langsom disk ($($r.DiskR) MB/s, $($r.Iops) små læsninger/sek)." 'Det ligner en mekanisk harddisk.' "Et skift til en SSD er den opgradering, du mærker mest i hverdagen." }
  if ($r.Gpu -and $r.GpuRenderer -and $hw.Gpu -match '(?i)nvidia|radeon rx|radeon pro|arc a|arc b') {
    $vend = if ($hw.Gpu -match '(?i)nvidia') { 'nvidia' } elseif ($hw.Gpu -match '(?i)arc') { 'arc' } else { 'radeon' }
    if ([string]$r.GpuRenderer -notmatch "(?i)$vend") { & $add "Grafiktesten kørte på $($r.GpuRenderer) og ikke på dit $($hw.Gpu)." 'Windows valgte den indbyggede grafik til browseren.' "Indstillinger → System → Skærm → Grafik → vælg Microsoft Edge (og dine spil) → 'Høj ydeevne'." }
  }
  try { if (Test-BgRecording) { [void]$out.Add("ℹ  Optagelse i baggrunden (Game Bar) er slået til. Den optager hele tiden, mens du spiller, og kan give små hak. Slå den fra under Ydelse og helbred, hvis du ikke bruger den.") } } catch {}
  if ($r.Gpu -and [int]$r.GpuV -ne $BenchGpuV -and (Test-HzCap ([pscustomobject]@{ Fps = $r.Gpu; P1 = $r.GpuLow }))) { [void]$out.Add("ℹ  Grafikken lå lige på $($r.Gpu) fps, som er en almindelig skærmfrekvens. Tallet kan være begrænset af skærmen og ikke af grafikkortet.") }
  if ((Get-Smi) -and (Test-Path $GpuPlFile)) { try { $g = Get-Content $GpuPlFile -Raw | ConvertFrom-Json; [void]$out.Add("ℹ  Du har valgt en lavere strømgrænse til grafikkortet ($($g.Pct) %, $($g.Watts) W). Det sparer strøm, men kan koste lidt FPS. Nulstil den under Optimering, hvis du vil se kortets fulde ydelse.") } catch {} }
  return @($out)
}
function Show-BenchAdvice($r) {
  $a = @(Get-BenchAdvice $r)
  $ui.BenchAdvice.Text = if ($a.Count) { $a -join "`n`n" } else { "✓  Ingen tegn på, at noget holder din pc tilbage. Processor, hukommelse, disk og grafik opfører sig, som de skal ud fra det, Opticon kan se." }
  $ui.BenchAdviceBox.Visibility = 'Visible'
}
function Show-Bench($r) {
  $hw = $r.Hw
  $ui.BenchScore.Text = $(if ($r.Score) { [string]$r.Score } else { 'Delvis' })
  $ui.BenchScoreSub.Text = $(if ($r.Score) { "Testet $(([datetime]$r.Date).ToString('dd-MM HH:mm')). 1000 er et fast pejlemærke. Højere er bedre." } else { "Testet $(([datetime]$r.Date).ToString('dd-MM HH:mm')). Ikke alle dele blev målt, så der er ingen samlet score. Delresultaterne nedenfor gælder stadig." })
  $ui.BenchHw.Text = "$($hw.Cpu) ($($hw.Cores) kerner / $($hw.Threads) tråde) · $($hw.Gpu) · $($hw.RamGB) GB RAM$(if ($hw.RamMHz) { " ($($hw.RamMHz) MHz)" }) · $($hw.Disk) · $(if ($hw.Laptop) { 'bærbar' } else { 'stationær' })$(if ($hw.OnBattery) { ' · ⚠ testet på batteri' })"
  $ui.BCpu1.Text = [string]$r.Cpu1; $ui.BCpu1Sub.Text = 'point · vigtigt for spil og hvor kvik pc''en føles'
  $ui.BCpuN.Text = [string]$r.CpuN; $ui.BCpuNSub.Text = "point · vigtigt for fx video og udpakning"
  $ui.BSus.Text = "$($r.Sustain) %"
  $ui.BSusSub.Text = $(if ($r.Sustain -ge 95) { 'Holder farten fint, når den bliver varm' } elseif ($r.Sustain -ge 85) { 'Taber lidt fart, når den bliver varm' } else { 'Taber mærkbart fart, når den bliver varm. Tjek køling og støv.' })
  $ui.BRam.Text = "$($r.Ram) GB/s"; $ui.BRamSub.Text = 'kopierer data i hukommelsen'
  $ui.BDisk.Text = "$($r.DiskR) MB/s"; $ui.BDiskSub.Text = "læs · skriv $($r.DiskW) MB/s · $($r.Iops) små læsninger/sek"
  $sameGpuV = ([int]$r.GpuV -eq $BenchGpuV)
  if ($r.GpuNative) {
    $ui.BGpuTitle.Text = "GRAFIK · TESTSCENE PÅ DIN SKÆRM ($(([string]$r.GpuNativeRes) -replace 'x', '×'))"
    $ui.BGpu.Text = "$($r.GpuNative) fps"
    $ui.BGpuSub.Text = "1080p til sammenligning: $($r.Gpu) fps$(if ($r.Gpu4K -and $r.GpuNativeRes -ne '3840x2160') { " · 4K: $($r.Gpu4K) fps" }) · renderhastighed i Opticons testscene uden V-Sync (ikke et bestemt spil)"
  } else {
    $ui.BGpuTitle.Text = 'GRAFIK · TESTSCENE (1080p)'
    $ui.BGpu.Text = $(if ($r.Gpu) { "$($r.Gpu) fps" } else { '–' })
    $ui.BGpuSub.Text = $(if ($r.Gpu -and $sameGpuV) { "laveste sekund: $(if ($r.GpuLow) { "$($r.GpuLow) fps" } else { '–' })$(if ($r.Gpu4K) { " · 4K: $($r.Gpu4K) fps" }) · renderhastighed i Opticons testscene uden V-Sync" } elseif ($r.Gpu) { 'målt med den gamle metode (låst til skærmens Hz)' } else { 'grafikdelen blev ikke målt' })
  }
  $ui.BtnBenchShare.IsEnabled = [bool]$r.Score
  try { Show-BenchAdvice $r } catch { Log "Råd-fejl: $_" }
  # Forskel i forhold til testen før denne (så du kan se, om en ændring i Optimering hjalp)
  $h = @(Get-BenchHist); $idx = -1
  for ($i = $h.Count - 1; $i -ge 0; $i--) { if ([string]$h[$i].Date -eq [string]$r.Date) { $idx = $i; break } }
  $prev = if ($idx -gt 0) { $h[$idx - 1] } else { $null }
  if ($prev) {
    $dl = { param($now, $was) if (-not $now -or -not $was -or [double]$was -le 0) { return '' }; $d = 100 * ([double]$now - [double]$was) / [double]$was; if ([math]::Abs($d) -lt 1.5) { return "  ·  ≈ som sidst" }; "  ·  $(if ($d -gt 0) { '▲' } else { '▼' }) $('{0:+0;-0}' -f $d) % siden sidst" }
    $ui.BCpu1Sub.Text += (& $dl $r.Cpu1 $prev.Cpu1); $ui.BCpuNSub.Text += (& $dl $r.CpuN $prev.CpuN)
    $ui.BRamSub.Text += (& $dl $r.Ram $prev.Ram); $ui.BDiskSub.Text += (& $dl $r.DiskR $prev.DiskR)
    $gpuSame = ($prev.V -eq $r.V -and [int]$prev.GpuV -eq [int]$r.GpuV)   # grafik blev målt anderledes før 2.45
    if ($gpuSame) { $ui.BGpuSub.Text += (& $dl $(if ($r.GpuNative -and $prev.GpuNative -and $prev.GpuNativeRes -eq $r.GpuNativeRes) { $r.GpuNative } else { $r.Gpu }) $(if ($r.GpuNative -and $prev.GpuNative -and $prev.GpuNativeRes -eq $r.GpuNativeRes) { $prev.GpuNative } else { $prev.Gpu })) }
    if ($r.Score -and $prev.Score -and $gpuSame) { $ui.BenchScoreSub.Text = "Testet $(([datetime]$r.Date).ToString('dd-MM HH:mm')).$((& $dl $r.Score $prev.Score) -replace '^  ·  ', ' ') Sidste test: $($prev.Score) point ($(([datetime]$prev.Date).ToString('dd-MM HH:mm')))." }
  }
}
function Start-Bench {
  if ($script:GpuMeasuring) { Msg 'En anden GPU-test kører allerede.' 'Benchmark' | Out-Null; return }
  if (-not (Confirm-ModeFree 'Den store test')) { return }
  $batt = $null; try { $batt = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1 } catch {}
  $bTxt = if ($batt -and -not $batt.PowerOnline) { "`n`n🔌 Sæt laderen i først. På batteri kører de fleste bærbare langsommere, og så kan tallene ikke sammenlignes med andre." } else { '' }
  if ((Msg "Den store test tager ca. 4 minutter:`n`n•  Processor: én kerne, alle kerner og om den holder farten, når den bliver varm (1 min. fuld belastning)`n•  Hukommelse og disk (en testfil på 512 MB, som slettes bagefter)`n•  Grafik: testscenen i fuld skærm til sidst, i 1080p, din skærms opløsning og 4K`n`nLuk spil og tunge programmer, og rør ikke pc'en imens. Blæserne kan godt larme lidt.$bTxt`n`nStart?" 'Den store test' 'YesNo' 'Question') -ne 'Yes') { return }
  $script:BenchStart = Get-Date
  $ui.BtnBench.IsEnabled = $false; $ui.BenchBar.Visibility = 'Visible'; $ui.BenchBar.Value = 0; $ui.BenchStatus.Text = 'Starter...'
  Log 'Benchmark startet'
  try { Import-OpticonType 'OptiBench.Cpu' $BenchCs } catch { Log "Benchmark-type: $_" }
  Invoke-Bg $BenchScript @{ Code = $BenchCs } {
    param($res, $err, $c)
    if ($res -is [array]) { $res = @($res | Where-Object { $_ -is [Collections.IDictionary] })[-1] }
    if ($err -or -not $res) { $ui.BtnBench.IsEnabled = $true; $ui.BenchBar.Visibility = 'Collapsed'; $ui.BenchStatus.Text = "⚠ Testen fejlede: $err"; Log "Benchmark fejl: $err"; return }
    $script:BenchPart = $res
    $ui.BenchStatus.Text = 'Grafik · testscenen åbner i fuld skærm om et øjeblik...'
    Start-GpuBench 'bench'
  } @{ Bench = $true }
  $benchTimer.Start()
}
$benchTimer = New-Object Windows.Threading.DispatcherTimer
$benchTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$benchTimer.Add_Tick({
  $j = $script:Jobs | Where-Object { $_.Ctx -is [hashtable] -and $_.Ctx.Bench } | Select-Object -First 1
  if (-not $j) { if (-not $script:GpuMeasuring) { $benchTimer.Stop() }; return }
  $p = [double]$j.S.Progress
  if ($p -ge 0) { $ui.BenchBar.Value = $p * 0.75 }
  if ($j.S.Status) { $ui.BenchStatus.Text = "$($j.S.Status)$(Bench-Remain ([math]::Max(0, $p) * 0.75))" }
})
# Skærmens egen opløsning (det, spil typisk kører i): den største aktive skærm
function Get-NativeRes {
  try {
    $v = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Sort-Object { [int64]$_.CurrentHorizontalResolution * $_.CurrentVerticalResolution } -Descending)[0]
    if ($v) { return "$($v.CurrentHorizontalResolution)x$($v.CurrentVerticalResolution)" }
  } catch {}
  return $null
}
function Finish-Bench($gpuStep, $gpuErr, $nativeStep) {
  $b = $script:BenchPart
  $ui.BtnBench.IsEnabled = $true; $ui.BenchBar.Visibility = 'Collapsed'
  try { $win.Activate() | Out-Null } catch {}
  if (-not $b) { return }
  $r = [ordered]@{ V = $BenchTestVersion; Date = (Get-Date).ToString('s'); App = $AppVersion; Hw = $b.Hw
                   Cpu1 = $b.Cpu1; CpuN = $b.CpuN; Sustain = $b.Sustain; Ram = $b.Ram; DiskR = $b.DiskR; DiskW = $b.DiskW; Iops = $b.Iops
                   GpuRenderer = $script:LastGpuRenderer
                   Gpu = $(if ($gpuStep -and $gpuStep.Fps) { [math]::Round([double]$gpuStep.Fps) } else { $null }); GpuLow = $(if ($gpuStep -and $gpuStep.FpsMin) { [math]::Round([double]$gpuStep.FpsMin) } else { $null }); GpuV = $BenchGpuV
                   GpuNative = $(if ($nativeStep -and $nativeStep.Fps) { [math]::Round([double]$nativeStep.Fps) } else { $null }); GpuNativeRes = $(if ($nativeStep -and $nativeStep.Fps) { [string]$nativeStep.Res } else { $null })
                   Gpu4K = $(if ($script:Bench4k -and $script:Bench4k.Fps) { [math]::Round([double]$script:Bench4k.Fps) } else { $null }); Score = 0 }
  $r.Score = Bench-Total $r
  $h = @(Get-BenchHist) + @([pscustomobject]$r)
  try { [IO.File]::WriteAllText($BenchHistFile, (ConvertTo-Json -InputObject @($h | Select-Object -Last 50) -Depth 5), (New-Object Text.UTF8Encoding $false)) } catch {}
  $script:BenchLast = ([pscustomobject]$r)
  Show-Bench $script:BenchLast; Show-BenchHist
  if (-not $r.Gpu -and $gpuErr) { $ui.BGpuSub.Text = "ikke målt: $gpuErr" }
  $prev = if ($h.Count -ge 2) { $h[-2] } else { $null }
  $ui.BenchStatus.Text = "$(if ($r.Score) { "✓ Færdig: $($r.Score) point" } else { '⚠ Delvis test: ikke alle dele blev målt' })$(if ($r.Score -and $prev -and $prev.Score -and $prev.V -eq $r.V -and [int]$prev.GpuV -eq [int]$r.GpuV) { " (sidst: $($prev.Score), $('{0:+0;-0;0}' -f (100 * ($r.Score - $prev.Score) / [math]::Max(1, $prev.Score))) %)" })$(if ($gpuErr) { " · grafikdelen fejlede: $gpuErr" })"
  try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
  try { Complete-BenchChange $r } catch { Log "Hjalp det-fejl: $_" }
  Log "Benchmark: $(if ($r.Score) { "$($r.Score) point" } else { 'delvis test' })"
  Load-BenchCompare
}
function Load-BenchCompare {
  $ri = Get-RepoInfo; $me = $script:BenchLast
  if (-not $ri -or -not $me) { return }
  $ui.BenchCmpText.Text = 'Henter resultater fra andre...'
  Invoke-Bg { param($sync, $arg) [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; try { return @(Invoke-RestMethod -Uri ("{0}?t={1}" -f $arg.Url, [DateTime]::UtcNow.Ticks) -UseBasicParsing -TimeoutSec 15) } catch { if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return @() }; throw } } @{ Url = $ri.Results } {
    param($res, $err, $c)
    $me = $script:BenchLast
    $all = @($res | ForEach-Object { $_ } | Where-Object { $_ -and $_.v -eq $BenchTestVersion -and -not $_.battery })
    $myCpu = Norm-Hw $me.Hw.Cpu; $myGpu = Norm-Hw $me.Hw.Gpu; $myLap = [bool]$me.Hw.Laptop
    $sameCpu = @($all | Where-Object { (Norm-Hw $_.cpu) -eq $myCpu -and [bool]$_.laptop -eq $myLap })
    $sameGpu = @($all | Where-Object { (Norm-Hw $_.gpu) -eq $myGpu -and [bool]$_.laptop -eq $myLap -and $(try { [version]([string]$_.app) -ge [version]'2.45' } catch { $false }) })
    $med = { param($list, $prop) $x = @($list | ForEach-Object { $_.scores.$prop } | Where-Object { $_ -and [double]$_ -gt 0 } | ForEach-Object { [double]$_ } | Sort-Object); if (-not $x.Count) { return $null }; if ($x.Count % 2) { $x[[int][math]::Floor($x.Count / 2)] } else { ($x[$x.Count / 2 - 1] + $x[$x.Count / 2]) / 2 } }
    $kind = if ($myLap) { 'bærbare' } else { 'stationære' }
    $defs = @(
      @{ N = 'CPU · én kerne'; Mine = $me.Cpu1; P = 'cpu1'; L = $sameCpu; W = "$kind med $($me.Hw.Cpu)"; U = '' }
      @{ N = 'CPU · alle kerner'; Mine = $me.CpuN; P = 'cpuN'; L = $sameCpu; W = "$kind med $($me.Hw.Cpu)"; U = '' }
      @{ N = 'Holder farten'; Mine = $me.Sustain; P = 'sustain'; L = $sameCpu; W = "$kind med $($me.Hw.Cpu)"; U = ' %' }
      @{ N = 'Hukommelse'; Mine = $me.Ram; P = 'ram'; L = $sameCpu; W = "$kind med $($me.Hw.Cpu)"; U = ' GB/s' }
      @{ N = 'Grafik (1080p)'; Mine = $me.Gpu; P = 'gpu'; L = $sameGpu; W = "$kind med $($me.Hw.Gpu)"; U = ' fps' }
    )
    $rows = @(); $cpuDiff = $null; $gpuDiff = $null
    foreach ($d in $defs) {
      $m = & $med $d.L $d.P
      if ($null -eq $m -or -not $d.Mine) { continue }
      $diff = 100 * ([double]$d.Mine - $m) / [math]::Max(0.001, $m)
      if ($d.P -eq 'cpuN') { $cpuDiff = $diff }; if ($d.P -eq 'gpu') { $gpuDiff = $diff }
      $r = New-Object PcTjek.Row; $r.Navn = $d.N; $r.Info = "$($d.Mine)$($d.U)"; $r.Note = "$([math]::Round($m, 1))$($d.U)"
      $cnt = @($d.L | Where-Object { $_.scores.($d.P) }).Count
      $r.Status = "$('{0:+0;-0;0}' -f $diff) %$(if ($diff -le -10) { ' ⚠' } elseif ($diff -ge 5) { ' 👍' })"; $r.Gruppe = "$(if ($cnt -eq 1) { 'Ét delt resultat' } else { "$cnt delte resultater" }) · $($d.W)"
      $rows += $r
    }
    $ui.GridBenchCmp.ItemsSource = $rows; $ui.GridBenchCmp.Visibility = $(if ($rows.Count) { 'Visible' } else { 'Collapsed' })
    $txt = @()
    if ($err) { $txt += "Kunne ikke hente andres resultater lige nu." }
    elseif (-not $rows.Count) { $txt += "Ingen har delt resultater med din processor eller dit grafikkort endnu (Opticon har $($all.Count) resultater i alt). Del dit, så er du den første. Indtil da kan du se, hvad tusindvis af andre med samme hardware får i Geekbench." }
    else {
      if ($null -ne $cpuDiff) { $txt += $(if ($cpuDiff -le -10) { "⚠ Din processor er $([math]::Round(-$cpuDiff)) % langsommere end andre med samme model. Tjek strømtilstand, køling og baggrundsprogrammer." } elseif ($cpuDiff -ge 5) { "👍 Din processor er $([math]::Round($cpuDiff)) % hurtigere end medianen for samme model." } else { "✓ Din processor yder som forventet for modellen." }) }
      if ($null -ne $gpuDiff) { $txt += $(if ($gpuDiff -le -10) { "⚠ Dit grafikkort er $([math]::Round(-$gpuDiff)) % langsommere end andre med samme kort. Tjek driver, strømtilstand og temperatur." } elseif ($gpuDiff -ge 5) { "👍 Dit grafikkort er $([math]::Round($gpuDiff)) % hurtigere end medianen for samme kort." } else { "✓ Dit grafikkort yder som forventet for modellen." }) }
      $txt += "Kun resultater fra samme testversion og samme type pc ($kind, tilsluttet strøm) tæller med."
    }
    $ui.BenchCmpText.Text = $txt -join "`n"
  } $null
}
$ui.BtnBench.Add_Click({ Start-Bench })
$ui.BtnBenchGb.Add_Click({
  $me = $script:BenchLast
  $cpu = if ($me) { [string]$me.Hw.Cpu } else { ((Get-CimInstance Win32_Processor | Select-Object -First 1).Name -replace '\((R|TM)\)', '' -replace '\s+CPU\s*@.*$', '').Trim() }
  if ((Msg "Geekbench Browser har millioner af resultater. Søg på din processor ($cpu), og se, hvad andre med samme model typisk får.`n`nBemærk: Geekbench er en anden test end Opticons, så tallene kan ikke sammenlignes direkte med dine Opticon-tal. Vil du sammenligne direkte, kan du selv køre den gratis Geekbench og se din plads blandt de andre.`n`nÅbn Geekbench Browser?" 'Andre i Geekbench' 'YesNo' 'Information') -eq 'Yes') {
    Start-Process ('https://browser.geekbench.com/search?q=' + [Uri]::EscapeDataString($cpu))
  }
})
$ui.BtnBenchShare.Add_Click({
  $me = $script:BenchLast; $ri = Get-RepoInfo
  if (-not $me -or -not $ri) { return }
  if (-not $me.Score) { Msg 'Kun fulde tests kan deles. Kør testen igen, så alle dele bliver målt.' 'Del resultat' | Out-Null; return }
  if ($me.Hw.OnBattery) { Msg "Dette resultat er målt på batteri og kan ikke sammenlignes retfærdigt. Sæt laderen i, kør testen igen, og del det." 'Del resultat' 'OK' 'Warning' | Out-Null; return }
  $a = Msg "Dit resultat deles offentligt i Opticons GitHub-projekt, så andre med samme hardware kan sammenligne.`n`nDet indeholder kun: processor, grafikkort, RAM, diskmodel, bærbar/stationær og testtallene. Ingen navne, filer eller andet.`n`nGitHub åbner med et færdigt opslag. Du skal være logget ind og trykke 'Create' / 'Submit new issue'. Opslaget vises under din GitHub-konto. Resultatet kommer med i Opticon få minutter efter.`n`nFortsæt?" 'Del mit resultat' 'YesNo' 'Question'
  if ($a -ne 'Yes') { return }
  $data = [ordered]@{ v = $BenchTestVersion; app = $AppVersion; cpu = $me.Hw.Cpu; gpu = $me.Hw.Gpu; cores = $me.Hw.Cores; threads = $me.Hw.Threads; ramGB = $me.Hw.RamGB; ramMHz = $me.Hw.RamMHz; disk = $me.Hw.Disk; laptop = [bool]$me.Hw.Laptop; battery = [bool]$me.Hw.OnBattery; power = $(try { PowerMode-Name (Get-PowerMode) } catch { '' })
                      scores = [ordered]@{ cpu1 = $me.Cpu1; cpuN = $me.CpuN; sustain = $me.Sustain; ram = $me.Ram; diskR = $me.DiskR; diskW = $me.DiskW; iops = $me.Iops; gpu = $me.Gpu; total = $me.Score } }
  $json = $data | ConvertTo-Json -Depth 4 -Compress
  $title = "[Opticon-resultat] $($me.Hw.Cpu) / $($me.Hw.Gpu)"
  $body = "Opticon-resultat. Det bliver tilføjet automatisk, og opslaget lukkes af sig selv.`n`n" + '```json' + "`n$json`n" + '```'
  Start-Process ("https://github.com/$($ri.Owner)/$($ri.Repo)/issues/new?title=" + [Uri]::EscapeDataString($title) + '&body=' + [Uri]::EscapeDataString($body))
  Log 'Benchmark-resultat sendt til deling'
})


# =====================================================================
#  HJALP DET?  -  én historik over ændringer med måling før og efter
# =====================================================================
$ChangesFile = Join-Path $OutDir 'hjalp-det.json'
function Get-Changes { if (Test-Path $ChangesFile) { try { return @(Get-Content $ChangesFile -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) } catch {} }; return @() }
function Save-Changes($list) { try { [IO.File]::WriteAllText($ChangesFile, (ConvertTo-Json -InputObject @($list | Select-Object -Last 200) -Depth 6), (New-Object Text.UTF8Encoding $false)) } catch {} }
function Add-Change($kind, $title, $before, $after, $status, $result, $good) {
  $e = [pscustomobject]@{ Id = [guid]::NewGuid().ToString('N').Substring(0, 8); Date = (Get-Date).ToString('s'); Kind = $kind; Title = $title
                          Before = $before; After = $after; Status = $status; Result = $result; Good = $good }
  Save-Changes (@(Get-Changes) + @($e))
  Log "Hjalp det? ${kind}: $title · $status $result"
  if ($ui.PageHelped.Visibility -eq 'Visible') { Show-Changes }
  return $e
}
function Get-Boots {
  $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 40 -ErrorAction SilentlyContinue)
  @($ev | ForEach-Object {
    $ms = (([xml]$_.ToXml()).Event.EventData.Data | Where-Object Name -eq 'BootTime').'#text'
    if ($ms) { [pscustomobject]@{ Time = $_.TimeCreated; Sek = [int][math]::Round([double]$ms / 1000) } }
  } | Sort-Object Time)
}
# Opstart: samler ændringer, der laves tæt efter hinanden, i én post
function Note-CleanResult($freeBefore) {
  if ($null -eq $freeBefore) { return }
  $after = (Get-PSDrive ($env:SystemDrive.Substring(0, 1))).Free
  $gb = ($after - $freeBefore) / 1GB
  [void](Add-Change 'oprydning' 'Oprydning af midlertidige filer' ([pscustomobject]@{ FreeGB = $freeBefore / 1GB }) ([pscustomobject]@{ FreeGB = $after / 1GB }) 'færdig' $(if ($gb -ge 0.05) { "✅ Ja: $([math]::Round($gb, 2)) GB mere ledig plads på $env:SystemDrive (målt)" } else { "➖ Næsten ingen forskel i ledig plads ($([math]::Round($gb, 2)) GB)" }) ($gb -ge 0.05))
}
function Note-GpuChange($title, $from, $to) {
  if (-not $from -or -not $to) { return }
  $bits = @()
  if ($null -ne $from.W -and $null -ne $to.W -and $from.W) { $bits += "$([math]::Round(100 * ($to.W - $from.W) / $from.W)) % strøm ($([math]::Round($from.W)) → $([math]::Round($to.W)) W)" }
  if ($from.Fps) { $bits += "FPS $('{0:+0;-0;0}' -f (100 * ($to.Fps - $from.Fps) / $from.Fps)) %" }
  if ($null -ne $from.T -and $null -ne $to.T) { $bits += "$([math]::Round($to.T - $from.T)) °C" }
  $good = ($null -ne $from.W -and $null -ne $to.W -and $to.W -lt $from.W * 0.95 -and $to.Fps -ge $from.Fps * 0.97)
  [void](Add-Change 'gpu' $title ([pscustomobject]@{ W = $from.W; Fps = $from.Fps; T = $from.T }) ([pscustomobject]@{ W = $to.W; Fps = $to.Fps; T = $to.T }) 'færdig' "$(if ($good) { '✅ Ja: ' } else { '➖ ' })$($bits -join ' · ') (målt i samme testscene)" $good)
}
function Note-StartupChange($what) {
  $list = @(Get-Changes)
  $last = $list | Where-Object { $_.Kind -eq 'opstart' -and $_.Status -eq 'venter' } | Select-Object -Last 1
  $boots = @(Get-Boots)
  if ($last -and ((Get-Date) - [datetime]$last.Date).TotalHours -lt 6 -and -not @($boots | Where-Object { $_.Time -gt [datetime]$last.Date }).Count) {
    $last.Title = "Opstart: $what"
    if ($last.Title.Length -gt 120) { $last.Title = $last.Title.Substring(0, 117) + '...' }
    Save-Changes $list; return
  }
  $b = Get-Median @($boots | Select-Object -Last 5 | ForEach-Object { $_.Sek })
  [void](Add-Change 'opstart' "Opstart: $what" ([pscustomobject]@{ Sek = $b; N = [math]::Min(5, $boots.Count) }) $null 'venter' "Venter på de næste opstarter (genstart pc'en)" $null)
}
# Udfylder ventende målinger (fx opstarter, der er sket siden)
function Update-Changes {
  $list = @(Get-Changes); $changed = $false; $news = @()
  $boots = $null
  foreach ($e in $list) {
    if ($e.Status -ne 'venter' -or $e.Kind -ne 'opstart') { continue }
    if ($null -eq $boots) { $boots = @(Get-Boots) }
    $after = @($boots | Where-Object { $_.Time -gt [datetime]$e.Date } | ForEach-Object { $_.Sek })
    if (-not $e.Before -or -not $e.Before.Sek) {
      $bb = @($boots | Where-Object { $_.Time -le [datetime]$e.Date } | Select-Object -Last 5 | ForEach-Object { $_.Sek })
      if ($bb.Count) { $e.Before = [pscustomobject]@{ Sek = (Get-Median $bb); N = $bb.Count } }
    }
    if ($after.Count -ge 2 -and $e.Before -and $e.Before.Sek) {
      $a = Get-Median $after; $diff = [int]$e.Before.Sek - [int]$a
      $e.After = [pscustomobject]@{ Sek = $a; N = $after.Count }
      $e.Status = 'færdig'
      $e.Result = if ($diff -ge 3) { "✅ Ja: opstarten er $diff sek hurtigere ($($e.Before.Sek) → $a sek)" } elseif ($diff -le -3) { "⚠ Nej: opstarten er $([math]::Abs($diff)) sek langsommere ($($e.Before.Sek) → $a sek)" } else { "➖ Ingen tydelig forskel ($($e.Before.Sek) → $a sek)" }
      $e.Good = ($diff -ge 3)
      $changed = $true; $news += $e
    } elseif ($after.Count -eq 1) { $e.Result = "1 af 2 opstarter målt. Genstart én gang til." ; $changed = $true }
  }
  if ($changed) { Save-Changes $list }
  if ($news.Count) { $ui.StatusText.Text = "Hjalp det? $($news[-1].Result -replace '^\S+\s', '')"; Log "Hjalp det? opstart målt: $($news[-1].Result)" }
}
function Show-Changes {
  $list = @(Get-Changes)
  [array]::Reverse($list)
  $rows = @(foreach ($e in $list) {
    $r = New-Object PcTjek.Row
    $r.Navn = ([datetime]$e.Date).ToString('dd-MM HH:mm')
    $r.Info = [string]$e.Title
    $fmt = { param($x, $k) if (-not $x) { return '–' }
      switch ($k) {
        'opstart'   { "$($x.Sek) sek$(if ($x.N) { " (median af $($x.N))" })" }
        'oprydning' { "$([math]::Round([double]$x.FreeGB, 1)) GB fri" }
        'gpu'       { "$(if ($null -ne $x.W) { "$([math]::Round([double]$x.W)) W · " })$([math]::Round([double]$x.Fps)) fps$(if ($null -ne $x.T) { " · $([math]::Round([double]$x.T)) °C" })" }
        'benchmark' { "$(if ($x.Score) { "$($x.Score) point" } else { 'delvis' })" }
        'spil'      { "$([math]::Round([double]$x.Fps)) fps · 1 % low $([math]::Round([double]$x.Low1))$(if ($null -ne $x.W) { " · $([math]::Round([double]$x.W)) W" })" }
        default     { [string]$x }
      } }
    $r.Note = & $fmt $e.Before $e.Kind
    $r.Gruppe = $(if ($e.Status -eq 'venter') { '⏳ venter' } else { & $fmt $e.After $e.Kind })
    $r.Status = [string]$e.Result
    $r })
  $ui.GridHelped.ItemsSource = $rows
  $done = @($list | Where-Object { $_.Status -eq 'færdig' }); $wait = @($list | Where-Object { $_.Status -eq 'venter' })
  $good = @($done | Where-Object { $_.Good -eq $true }).Count
  $ui.HelpedSummary.Text = if (-not $list.Count) { 'Ingen ændringer registreret endnu.' } else { "$($list.Count) ændring$(if ($list.Count -ne 1) { 'er' }) · $good hjalp tydeligt · $($wait.Count) venter på måling" }
}
$ui.BtnHelpedBench.Add_Click({
  $h = @(Get-BenchHist | Where-Object { $_.Score -and $_.V -eq $BenchTestVersion })
  if (-not $h.Count) { Msg "Opticon skal bruge en måling FØR ændringen. Kør den store test først (side Benchmark), lav så din ændring, og tryk på knappen her bagefter." 'Hjalp det?' | Out-Null; $ui.NavBench.IsChecked = $true; return }
  $what = [Microsoft.VisualBasic.Interaction]::InputBox("Hvad ændrede du? (fx 'Undervolt i Afterburner', 'XMP slået til i BIOS', 'Ny driver')`n`nOpticon kører den store test igen og sammenligner med din seneste test fra $(([datetime]$h[-1].Date).ToString('dd-MM HH:mm')).", 'Hjalp det?', '')
  if (-not $what.Trim()) { return }
  $b = $h[-1]
  $script:PendingBenchChange = Add-Change 'benchmark' $what.Trim() ([pscustomobject]@{ Score = $b.Score; Cpu1 = $b.Cpu1; CpuN = $b.CpuN; Ram = $b.Ram; DiskR = $b.DiskR; Gpu = $b.Gpu; Date = $b.Date }) $null 'venter' 'Kører den store test...' $null
  $ui.NavBench.IsChecked = $true
  Start-Bench
})
# Kaldes, når en stor test er færdig: udfyld en ventende "Hjalp det?"-post
function Complete-BenchChange($r) {
  $list = @(Get-Changes)
  $e = $list | Where-Object { $_.Kind -eq 'benchmark' -and $_.Status -eq 'venter' } | Select-Object -Last 1
  if (-not $e) { return }
  if (-not $r.Score) { $e.Result = 'Testen blev ikke fuldført. Tryk på knappen igen.'; Save-Changes $list; return }
  $b = $e.Before
  $e.After = [pscustomobject]@{ Score = $r.Score; Cpu1 = $r.Cpu1; CpuN = $r.CpuN; Ram = $r.Ram; DiskR = $r.DiskR; Gpu = $r.Gpu; Date = $r.Date }
  $pc = { param($a, $bb) if (-not $a -or -not $bb -or [double]$bb -le 0) { return $null }; 100 * ([double]$a - [double]$bb) / [double]$bb }
  $parts = @()
  foreach ($p in @(@('Cpu1', 'CPU 1 kerne'), @('CpuN', 'CPU alle'), @('Ram', 'RAM'), @('DiskR', 'disk'), @('Gpu', 'grafik'))) {
    $d = & $pc $r.($p[0]) $b.($p[0]); if ($null -ne $d -and [math]::Abs($d) -ge 2) { $parts += "$($p[1]) $('{0:+0;-0}' -f $d) %" }
  }
  $tot = & $pc $r.Score $b.Score
  $e.Status = 'færdig'
  $e.Good = ($tot -ge 2)
  $e.Result = if ($tot -ge 2) { "✅ Ja: samlet $('{0:+0}' -f $tot) %$(if ($parts) { " · $($parts -join ', ')" })" } elseif ($tot -le -2) { "⚠ Nej: samlet $('{0:+0;-0}' -f $tot) %$(if ($parts) { " · $($parts -join ', ')" })" } else { "➖ Ingen målbar forskel (under 2 %)$(if ($parts) { " · $($parts -join ', ')" })" }
  Save-Changes $list
  $ui.BenchStatus.Text += "  ·  Hjalp det? $($e.Result -replace '^\S+\s', '')"
  Log "Hjalp det? benchmark: $($e.Result)"
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
<!DOCTYPE html><html lang="da"><meta charset="utf-8"><title>Opticon rapport $(Get-Date -Format 'yyyy-MM-dd HH:mm')</title>
<style>body{font-family:'Segoe UI',sans-serif;background:#0D0F14;color:#E7E9EE;max-width:1100px;margin:auto;padding:32px}
h1{background:linear-gradient(90deg,#8B5CF6,#3B9EFF);-webkit-background-clip:text;color:transparent}
pre{white-space:pre-wrap;background:#161A23;border:1px solid #242A39;padding:20px;border-radius:12px;font-family:'Segoe UI',sans-serif}
table{width:100%;border-collapse:collapse;margin-bottom:32px;background:#161A23;border-radius:12px;overflow:hidden}
td,th{padding:8px 10px;border-bottom:1px solid #242A39;vertical-align:top;text-align:left}th{color:#8A94A7;font-weight:600}small{color:#8A94A7}
.r4 td:first-child{color:#FF5D6C;font-weight:bold}.r3 td:first-child{color:#FFA24A;font-weight:bold}.r2 td:first-child{color:#F6D44A}.r1 td:first-child{color:#4ADE80}
.focus{background:#2A1E12}</style>
<h1>Opticon rapport</h1><p>$(Get-Date -Format 'dd-MM-yyyy HH:mm') · $env:COMPUTERNAME · score $($ui.ScoreText.Text)</p>
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
      $ui.StatusText.Text = "Opticon $AppVersion er den nyeste version."
      if ($c.Manual) { Msg "Du har den nyeste version ($AppVersion)." | Out-Null }
    }
  } @{ Manual = $manual }
}
$ui.BtnCheckUpdate.Add_Click({ Check-AppUpdate $true })
$ui.BtnUpdateApp.Add_Click({
  $v = $script:PendingUpdate
  if (-not $v) { return }
  $notes = (@($v.notes) | Select-Object -First 4 | ForEach-Object { "  • $_" }) -join "`n"
  if ((Msg "Opdatér Opticon fra $AppVersion til $($v.version)?`n`nNyheder:`n$notes`n`nFilernes fingeraftryk (SHA256) bliver tjekket, før noget installeres. Den gamle version gemmes som backup." 'Opdatering' 'YesNo' 'Question') -ne 'Yes') { return }
  $ui.BtnUpdateApp.IsEnabled = $false
  Invoke-Bg $UpdateApplyScript @{ Url = $(if ($v.BaseUrl) { $v.BaseUrl } else { $UpdateUrl }); Files = @($v.files); Dest = $PSScriptRoot; OldVersion = $AppVersion; JobRoot = $JobRoot } {
    param($r, $err, $c)
    if ($err) { $ui.BtnUpdateApp.IsEnabled = $true; Log "Opdatering fejlede: $err"; Msg "Opdateringen blev ikke installeret:`n`n$err" 'Opdatering' 'OK' 'Error' | Out-Null; return }
    Log "Opdateret til $($c.Version)"
    Msg "Opticon er opdateret til $($c.Version). Appen genstarter nu." 'Opdatering' | Out-Null
    # Genstart med sikkerhedsnet: en lille hjælper (egen proces) venter, til dette vindue er lukket, og starter den nye version.
    # Når præcis den nye version ikke når frem til et vist vindue ('Vindue vist v<ny>' i loggen) inden for 45 sek., sættes den forrige version tilbage og startes.
    $bk = Join-Path $PSScriptRoot ("backup-v" + $AppVersion)
    $tpl = @'
$ErrorActionPreference = 'SilentlyContinue'
Wait-Process -Id __PID__ -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500
$log = '__LOG__'; $dest = '__DEST__'; $bk = '__BK__'; $ver = '__NEW__'; $old = '__OLD__'
function Go {
  try { Start-ScheduledTask -TaskName 'PC-Tjek' -ErrorAction Stop }
  catch {
    $f = Join-Path $dest 'PC-Tjek-Start.ps1'; if (-not (Test-Path $f)) { $f = Join-Path $dest 'PC-Tjek-App.ps1' }
    Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoProfile -ExecutionPolicy RemoteSigned -STA -WindowStyle Hidden -File "' + $f + '"')
  }
}
$t0 = (Get-Date).AddSeconds(-2); Go
$ok = $false
for ($i = 0; $i -lt 45 -and -not $ok; $i++) {
  Start-Sleep -Seconds 1
  try { $ok = [bool](Get-Content -LiteralPath $log -Tail 60 -Encoding UTF8 | Where-Object { $_ -like ('*Vindue vist v' + $ver) -and $_.Length -ge 19 -and [datetime]$_.Substring(0, 19) -ge $t0 }) } catch {}
}
if (-not $ok -and (Test-Path -LiteralPath $bk)) {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*PC-Tjek-App.ps1*' -or $_.CommandLine -like '*PC-Tjek-Start.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  Start-Sleep -Milliseconds 800
  Get-ChildItem -LiteralPath $bk -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dest $_.Name) -Force }
  $msg = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  Version ' + $ver + ' startede ikke. Den forrige version (' + $old + ') er sat tilbage automatisk.'
  [IO.File]::AppendAllText($log, $msg + "`r`n", [Text.Encoding]::UTF8)
  Go
}
'@
    $cmd = $tpl.Replace('__PID__', [string]$PID).Replace('__LOG__', $LogFile.Replace("'", "''")).Replace('__DEST__', $PSScriptRoot.Replace("'", "''")).Replace('__BK__', $bk.Replace("'", "''")).Replace('__NEW__', [string]$c.Version).Replace('__OLD__', $AppVersion)
    # Hjælperen gemmes som en almindelig, læsbar .ps1-fil (ingen kodet kommando)
    Get-ChildItem $JobRoot -Filter 'opdater-genstart*.ps1' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $helper = Join-Path $JobRoot ('opdater-genstart-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
    try { [IO.File]::WriteAllText($helper, $cmd, (New-Object Text.UTF8Encoding $true)) }
    catch {
      Log "Genstart-hjælper kunne ikke gemmes: $($_.Exception.Message)"
      Msg "Opdateringen til $($c.Version) er installeret. Luk Opticon, og åbn den igen for at bruge den nye version." 'Opdatering' 'OK' 'Information' | Out-Null
      return
    }
    Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File `"$helper`""
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


# Ikonet skal starte den lille starter (som kan reparere appen), ikke appen direkte
function Ensure-Launcher {
  $launcher = Join-Path $PSScriptRoot 'PC-Tjek-Start.ps1'
  if (-not (Test-Path $launcher) -or $PSScriptRoot -notlike "$env:ProgramFiles\*") { return }
  try {
    $t = Get-ScheduledTask -TaskName 'PC-Tjek' -ErrorAction Stop
    $a = @($t.Actions)[0]
    if ($a.Arguments -like '*PC-Tjek-Start.ps1*' -and -not (Test-OldTaskAction $t)) { return }
    Set-ScheduledTask -TaskName 'PC-Tjek' -TaskPath '\' -Action (New-PsTaskAction $launcher) -ErrorAction Stop | Out-Null
    Log 'Ikonet bruger nu den nye startmåde'
  } catch { Log "Kunne ikke sætte starteren op: $_" }
}
# Navneskift: omdøb gamle genveje til det nye navn (én gang)
function Update-Shortcuts {
  $old = 'PC' + '-Tjek'   # det gamle navn (skrevet sådan, så det ikke bliver omdøbt)
  if ($AppName -eq $old) { return }
  $changed = $false
  try {
    $desk = [Environment]::GetFolderPath('Desktop'); $prog = [Environment]::GetFolderPath('Programs')
    $o = Join-Path $desk "$old.lnk"
    if ((Test-Path $o) -and -not (Test-Path (Join-Path $desk "$AppName.lnk"))) { Rename-Item $o "$AppName.lnk"; $changed = $true }
    $om = Join-Path $prog $old; $nm = Join-Path $prog $AppName
    if ((Test-Path $om) -and -not (Test-Path $nm)) {
      $l1 = Join-Path $om "$old.lnk"; if (Test-Path $l1) { Rename-Item $l1 "$AppName.lnk" }
      $l2 = Join-Path $om "Afinstallér $old.lnk"; if (Test-Path $l2) { Rename-Item $l2 "Afinstallér $AppName.lnk" }
      Rename-Item $om $AppName; $changed = $true
    }
  } catch { Log "Genveje kunne ikke omdøbes: $_" }
  if ($changed) { Log "Genveje omdøbt til $AppName"; try { Start-Process "$env:SystemRoot\System32\ie4uinit.exe" '-show' -WindowStyle Hidden } catch {} }
}
# Genveje fra ældre versioner startede via conhost. Peg dem direkte på schtasks.
function Update-ShortcutTargets {
  try {
    $sh = New-Object -ComObject WScript.Shell
    $sys = Join-Path $env:SystemRoot 'System32'
    foreach ($lp in @((Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"), (Join-Path (Join-Path ([Environment]::GetFolderPath('Programs')) $AppName) "$AppName.lnk"))) {
      if (-not (Test-Path $lp)) { continue }
      $l = $sh.CreateShortcut($lp)
      if ([string]$l.TargetPath -match '(?i)conhost\.exe$') {
        $l.TargetPath = "$sys\schtasks.exe"; $l.Arguments = '/run /tn "\PC-Tjek"'; $l.WindowStyle = 7
        $l.Save(); Log "Genvej opdateret (uden conhost): $lp"
      }
    }
  } catch { Log "Genveje kunne ikke opdateres: $_" }
}
$win.Add_ContentRendered({
  Log "Vindue vist v$AppVersion"   # bekræftelse til opdateringens sikkerhedsnet: præcis denne version kom helt frem til vinduet
  Load-SysInfo; Refresh-VagtVersion; Check-AppUpdate $false
  Update-Shortcuts
  Ensure-Launcher; Update-TaskActions; Update-ShortcutTargets
  try { Load-SpaceLast } catch {}; $spaceTimer.Start()
  try { $r = Repair-Modes; if ($r) { Log "Tilstand ryddet op ved start: $($r.Mode) ($($r.Reason))" } } catch { Log "Tilstand-oprydning fejlede: $_" }
  try { Update-ModeUi } catch {}; $modeTimer.Start()
  try { Update-Changes } catch { Log "Hjalp det-fejl: $_" }
})
Log 'UI klar'
[void]$win.ShowDialog()
$jobTimer.Stop()
Log 'Lukket'
# Sørg for at ingen hængende baggrundsjob holder processen i live
if (-not $RestoreOnly) { [Environment]::Exit(0) }
