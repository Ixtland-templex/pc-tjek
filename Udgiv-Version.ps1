<#
  Udgiv en ny version af PC-Tjek
  ------------------------------
  Brug:   .\Udgiv-Version.ps1 -Version 2.2 -Notes 'Ny funktion X', 'Rettet fejl Y'
  1. Sætter versionsnummeret i PC-Tjek-App.ps1
  2. Beregner SHA256-fingeraftryk og skriver version.json
  3. Derefter: commit og push i GitHub Desktop. Så ser alle installerede apps opdateringen ved næste start.
#>
param(
  [Parameter(Mandatory)][string]$Version,
  [string[]]$Notes = @()
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$utf8Bom = New-Object Text.UTF8Encoding $true
$utf8 = New-Object Text.UTF8Encoding $false

$app = Join-Path $root 'PC-Tjek-App.ps1'
$txt = [IO.File]::ReadAllText($app)
if ($txt -notmatch "\`$AppVersion = '[\d.]+'") { throw 'Kunne ikke finde $AppVersion i PC-Tjek-App.ps1' }
$txt = $txt -replace "\`$AppVersion = '[\d.]+'", "`$AppVersion = '$Version'"
[IO.File]::WriteAllText($app, $txt, $utf8Bom)

$files = foreach ($f in 'PC-Tjek-App.ps1', 'PC-Tjek.ico', 'Uninstall-PCTjek.ps1') {
  [ordered]@{ name = $f; sha256 = (Get-FileHash (Join-Path $root $f) -Algorithm SHA256).Hash }
}
$json = [ordered]@{ version = $Version; date = (Get-Date -Format 'yyyy-MM-dd'); notes = @($Notes); files = @($files) } | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $root 'version.json'), $json, $utf8)
Write-Host "✓ version.json er opdateret til $Version." -ForegroundColor Green
Write-Host '  Commit og push nu i GitHub Desktop.'
