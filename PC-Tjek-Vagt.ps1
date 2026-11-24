<#
  Opticon Vagt  –  kører stille i baggrunden (startes af den planlagte opgave "PC-Tjek Vagt" ved login)
  ---------------------------------------------------------------------------------------------------
  * Download-vagt: tjekker nye programfiler i Overførsler (signatur, hvor de kommer fra, Defender, indhold i zip)
  * Vagthund: giver besked, når noget nyt sætter sig i opstart, planlagte opgaver, tjenester, browserudvidelser
    eller Defender-undtagelser
  * Viser små popups nederst til højre. Indstillinger og log ligger i C:\ProgramData\PC-Tjek
#>
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, Microsoft.VisualBasic
try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch {}

$mutex = New-Object System.Threading.Mutex($false, 'Global\PCTjekVagt')
if (-not $mutex.WaitOne(0)) { return }   # kører allerede

$Base     = Join-Path $env:ProgramData 'PC-Tjek'
New-Item -ItemType Directory -Force $Base | Out-Null
$CfgFile  = Join-Path $Base 'vagt.json'
$SnapFile = Join-Path $Base 'vagt-baseline.json'
$VLogFile = Join-Path $Base 'vagt-log.txt'
$TestFlag = Join-Path $Base 'vagt-test.flag'
$AppDir   = $PSScriptRoot

function Get-Cfg {
  $c = @{ Downloads = $true; Watchdog = $true }
  if (Test-Path $CfgFile) {
    try { $j = Get-Content $CfgFile -Raw -ErrorAction Stop | ConvertFrom-Json; $script:CfgErr = ''
      if ($null -ne $j.Downloads) { $c.Downloads = [bool]$j.Downloads }
      if ($null -ne $j.Watchdog) { $c.Watchdog = [bool]$j.Watchdog } } catch { $script:CfgErr = $_.Exception.Message }
  }
  return $c
}
function VLog($kind, $level, $title, $detail, $path) {
  $o = [ordered]@{ Tid = (Get-Date).ToString('s'); Type = $kind; Niveau = $level; Titel = $title; Detalje = $detail; Sti = $path }
  try { [IO.File]::AppendAllText($VLogFile, (($o | ConvertTo-Json -Compress) + "`r`n"), [Text.Encoding]::UTF8) } catch {}
}

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

function Open-App { try { Start-ScheduledTask -TaskName 'PC-Tjek' -ErrorAction Stop } catch { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy RemoteSigned -STA -WindowStyle Hidden -File `"$(if (Test-Path "$AppDir\PC-Tjek-Start.ps1") { "$AppDir\PC-Tjek-Start.ps1" } else { "$AppDir\PC-Tjek-App.ps1" })`"" } }

# =====================================================================
#  POPUPS (eget design, nederst til højre)
# =====================================================================
$script:Popups = New-Object System.Collections.ArrayList
$script:Held = New-Object System.Collections.ArrayList
$PopupXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="False" ShowActivated="False"
        Width="400" SizeToContent="Height" ResizeMode="NoResize" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Opacity="0">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#E7E9EE"/><Setter Property="Background" Value="#262C3B"/><Setter Property="Padding" Value="12,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.82"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Border Name="Card" CornerRadius="14" Background="#161A23" BorderThickness="1" Padding="16,14" Margin="10">
    <Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="0" Opacity="0.55" Color="Black"/></Border.Effect>
    <StackPanel>
      <DockPanel>
        <TextBlock Name="CloseX" Text="✕" DockPanel.Dock="Right" Cursor="Hand" Foreground="#8A94A7" FontSize="13" VerticalAlignment="Top"/>
        <StackPanel Orientation="Horizontal">
          <Border Name="IconBg" Width="34" Height="34" CornerRadius="10"><TextBlock Name="Icon" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="White"/></Border>
          <StackPanel Margin="11,0,0,0" VerticalAlignment="Center" MaxWidth="290">
            <TextBlock Text="Opticon Vagt" FontSize="11" Foreground="#8A94A7"/>
            <TextBlock Name="Title" FontWeight="SemiBold" FontSize="14.5" Foreground="#F2F4F8" TextWrapping="Wrap"/>
          </StackPanel>
        </StackPanel>
      </DockPanel>
      <TextBlock Name="Body" TextWrapping="Wrap" Foreground="#C3CAD6" Margin="0,10,0,0" LineHeight="19"/>
      <WrapPanel Name="Buttons" Margin="0,12,0,0"/>
    </StackPanel>
  </Border>
