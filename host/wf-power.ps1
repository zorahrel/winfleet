<#
.SYNOPSIS
  Spegne o riaccende TUTTO winfleet sull'host, in un colpo solo.

.DESCRIPTION
  Nasce da un guasto del 05/09/2026: chi usava il PC davanti al monitor aveva una
  finestra che non si chiudeva e non vedeva piu' le finestre che apriva. Non era
  un difetto di Windows. Erano i monitor virtuali di winfleet: con quattro schermi
  fantasma attaccati, lo schermo PRIMARIO era diventato uno di quelli - `WinDisc`
  1024x768 - e Windows apre le finestre nuove sul primario. Nascevano su uno
  schermo che nessuno guarda, in una risoluzione che nessuno ha.

  Il rimedio esisteva a pezzi: `winfleet stop` chiude gli STREAM, e basta. I
  monitor virtuali, le quattro istanze Sunshine, l'agente e l'icona nella barra
  restavano su, cioe' restava su esattamente cio' che causa il guasto. Rimetterlo
  a posto voleva dire tredici comandi a mano e ricordarseli tutti.

  L'ordine dello spegnimento non e' arbitrario:

    1. i cursori di sistema, PRIMA di tutto. wf-cursor.ps1 li sostituisce con
       cursori vuoti mentre si trasmette; se si spegne il guardiano prima di
       ripristinarli, il PC resta senza puntatore e nessun indizio porta a
       winfleet (successo davvero: quattro giorni).
    2. i task, disabilitati e non solo fermati. `schtasks /end` chiude il task e
       lascia vivo il powershell che ci gira dentro, e al login successivo un
       task solo fermato riparte: si riaccenderebbe da solo la cosa appena spenta.
    3. i processi, per RIGA DI COMANDO. Fermare "powershell.exe" ucciderebbe
       qualunque script di chi sta usando il PC in quel momento.
    4. i monitor virtuali NON si staccano a mano. Chiamare REMOVE sul driver
       lascia il VDD in uno stato in cui rifiuta anche le aggiunte successive
       ("Nessun monitor virtuale collegato"): provato e misurato. Li stacca il
       watchdog del driver da solo quando smette di ricevere il ping, cioe'
       quando wf-vdd.ps1 muore - punto 3.

  Cosa NON tocca, di proposito: `wf-idleguard` (senza, il PC si sospende in mezzo
  a una partita in streaming) e `wf-nolock` (senza, la sessione si blocca da
  sola). Sono guardiani del PC, non di winfleet.

.PARAMETER Action
  off | on | status

.EXAMPLE
  powershell -File wf-power.ps1 -Action off
  powershell -File wf-power.ps1 -Action status
#>
[CmdletBinding()]
param([ValidateSet('off','on','status')][string]$Action = 'status')

# Niente 'Stop' globale: qui si spengono dieci cose indipendenti, e la prima che
# non c'e' piu' (un task gia' tolto, un processo gia' morto) fermerebbe tutte le
# altre a meta'. Un guasto lasciato a meta' spegnimento e' peggio di nessuno
# spegnimento: si resta con i monitor virtuali attaccati e senza chi li governa.
$ErrorActionPreference = 'Continue'
$LOG = 'C:\winfleet\power.log'
function Note($m) { "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  $m" | Add-Content $LOG -EA SilentlyContinue }

# I task di winfleet, quelli che si spengono e si riaccendono.
# wf-idleguard e wf-nolock NON sono qui: vedi sopra.
$TASKS = @(
  'winfleet-agent', 'winfleet-tray', 'winfleet-vdd', 'winfleet-vdd-guard',
  'winfleet-cursor-guard',
  'winfleet-sun0', 'winfleet-sun1', 'winfleet-sun2', 'winfleet-sun3',
  'winfleet-place0', 'winfleet-place1', 'winfleet-place2', 'winfleet-place3'
)

# I processi si riconoscono dalla riga di comando, mai dal nome: con
# "conhost --headless" (che i task usano per non lasciare console sul desktop)
# il processo si chiama conhost.exe. Gia' costato quattro monitor staccati.
$PROC_PAT = 'wf-agent\.ps1|wf-tray\.ps1|wf-vdd\.ps1|wf-vdd-guard\.ps1|wf-cursor\.ps1|wf-place\.ps1'

function Stop-WFProcs {
  $n = 0
  foreach ($p in @(Get-CimInstance Win32_Process -EA SilentlyContinue |
                   Where-Object { $_.CommandLine -match $PROC_PAT })) {
    try { Stop-Process -Id $p.ProcessId -Force -EA Stop; $n++; Note "  ucciso pid=$($p.ProcessId)" }
    catch { Note "  ERRORE su pid=$($p.ProcessId): $($_.Exception.Message)" }
  }
  $n
}

