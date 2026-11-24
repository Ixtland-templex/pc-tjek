<#
  Opticon-starter (lille og stabil, ændres næsten aldrig)
  1. Tjekker, at appen kan læses af PowerShell.
  2. Er den i stykker: sætter den nyeste brugbare backup tilbage, ellers hentes den nyeste version fra GitHub
     (fingeraftryk og læsbarhed tjekkes, før noget erstattes).
  3. Starter appen.
#>
$ErrorActionPreference = 'SilentlyContinue'
$dir = $PSScriptRoot
$app = Join-Path $dir 'PC-Tjek-App.ps1'
$logDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\PC-Tjek-rapport'
$log = Join-Path $logDir 'pc-tjek.log'

function L($m) {
  try { New-Item -ItemType Directory -Force $logDir | Out-Null; [IO.File]::AppendAllText($log, ('{0:yyyy-MM-dd HH:mm:ss}  Starter: {1}' -f (Get-Date), $m) + "`r`n", [Text.Encoding]::UTF8) } catch {}
}
function Test-Script($f) {
  if (-not (Test-Path -LiteralPath $f)) { return $false }
  $e = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e)
  return (-not ($e -and $e.Count))
}
function Restore-FromBackup {
  $backups = @(Get-ChildItem -LiteralPath $dir -Directory -Filter 'backup-v*' | Sort-Object LastWriteTime -Descending)
  foreach ($b in $backups) {
    $cand = Join-Path $b.FullName 'PC-Tjek-App.ps1'
    if (Test-Script $cand) {
      Copy-Item -LiteralPath $cand -Destination $app -Force
      L "Appen kunne ikke læses. Den forrige version er sat tilbage fra $($b.Name)."
      return $true
    }
  }
  return $false
}
function Restore-FromGitHub {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $cfg = Get-Content (Join-Path $dir 'pc-tjek.config.json') -Raw | ConvertFrom-Json
    $base = ([string]$cfg.UpdateUrl).TrimEnd('/')
    if (-not $base) { return $false }
    $v = Invoke-RestMethod -Uri ('{0}/version.json?t={1}' -f $base, [DateTime]::UtcNow.Ticks) -UseBasicParsing -TimeoutSec 20
    $f = @($v.files | Where-Object { $_.name -eq 'PC-Tjek-App.ps1' })[0]
    if (-not $f) { return $false }
    $tmp = Join-Path $env:TEMP ('opticon-' + [guid]::NewGuid().ToString('N') + '.ps1')
    Invoke-WebRequest -Uri ('{0}/PC-Tjek-App.ps1?t={1}' -f $base, [DateTime]::UtcNow.Ticks) -OutFile $tmp -UseBasicParsing -TimeoutSec 60
    $h = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
    if ($h -ne ([string]$f.sha256).ToUpper() -or -not (Test-Script $tmp)) { Remove-Item $tmp -Force; return $false }
    Copy-Item -LiteralPath $tmp -Destination $app -Force
    Remove-Item $tmp -Force
    L "Appen kunne ikke læses. Version $($v.version) er hentet fra GitHub og sat ind."
    return $true
  } catch { return $false }
}

if (-not (Test-Script $app)) {
  L 'Appen kunne ikke læses (skrivefejl). Prøver at reparere.'
  $fixed = Restore-FromBackup
  if (-not $fixed) { $fixed = Restore-FromGitHub }
  if (-not $fixed) {
    Add-Type -AssemblyName PresentationFramework
    [void][Windows.MessageBox]::Show("Opticon kunne ikke starte, og det lykkedes ikke at reparere den automatisk.`n`nKør 'Installer PC-Tjek.cmd' igen (fra den mappe, du installerede fra).", 'Opticon', 'OK', 'Error')
    return
  }
}
& $app
