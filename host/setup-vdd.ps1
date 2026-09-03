<#
.SYNOPSIS
  Registers the WinFleet virtual-monitor manager as a scheduled task.

.DESCRIPTION
  wf-vdd.ps1 must run inside the logged-in session: plugging a monitor works from
  anywhere, but reading and setting display modes only sees the console session's
  screens, so a remote shell (session 0) would find nothing to configure.

.PARAMETER Slots
  How many virtual monitors to keep plugged — this is the ceiling on how many app
  windows can be streamed at once.

.EXAMPLE
  .\setup-vdd.ps1 -Slots 2
#>
[CmdletBinding()]
param(
    [int]$Slots  = 2,
    [string]$User = "$env:COMPUTERNAME\$env:USERNAME"
)
$ErrorActionPreference = 'Stop'

# I processi persistenti si lanciano tramite un VBScript che avvia powershell
# senza finestra.
#
# Il problema: "-WindowStyle Hidden" non basta. Quando un task avvia
# powershell.exe, Windows gli alloca comunque una console, e su un PC dove il
# terminale predefinito e' Windows Terminal quella console diventa una FINESTRA
# VERA sul desktop. Sull'host si vedeva la console di wf-vdd con dentro "PING -
# i monitor restano finche' questo processo vive": un dettaglio interno in mezzo
# allo schermo, e per giunta chiudibile per sbaglio - chiudendola si staccano
# tutti i monitor virtuali.
#
# Due strade provate e scartate, in ordine:
#
# 1) ShowWindow(SW_HIDE) sulla propria console. Nasconde la console classica, non
#    la finestra di Windows Terminal che la ospita in una scheda. Verificato
#    fotografando il desktop - non leggendo MainWindowHandle, che su questi
#    processi vale 0 mentre la finestra sullo schermo c'e' eccome.
#
# 2) "conhost.exe --headless". La finestra sparisce davvero, ma il processo
#    dentro si BLOCCA: wf-vdd restava vivo con il log fermo al primo giro e i
#    quattro monitor virtuali staccati. Una console headless non regge un
#    processo che deve girare per sempre e scrivere di continuo. Il sintomo e'
#    il peggiore possibile - processo presente, task "In esecuzione", e niente
#    che funziona.
#
# wscript.exe non alloca console AFFATTO: non c'e' finestra da nascondere e non
# c'e' console che si blocca. Lo script wf-run-hidden.vbs e' tre righe e lancia
# quello che gli si passa.
$HEADLESS = 'wscript.exe'
function Arg-Headless([string]$psArgs) {
    # //B = niente finestre di dialogo, //Nologo = niente banner.
    "//B //Nologo C:\winfleet\wf-run-hidden.vbs powershell.exe $psArgs"
}

$arg = Arg-Headless ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-vdd.ps1 ' +
       "-Count $Slots")
$action    = New-ScheduledTaskAction -Execute $HEADLESS -Argument $arg

