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

$arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-vdd.ps1 ' +
       "-Count $Slots"
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
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
schtasks /create /tn winfleet-vdd-guard `
    /tr "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-vdd-guard.ps1" `
    /sc minute /mo 1 /f | Out-Null
Write-Host "Task 'winfleet-vdd-guard' registrato: rimette i monitor se cadono"

Write-Host "Task 'winfleet-vdd' registrato: $Slots monitor virtuali" -ForegroundColor Green
Write-Host "Avvia con:  schtasks /run /tn winfleet-vdd     (stato in C:\winfleet\vdd.json)"

# --- agente per il ridimensionamento ------------------------------------------
# Sta nella sessione interattiva perche' deve toccare finestre, e risponde in
# millisecondi: e' la differenza fra un ridimensionamento che segue il trascinamento
# e uno che arriva mezzo secondo dopo.
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
