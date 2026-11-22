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
$serverExe = Join-Path $env:LOCALAPPDATA "Topics\topics-server.exe"
$serverBefore = if (Test-Path $serverExe) { (Get-FileHash $serverExe -Algorithm SHA256).Hash } else { "" }
$tasks = @("topics-watchdog", "topics-nodo")
foreach ($t in $tasks) { Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue }
function Stop-Topics {
  # Anche i ponti `topics-server.exe --topics-mcp-bridge`: tengono il file aperto.
  $end = (Get-Date).AddSeconds(60)
  do {
    $procs = @(Get-Process app, topics-server -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $true }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    $procs | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
  } while ((Get-Date) -lt $end)
  return (@(Get-Process app, topics-server -ErrorAction SilentlyContinue).Count -eq 0)
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
$serverAfter = if (Test-Path $serverExe) { (Get-FileHash $serverExe -Algorithm SHA256).Hash } else { "" }
$serverOk = $serverAfter -and ($serverAfter -ne $serverBefore -or -not $serverBefore)
Say "server: $(if ($serverOk) { 'sostituito' } else { 'NON sostituito' })"
# Verdetto: contano i byte arrivati (server sostituito + versione giusta), non l'exit.
# L'exit 5 dell'installer viene dall'hook POSTINSTALL (installer-hooks.nsh): riapre i
# sidecar in scrittura e, se uno e' bloccato, imposta 5. Dopo la copia il guscio
# rilanciato dal template riapre topics-server/pty-bridge, quindi il blocco e' dopo
# la copia e non la prova di un file saltato. Un file davvero saltato lo prende il
# confronto dell'hash del server qui sotto.
if ($p.ExitCode -ne 0) { Say "nota: installer exit $($p.ExitCode) ma i file sono arrivati" }
if ($serverOk -and $after -like "$Version*") { Say "OK"; exit 0 }
Say "KO exit $($p.ExitCode), voluta $Version, trovata '$after'"; exit 1
