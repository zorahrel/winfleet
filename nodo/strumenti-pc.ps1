# Porta il PC ad avere tutti gli strumenti di strumenti.txt (idempotente).
# Lo lancia pc-nodo-prep dal Mac (al massimo una volta al giorno o quando l'elenco cambia),
# con -SoloVerifica lo usa la barra. Stampa "OK nome" / "MANCA nome: motivo"; exit 1 se ne manca uno.
param([string]$Elenco = "E:\topics-nodo\strumenti.txt", [switch]$SoloVerifica)
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# winget e npm aggiornano il PATH nel registro, non in questo processo: lo rileggo dopo ogni installazione.
function Ricarica-Path {
  $m = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $u = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$m;$u;$env:USERPROFILE\.bun\bin;$env:APPDATA\npm;$env:LOCALAPPDATA\Microsoft\WinGet\Links"
}
function Presente($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

Ricarica-Path
$manca = 0
foreach ($riga in Get-Content $Elenco) {
  $r = $riga.Trim()
  if (-not $r -or $r.StartsWith("#")) { continue }
  $c = $r -split "\s+"
  $nome, $cmd, $wg, $npm = $c[0], $c[1], $c[2], $c[4]
  if ($wg -eq "-" -and $npm -eq "-") { continue }  # solo Linux
  if (Presente $cmd) { "OK $nome"; continue }
  if (-not $SoloVerifica) {
    if ($wg -ne "-") {
      winget install --id $wg -e --silent --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity *> $null
      if ($LASTEXITCODE -ne 0) { winget install --id $wg -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity *> $null }
    } elseif ($npm -ne "-") {
      npm install -g --silent $npm *> $null
    }
    Ricarica-Path
    if (Presente $cmd) { "OK $nome (installato ora)"; continue }
  }
  "MANCA ${nome}: comando '$cmd' non trovato" + $(if ($SoloVerifica) { "" } else { " neanche dopo l'installazione" })
  $manca++
}
if ($manca) { exit 1 } else { exit 0 }