</Window>
'@
function Place-Popups {
  $wa = [System.Windows.SystemParameters]::WorkArea
  $y = $wa.Bottom
  foreach ($w in @($script:Popups)) {
    $y -= $w.ActualHeight
    $w.Left = $wa.Right - $w.Width
    $w.Top = $y
  }
}
# level: safe / caution / danger / info. buttons: @(@{ Text=''; Kind='primary|danger|normal'; Action={ param($d) }; Data=... })
function Show-Popup($level, $title, $body, $buttons, [int]$autoClose = 0, [switch]$Force) {
  # Under Spil/Fokus: almindelige beskeder venter til bagefter (de logges stadig). Farlige vises altid.
  if (-not $Force -and $level -ne 'danger' -and (Test-Path $ModeFile)) { [void]$script:Held.Add([string]$title); return }
  $colors = @{ safe = @('#22C55E', '✓', '#1E5A3A'); caution = @('#F6C344', '!', '#6B5313'); danger = @('#FF5D6C', '⛔', '#6E1E28'); info = @('#8B5CF6', 'i', '#3B2C6E') }
  $c = $colors[$level]; if (-not $c) { $c = $colors.info }
  $w = [Windows.Markup.XamlReader]::Parse($PopupXaml)
  $conv = New-Object Windows.Media.BrushConverter
  $w.FindName('Card').BorderBrush = $conv.ConvertFromString($c[0])
  $w.FindName('IconBg').Background = $conv.ConvertFromString($c[0])
  $w.FindName('Icon').Text = $c[1]
  $w.FindName('Title').Text = $title
  $w.FindName('Body').Text = $body
  $panel = $w.FindName('Buttons')
  foreach ($b in @($buttons)) {
    $btn = New-Object Windows.Controls.Button
    $btn.Content = $b.Text
    if ($b.Kind -eq 'primary') { $btn.Background = $conv.ConvertFromString('#7C5CFF') }
    elseif ($b.Kind -eq 'danger') { $btn.Background = $conv.ConvertFromString($c[2]) }
    $btn.Tag = @{ Action = $b.Action; Data = $b.Data; Win = $w }
    $btn.Add_Click({ param($s, $e) $t = $s.Tag; try { if ($t.Action) { & $t.Action $t.Data } } catch {}; $t.Win.Close() })
    [void]$panel.Children.Add($btn)
  }
  $w.FindName('CloseX').Add_MouseLeftButtonUp({ param($s, $e) [Windows.Window]::GetWindow($s).Close() })
  $w.Add_Closed({ param($s, $e) [void]$script:Popups.Remove($s); Place-Popups })
  $w.Add_ContentRendered({ param($s, $e)
    Place-Popups
    $a = New-Object Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(250))
    $s.BeginAnimation([Windows.Window]::OpacityProperty, $a)
  })
  if ($autoClose -gt 0) {
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds($autoClose)
    $t.Tag = $w
    $t.Add_Tick({ param($s, $e) $s.Stop(); if (-not $s.Tag.IsMouseOver) { $s.Tag.Close() } else { $s.Start() } })
    $t.Start()
  }
  [void]$script:Popups.Insert(0, $w)
  $w.Show()
}

# =====================================================================
#  DOWNLOAD-VAGT
# =====================================================================
function Get-DownloadsDir {
  $p = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue).'{374DE290-123F-4565-9164-39C4925E467B}'
  if ($p) { $p = [Environment]::ExpandEnvironmentVariables($p) }
  if (-not $p -or -not (Test-Path $p)) { $p = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads' }
  return $p
}
$DlDir = Get-DownloadsDir
$WatchExt = '.exe', '.msi', '.msix', '.msixbundle', '.appx', '.zip', '.rar', '.7z', '.iso', '.scr', '.bat', '.cmd', '.ps1', '.vbs', '.js', '.jar', '.lnk', '.hta', '.reg'
$ExecExt  = '.exe', '.msi', '.msix', '.scr', '.bat', '.cmd', '.ps1', '.vbs', '.js', '.jar', '.lnk', '.hta', '.reg'
$script:SeenDl = @{}
Get-ChildItem -LiteralPath $DlDir -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $script:SeenDl[$_.FullName] = $true }