function Get-WFStatus {
  $o = [ordered]@{}
  $att = @($TASKS | ForEach-Object {
    $t = Get-ScheduledTask -TaskName $_ -EA SilentlyContinue
    if ($t -and $t.State -ne 'Disabled') { $_ }
  })
  $o.task_attivi = $att.Count
  $o.task_totali = $TASKS.Count
  $o.sunshine    = @(Get-Process sunshine -EA SilentlyContinue).Count
  $o.processi    = @(Get-CimInstance Win32_Process -EA SilentlyContinue |
                     Where-Object { $_.CommandLine -match $PROC_PAT }).Count
  # I monitor virtuali si contano da quanti schermi vede la SESSIONE, non dal
  # driver: il driver resta installato sempre, e "installato" non vuol dire
  # "attaccato".
  #
  # Ma da una shell SSH questo script gira in SESSIONE 0, e la sessione 0 non
  # enumera gli schermi veri: risponde con un display fantasma ("WinDisc
  # 1024x768") che non e' quello che vede chi sta davanti al monitor. Leggerlo
  # da li' e dirlo come se fosse lo stato del PC e' peggio che tacere - e' la
  # misura sbagliata che ha fatto sembrare il guasto irreparabile. Se non siamo
  # nella sessione grafica, lo si dichiara.
  $sess = (Get-Process -Id $PID).SessionId
  if ($sess -eq 0) {
    $o.schermi  = 'n/d (sessione 0)'
    $o.primario = 'n/d (sessione 0: gli schermi si vedono solo dalla sessione grafica)'
  } else {
    Add-Type -AssemblyName System.Windows.Forms -EA SilentlyContinue
    try {
      $s = @([System.Windows.Forms.Screen]::AllScreens)
      $o.schermi = $s.Count
      $o.primario = ($s | Where-Object { $_.Primary } | ForEach-Object { "$($_.DeviceName) $($_.Bounds.Width)x$($_.Bounds.Height)" }) -join ''
    } catch { $o.schermi = -1; $o.primario = 'non leggibile' }
  }
  $o
}

switch ($Action) {

  'status' {
    $s = Get-WFStatus
    $s.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }
  }

  'off' {
    Note '=== OFF ==='

    # 1. I cursori di sistema, prima di spegnere chi li rimetterebbe.
    try {
      & 'C:\winfleet\wf-cursor.ps1' -Action restore
      Note 'cursori ripristinati'
      Write-Output 'cursori di sistema ripristinati'
    } catch { Note "cursori: $($_.Exception.Message)" }

    # 2. I task: fermati E disabilitati, o al prossimo login tornano su.
    $dis = 0
    foreach ($t in $TASKS) {
      $task = Get-ScheduledTask -TaskName $t -EA SilentlyContinue
      if (-not $task) { continue }
      try { Stop-ScheduledTask -TaskName $t -EA SilentlyContinue } catch { }
      try { Disable-ScheduledTask -TaskName $t -EA Stop | Out-Null; $dis++ }
      catch { Note "task $t : $($_.Exception.Message)" }
    }
    Write-Output "$dis task disabilitati (su $($TASKS.Count))"
    Note "$dis task disabilitati"

    # 3. Le istanze Sunshine. Qui il nome basta: sunshine.exe e' solo nostro,
    #    winfleet lo porta in C:\winfleet\engine e non e' installato sul PC.
    $sun = @(Get-Process sunshine -EA SilentlyContinue)
    if ($sun.Count) { $sun | Stop-Process -Force -EA SilentlyContinue }
    Write-Output "$($sun.Count) istanze Sunshine chiuse"
    Note "$($sun.Count) sunshine chiuse"

    # 4. I processi guardiani. Morto wf-vdd, il driver stacca i monitor da solo.
    $np = Stop-WFProcs
    Write-Output "$np processi winfleet fermati"

    # Il driver stacca i monitor entro ~100ms dal mancato ping, ma il conteggio
    # della sessione si aggiorna qualche istante dopo: senza attesa lo stato
    # finale direbbe "4 schermi" su un PC che ne ha gia' uno solo.
    Start-Sleep -Seconds 3
    $s = Get-WFStatus
    Write-Output "stato: schermi=$($s.schermi) primario=$($s.primario)"
    Note "OFF fatto: $($s | Out-String)"
  }

  'on' {
    Note '=== ON ==='
    $en = 0
    foreach ($t in $TASKS) {
      $task = Get-ScheduledTask -TaskName $t -EA SilentlyContinue
      if (-not $task) { Note "task $t non registrato"; continue }
      try { Enable-ScheduledTask -TaskName $t -EA Stop | Out-Null; $en++ }
      catch { Note "task $t : $($_.Exception.Message)" }
    }
    Write-Output "$en task riabilitati (su $($TASKS.Count))"

    # I task ad AtLogOn non ripartono da soli quando li si riabilita: il loro
    # trigger e' gia' passato. Vanno avviati, e nell'ordine giusto - senza i
    # monitor virtuali le istanze Sunshine non hanno niente da catturare.
    foreach ($t in @('winfleet-vdd', 'winfleet-agent', 'winfleet-tray',
                     'winfleet-vdd-guard', 'winfleet-cursor-guard')) {
      try { Start-ScheduledTask -TaskName $t -EA SilentlyContinue } catch { }
    }
    Start-Sleep -Seconds 4
    foreach ($t in @('winfleet-sun0','winfleet-sun1','winfleet-sun2','winfleet-sun3')) {
      try { Start-ScheduledTask -TaskName $t -EA SilentlyContinue } catch { }
    }
    Start-Sleep -Seconds 3
    $s = Get-WFStatus
    Write-Output "stato: sunshine=$($s.sunshine) processi=$($s.processi) schermi=$($s.schermi)"
    Note "ON fatto: $($s | Out-String)"
  }
}
