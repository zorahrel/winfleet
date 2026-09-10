# wf-powerlog: campiona ogni 5 minuti quanto consuma il PC, e RIMETTE il timeout
# di sospensione quando qualcuno lo azzera.
#
# Il watchdog non e' un edge case teorico: il 30/08/2026 standby-timeout-ac era
# stato messo a 1800s e il 10/09 era di nuovo 0x0 (= mai suspend), su Bilanciato
# E su Prestazioni elevate. Nessuno se n'era accorto per 11 giorni, e nel
# frattempo il PC ha fatto 20 ore filate sveglio con la GPU a 34 W e
# `powercfg /requests` vuoto: nessuno gli chiedeva di restare acceso, gli
# mancava solo il timer. Un campionatore che misura lo spreco senza fermarlo
# sarebbe solo un modo piu' preciso di buttare 0,76 EUR al giorno.
#
# Il task NON deve avere -WakeToRun: un tracker che sveglia il PC per misurare
# quanto dorme falsa la propria misura. Per lo stesso motivo lo stato "sospeso"
# non si scrive: si DEDUCE dal buco fra due campioni (winwatt, lato Mac).
$ErrorActionPreference = 'Continue'
$csv = 'C:\winfleet\power.csv'
$log = 'C:\winfleet\powerlog.log'
New-Item -ItemType Directory -Force -Path 'C:\winfleet' | Out-Null

function Log($m) {
  "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $m" | Add-Content $log
  if ((Get-Item $log -EA SilentlyContinue).Length -gt 512KB) {
    Get-Content $log -Tail 200 | Set-Content $log
  }
}

# --- lettura del timeout di sospensione, a prova di lingua ---------------
# powercfg e' localizzato ("Indice impostazione alimentazione CA corrente" in
# italiano, "Current AC Power Setting Index" in inglese): agganciarsi al testo
# rompe il watchdog il giorno che qualcuno cambia lingua a Windows. I valori
# esadecimali invece escono sempre nello stesso ordine: minima, massima,
# incremento, unita', CA, CC -> il penultimo e' quello che ci interessa.
function Get-StandbyAC {
  $hex = @(powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null |
           Select-String -Pattern '0x[0-9a-fA-F]{8}' -AllMatches |
           ForEach-Object { $_.Matches[0].Value })
  if ($hex.Count -lt 2) { return -1 }
  return [int][Convert]::ToUInt32($hex[-2], 16)
}

$standby = Get-StandbyAC
if ($standby -eq 0) {
  # Bilanciato e Prestazioni elevate: la regressione le aveva azzerate
  # entrambe, e basta che un gioco cambi combinazione per tornare a zero.
  powercfg /setacvalueindex SCHEME_BALANCED SUB_SLEEP STANDBYIDLE 1800 2>$null
  powercfg /setacvalueindex SCHEME_MIN      SUB_SLEEP STANDBYIDLE 1800 2>$null
  powercfg /setactive SCHEME_CURRENT 2>$null
  $standby = Get-StandbyAC
  Log "WATCHDOG: standby era 0 (mai), rimesso a $standby s"
}

# --- campione -------------------------------------------------------------
$gpu = -1; $enc = -1; $watt = -1
$q = & nvidia-smi --query-gpu=utilization.gpu,utilization.encoder,power.draw --format=csv,noheader,nounits 2>$null
if ($q) {
  $p = ($q -split ',') | ForEach-Object { [double]($_.Trim()) }
  if ($p.Count -ge 3) { $gpu = [int]$p[0]; $enc = [int]$p[1]; $watt = [math]::Round($p[2],1) }
}
$cpu = (Get-CimInstance Win32_Processor -EA SilentlyContinue | Measure-Object -Property LoadPercentage -Average).Average
if ($null -eq $cpu) { $cpu = -1 } else { $cpu = [int]$cpu }

if (-not (Test-Path $csv)) { 'ts,gpu,enc,watt,cpu,standby_ac' | Set-Content $csv -Encoding ASCII }
"$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')),$gpu,$enc,$watt,$cpu,$standby" | Add-Content $csv -Encoding ASCII
