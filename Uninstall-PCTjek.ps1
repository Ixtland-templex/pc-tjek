# Fjerner PC-Tjek: den planlagte opgave, genvejene og programmappen. Dine rapporter i Overførsler\PC-Tjek-rapport bliver liggende.
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  return
}
Write-Host ''
Write-Host '  Afinstallerer PC-Tjek...' -ForegroundColor Magenta
Unregister-ScheduledTask -TaskName 'PC-Tjek' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PC-Tjek.lnk')
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Programs')) 'PC-Tjek')
$dest = Join-Path $env:ProgramFiles 'PC-Tjek'
# scriptet ligger selv i mappen, så mappen slettes lige efter, at vinduet lukker
Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c timeout /t 2 >nul & rmdir /s /q `"$dest`""
Write-Host '  ✓ PC-Tjek er fjernet. Rapporterne i Overførsler\PC-Tjek-rapport er bevaret.' -ForegroundColor Green
Start-Sleep -Seconds 3
