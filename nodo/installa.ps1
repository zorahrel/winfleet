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

# Il guscio si rilancia da solo dopo un aggiornamento: fermo tutto prima.
foreach ($n in @("app", "topics-server")) {
  Get-Process $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep 3
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
foreach ($n in @("app", "topics-server")) {
  Get-Process $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
$idx = Get-ChildItem (Join-Path $env:LOCALAPPDATA "Topics") -Recurse -Filter index.html -ErrorAction SilentlyContinue | Select-Object -First 1
Say "public: $($idx.DirectoryName)"
if ($after -like "$Version*") { Say "OK"; exit 0 } else { Say "KO voluta $Version, trovata '$after'"; exit 1 }