$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
# Un trigger al logon, non perche' serva a far girare il task a mano, ma perche'
# senza nessun trigger dopo ogni riavvio del PC winfleet e' morto: i monitor
# virtuali non esistono, le istanze non ascoltano, e dal Mac si vede solo "finestra
# non risponde" senza capire che basta riaccendere qualcosa. Il ritardo lascia
# arrivare la sessione grafica: il driver dei monitor virtuali chiede un desktop.
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
$trigger.Delay = 'PT10S'
# E un secondo trigger, ogni minuto, perche' il logon copre solo il riavvio.
#
# I monitor virtuali esistono finche' QUESTO processo vive, e il processo puo'
# morire: basta un aggiornamento del driver, una sessione che si riduce, o un
# kill andato male. Quando succede il task torna "Pronta" e nessuno lo rilancia
# - visto due volte in una sera, a distanza di un'ora.
#
# Il sintomo e' il piu' ingannevole di tutti: le finestre continuano ad aprirsi,
# winfleet dice "Arc -> finestra 1", ogni controllo e' verde, e sul Mac si vede
# il DESKTOP di Windows invece dell'app - perche' il monitor su cui l'app
# dovrebbe stare non esiste piu' e la finestra finisce altrove. Nessun errore da
# nessuna parte.
#
# MultipleInstances=IgnoreNew: se il processo e' ancora vivo, il giro successivo
# non fa niente. Quindi a regime il costo e' zero, e quando serve il ripristino
# arriva entro un minuto invece che al prossimo riavvio.
$settings.MultipleInstances = 'IgnoreNew'
Register-ScheduledTask -TaskName 'winfleet-vdd' -Action $action -Principal $principal `
    -Settings $settings -Trigger $trigger -Force | Out-Null

# La risurrezione sta in un task A PARTE, e la registra schtasks.
#
# Due strade provate e fallite entrambe con HRESULT 0x80041318: passare due
# trigger insieme a Register-ScheduledTask, e mettere una Repetition su un
# trigger -AtLogOn. schtasks /sc minute invece funziona (lo usa gia' il
# guardiano del cursore).
#
# Il guardiano CONTROLLA prima di avviare, invece di lanciare e sperare.
#
# La prima versione faceva "schtasks /run" a ogni giro, fidandosi di
# MultipleInstances=IgnoreNew per non duplicare. Non funziona: /run avvia
# comunque, e in poche ore si erano accumulate TRE istanze di wf-vdd con OTTO
# monitor virtuali al posto di quattro - il doppio degli schermi, il doppio del
# lavoro per la GPU, e slot che winfleet non usera' mai.
#
# Ora si guarda se un processo wf-vdd e' gia' vivo: se c'e', non si fa niente.
# Il costo a regime e' una query WMI al minuto.
#
# Lo script sta in host/ come tutti gli altri e sale con "winfleet push": uno
# generato qui verrebbe portato via da "winfleet host-clean", che tiene solo i
# file del repo - e il guardiano sparirebbe senza che nessuno se ne accorga.
#
# Con -Count: il guardiano conta gli SCHERMI, non i processi, e deve sapere
# quanti aspettarsene. Un processo vivo che non tiene su nessun monitor e'
# esattamente il caso che ci e' costato diciassette secondi per apertura.
#
# E come utente interattivo: gli schermi si contano solo da dentro la sessione
# grafica - da sessione 0 se ne vede uno solo, e il guardiano rifarebbe il VDD
# ogni minuto per sempre.
#
# Anche il guardiano passa dal lanciatore nascosto, per lo stesso motivo di
# wf-vdd: lanciato come "powershell.exe" apriva una finestra di Windows Terminal
# sul desktop A OGNI MINUTO. Qui si notava meno che con un processo persistente
# (la finestra vive quanto il guardiano e poi sparisce) e proprio per questo era
# peggio: due finestre che compaiono e se ne vanno da sole, senza un motivo
# visibile, mentre uno sta usando il PC.
schtasks /create /tn winfleet-vdd-guard `
    /tr "$HEADLESS $(Arg-Headless "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-vdd-guard.ps1 -Count $Slots")" `
    /sc minute /mo 1 /ru $User /it /f 2>&1 | Out-Null
Write-Host "Task 'winfleet-vdd-guard' registrato: rimette i monitor se cadono"

Write-Host "Task 'winfleet-vdd' registrato: $Slots monitor virtuali" -ForegroundColor Green
Write-Host "Avvia con:  schtasks /run /tn winfleet-vdd     (stato in C:\winfleet\vdd.json)"

# --- agente per il ridimensionamento ------------------------------------------
# Sta nella sessione interattiva perche' deve toccare finestre, e risponde in
# millisecondi: e' la differenza fra un ridimensionamento che segue il trascinamento
# e uno che arriva mezzo secondo dopo.
# L'agente NON passa dal lanciatore nascosto, e non e' una dimenticanza.
#
# Serve elevato (RunLevel Highest, sotto) per mettersi in ascolto su tutte le
# interfacce, e l'elevazione non sopravvive al giro attraverso wscript: il
# processo nasce, non riesce a prendere la porta e muore in silenzio - nel log
# nemmeno una riga, perche' muore prima di aprirlo. Da fuori: "winfleet open"
# smette di funzionare e il doctor dice solo "agente non risponde".
#
# Non e' un problema per il desktop: la sua console resta aperta un istante e
# poi il processo va in ascolto senza scrivere piu' nulla, quindi non c'e' una
# finestra che si guarda addosso come quella del pinger dei monitor. Il costo
# di nasconderla non varrebbe il rischio di lasciare l'agente giu'.
$agentAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-agent.ps1'

# Elevato: mettersi in ascolto su una porta per tutte le interfacce e' un privilegio,
# e senza si otterrebbe un rifiuto di accesso invece di un errore comprensibile.
$agentPrincipal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
# Dopo i monitor: l'agente muove finestre su schermi che devono gia' esistere.
$agentTrigger = New-ScheduledTaskTrigger -AtLogOn -User $User
$agentTrigger.Delay = 'PT30S'
Register-ScheduledTask -TaskName 'winfleet-agent' -Action $agentAction -Principal $agentPrincipal `
    -Settings $settings -Trigger $agentTrigger -Force | Out-Null
