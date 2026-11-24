<#
  PC-Tjek Vagt  –  kører stille i baggrunden (startes af den planlagte opgave "PC-Tjek Vagt" ved login)
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
    try { $j = Get-Content $CfgFile -Raw | ConvertFrom-Json
      if ($null -ne $j.Downloads) { $c.Downloads = [bool]$j.Downloads }
      if ($null -ne $j.Watchdog) { $c.Watchdog = [bool]$j.Watchdog } } catch {}
  }
  return $c
}
function VLog($kind, $level, $title, $detail, $path) {
  $o = [ordered]@{ Tid = (Get-Date).ToString('s'); Type = $kind; Niveau = $level; Titel = $title; Detalje = $detail; Sti = $path }
  try { [IO.File]::AppendAllText($VLogFile, (($o | ConvertTo-Json -Compress) + "`r`n"), [Text.Encoding]::UTF8) } catch {}
}
function Open-App { try { Start-ScheduledTask -TaskName 'PC-Tjek' -ErrorAction Stop } catch { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$AppDir\PC-Tjek-App.ps1`"" } }

# =====================================================================
#  POPUPS (eget design, nederst til højre)
# =====================================================================
$script:Popups = New-Object System.Collections.ArrayList
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
            <TextBlock Text="PC-Tjek Vagt" FontSize="11" Foreground="#8A94A7"/>
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
function Show-Popup($level, $title, $body, $buttons, [int]$autoClose = 0) {
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
      $btns = if (Test-Path -LiteralPath $path) { @($del, @{ Text = 'Åbn PC-Tjek'; Kind = 'normal'; Action = { Open-App } }) } else { @($ok) }
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
    $j = Get-Content $SnapFile -Raw | ConvertFrom-Json
    if ($j -is [array]) { $script:Baseline = $null }   # gammelt format: start forfra uden alarmer
    else { $script:Baseline = @{}; foreach ($pr in $j.PSObject.Properties) { $script:Baseline[$pr.Name] = [string]$pr.Value } }
  } catch {}
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
    } else { [void]$btns.Add(@{ Text = 'Åbn PC-Tjek'; Kind = 'primary'; Action = { Open-App } }) }
    [void]$btns.Add(@{ Text = 'Det er OK'; Kind = 'normal'; Action = $null })
    Show-Popup $level "Ændret $($label.ToLower()): $($it.Name)" "Peger nu på et andet program. $who`n`nNu:  $($it.Cmd)`nFør: $old" @($btns) $(if ($level -eq 'caution') { 0 } else { 30 })
    VLog 'Vagthund' $level "Ændret $($label.ToLower()): $($it.Name)" "Før: $old · Nu: $($it.Cmd)" $it.Cmd
  }
  $new = @($keys | Where-Object { -not $script:Baseline.ContainsKey($_) })
  if ($changed.Count -or $new.Count -or $keys.Count -ne $script:Baseline.Count -or @($keys | Where-Object { $script:Baseline[$_] -ne [string]$now[$_].Cmd }).Count) { Save-Baseline $now }
  if ($new.Count) {
    $items = @($new | ForEach-Object { $it = $now[$_]; $it.Key = $_; $it })
    if ($items.Count -gt 3) {
      $list = ($items | Select-Object -First 6 | ForEach-Object { "•  $(Kind-Label $_.Kind): $(if ($_.Kind -eq 'ext') { Ext-Name $_.Cmd } else { $_.Name })" }) -join "`n"
      Show-Popup 'info' "$($items.Count) nye ting starter automatisk" "Har du lige installeret eller opdateret et program? Så er det sikkert fint.`n`n$list" @(@{ Text = 'Åbn PC-Tjek'; Kind = 'primary'; Action = { Open-App } }, @{ Text = 'OK'; Kind = 'normal'; Action = $null }) 30
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
        [void]$btns.Add(@{ Text = '⛔  Slå fra'; Kind = 'danger'; Data = $it; Action = { param($x) try { Disable-Item $x; VLog 'Vagthund' 'handling' "Slået fra: $($x.Name)" $x.Cmd $x.Cmd } catch { Show-Popup 'caution' 'Kunne ikke slå det fra' 'Åbn PC-Tjek, og gør det derfra.' @(@{ Text = 'OK'; Kind = 'normal'; Action = $null }) 10 } } })
      }
      if ($it.Kind -eq 'ext') { [void]$btns.Add(@{ Text = '🧩  Åbn udvidelser'; Kind = 'primary'; Data = $it.Browser; Action = { param($b) if ($b -eq 'Chrome') { Start-Process 'chrome.exe' 'chrome://extensions' } else { Start-Process 'msedge.exe' 'edge://extensions' } } }) }
      if ($it.Kind -in 'service', 'excl') { [void]$btns.Add(@{ Text = 'Åbn PC-Tjek'; Kind = 'primary'; Action = { Open-App } }) }
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
function Write-Status {
  $o = [ordered]@{ Heartbeat = (Get-Date).ToString('s'); Downloads = $script:Cfg.Downloads; Watchdog = $script:Cfg.Watchdog
                   DownloadsChecked = $(if ($script:LastDl) { $script:LastDl.ToString('s') } else { '' }); WatchdogChecked = $(if ($script:LastWd) { $script:LastWd.ToString('s') } else { '' }) }
  try { [IO.File]::WriteAllText($StatusFile, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch {}
}
VLog 'Vagt' 'info' 'Vagten er startet' "Overvåger $DlDir" ''
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
    if ($script:Tick % 10 -eq 1) { Write-Status }
  } catch { VLog 'Fejl' 'info' 'Fejl i vagten' $_.Exception.Message '' }
})
$timer.Start()
# Uventede fejl må ikke lukke vagten
[Windows.Threading.Dispatcher]::CurrentDispatcher.Add_UnhandledException({ param($s, $e) $e.Handled = $true; VLog 'Fejl' 'info' 'Uventet fejl i vagten (fortsætter)' $e.Exception.Message '' })
try { [Windows.Threading.Dispatcher]::Run() }
finally { VLog 'Vagt' 'info' 'Vagten stoppede' '' '' }
