# wf-schermo-ctl: interruttore dello schermo a tutto campo (wf-schermo.ps1).
#   off     = nessuna comparsa e niente in esecuzione: task disattivato e fermato, guardiano e Edge dello
#             schermo chiusi, flag C:\winfleet\schermo.off (anche un avvio a mano non mostra niente)
#   on      = toglie il flag, riattiva il task e lo avvia
#   status  = stato di task, guardiano, Edge e flag
# Da ssh:  powershell -NoProfile -ExecutionPolicy Bypass -File C:\winfleet\wf-schermo-ctl.ps1 off
# Si chiude solo l'Edge col profilo C:\winfleet\schermo\edge-profilo: quello di Attilio non si tocca.
param([Parameter(Mandatory = $true)][ValidateSet('on', 'off', 'status')][string]$Azione)
$flag = 'C:\winfleet\schermo.off'

function Processi {
  $guardiano = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
    Where-Object { $_.CommandLine -like '*wf-schermo.ps1*' -and $_.ProcessId -ne $PID })
  $edge = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -EA SilentlyContinue |
    Where-Object { $_.CommandLine -like '*schermo\edge-profilo*' })
  [pscustomobject]@{ Guardiano = $guardiano; Edge = $edge }
}

switch ($Azione) {
  'off' {
    Set-Content -Path $flag -Value 'spento a mano'
    & schtasks /change /tn wf-schermo /disable 2>&1 | Out-Null
    & schtasks /end /tn wf-schermo 2>&1 | Out-Null
    $p = Processi
    foreach ($x in @($p.Guardiano) + @($p.Edge)) { Stop-Process -Id $x.ProcessId -Force -EA SilentlyContinue }
    $d = Processi
    "off: task disattivato, guardiani rimasti $(@($d.Guardiano).Count), Edge dello schermo rimasti $(@($d.Edge).Count)"
  }
  'on' {
    Remove-Item $flag -Force -EA SilentlyContinue
    & schtasks /change /tn wf-schermo /enable 2>&1 | Out-Null
    & schtasks /run /tn wf-schermo 2>&1 | Out-Null
    'on: task attivato e avviato'
  }
  'status' {
    $t = Get-ScheduledTask -TaskName wf-schermo -EA SilentlyContinue
    $p = Processi
    "task: $(if ($t) { $t.State } else { 'non registrato' }) | guardiano: $(@($p.Guardiano).Count) | Edge schermo: $(@($p.Edge).Count) | flag off: $(Test-Path $flag)"
  }
}
