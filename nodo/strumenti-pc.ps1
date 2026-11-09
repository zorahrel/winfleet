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
# Login di git per gli agenti. Il gitconfig di sistema di Git for Windows usa
# l'helper "manager" (GCM su wincredman), che dal processo dell'agente non legge
# ne' salva: "Unable to persist credentials", e ogni fetch fallisce (09/11, card
# vuote rimandate al Mac). gh e' gia' loggato: diventa lui l'helper per github.com.
if (-not $SoloVerifica -and (Presente "gh")) { gh auth setup-git --hostname github.com *> $null }

# Verifica con l'ambiente ripulito dell'agente (agent-env.ts di topics-app):
# solo queste variabili, prompt spenti.
$keep = 'PATH','APPDATA','LOCALAPPDATA','USERPROFILE','HOMEDRIVE','HOMEPATH','SystemRoot','SystemDrive','windir','ComSpec','PATHEXT','TEMP','TMP','ProgramData','ProgramFiles','ProgramFiles(x86)','ProgramW6432','CommonProgramFiles','USERNAME','USERDOMAIN','COMPUTERNAME','NUMBER_OF_PROCESSORS','PROCESSOR_ARCHITECTURE','OS'
function ComeAgente($exe, $argomenti) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe; $psi.Arguments = $argomenti
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables.Clear()
  foreach ($k in $keep) { $v = [Environment]::GetEnvironmentVariable($k); if ($v) { $psi.EnvironmentVariables[$k] = $v } }
  $psi.EnvironmentVariables['HOME'] = $env:USERPROFILE
  $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
  $psi.EnvironmentVariables['GCM_INTERACTIVE'] = 'Never'
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
  if (-not $p.WaitForExit(60000)) { $p.Kill(); return @(124, "timeout") }
  return @($p.ExitCode, $out)
}
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if ($gh -and $git) {
  $r = ComeAgente $gh "auth status"
  if ($r[0] -ne 0) { "MANCA gh-login-agente: gh auth status rc=$($r[0])"; $manca++ } else { "OK gh-login-agente" }
  $repo = Get-ChildItem (Join-Path (Split-Path $Elenco) "repos") -Directory -ErrorAction SilentlyContinue |
    Get-ChildItem -Directory | Where-Object { Test-Path (Join-Path $_.FullName ".git") } | Select-Object -First 1
  if ($repo) {
    $r = ComeAgente $git "-C `"$($repo.FullName)`" ls-remote origin HEAD"
    if ($r[0] -ne 0) { "MANCA git-login-agente: git ls-remote origin in $($repo.Name) rc=$($r[0]): $(($r[1] -split "`n")[0])"; $manca++ } else { "OK git-login-agente ($($repo.Name))" }
  }
}
if ($manca) { exit 1 } else { exit 0 }
