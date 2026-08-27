<#
.SYNOPSIS
  Mette il motore di cattura dentro C:\winfleet\engine e toglie Sunshine dal PC.

.DESCRIPTION
  winfleet usa Sunshine come MOTORE - cattura DXGI piu' encode NVENC - non come
  programma. Delle sue istanze conosce gia' tutto: porte, configurazioni,
  certificati, tutto in C:\winfleet\sunN. Dell'installazione servono solo i file.

  Finche' resta installato, pero', sul PC c'e' "Sunshine": una voce fra i
  programmi, un servizio che puo' ripartire e prendersi la 47990, una cartella in
  Program Files con dentro una web UI da cui si puo' cambiare la configurazione e
  rompere winfleet senza sapere di averlo fatto. E un aggiornamento automatico
  puo' sostituire il binario sotto i piedi delle istanze.

  Questo script porta i file dentro casa e disinstalla il pacchetto. Il PC non ha
  piu' Sunshine: ha winfleet, che dentro di se' ha un motore.

  L'ordine conta ed e' il punto delicato: prima si copia, poi si VERIFICA che la
  copia funzioni, e solo dopo si disinstalla. Disinstallare per primo lascerebbe
  un PC senza motore e senza modo di rifarlo, se la copia fosse incompleta.

  -SoloCopia si ferma prima della disinstallazione: utile per provare il motore
  locale tenendo l'installazione come rete di sicurezza.

.EXAMPLE
  .\wf-engine-adopt.ps1
  .\wf-engine-adopt.ps1 -SoloCopia
#>
[CmdletBinding()]
param([switch]$SoloCopia)
$ErrorActionPreference = 'Stop'

$dest = 'C:\winfleet\engine'
$src  = 'C:\Program Files\Sunshine'

# --- 1. i file --------------------------------------------------------------
if (Test-Path (Join-Path $dest 'sunshine.exe')) {
    "motore gia presente in $dest"
} elseif (-not (Test-Path (Join-Path $src 'sunshine.exe'))) {
    # I due punti SUBITO dopo una variabile non sono punteggiatura: PowerShell
    # legge "$src:" come "variabile src nello scope src" e lo script non COMPILA
    # - l'errore indica la riga giusta ma sembra parlare di virgolette.
    # Le graffe chiudono il nome e i due punti tornano testo.
    throw "Manca sia il motore in ${dest} sia l installazione in ${src}: niente da adottare."
} else {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item "$src\*" $dest -Recurse -Force
    "copiati $((Get-ChildItem $dest -Recurse | Measure-Object).Count) file in $dest"
}

# --- 2. la prova ------------------------------------------------------------
# Che il file ci sia non dice che funzioni: manca una dll, manca la cartella
# shaders, e sunshine parte e muore. Si chiede la versione, che e' il modo piu'
# economico di farlo caricare davvero.
$exe = Join-Path $dest 'sunshine.exe'
$ver = (Get-Item $exe).VersionInfo.FileVersion
if (-not $ver) { throw "Il motore copiato non ha una versione leggibile: copia incompleta." }
foreach ($n in @('assets', 'assets\shaders', 'assets\web')) {
    if (-not (Test-Path (Join-Path $dest $n))) { throw "Manca $n nel motore copiato: senza, la cattura fallisce a runtime." }
}
"motore $ver, assets completi"

# --- 3. le istanze ci girano davvero? --------------------------------------
# La prova che conta, e non e' "il file esiste": si guarda quali processi
# sunshine sono vivi e da DOVE. Se anche una sola istanza sta ancora girando dal
# vecchio percorso, disinstallare la ucciderebbe.
$vecchie = @(Get-CimInstance Win32_Process -Filter "Name='sunshine.exe'" -EA SilentlyContinue |
             Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($src) })
if ($vecchie.Count -gt 0) {
    "ATTENZIONE: $($vecchie.Count) istanze girano ancora da $src."
    'Riavviale prima di disinstallare:  winfleet push, poi wf-inst-ctl.ps1 -Slot N -Action restart'
    if (-not $SoloCopia) { throw "Non disinstallo con istanze vive sul vecchio percorso." }
}

if ($SoloCopia) { 'fermo qui (-SoloCopia): l installazione resta al suo posto.'; return }

# --- 4. via il pacchetto ----------------------------------------------------
# Prima il servizio: un servizio in esecuzione blocca la disinstallazione e
# lascia il pacchetto a meta'.
$svc = Get-Service SunshineService -EA SilentlyContinue
if ($svc) {
    Stop-Service SunshineService -Force -EA SilentlyContinue
    Set-Service  SunshineService -StartupType Disabled -EA SilentlyContinue
    'servizio fermato e disabilitato'
}

$pkg = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*,
                        HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -EA SilentlyContinue |
       Where-Object { $_.DisplayName -eq 'Sunshine' } | Select-Object -First 1
if (-not $pkg) {
    'nessun pacchetto Sunshine registrato: niente da disinstallare.'
} else {
    # Il codice prodotto dal registro, con /qn: l'UninstallString e' "MsiExec /I{...}",
    # cioe' INSTALLA in modo interattivo - lanciarla cosi' aprirebbe una finestra
    # sul PC e resterebbe li' ad aspettare un clic che nessuno dara' mai.
    $code = $pkg.PSChildName
    "disinstallo $($pkg.DisplayName) $($pkg.DisplayVersion) ($code)"
    $p = Start-Process msiexec.exe -ArgumentList "/x $code /qn /norestart" -Wait -PassThru
    "msiexec exit $($p.ExitCode)"
}

# --- 5. e il motore e' ancora li' ------------------------------------------
# Il controllo che vale: la disinstallazione poteva portarsi via anche la nostra
# copia (stessi nomi di file, e un installer che pulisce a fondo).
if (-not (Test-Path $exe)) { throw "GRAVE: la disinstallazione ha portato via anche $dest. Reinstalla Sunshine e rifai l adozione." }
$vive = @(Get-CimInstance Win32_Process -Filter "Name='sunshine.exe'" -EA SilentlyContinue)
"motore in $dest : presente"
"istanze sunshine vive: $($vive.Count)"
foreach ($v in $vive) { "  $($v.ExecutablePath)" }
