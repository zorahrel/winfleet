# wf-idleguard: impedisce la sospensione SOLO quando c'e' attivita' vera.
# Serve perche' l'input di uno stream (Parsec/Sunshine) e' INIETTATO: non
# resetta l'idle timer di Windows, quindi il PC si sospenderebbe in partita.
#
# Il task va lanciato da wf-run-hidden.vbs, non da powershell.exe: un'attivita'
# pianificata che avvia powershell alloca una console, e con Windows Terminal
# predefinito quella console e' una finestra vera. Qui restava minimizzata
# invece che sul desktop, quindi non dava fastidio - ma era CHIUDIBILE, e
# chiuderla spegne il guardiano: il PC torna a sospendersi in mezzo a una
# partita, che e' esattamente il difetto per cui questo script esiste.
# (Come wf-vdd e wf-tray. L'agente invece resta su powershell: attraverso
# wscript perde l'elevazione che gli serve per ascoltare sulla rete.)
$sig = @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
$K = Add-Type -MemberDefinition $sig -Name Pwr -Namespace WF -PassThru
$CONTINUOUS = 0x80000000; $SYSTEM = 0x00000001; $DISPLAY = 0x00000002

$log = "C:\winfleet\idleguard.log"
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
function Log($m) {
  "$((Get-Date).ToString('HH:mm:ss')) $m" | Add-Content $log
  if ((Get-Item $log -EA SilentlyContinue).Length -gt 1MB) {
    Get-Content $log -Tail 300 | Set-Content $log
  }
}

function Is-Active {
  # 1) GPU sotto carico: gioco o rendering. Idle misurato = 1%, 39W.
  # Baseline misurato a riposo su 20 campioni: gpu max 8%, enc 0%.
  # I WATT sono inutilizzabili come segnale: a riposo spikano a 127W (2/20
  # campioni sopra 80W) e terrebbero il PC sveglio per sempre.
  # Un singolo campione alto non basta (letto 40% con la GPU ferma): due di fila.
  $q = & nvidia-smi --query-gpu=utilization.gpu,utilization.encoder --format=csv,noheader,nounits 2>$null
  if ($q) {
    $p = $q -split ',' | ForEach-Object { [double]($_.Trim()) }
    if ($p[0] -ge 20 -or $p[1] -ge 5) {
      Start-Sleep -Seconds 3
      $q2 = & nvidia-smi --query-gpu=utilization.gpu,utilization.encoder --format=csv,noheader,nounits 2>$null
      $p2 = $q2 -split ',' | ForEach-Object { [double]($_.Trim()) }
      if ($p2[0] -ge 20 -or $p2[1] -ge 5) { return "gpu=$($p2[0])% enc=$($p2[1])%" }
    }
  }
  # 2) Stream davvero connesso (Parsec 8000-8010 / Sunshine 47989+, 48089+).
  $c = Get-NetTCPConnection -State Established -EA SilentlyContinue |
       Where-Object { $_.RemoteAddress -notlike '127.*' -and
                      ($_.LocalPort -in 8000..8010 -or $_.LocalPort -in 47984..48500) }
  if ($c) { return "stream porta $($c[0].LocalPort)" }
  # 3) Coda ComfyUI non vuota: un job in corso non va interrotto.
  try {
    $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8188/prompt' -TimeoutSec 2 -EA Stop
    if ($r.exec_info.queue_remaining -gt 0) { return "comfyui $($r.exec_info.queue_remaining) job" }
  } catch {}
  return $null
}

$held = $false
while ($true) {
  $why = Is-Active
  if ($why) {
    # ES_CONTINUOUS tiene sveglio finche' non lo rilasciamo.
    $K::SetThreadExecutionState($CONTINUOUS -bor $SYSTEM -bor $DISPLAY) | Out-Null
    if (-not $held) { Log "TIENI SVEGLIO: $why"; $held = $true }
  } else {
    if ($held) {
      $K::SetThreadExecutionState($CONTINUOUS) | Out-Null   # rilascia
      Log "RILASCIO: nessuna attivita', il timer di 30 min riparte"
      $held = $false
    }
  }
  Start-Sleep -Seconds 30
}

