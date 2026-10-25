# Barra dello schermo del PC, da lanciare sul PC con la schermata mostrata (exit 0 = tutta verde):
#   wf-schermo-ctl status      task Ready|Running e interruttore acceso (flag off: False)
#   Edge dello schermo         presente (la schermata e' davvero mostrata durante le misure)
#   GPU                        mediana su 12 letture (un minuto) <= 5%
#   Edge                       il processo piu' pesante sotto mezzo core
#   powercfg /requests         niente SYSTEM / AWAYMODE / EXECUTION
# Lo «dorme ancora con soglia 3 min» lo prova il Mac (deploy.sh sonno), perche' il PC che dorme non risponde.
$dir = 'C:\winfleet'
$fail = 0
function V($ok, $msg) { if ($ok) { "OK  $msg" } else { "KO  $msg"; $script:fail++ } }
$st = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$dir\wf-schermo-ctl.ps1" status) -join ' '
$st
V ($st -match 'task: (Ready|Running)' -and $st -match 'flag off: False') 'task Ready|Running e interruttore acceso'
# la schermata deve essere sul video prima di misurare: si aspetta fino a 90 s
$t = 0
while ($t -lt 90 -and -not @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -EA SilentlyContinue | Where-Object { $_.CommandLine -like '*schermo\edge-profilo*' }).Count) { Start-Sleep 3; $t += 3 }
$m = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$dir\schermo\prova\misura.ps1") | Select-Object -Last 1
$m
$j = $m | ConvertFrom-Json
V ($j.edge -ge 1) 'schermata mostrata durante le misure'
V (@($j.req).Count -eq 0) 'nessuna richiesta di veglia (SYSTEM/AWAYMODE/EXECUTION)'
V ($j.gpuMed -le 5) "GPU mediana $($j.gpuMed)% (<= 5)"
V ($j.cpuTop.c -lt 0.5) "processo piu' pesante $($j.cpuTop.n) $($j.cpuTop.c) core (< 0,5)"
exit $(if ($fail) { 1 } else { 0 })
