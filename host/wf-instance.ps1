<#
.SYNOPSIS
  Creates a Sunshine instance bound to one virtual monitor.

.DESCRIPTION
  Sunshine streams one screen per instance, so several app windows at once means
  several instances — one per virtual monitor, each with its own ports, its own
  config and its own pairing.

  Unlike the packaged service, these instances run *inside the logged-in session*.
  That is what makes per-app windows simple: a service lives in session 0 and cannot
  put a window on your desktop, while an instance in your session launches the app
  directly onto its own screen.

  Everything an instance owns lives under C:\winfleet\sun<slot>\ — config, apps,
  certificate, pairing state, log — so instances never touch each other or the
  packaged Sunshine.

.PARAMETER Slot
  Which virtual monitor to bind, 0-based, as published in C:\winfleet\vdd.json.

.EXAMPLE
  .\wf-instance.ps1 -Slot 0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][int]$Slot,
    [string]$User = "$env:COMPUTERNAME\$env:USERNAME"
)
$ErrorActionPreference = 'Stop'

# Il lanciatore nascosto, per i task che NON hanno bisogno di una console.
#
# "-WindowStyle Hidden" non basta: quando un'attivita' pianificata avvia
# powershell.exe Windows gli alloca comunque una console, e su questo PC il
# terminale predefinito e' Windows Terminal - quindi quella console e' una
# FINESTRA VERA sul desktop, 1129x635, in mezzo a quello che si sta facendo.
#
# Misurato il 03/09/2026, campionando le finestre visibili ogni 100 ms dalla
# sessione grafica: DUE finestre "Windows Terminal" comparivano insieme a ogni
# minuto (:02) e restavano ~14 secondi, una per winfleet-cursor-guard e una per
# winfleet-vdd-guard. Da qui le "due finestre del terminale che si aprono a
# caso" - a caso non era: era un cron al minuto.
#
# Perche' wscript e non conhost --headless: la seconda toglie la finestra ma
# BLOCCA il processo dentro (provata e scartata il 27/08 su wf-vdd). wscript.exe
# non alloca console affatto. Vale per i task brevi e non elevati; l'agente
# resta su powershell perche' attraverso wscript perde l'elevazione.
$HEADLESS = 'wscript.exe'
function Arg-Headless([string]$psArgs) {
    # //B = niente finestre di dialogo, //Nologo = niente banner.
    "//B //Nologo C:\winfleet\wf-run-hidden.vbs powershell.exe $psArgs"
}

# Il motore: quello dentro C:\winfleet se c'e', altrimenti l'installazione.
# La scelta sta in wf-engine.ps1, una volta sola per tutti gli script.
. C:\winfleet\wf-engine.ps1
$exe = Get-WinfleetEngine


$state = 'C:\winfleet\vdd.json'
if (-not (Test-Path $state)) { throw "Nessun monitor virtuale attivo: avvia il task winfleet-vdd." }
# ConvertFrom-Json su PowerShell 5.1 manda l'array giu' per la pipeline come UN
# oggetto solo: @() lo lascia intero e il conteggio viene 1. foreach lo scorre.
$parsed = ConvertFrom-Json ((Get-Content $state -Raw).TrimStart([char]0xFEFF))
$vdd = @(); foreach ($e in $parsed) { $vdd += $e }
$mon = $vdd | Where-Object { $_.slot -eq $Slot }
if (-not $mon) { throw "Slot $Slot inesistente (monitor virtuali: $($vdd.Count))." }

$dir  = "C:\winfleet\sun$Slot"
$port = 48089 + ($Slot * 100)
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# Sunshine identifies a screen by a device id of its own making, printed at startup.
# Start once with a bare config, read the id matching our \\.\DISPLAYn, then write
# the real config.
function Write-Conf($outputName) {
    # system_tray = disabled: niente icona e niente notifiche di Sunshine.
    #
    # Sunshine mette un'icona nella barra di Windows e annuncia ogni sessione
    # che si apre o si chiude. Con QUATTRO istanze diventano quattro icone e un
    # avviso per ogni finestra aperta - e per chi guarda quelle notifiche
    # arrivano da un programma che non ha mai lanciato: Sunshine e' un dettaglio
    # di come winfleet e' fatto dentro, non qualcosa con cui si interagisce.
    #
    # Non e' solo estetica: un avviso che non porta nessuna informazione
    # utilizzabile insegna a ignorare gli avvisi, e il giorno che ne arriva uno
    # che conta viene ignorato anche quello.
    $conf = @"
sunshine_name = WinFleet $($Slot + 1)
port = $port
origin_web_ui_allowed = lan
encoder = nvenc
nvenc_preset = 1
nvenc_twopass = quarter_res
min_fps_factor = 1
fps = [30,60,90,120]
channels = 2
gamepad = disabled
system_tray = disabled
log_path = $dir\sunshine.log
file_state = $dir\state.json
pkey = $dir\pkey.pem
cert = $dir\cert.pem
file_apps = $dir\apps.json

"@
    # La riga vuota sopra non e' cosmetica: un here-string finisce senza a capo, e
    # senza di essa output_name resterebbe incollato alla riga precedente — con il
    # risultato che Sunshine legge un file_apps inesistente e rimette i suoi default.
    if ($outputName) { $conf += "output_name = $outputName`r`n" }
    Set-Content "$dir\sunshine.conf" $conf -Encoding ASCII
}

