# Installa (o aggiorna) Topics sul PC per farlo girare come NODO della Topics del Mac.
# Va lanciato DENTRO la sessione della console, da un task pianificato Interactive:
# via ssh l'installer NSIS parte in un'altra window station e fallisce muto
# (misurato il 29/08, tools/win-desktop-install.ps1 di topics-app).
# A differenza di quello script NON lancia app.exe: il nodo e' solo il server
# headless (avvia-nodo.cmd), senza finestra.
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$Repo = "armonia/topics-app",
  [string]$Dir = "E:\topics-nodo"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path "$Dir\dl" | Out-Null
$log = Join-Path $Dir "installa.log"
function Say($t) { "$([DateTime]::Now.ToString('HH:mm:ss')) $t" | Add-Content $log }
"" | Set-Content $log

$exe = Join-Path $env:LOCALAPPDATA "Topics\app.exe"
$before = if (Test-Path $exe) { (Get-Item $exe).VersionInfo.FileVersion } else { "assente" }
Say "prima: $before"

$name = "Topics_${Version}_x64-setup.exe"
$file = Join-Path "$Dir\dl" $name
if (-not (Test-Path $file)) {
  # Release pubblica: si scarica senza token.
  $url = "https://github.com/$Repo/releases/download/tauri-v$Version/$name"
  Say "scarico $url"
  $ProgressPreference = "SilentlyContinue"
  Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
}
Say "installer: $((Get-Item $file).Length) byte"

# Nota: i processi della sessione S4U (server del nodo, ponti MCP) da qui non si
# chiudono: li ferma chi lancia questo task via ssh (pc-nodo-prep, ensure_version).
# Il guscio si rilancia da solo dopo un aggiornamento, e il watchdog (task
# pianificato) rilancia il server: senza fermarli prima, topics-server.exe si
# riapre tra lo stop e la scrittura di NSIS e l'installer esce 5 (accesso negato).
# Sidecar del bundle (externalBin in tauri.conf.json): tutti vanno chiusi e tutti sostituiti.
$sidecars = @("topics-server", "pty-bridge", "webrtc-bridge")
function Get-Hashes {
  $h = @{}
  foreach ($s in $sidecars) {
    $f = Join-Path $env:LOCALAPPDATA "Topics\$s.exe"
    $h[$s] = if (Test-Path $f) { (Get-FileHash $f -Algorithm SHA256).Hash } else { "" }
  }
  return $h
}
$hashBefore = Get-Hashes
$tasks = @("topics-watchdog", "topics-nodo")
foreach ($t in $tasks) { Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue }
function Stop-Topics {
  # Anche i ponti `topics-server.exe --topics-mcp-bridge`: tengono il file aperto.
  $end = (Get-Date).AddSeconds(60)
  do {
    $procs = @(Get-Process app, topics-server, pty-bridge, webrtc-bridge -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $true }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    $procs | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
  } while ((Get-Date) -lt $end)
  return (@(Get-Process app, topics-server, pty-bridge, webrtc-bridge -ErrorAction SilentlyContinue).Count -eq 0)
}
if (-not (Stop-Topics)) { Say "KO processi ancora vivi dopo 60 s" }
$p = Start-Process -FilePath $file -ArgumentList "/S" -PassThru -Wait
Say "installer exit $($p.ExitCode)"

# NSIS risponde 0 prima che i file siano a posto: aspetto la versione giusta.
$deadline = (Get-Date).AddSeconds(120)
$after = ""
while ((Get-Date) -lt $deadline) {
  if (Test-Path $exe) { $after = (Get-Item $exe).VersionInfo.FileVersion; if ($after -like "$Version*") { break } }
  Start-Sleep 2
}
Say "dopo: $after"
# Se l'installer ha riaperto il guscio, lo richiudo: il nodo non ha finestra.
Start-Sleep 5
[void](Stop-Topics)
$idx = Get-ChildItem (Join-Path $env:LOCALAPPDATA "Topics") -Recurse -Filter index.html -ErrorAction SilentlyContinue | Select-Object -First 1
Say "public: $($idx.DirectoryName)"
# Il watchdog rilancia il nodo; topics-nodo lo riavvia aggiorna-nodo.ps1.
Start-ScheduledTask -TaskName "topics-watchdog" -ErrorAction SilentlyContinue
$hashAfter = Get-Hashes
$stale = @($sidecars | Where-Object { -not $hashAfter[$_] -or $hashAfter[$_] -eq $hashBefore[$_] })
# Su una versione gia' installata gli hash restano uguali: e' informativo, non decide.
Say "sidecar non cambiati: $(if ($stale.Count) { $stale -join ', ' } else { 'nessuno' })"
# Verdetto: exit 0 dell'installer. L'exit 5 viene dall'hook POSTINSTALL
# (installer-hooks.nsh) e significa che un sidecar e' ancora bloccato e NON e' stato
# sostituito (misurato il 22/11: pty-bridge.exe vivo nella sessione 0): aggiornamento a meta', KO.
if ($p.ExitCode -eq 0 -and $after -like "$Version*") { Say "OK"; exit 0 }
Say "KO exit $($p.ExitCode), voluta $Version, trovata '$after'"; exit 1
