# Prova: cosa tiene sveglio il PC con lo schermo mostrato. Scrive una riga JSON.
#   edge    = processi Edge col profilo dello schermo
#   req     = richieste di alimentazione SYSTEM/AWAYMODE/EXECUTION (quelle che contano per wf-autosleep)
#   reqTutte= tutto powercfg /requests su una riga
#   gpuMed  = mediana della GPU su N letture a 5 s (default 12 = un minuto)
#   cpuTop  = il processo piu' pesante su 5 s, in core (wf-autosleep lo conta come lavoro da 0,5)
param([int]$Letture = 12)
$edge = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -EA SilentlyContinue | Where-Object { $_.CommandLine -like '*schermo\edge-profilo*' }).Count
$sez = -1; $req = @()
$tutte = (powercfg /requests 2>$null)
foreach ($r in $tutte) {
  if ($r -match '^\S+:\s*$') { $sez++; continue }
  if ($r -like '[[]*' -and $sez -in 1, 2, 3) { $req += $r.Trim() }
}
$g = @()
for ($i = 0; $i -lt $Letture; $i++) {
  $q = & nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1
  $g += [int]("$q".Trim()); if ($i -lt $Letture - 1) { Start-Sleep -Seconds 5 }
}
$ord = @($g | Sort-Object); $med = $ord[[int]($ord.Count / 2)]
$t0 = @{}; Get-Process | ForEach-Object { if ($_.TotalProcessorTime) { $t0[$_.Id] = $_.TotalProcessorTime.TotalSeconds } }
Start-Sleep -Seconds 5
$top = Get-Process | Where-Object { $_.Id -ne $PID -and $_.Name -ne 'Idle' -and $t0.ContainsKey($_.Id) -and $_.TotalProcessorTime } |
  ForEach-Object { [pscustomobject]@{ n = $_.Name; c = [math]::Round(($_.TotalProcessorTime.TotalSeconds - $t0[$_.Id]) / 5, 2) } } |
  Sort-Object c -Descending | Select-Object -First 1
[ordered]@{ edge = $edge; req = @($req); reqTutte = (($tutte | Where-Object { $_.Trim() }) -join ' | '); gpuMed = $med; gpu = @($g); cpuTop = $top } | ConvertTo-Json -Compress
