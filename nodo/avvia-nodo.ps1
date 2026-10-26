# Server headless di Topics sul PC, come NODO della Topics del Mac.
# Lo lancia il task pianificato "topics-nodo" (registra-nodo.ps1) tramite
# wf-run-hidden.vbs: nessuna finestra sul desktop di chi usa il PC.
#
# Porte, tutte e due solo su 127.0.0.1 (il firewall non si tocca):
#   3333  porta principale: da qui il PC stesso e' proprietario (loopback).
#   3341  ascoltatore "tunnel": il Mac ci arriva con ssh -L e conta come
#         remoto, quindi deve essersi appaiato. Mai far arrivare il tunnel
#         sulla 3333: chi arriva da loopback e' proprietario senza credenziali.
#
# Il modello: il CLI claude lanciato dal nodo eredita ANTHROPIC_BASE_URL
# (tunnel -R verso il proxy della Topics del Mac) e ANTHROPIC_AUTH_TOKEN (token
# di nodo emesso dal Mac, valido solo li'). Sul PC nessun login di Claude.
param([string]$Dir = "E:\topics-nodo")
$ErrorActionPreference = "Continue"
$inst = Join-Path $env:LOCALAPPDATA "Topics"
New-Item -ItemType Directory -Force -Path "$Dir\logs", "$Dir\stato\data", "$Dir\stato\home" | Out-Null
$log = "$Dir\logs\avvio.log"
function Say($t) { "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) $t" | Add-Content $log }

# Una sola istanza: se qualcuno ascolta gia' sulla 3333, non parto.
if (Get-NetTCPConnection -State Listen -LocalPort 3333 -ErrorAction SilentlyContinue) { Say "3333 gia' occupata: esco"; exit 0 }

$env:NO_TLS = "1"
$env:BUN_PORT = "3333"
$env:SERVER_HOST = "127.0.0.1"
$env:TOPICS_TUNNEL_HTTP_PORT = "3341"
$env:TOPICS_DATA_DIR = "$Dir\stato"
$env:DATA_DIR = "$Dir\stato\data"
$env:TOPICS_HOME = "$Dir\stato\home"
$env:HOME = $env:USERPROFILE
$env:TOPICS_PUBLIC_DIR = "$inst\_up_\_up_\public"
$env:TOPICS_PTY_BRIDGE_BIN = "$inst\pty-bridge.exe"
# git non deve mai chiedere credenziali con una finestra (Git Credential Manager):
# i repo arrivano dal Mac con un bundle, il PC non ha token GitHub.
$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE = "Never"
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
# Il modello va anche nel blocco "env" di ~/.claude/settings.json. Topics
# lancia il CLI con --setting-sources user, e allora quel blocco vince
# sull'ambiente del processo. Serve perche' i CLI li lancia pty-bridge.exe, che
# sopravvive ai riavvii del server: nato prima di modello.env, non avrebbe mai
# le due variabili, e il CLI andrebbe dritto ad Anthropic col login del PC.
function Set-ClaudeModelEnv([string]$BaseUrl, [string]$Token) {
  $f = Join-Path $env:USERPROFILE ".claude\settings.json"
  $s = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
  if (-not (Test-Path "$f.prima-del-nodo") -and (Test-Path $f)) { Copy-Item $f "$f.prima-del-nodo" }
  if (-not $s.PSObject.Properties["env"]) { $s | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) }
  foreach ($k in "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN") { $s.env.PSObject.Properties.Remove($k) }
  if ($BaseUrl -and $Token) {
    $s.env | Add-Member -NotePropertyName ANTHROPIC_BASE_URL -NotePropertyValue $BaseUrl
    $s.env | Add-Member -NotePropertyName ANTHROPIC_AUTH_TOKEN -NotePropertyValue $Token
  }
  # UTF-8 senza BOM: con il BOM il CLI non legge il file.
  [IO.File]::WriteAllText($f, ($s | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding($false)))
}
# Riparte da solo se cade, con una pausa che cresce: un crash in loop non
# deve mangiarsi il PC.
$pausa = 5
while ($true) {
  # Riletto a ogni partenza: un token nuovo (o tolto) vale dal prossimo avvio.
  $cfg = "$Dir\modello.env"
  foreach ($k in "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN") { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
  if (Test-Path $cfg) {
    foreach ($line in Get-Content $cfg) {
      if ($line -match '^\s*([A-Z_]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
    }
    Say "modello: via $env:ANTHROPIC_BASE_URL"
  } else { Say "modello: nessun $cfg (il nodo non ha un modello)" }
  try { Set-ClaudeModelEnv $env:ANTHROPIC_BASE_URL $env:ANTHROPIC_AUTH_TOKEN; Say "settings.json del CLI allineato" }
  catch { Say "settings.json del CLI NON allineato: $($_.Exception.Message)" }
  # Una build del server compilata da un ramo (compila-dal-ramo.sh) vince su
  # quella installata; togliere $Dir\bin\topics-server.exe riporta la release.
  $exe = if (Test-Path "$Dir\bin\topics-server.exe") { "$Dir\bin\topics-server.exe" } else { "$inst\topics-server.exe" }
  Say "parto: $exe"
  $t0 = Get-Date
  & $exe *>> "$Dir\logs\server.log"
  $durata = [int]((Get-Date) - $t0).TotalSeconds
  Say "uscito con $LASTEXITCODE dopo $durata s"
  if (Test-Path "$Dir\fermo") { Say "trovato $Dir\fermo: non riparto"; exit 0 }
  if ($durata -gt 300) { $pausa = 5 } else { $pausa = [Math]::Min($pausa * 2, 300) }
  Start-Sleep $pausa
}