if ($true) {
    # Una sola voce: l'istanza trasmette il suo schermo, le app le apre WinFleet.
    # (Senza scrivere il file senza BOM Sunshine lo scarta e rimette i suoi default.)
    $seedApps = '{"env":{},"apps":[{"name":"Desktop","cmd":"","auto-detach":true}]}'
    [IO.File]::WriteAllText("$dir\apps.json", $seedApps, (New-Object Text.UTF8Encoding $false))
}

# Le credenziali della web UI vivono nel file di stato, non in un file a parte, e
# "sunshine.exe --creds" avvia il server invece di uscire. Si semina quindi lo stato
# con l'utenza gia' in uso sull'istanza di sistema: stessa password, ma identita' e
# dispositivi accoppiati nuovi, cosi' Moonlight vede host distinti.
if (-not (Test-Path "$dir\state.json")) {
    # Il seme si cerca accanto al MOTORE, non in Program Files: da quando il
    # motore vive in C:\winfleet\engine l'installazione puo' non esistere piu'
    # affatto, e questo percorso fisso avrebbe smesso di trovare niente in
    # silenzio - un'istanza nuova con credenziali diverse dalle altre.
    $seed = [ordered]@{}
    foreach ($cand in @(
        (Join-Path (Split-Path (Get-WinfleetEngine)) 'config\sunshine_state.json'),
        'C:\Program Files\Sunshine\config\sunshine_state.json'
    )) {
        if (Test-Path $cand) {
            $j = Get-Content $cand -Raw | ConvertFrom-Json
            $seed = [ordered]@{ username = $j.username; salt = $j.salt; password = $j.password }
            break
        }
    }
    [IO.File]::WriteAllText("$dir\state.json", ($seed | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding $false))
}

Write-Conf $null

# L'istanza gira nella sessione interattiva: solo cosi' puo' aprire le app sul suo
# schermo, e solo cosi' vede gli schermi (un processo in sessione 0 non ne enumera
# nessuno — per questo anche la sonda qui sotto passa dal task).
#
# Il task si limita a lanciarla staccata: Sunshine e' un programma da console e, se il
# task gliene fa possedere una, un CTRL_CLOSE (basta una shell remota che si chiude)
# lo spegne a meta' sessione. Ciclo di vita e working directory li gestisce
# wf-inst-ctl.ps1.
$launch = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-inst-ctl.ps1 -Slot $Slot -Action start -Direct"
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $launch
# Elevata: per aprire un'app nella sessione interattiva Sunshine duplica il token
# della console, e senza privilegi il lancio fallisce con ACCESS_DENIED (errore 5).
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
# Al logon, dopo i monitor virtuali: un'istanza di Sunshine legata a uno schermo
# che non c'e' ancora parte e non trova niente da catturare.
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
$trigger.Delay = 'PT30S'
Register-ScheduledTask -TaskName "winfleet-sun$Slot" -Action $action -Principal $principal `
    -Settings $settings -Trigger $trigger -Force | Out-Null

# Sunshine names screens with a device id of its own making, printed at startup:
# run it once to read ours off the log.
# I due task del cursore: uno solo per tutta la flotta, non uno per slot.
#
# Vivono qui perche' qui c'e' gia' il principal giusto: SetSystemCursor vuole un
# desktop interattivo, e lanciata da ssh (sessione 0) fallisce con l'errore 1459.
# Un'attivita' pianificata "Interactive" gira invece nella sessione dello schermo,
# che e' l'unica in cui quel cambiamento ha senso.
foreach ($c in @('hide','restore')) {
    $ca = New-ScheduledTaskAction -Execute $HEADLESS `
        -Argument (Arg-Headless "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-cursor.ps1 -Action $c")
    Register-ScheduledTask -TaskName "winfleet-cursor-$c" -Action $ca -Principal $principal `
        -Settings $settings -Force -EA SilentlyContinue | Out-Null
}

# Il guardiano: rimette il cursore se il Mac smette di farsi vivo.
#
# Serve perche' "hide" e' globale su Windows mentre il ripristino dipendeva solo
# dal Mac: un kill -9, un Mac che dorme o uno stream mai partito lasciavano il PC
# senza puntatore a tempo indeterminato. Misurato: quattro giorni, invisibile
# anche da Parsec e davanti al monitor, senza nessun indizio che portasse qui.
#
# Ogni minuto, all'infinito: non fa nulla se il battito e' fresco o se non c'e'
# niente da ripristinare, quindi il costo a regime e' un processo che parte e
# muore subito.
#
# Dal lanciatore nascosto: "un processo che parte e muore subito" apriva una
# finestra di Windows Terminal ogni minuto per ~14 secondi (vedi la nota su
# $HEADLESS in testa al file). Un guardiano che si nota e' un guardiano rotto.
$gt = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration ([TimeSpan]::MaxValue)
$ga = New-ScheduledTaskAction -Execute $HEADLESS `
    -Argument (Arg-Headless '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-cursor.ps1 -Action guard')
