# Riscrive i quattro task di winfleet che lanciavano powershell.exe direttamente
# perche' passino dal lanciatore nascosto (wscript + wf-run-hidden.vbs).
#
# Il perche' sta in wf-instance.ps1: un'attivita' pianificata che avvia
# powershell.exe apre una finestra di Windows Terminal VERA sul desktop, e i due
# guard al minuto la aprivano a ogni giro. Misurato il 03/09/2026 campionando le
# finestre visibili ogni 100 ms dalla sessione grafica: due finestre 1129x635 a
# ogni :02, vive ~14 secondi.
#
# Si riscrivono i task INVECE di rieseguire setup-vdd.ps1 e wf-instance.ps1
# perche' quelli rifanno anche i monitor virtuali e le istanze di Sunshine:
# cambiare come si lancia un guardiano non deve staccare gli schermi a chi sta
# usando il PC.
param(
    [int]$Slots = 4,
    [string]$User = "$env:COMPUTERNAME\$env:USERNAME"
)

# Niente $ErrorActionPreference = 'Stop' globale: al primo giro lo script si e'
# fermato a meta' e i due guard - cioe' proprio quelli che aprivano le finestre -
# sono rimasti come prima. Ogni task si registra da solo e il suo esito va nel log.
$LOG = 'C:\winfleet\task-hidden.log'
function Note($m) { "$(Get-Date -f 'HH:mm:ss')  $m" | Add-Content $LOG }
Note "=== avvio, Slots=$Slots, User=$User ==="

$HEADLESS = 'wscript.exe'
function Arg-Headless([string]$psArgs) {
    # //B = niente finestre di dialogo, //Nologo = niente banner.
    "//B //Nologo C:\winfleet\wf-run-hidden.vbs powershell.exe $psArgs"
}

if (-not (Test-Path 'C:\winfleet\wf-run-hidden.vbs')) {
    Note "ABORT: manca C:\winfleet\wf-run-hidden.vbs (serve 'winfleet push')"
    exit 1
}

# Si cambia SOLO l'azione, con Set-ScheduledTask.
#
# Register-ScheduledTask -Force sui due guard uccideva il processo senza un
# errore: il log si fermava esattamente prima della chiamata, il catch non
# scattava e il task risultava "completato con 0". Ricreare un task ripetuto
# mentre il suo stesso trigger sta girando non e' un'operazione innocua.
#
# Set-ScheduledTask sostituisce l'azione e lascia intatto tutto il resto -
# trigger, ripetizione, principal - che e' esattamente cio' che serve qui: non
# stiamo cambiando QUANDO gira un guardiano, solo COME viene lanciato. Funziona
# anche da ssh (sessione 0), a differenza della registrazione.
function Set-Azione([string]$task, [string]$psArgs) {
    try {
        $t = Get-ScheduledTask -TaskName $task -EA Stop
        $a = New-ScheduledTaskAction -Execute $HEADLESS -Argument (Arg-Headless $psArgs) -EA Stop
        Set-ScheduledTask -TaskName $task -Action $a -EA Stop | Out-Null
        $now = (Get-ScheduledTask -TaskName $task).Actions[0].Execute
        if ($now -ne $HEADLESS) { Note "FAIL ${task}: exec e' ancora $now"; return }
        Note "ok   $task"
    } catch { Note "FAIL ${task}: $_" }
}

Set-Azione 'winfleet-cursor-hide'    '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-cursor.ps1 -Action hide'
Set-Azione 'winfleet-cursor-restore' '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-cursor.ps1 -Action restore'
Set-Azione 'winfleet-cursor-guard'   '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-cursor.ps1 -Action guard'
Set-Azione 'winfleet-vdd-guard'      "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-vdd-guard.ps1 -Count $Slots"

Note "--- come sono adesso ---"
foreach ($n in @('winfleet-cursor-hide','winfleet-cursor-restore','winfleet-cursor-guard','winfleet-vdd-guard')) {
    $t = Get-ScheduledTask -TaskName $n -EA SilentlyContinue
    if (-not $t) { Note "$n MANCA"; continue }
    $rep = ($t.Triggers | ForEach-Object { $_.Repetition.Interval }) -join ','
    Note ("{0} -> {1} (rep={2})" -f $n, $t.Actions[0].Execute, $rep)
}
Note "=== fine ==="
