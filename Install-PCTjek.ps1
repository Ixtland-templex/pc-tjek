<#
  Installerer Opticon:
   1. Kopierer appen til  C:\Program Files\PC-Tjek  (kun administratorer kan ændre filerne der)
   2. Opretter en planlagt opgave "PC-Tjek", der må køre appen med administratorrettigheder.
      Den kører KUN, når du selv klikker på ikonet (ingen tidsplan, ingen autostart).
   3. Laver genveje på skrivebordet og i Start-menuen, der åbner appen uden konsolvindue og uden UAC.
  Afinstallér: Start-menuen → "Afinstallér Opticon", eller kør Uninstall-PCTjek.ps1.
#>
$ErrorActionPreference = 'Stop'
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  return
}
$Host.UI.RawUI.WindowTitle = 'Opticon installation'
Write-Host ''
Write-Host '  Opticon – installation' -ForegroundColor Magenta
Write-Host '  ----------------------'
try {
  $src  = $PSScriptRoot
  $dest = Join-Path $env:ProgramFiles 'PC-Tjek'
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $sys  = Join-Path $env:SystemRoot 'System32'

  Write-Host "  • Kopierer filer til $dest"
  New-Item -ItemType Directory -Force $dest | Out-Null
  foreach ($f in 'PC-Tjek-App.ps1', 'PC-Tjek-Start.ps1', 'PC-Tjek-Vagt.ps1', 'PC-Tjek.ico', 'Uninstall-PCTjek.ps1') {
    if (-not (Test-Path (Join-Path $src $f))) { throw "Mangler filen $f ved siden af installeren." }
    Copy-Item -Force (Join-Path $src $f) $dest
    Unblock-File (Join-Path $dest $f) -ErrorAction SilentlyContinue
  }
  if (Test-Path (Join-Path $src 'pc-tjek.config.json')) { Copy-Item -Force (Join-Path $src 'pc-tjek.config.json') $dest }
  Get-ChildItem $dest -Directory -Filter 'backup-v*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -Skip 3 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

  if (Get-ScheduledTask -TaskName 'PC-Tjek Vagt' -ErrorAction SilentlyContinue) {   # genstart vagten med den nye version
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*PC-Tjek-Vagt.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-ScheduledTask -TaskName 'PC-Tjek Vagt' -ErrorAction SilentlyContinue
  }
  Write-Host "  • Opretter den planlagte opgave 'PC-Tjek' (kører som $user, kun når du starter den)"
  $appArgs = "--headless `"$sys\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$dest\PC-Tjek-Start.ps1`""
  $action    = New-ScheduledTaskAction -Execute "$sys\conhost.exe" -Argument $appArgs -WorkingDirectory $dest
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
  $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable:$false
  Register-ScheduledTask -TaskName 'PC-Tjek' -TaskPath '\' -Action $action -Principal $principal -Settings $settings `
    -Description 'Starter Opticon med administratorrettigheder, når du klikker på ikonet. Ingen tidsplan.' -Force | Out-Null

  Write-Host '  • Laver genveje (skrivebord + Start-menu)'
  $shell = New-Object -ComObject WScript.Shell
  function New-Link($path, $target, $arguments, $desc) {
    $l = $shell.CreateShortcut($path)
    $l.TargetPath = $target; $l.Arguments = $arguments; $l.WorkingDirectory = $dest
    $l.IconLocation = "$dest\PC-Tjek.ico,0"; $l.Description = $desc; $l.WindowStyle = 7
    $l.Save()
  }
  $runArgs = "--headless `"$sys\schtasks.exe`" /run /tn `"\PC-Tjek`""
  $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Opticon'
  $old = 'PC' + '-Tjek'   # gammelt navn: fjern gamle genveje
  Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Desktop')) "$old.lnk")
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Programs')) $old)
  New-Item -ItemType Directory -Force $menu | Out-Null
  New-Link (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Opticon.lnk') "$sys\conhost.exe" $runArgs 'Sikkerhed, oprydning og optimering'
  New-Link (Join-Path $menu 'Opticon.lnk') "$sys\conhost.exe" $runArgs 'Sikkerhed, oprydning og optimering'
  New-Link (Join-Path $menu 'Afinstallér Opticon.lnk') "$sys\WindowsPowerShell\v1.0\powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File `"$dest\Uninstall-PCTjek.ps1`"" 'Fjerner Opticon'

  Write-Host ''
  Write-Host '  ✓ Færdig! Start Opticon fra ikonet på skrivebordet.' -ForegroundColor Green
  Write-Host '    (Dine rapporter gemmes i Overførsler\PC-Tjek-rapport)'
  $go = Read-Host '  Vil du starte Opticon nu? (J/n)'
  if ($go -notmatch '^[nN]') { Start-ScheduledTask -TaskName 'PC-Tjek' }
} catch {
  Write-Host ''
  Write-Host "  ✗ Installationen fejlede: $($_.Exception.Message)" -ForegroundColor Red
  Read-Host '  Tryk Enter for at lukke'
}