Register-ScheduledTask -TaskName 'winfleet-cursor-guard' -Action $ga -Principal $principal `
    -Settings $settings -Trigger $gt -Force -EA SilentlyContinue | Out-Null

schtasks /run /tn "winfleet-sun$Slot" | Out-Null
Start-Sleep 14
& 'C:\winfleet\wf-inst-ctl.ps1' -Slot $Slot -Action stop | Out-Null
Start-Sleep 2

# Sunshine stampa l'elenco come JSON dentro il log: si prende quel blocco e lo si
# parsa, invece di inseguire i backslash con una regex (nel log "\\.\DISPLAY5"
# compare raddoppiato due volte, ed e' una fonte di errori sicura).
$deviceId = $null
$lines = @(Get-Content "$dir\sunshine.log" -EA SilentlyContinue)
for ($i = $lines.Count - 1; $i -ge 0 -and -not $deviceId; $i--) {
    if ($lines[$i] -notmatch 'available display devices') { continue }
    $buf = New-Object Text.StringBuilder
    for ($k = $i + 1; $k -lt $lines.Count; $k++) {
        [void]$buf.AppendLine($lines[$k])
        if ($lines[$k] -match '^\]\s*$') { break }
    }
    $devs = $null
    try { $devs = ConvertFrom-Json $buf.ToString() } catch { }
    foreach ($d in $devs) {
        if ($d.display_name -eq $mon.device) { $deviceId = $d.device_id; break }
    }
}
if (-not $deviceId) { throw "Non trovo il device id di $($mon.device) nel log di Sunshine ($dir\sunshine.log)." }
Write-Host "slot $Slot -> $($mon.device) = $deviceId"
Write-Conf $deviceId

# Un task per slot che apre l'app sul suo schermo. Serve perche' Sunshine non puo'
# lanciare processi nella sessione interattiva senza i privilegi di LocalSystem.
$placeAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-place.ps1 -Slot $Slot"
Register-ScheduledTask -TaskName "winfleet-place$Slot" -Action $placeAction -Principal $principal `
    -Settings $settings -Force | Out-Null

# Ports derived from the base: base-5/base/base+1/base+21 TCP, base+9..+13 UDP.
# -LocalPort vuole un array, non una stringa con le virgole (altrimenti 0x80070057).
$tcp = @("$($port-5)", "$port", "$($port+1)", "$($port+21)")
$udp = @("$($port+9)-$($port+13)")
Remove-NetFirewallRule -DisplayName "WinFleet sun$Slot*" -EA SilentlyContinue
New-NetFirewallRule -DisplayName "WinFleet sun$Slot TCP" -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort $tcp -RemoteAddress @('192.168.0.0/16','100.64.0.0/10') | Out-Null
New-NetFirewallRule -DisplayName "WinFleet sun$Slot UDP" -Direction Inbound -Action Allow -Protocol UDP `
    -LocalPort $udp -RemoteAddress @('192.168.0.0/16','100.64.0.0/10') | Out-Null

Write-Host "Istanza 'winfleet-sun$Slot' pronta su porta $port ($($mon.width)x$($mon.height))" -ForegroundColor Green
Write-Host "Avvia con:  schtasks /run /tn winfleet-sun$Slot   (o wf-inst-ctl.ps1 -Slot $Slot -Action start)"