function Check-Download($path) {
  $f = Get-Item -LiteralPath $path -Force
  $ext = $f.Extension.ToLower()
  $reasons = New-Object System.Collections.ArrayList
  $good = New-Object System.Collections.ArrayList
  # Hvor kommer den fra? (Windows gemmer adressen i en skjult "Zone.Identifier")
  $zone = @(Get-Content -LiteralPath $path -Stream Zone.Identifier -ErrorAction SilentlyContinue)
  $url = (($zone | Where-Object { $_ -like 'HostUrl=*' }) -replace '^HostUrl=', '') | Select-Object -First 1
  $domain = ''; try { if ($url -and $url -notmatch '^about:') { $domain = ([Uri]$url).Host -replace '^www\.', '' } } catch {}
  $signer = $null
  if ($ext -in '.exe', '.msi', '.msix', '.scr', '.dll', '.ps1') {
    $s = Get-AuthenticodeSignature -LiteralPath $path
    if ($s.Status -eq 'Valid') { $signer = $s.SignerCertificate.Subject -replace '^CN="?([^,"]+).*', '$1'; [void]$good.Add("Signeret af $signer") }
    else { [void]$reasons.Add('Filen er ikke signeret af en kendt udgiver') }
  }
  # Defender tjekker filen (bruger også Microsofts cloud-database)
  # Defender-resultatet læses fra Defenders egen tekst og historik. Er det uklart, siger vi det.
  $def = 'unknown'
  $mp = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
  if (Test-Path $mp) {
    $t0 = (Get-Date).AddSeconds(-2)
    $out = (& $mp -Scan -ScanType 3 -File $path 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    $code = $LASTEXITCODE
    $n = if ($out -match '(?i)found (\d+) threat') { [int]$matches[1] } else { -1 }
    $hist = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $t0 -and (($_.Resources -join ' ') -like "*$path*") })
    if ($n -gt 0 -or $hist.Count) { $def = 'threat' }
    elseif ($code -eq 0 -and $out -match '(?i)found no threats') { $def = 'clean' }
  }
  if (-not (Test-Path -LiteralPath $path)) { $def = 'threat' }   # filen er væk: Defender har fjernet den
  $threat = $def -eq 'threat'
  switch ($def) {
    'threat' { [void]$reasons.Insert(0, 'Microsoft Defender har fundet malware i filen') }
    'clean'  { [void]$good.Add('Defender fandt intet') }
    default  { [void]$reasons.Add('Defender kunne ikke tjekke filen, så den er ikke verificeret') }
  }
  # Mistænkelige mønstre
  $double = $f.Name -match '(?i)\.(pdf|docx?|xlsx?|jpe?g|png|mp4|mp3|txt)\.(exe|scr|bat|cmd|js|vbs|lnk|com)$'
  if ($double) { [void]$reasons.Add('Dobbelt filendelse (fx .pdf.exe). Det er et klassisk trick') }
  $words = $f.Name -match '(?i)crack|keygen|patch|activator|free.?download|cheat|hack|unlock|repack|loader'
  if ($words) { [void]$reasons.Add('Navnet ligner crack/cheat/gratis-download. Den slags indeholder ofte malware') }
  $hoster = $domain -match '(?i)mediafire|mega\.nz|dropbox|discord|anonfiles|gofile|pixeldrain|1fichier|sendspace|uploadhaven|transfer\.sh|wetransfer|catbox|bit\.ly|tinyurl'
  if ($hoster -and $ext -in $ExecExt + '.zip', '.rar', '.7z') { [void]$reasons.Add("Hentet fra en fildelingstjeneste ($domain) og ikke fra producentens egen side") }
  $inside = @()
  if ($ext -eq '.zip') {
    try { $z = [IO.Compression.ZipFile]::OpenRead($path); $inside = @($z.Entries | Where-Object { $_.Name -match '(?i)\.(exe|msi|scr|bat|cmd|js|vbs|ps1|lnk|hta|jar)$' } | ForEach-Object { $_.FullName }); $z.Dispose() } catch {}
    if ($inside.Count) { [void]$reasons.Add("Indeholder programfiler: $((($inside | Select-Object -First 3) -join ', '))$(if ($inside.Count -gt 3) { ' …' })") }
  }
  if ($ext -in '.bat', '.cmd', '.ps1', '.vbs', '.js', '.hta', '.reg', '.lnk') { [void]$reasons.Add('Det er et script/genvej, der kan køre kommandoer direkte') }

  $level = if ($threat -or $double -or ($words -and -not $signer)) { 'danger' }
           elseif ($signer -and $def -eq 'clean' -and $reasons.Count -eq 0) { 'safe' }
           elseif ($reasons.Count -eq 1 -and $def -eq 'unknown' -and $signer) { 'info' }
           elseif ($reasons.Count) { 'caution' }
           else { 'info' }
  $from = if ($domain) { "Hentet fra $domain" } else { 'Ukendt kilde' }
  $sizeTxt = if ($f.Length -ge 1MB) { '{0:N1} MB' -f ($f.Length / 1MB) } else { '{0:N0} KB' -f ($f.Length / 1KB) }
  $del = @{ Text = '🗑  Flyt til papirkurv'; Kind = 'danger'; Data = $path; Action = { param($p) [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin'); VLog 'Download' 'handling' "Flyttet til papirkurv: $(Split-Path $p -Leaf)" '' $p } }
  $open = @{ Text = '📂  Åbn mappe'; Kind = 'normal'; Data = $path; Action = { param($p) if (Test-Path -LiteralPath $p) { Start-Process explorer.exe "/select,`"$p`"" } else { Start-Process explorer.exe (Split-Path $p) } } }
  $ok = @{ Text = 'OK'; Kind = 'normal'; Data = $null; Action = $null }
  switch ($level) {
    'danger' {
      $btns = if (Test-Path -LiteralPath $path) { @($del, @{ Text = 'Åbn Opticon'; Kind = 'normal'; Action = { Open-App } }) } else { @($ok) }
      Show-Popup 'danger' "Kør IKKE: $($f.Name)" ("$from · $sizeTxt`n`n" + (($reasons | ForEach-Object { "•  $_" }) -join "`n")) $btns 0
    }
    'caution' {
      Show-Popup 'caution' "Vær forsigtig: $($f.Name)" ("$from · $sizeTxt`n`n" + (($reasons | ForEach-Object { "•  $_" }) -join "`n") + "`n`nKør den kun, hvis du stoler på, hvor den kommer fra.") @($del, $open, @{ Text = 'Jeg stoler på den'; Kind = 'normal'; Action = $null }) 45
    }
    'safe' {
      Show-Popup 'safe' "Ser sikker ud: $($f.Name)" ("$from · $sizeTxt`n" + (($good | ForEach-Object { "✓  $_" }) -join "`n")) @($ok) 12
    }
    default {
      $txt = (@($good | ForEach-Object { "✓  $_" }) + @($reasons | ForEach-Object { "•  $_" })) -join "`n"
      Show-Popup 'info' "Ny fil: $($f.Name)" "$from · $sizeTxt`n$txt$(if ($ext -in '.iso', '.rar', '.7z', '.zip') { "`nPas på med programmer indeni, hvis kilden er ukendt." })" @($ok) 15
    }
  }
  VLog 'Download' $level $f.Name ((@($reasons) + @($good)) -join ' · ') $path
}

function Poll-Downloads {
  foreach ($f in @(Get-ChildItem -LiteralPath $DlDir -File -Force -ErrorAction SilentlyContinue)) {
    if ($script:SeenDl.ContainsKey($f.FullName)) { continue }
    if ($f.Extension -match '(?i)^\.(crdownload|part|tmp|download|partial|opdownload)$') { continue }
    if ($WatchExt -notcontains $f.Extension.ToLower()) { $script:SeenDl[$f.FullName] = $true; continue }
    if (((Get-Date) - $f.LastWriteTime).TotalSeconds -lt 2) { continue }   # bliver stadig skrevet
    try { $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite'); $fs.Close() } catch { continue }
    $script:SeenDl[$f.FullName] = $true
    try { Check-Download $f.FullName } catch { VLog 'Fejl' 'info' "Kunne ikke tjekke $($f.Name)" $_.Exception.Message $f.FullName }
  }
}

# =====================================================================
#  VAGTHUND
# =====================================================================
function Sig-Of($cmd) {
  if (-not $cmd) { return '' }
  $c = [Environment]::ExpandEnvironmentVariables([string]$cmd).Trim()
  $p = if ($c -match '^"([^"]+)"') { $matches[1] } elseif ($c -match '^(.+?\.(exe|dll|bat|cmd|ps1|vbs|js))(\s|$)') { $matches[1] } else { ($c -split ' ')[0] }
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return '' }
  $s = Get-AuthenticodeSignature -LiteralPath $p
  if ($s.Status -eq 'Valid') { return ($s.SignerCertificate.Subject -replace '^CN="?([^,"]+).*', '$1') }
  return 'USIGNERET'
}
function Get-Snap {
  $s = @{}
  foreach ($src in @(@{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; H = 'HKCU'; A = 'Run' }, @{ K = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; H = 'HKLM'; A = 'Run' },
                     @{ K = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; H = 'HKLM'; A = 'Run32' },
                     @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; H = ''; A = '' }, @{ K = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; H = ''; A = '' })) {
    $p = Get-ItemProperty $src.K -ErrorAction SilentlyContinue
    if ($p) { foreach ($pr in ($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) { $s["Autostart|$($src.K)|$($pr.Name)"] = @{ Kind = 'run'; Name = $pr.Name; Cmd = [string]$pr.Value; Hive = $src.H; Appr = $src.A } } }
  }
  foreach ($sf in @(@{ P = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"; H = 'HKCU' }, @{ P = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"; H = 'HKLM' })) {
    Get-ChildItem $sf.P -File -Force -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini' | ForEach-Object { $s["Startmappe|$($_.FullName)"] = @{ Kind = 'startfile'; Name = $_.Name; Cmd = $_.FullName; Hive = $sf.H } }
  }
  Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
    $a = @($_.Actions)[0]
    $s["Opgave|$($_.TaskPath)$($_.TaskName)"] = @{ Kind = 'task'; Name = $_.TaskName; TaskPath = $_.TaskPath; Cmd = "$($a.Execute) $($a.Arguments)".Trim() }
  }
  Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p.ImagePath -and ($p.Type -eq 16 -or $p.Type -eq 32)) { $s["Tjeneste|$($_.PSChildName)"] = @{ Kind = 'service'; Name = $(if ($p.DisplayName -and $p.DisplayName -notlike '@*') { $p.DisplayName } else { $_.PSChildName }); Cmd = [string]$p.ImagePath } }
  }
  foreach ($b in @(@{ N = 'Chrome'; P = "$env:LOCALAPPDATA\Google\Chrome\User Data" }, @{ N = 'Edge'; P = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" })) {
    Get-ChildItem $b.P -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(Default|Profile \d+)$' } | ForEach-Object {
      Get-ChildItem (Join-Path $_.FullName 'Extensions') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $s["Udvidelse|$($b.N)|$($_.Name)"] = @{ Kind = 'ext'; Browser = $b.N; Name = $_.Name; Cmd = $_.FullName } }
    }
  }
  try { $mp = Get-MpPreference; foreach ($x in @($mp.ExclusionPath) + @($mp.ExclusionProcess) + @($mp.ExclusionExtension)) { if ($x -and $x -notmatch '^N/A') { $s["Undtagelse|$x"] = @{ Kind = 'excl'; Name = $x; Cmd = $x } } } } catch {}
  return $s
}
function Ext-Name($dir) {
  $m = Get-ChildItem $dir -Recurse -Filter manifest.json -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($m) { try { $n = (Get-Content $m.FullName -Raw | ConvertFrom-Json).name; if ($n -and $n -notlike '__MSG_*') { return $n } } catch {} }
  return (Split-Path $dir -Leaf)
}
function Disable-Item($it) {
  switch ($it.Kind) {
    'task' { Disable-ScheduledTask -TaskPath $it.TaskPath -TaskName $it.Name -ErrorAction Stop | Out-Null }
    { $_ -in 'run', 'startfile' } {
      $sub = if ($it.Kind -eq 'startfile') { 'StartupFolder' } else { $it.Appr }
      if (-not $it.Hive -or -not $sub) { throw 'Kan ikke slås fra her' }
      $k = "$($it.Hive):\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$sub"
      if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
      $b = New-Object byte[] 12; $b[0] = 3; [BitConverter]::GetBytes([DateTime]::Now.ToFileTime()).CopyTo($b, 4)
      New-ItemProperty -Path $k -Name $it.Name -Value $b -PropertyType Binary -Force | Out-Null
    }
  }
}
# Baseline: nøgle -> mål (kommando/sti), så vi også opdager, når en kendt post pludselig peger på noget andet
$script:Baseline = $null
if (Test-Path $SnapFile) {
  try {
    $j = Get-Content $SnapFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($j -is [array] -or $null -eq $j) { $script:Baseline = $null }   # gammelt format eller tom fil: start forfra uden alarmer
    else { $script:Baseline = @{}; foreach ($pr in $j.PSObject.Properties) { $script:Baseline[$pr.Name] = [string]$pr.Value } }
    if ($script:Baseline -and $script:Baseline.Count -eq 0) { $script:Baseline = $null }
  } catch { $script:Baseline = $null; $script:BaseErr = $_.Exception.Message }
}
function Save-Baseline($now) {
  $m = [ordered]@{}; foreach ($k in $now.Keys) { $m[$k] = [string]$now[$k].Cmd }
  $script:Baseline = @{}; foreach ($k in $m.Keys) { $script:Baseline[$k] = $m[$k] }
  try { [IO.File]::WriteAllText($SnapFile, ($m | ConvertTo-Json -Depth 2), (New-Object Text.UTF8Encoding $false)) } catch {}
}
function Norm-Ver($s) { ([string]$s) -replace '\d+(\.\d+){1,3}', '#' }   # versionsnumre ignoreres (almindelige opdateringer)
function Check-Watchdog {
  $now = Get-Snap
  $keys = @($now.Keys)
  $script:LastWd = Get-Date
  if ($null -eq $script:Baseline) {   # første gang: husk alt, ingen alarmer
    Save-Baseline $now
    VLog 'Vagthund' 'info' 'Vagthunden er startet' "$($keys.Count) ting registreret" ''
    return
  }
  # Ændrede poster: samme navn, men nyt mål
  $changed = @($keys | Where-Object { $script:Baseline.ContainsKey($_) -and (Norm-Ver $script:Baseline[$_]) -ne (Norm-Ver $now[$_].Cmd) })
  foreach ($k in $changed) {
    $it = $now[$k]; $old = $script:Baseline[$k]
    $label = Kind-Label $it.Kind
    $sig = if ($it.Kind -in 'run', 'task', 'service', 'startfile') { Sig-Of $it.Cmd } else { '' }
    $level = if ($sig -eq 'USIGNERET' -or $it.Kind -eq 'excl') { 'caution' } else { 'info' }
    $who = if ($sig -and $sig -ne 'USIGNERET') { "Det nye mål er signeret af $sig." } elseif ($sig -eq 'USIGNERET') { 'Det nye mål er IKKE signeret af en kendt udgiver.' } else { '' }
    $btns = New-Object System.Collections.ArrayList
    if ($it.Kind -in 'run', 'task', 'startfile' -and ($it.Kind -eq 'task' -or $it.Hive)) {
      [void]$btns.Add(@{ Text = '⛔  Slå fra'; Kind = 'danger'; Data = $it; Action = { param($x) try { Disable-Item $x; VLog 'Vagthund' 'handling' "Slået fra: $($x.Name)" $x.Cmd $x.Cmd } catch {} } })
    } else { [void]$btns.Add(@{ Text = 'Åbn Opticon'; Kind = 'primary'; Action = { Open-App } }) }
    [void]$btns.Add(@{ Text = 'Det er OK'; Kind = 'normal'; Action = $null })
    Show-Popup $level "Ændret $($label.ToLower()): $($it.Name)" "Peger nu på et andet program. $who`n`nNu:  $($it.Cmd)`nFør: $old" @($btns) $(if ($level -eq 'caution') { 0 } else { 30 })
    VLog 'Vagthund' $level "Ændret $($label.ToLower()): $($it.Name)" "Før: $old · Nu: $($it.Cmd)" $it.Cmd
  }
  $new = @($keys | Where-Object { -not $script:Baseline.ContainsKey($_) })
  # Rigtig mange "nye" på én gang er aldrig et angreb, men en tabt/forældet liste (fx efter en stor Windows-opdatering): husk stille
  if ($new.Count -gt 40 -and $new.Count -gt ($keys.Count / 3)) {
    Save-Baseline $now
    VLog 'Vagthund' 'info' "Listen er opdateret ($($new.Count) ting)" 'Mange ændringer på én gang, fx efter en Windows-opdatering. Registreret uden besked.' ''
    return
  }
  if ($changed.Count -or $new.Count -or $keys.Count -ne $script:Baseline.Count -or @($keys | Where-Object { $script:Baseline[$_] -ne [string]$now[$_].Cmd }).Count) { Save-Baseline $now }
  if ($new.Count) {
    $items = @($new | ForEach-Object { $it = $now[$_]; $it.Key = $_; $it })
    if ($items.Count -gt 3) {
      $list = ($items | Select-Object -First 6 | ForEach-Object { "•  $(Kind-Label $_.Kind): $(if ($_.Kind -eq 'ext') { Ext-Name $_.Cmd } else { $_.Name })" }) -join "`n"
      Show-Popup 'info' "$($items.Count) nye ting starter automatisk" "Har du lige installeret eller opdateret et program? Så er det sikkert fint.`n`n$list" @(@{ Text = 'Åbn Opticon'; Kind = 'primary'; Action = { Open-App } }, @{ Text = 'OK'; Kind = 'normal'; Action = $null }) 30
      foreach ($it in $items) { VLog 'Vagthund' 'info' "$(Kind-Label $it.Kind): $($it.Name)" $it.Cmd $it.Cmd }
      return
    }
    foreach ($it in $items) {
      $label = Kind-Label $it.Kind
      $name = if ($it.Kind -eq 'ext') { Ext-Name $it.Cmd } else { $it.Name }
      $sig = if ($it.Kind -in 'run', 'task', 'service', 'startfile') { Sig-Of $it.Cmd } else { '' }
      $level = if ($it.Kind -eq 'excl' -or $sig -eq 'USIGNERET') { 'caution' } else { 'info' }
      $who = if ($sig -and $sig -ne 'USIGNERET') { "Signeret af $sig." } elseif ($sig -eq 'USIGNERET') { 'Programmet er ikke signeret af en kendt udgiver.' } else { '' }
      $why = switch ($it.Kind) {
        'excl'    { 'Noget har bedt Defender om IKKE at scanne dette sted. Det gør malware ofte. Har du ikke selv gjort det, så fjern undtagelsen.' }
        'ext'     { "En ny udvidelse i $($it.Browser). Har du ikke selv installeret den, så fjern den." }
        'service' { 'En ny baggrundstjeneste. De kører med fulde rettigheder.' }
        default   { 'Det starter nu automatisk. Har du lige installeret noget, er det sikkert fint.' }
      }
      $btns = New-Object System.Collections.ArrayList
      if ($it.Kind -in 'run', 'task', 'startfile' -and ($it.Kind -eq 'task' -or $it.Hive)) {
        [void]$btns.Add(@{ Text = '⛔  Slå fra'; Kind = 'danger'; Data = $it; Action = { param($x) try { Disable-Item $x; VLog 'Vagthund' 'handling' "Slået fra: $($x.Name)" $x.Cmd $x.Cmd } catch { Show-Popup 'caution' 'Kunne ikke slå det fra' 'Åbn Opticon, og gør det derfra.' @(@{ Text = 'OK'; Kind = 'normal'; Action = $null }) 10 } } })
      }
      if ($it.Kind -eq 'ext') { [void]$btns.Add(@{ Text = '🧩  Åbn udvidelser'; Kind = 'primary'; Data = $it.Browser; Action = { param($b) if ($b -eq 'Chrome') { Start-Process 'chrome.exe' 'chrome://extensions' } else { Start-Process 'msedge.exe' 'edge://extensions' } } }) }
      if ($it.Kind -in 'service', 'excl') { [void]$btns.Add(@{ Text = 'Åbn Opticon'; Kind = 'primary'; Action = { Open-App } }) }
      [void]$btns.Add(@{ Text = 'Det er OK'; Kind = 'normal'; Action = $null })
      Show-Popup $level "Ny $($label.ToLower()): $name" ("$why $who`n`n$($it.Cmd)").Trim() @($btns) $(if ($level -eq 'caution') { 0 } else { 40 })
      VLog 'Vagthund' $level "$($label): $name" "$why $who" $it.Cmd
    }
  }
}
function Kind-Label($k) { switch ($k) { 'run' { 'Opstartsprogram' } 'startfile' { 'Opstartsfil' } 'task' { 'Planlagt opgave' } 'service' { 'Tjeneste' } 'ext' { 'Browserudvidelse' } 'excl' { 'Defender-undtagelse' } default { 'Ting' } } }

# =====================================================================
#  HOVEDLØKKE
# =====================================================================
$script:Cfg = Get-Cfg
$script:Tick = 0
$script:LastDl = $null; $script:LastWd = $null
$StatusFile = Join-Path $Base 'vagt-status.json'
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$DiagFile = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\PC-Tjek-rapport\vagt-diag.txt'
function Write-Status {
  $m = Get-ModeState
  $o = [ordered]@{ Heartbeat = (Get-Date).ToString('s'); Pid = $PID; Admin = $IsAdmin; Downloads = $script:Cfg.Downloads; Watchdog = $script:Cfg.Watchdog
                   DownloadsChecked = $(if ($script:LastDl) { $script:LastDl.ToString('s') } else { '' }); WatchdogChecked = $(if ($script:LastWd) { $script:LastWd.ToString('s') } else { '' })
                   Baseline = $(if ($script:Baseline) { $script:Baseline.Count } else { 0 }); Mode = $(if ($m) { $m.Mode } else { '' }); Held = $script:Held.Count }
  $err = ''
  try { [IO.File]::WriteAllText($StatusFile, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch { $err = $_.Exception.Message }
  # Lille kopi i rapportmappen, så fejl kan findes uden administratoradgang
  try { [IO.File]::WriteAllText($DiagFile, ("$(($o | ConvertTo-Json -Compress))`r`nStatusfil: $(if ($err) { "FEJL: $err" } else { 'ok' })`r`nIndstillinger: $(if ($script:CfgErr) { "FEJL: $($script:CfgErr)" } else { 'ok' })`r`nListe: $(if ($script:BaseErr) { "FEJL: $($script:BaseErr)" } else { 'ok' })`r`nScript: $PSCommandPath"), (New-Object Text.UTF8Encoding $false)) } catch {}
}
# ---------- Tilstande ----------
$script:GameMiss = 0; $script:SkipGame = ''
function End-ModeWithPopup($reason) {
  $s = Stop-Mode $reason
  if (-not $s) { return }
  $held = @($script:Held); $script:Held.Clear()
  $label = if ($s.Mode -eq 'Fokus') { '🔕 Fokus er slut' } else { "🎮 Spil-tilstand slut: $($s.Name)" }
  $fails = @($s.Failed)
  $body = ((@($s.Done) | ForEach-Object { "✓  $_" }) -join "`n")
  if ($fails.Count) { $body += "`n" + ((@($fails) | ForEach-Object { "⚠  $_. Prøver igen ved næste start." }) -join "`n") }
  if ($held.Count) { $body += "`n`nImens fik du $($held.Count) besked$(if ($held.Count -ne 1) { 'er' }) fra Vagten:`n" + ((@($held) | Select-Object -First 5 | ForEach-Object { "•  $_" }) -join "`n") }
  if (-not $body.Trim()) { $body = 'Der var intet at sætte tilbage.' }
  Show-Popup $(if ($fails.Count) { 'caution' } else { 'safe' }) $label $body.Trim() @(@{ Text = 'Åbn Opticon'; Kind = 'normal'; Action = { Open-App } }, @{ Text = 'OK'; Kind = 'primary'; Action = $null }) $(if ($held.Count) { 0 } else { 20 }) -Force
}
function Mode-Tick {
  $m = Get-ModeState
  if (Test-Path $ModeStopFlag) {
    Remove-Item $ModeStopFlag -Force -ErrorAction SilentlyContinue
    if ($m) { if ($m.Mode -eq 'Spil') { $script:SkipGame = Exe-Key $m.Exe }; End-ModeWithPopup 'du afsluttede den' }
    return
  }
  if ($m) {
    if ($m.Mode -eq 'Fokus') { if ($m.Until -and (Get-Date) -gt [datetime]$m.Until) { End-ModeWithPopup 'tiden er gået' }; return }
    if ($m.Mode -eq 'Spil') {
      if (Get-Process -Name (Exe-Key $m.Exe) -ErrorAction SilentlyContinue) { $script:GameMiss = 0 }
      else { $script:GameMiss++; if ($script:GameMiss -ge 3) { $script:GameMiss = 0; End-ModeWithPopup 'spillet er lukket' } }
    }
    return
  }
  if ($script:Tick % 2 -ne 0) { return }
  $games = @(Get-Games); if (-not $games.Count) { return }
  $running = @{}; foreach ($p in Get-Process -ErrorAction SilentlyContinue) { $running[$p.ProcessName.ToLower()] = $true }
  if ($script:SkipGame -and -not $running.ContainsKey($script:SkipGame)) { $script:SkipGame = '' }
  foreach ($g in $games) {
    $k = Exe-Key $g.Exe
    if ($k -and $running.ContainsKey($k) -and $k -ne $script:SkipGame) {
      $nm = Start-GameMode $g
      if ($nm) {
        $txt = ''
        if (@($nm.Paused).Count) { $txt += "Lukket: $((@($nm.Paused) | ForEach-Object { $_.Name }) -join ', '). De startes igen, når du lukker spillet.`n" }
        if (@($nm.NotClosed).Count) { $txt += "Kunne ikke lukkes: $(@($nm.NotClosed) -join ', '). Opticon tvinger aldrig noget til at lukke. Luk dem selv, hvis du vil.`n" }
        $txt += 'Beskeder fra Opticon venter, til du er færdig.'
        if ($nm.NewPl) { $txt += "`nGrafikkort: $($nm.NewPl) W." }
        Show-Popup 'info' "🎮 Spil-tilstand: $($g.Name)" $txt.Trim() @(@{ Text = 'OK'; Kind = 'normal'; Action = $null }) $(if (@($nm.NotClosed).Count) { 15 } else { 6 }) -Force
      }
      break
    }
  }
}
VLog 'Vagt' 'info' 'Vagten er startet' "Overvåger $DlDir$(if (-not $IsAdmin) { ' · ADVARSEL: kører uden administratorrettigheder' })" ''
try { $r = Repair-Modes; if ($r) { $script:StartupSummary = $r } } catch {}
# Grafikkortets strømgrænse fra Opticons GPU-test (Windows nulstiller den ved genstart)
$GpuPlFile = Join-Path $Base 'gpu-pl.json'
if (Test-Path $GpuPlFile) {
  try {
    $g = Get-Content $GpuPlFile -Raw | ConvertFrom-Json
    $smi = "$env:SystemRoot\System32\nvidia-smi.exe"; if (-not (Test-Path $smi)) { $smi = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe" }
    if ($g.Uuid -and -not (Test-GpuIdPresent ([string]$g.Uuid))) { VLog 'Vagt' 'info' 'GPU-profilen hører til et andet grafikkort end det, der sidder i nu, så den bruges ikke.' }
    elseif ((Test-Path $smi) -and [int]$g.Watts -gt 0) { $null = & $smi -i $(if ($g.Uuid) { [string]$g.Uuid } else { Get-GpuId }) -pl ([int]$g.Watts) 2>&1; VLog 'Vagt' 'info' "Grafikkortets strømgrænse sat til $($g.Pct) % ($($g.Watts) W)" '' '' }
  } catch {}
}
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(3)
$timer.Add_Tick({
  $script:Tick++
  try {
    if ($script:Tick % 10 -eq 1) { $script:Cfg = Get-Cfg }
    if (Test-Path $TestFlag) {
      Remove-Item $TestFlag -Force
      Show-Popup 'safe' 'Ser sikker ud: SteamSetup.exe' "Hentet fra cdn.akamai.steamstatic.com · 2,3 MB`n✓  Signeret af Valve Corp.`n✓  Defender fandt intet" @(@{ Text = 'OK'; Kind = 'normal'; Action = $null }) 15
      Show-Popup 'caution' 'Vær forsigtig: PawPatrol_Setup.exe' "Hentet fra mediafire.com · 4,1 MB`n`n•  Filen er ikke signeret af en kendt udgiver`n•  Hentet fra en fildelingstjeneste og ikke fra producentens egen side`n`n(Dette er bare et eksempel.)" @(@{ Text = '🗑  Flyt til papirkurv'; Kind = 'danger'; Action = $null }, @{ Text = 'Jeg stoler på den'; Kind = 'normal'; Action = $null }) 30
    }
    if ($script:Cfg.Downloads) { Poll-Downloads; $script:LastDl = Get-Date }
    if ($script:Cfg.Watchdog -and ($script:Tick % 20 -eq 2)) { Check-Watchdog }   # ca. hvert minut
    try { Mode-Tick } catch { VLog 'Fejl' 'info' 'Fejl i tilstand' $_.Exception.Message '' }
    if ($script:Tick % 20 -eq 7) { [void](Repair-GpuRestore) }
    if ($script:Tick % 10 -eq 1) { Write-Status }
  } catch { VLog 'Fejl' 'info' 'Fejl i vagten' $_.Exception.Message '' }
})
$timer.Start()
# Uventede fejl må ikke lukke vagten
[Windows.Threading.Dispatcher]::CurrentDispatcher.Add_UnhandledException({ param($s, $e) $e.Handled = $true; VLog 'Fejl' 'info' 'Uventet fejl i vagten (fortsætter)' $e.Exception.Message '' })
try { [Windows.Threading.Dispatcher]::Run() }
finally { VLog 'Vagt' 'info' 'Vagten stoppede' '' '' }