Remove-NetFirewallRule -DisplayName 'WinFleet agent' -EA SilentlyContinue
New-NetFirewallRule -DisplayName 'WinFleet agent' -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort 48088 -RemoteAddress @('192.168.0.0/16','100.64.0.0/10') | Out-Null
Write-Host "Agente registrato (winfleet-agent, porta 48088)." -ForegroundColor Green

# --- l'icona nella barra ---------------------------------------------------
# La faccia del sistema sul lato Windows. Nasce da un guasto preciso: l'istanza
# Sunshine dello slot 0 e' morta da sola all'01:00 del 27/08 e non se n'e'
# accorto nessuno per tredici ore, perche' sul PC non c'era niente da guardare.
#
# NON elevata (RunLevel Limited, a differenza dell'agente): un processo elevato
# non puo' mettere icone nella barra di un Explorer che gira senza privilegi -
# l'icona semplicemente non comparirebbe, senza un errore. E non le serve
# nessun privilegio: legge porte su localhost e conta schermi.
$trayAction = New-ScheduledTaskAction -Execute $HEADLESS `
    -Argument (Arg-Headless '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-tray.ps1')
$trayPrincipal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
$trayTrigger = New-ScheduledTaskTrigger -AtLogOn -User $User
# Dopo l'agente: la prima cosa che l'icona controlla e' proprio se lui risponde,
# e dire "agente giu'" nei primi secondi di ogni accensione sarebbe un falso
# allarme che insegna a ignorare l'icona.
$trayTrigger.Delay = 'PT45S'
Register-ScheduledTask -TaskName 'winfleet-tray' -Action $trayAction -Principal $trayPrincipal `
    -Settings $settings -Trigger $trayTrigger -Force | Out-Null

# Promuoverla non e' un vezzo: Windows 11 mette ogni icona nuova nel cassetto
# nascosto dietro la freccetta, e un'icona che nessuno vede non avvisa nessuno.
# Va fatto DOPO che la tray e' partita almeno una volta, perche' prima Windows
# non ha ancora creato la sua voce di registro: si registra il comando e lo si
# lancia piu' avanti.
#
# "2>&1 | Out-Null" e non solo "| Out-Null": un task /sc once con un'ora gia'
# passata fa scrivere a schtasks un AVVISO su stderr, e con
# $ErrorActionPreference = 'Stop' PowerShell tratta qualunque riga su stderr di
# un comando nativo come errore FATALE. Lo script moriva li', dopo aver
# registrato l'agente e prima della tray: nessun messaggio, nessuna eccezione da
# catturare, solo un setup che finiva a meta' - e l'icona nella barra che non
# veniva mai registrata su un host nuovo.
schtasks /create /tn winfleet-tray-show `
    /tr "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-tray-show.ps1" `
    /sc once /st 00:00 /rl limited /f 2>&1 | Out-Null
Write-Host "Icona nella barra registrata (winfleet-tray)." -ForegroundColor Green
