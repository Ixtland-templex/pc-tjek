# Fjerner Opticon: den planlagte opgave, genvejene og programmappen. Dine rapporter i Overførsler\PC-Tjek-rapport bliver liggende.
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  return
}
Write-Host ''
Write-Host '  Afinstallerer Opticon...' -ForegroundColor Magenta
Unregister-ScheduledTask -TaskName 'PC-Tjek' -Confirm:$false -ErrorAction SilentlyContinue
Stop-ScheduledTask -TaskName 'PC-Tjek Vagt' -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*PC-Tjek-Vagt.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# Sæt en aktiv Spil-/Fokus-tilstand, grafikkortet og evt. blokerede sider tilbage, før appen fjernes
$appFile = Join-Path $PSScriptRoot 'PC-Tjek-App.ps1'
if (Test-Path $appFile) {
  Write-Host '  • Sætter alt tilbage, som Opticon har ændret midlertidigt...'
  $out = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $appFile -RestoreOnly
  if ($LASTEXITCODE -ne 0) {
    $what = ($out | Where-Object { $_ -like 'MANGLER:*' } | Select-Object -First 1) -replace '^MANGLER:\s*', ''
    Write-Host "  ⚠ Dette kunne ikke sættes tilbage: $what" -ForegroundColor Yellow
    Write-Host '    Genstart pc''en: grafikkortets strømgrænse nulstilles ved genstart. Tjek også Indstillinger → System → Meddelelser og Strøm.' -ForegroundColor Yellow
  } else { Write-Host '  ✓ Alt midlertidigt er sat tilbage' -ForegroundColor Green }
}
Unregister-ScheduledTask -TaskName 'PC-Tjek Vagt' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Opticon.lnk')
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Programs')) 'Opticon')
$old = 'PC' + '-Tjek'   # gammelt navn
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Desktop')) "$old.lnk")
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Programs')) $old)
$dest = Join-Path $env:ProgramFiles 'PC-Tjek'
# scriptet ligger selv i mappen, så mappen slettes lige efter, at vinduet lukker
Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c timeout /t 2 >nul & rmdir /s /q `"$dest`""
Write-Host '  ✓ Opticon er fjernet. Rapporterne i Overførsler\PC-Tjek-rapport er bevaret.' -ForegroundColor Green
Start-Sleep -Seconds 3
