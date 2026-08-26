# Spegne TUTTI i processi dell'agente winfleet.
#
# Serve a due cose, e nessuna delle due si ottiene con "schtasks /end":
# quel comando chiude il task e lascia vivo il powershell che ci gira dentro.
#
#  1. Al test agent-revive, per spegnere davvero l'agente e vedere se torna.
#     Finche' non lo faceva, il test si arrendeva con uno SKIP e per mesi ha
#     finto di provare qualcosa.
#
#  2. A chi deve rimettere ordine: ogni riavvio lasciava un agente in piu'.
#     Trovati TRE processi vivi insieme il 26/08, avviati alle 00:00, alle
#     12:39 e alle 19:19, tutti convinti di essere l'agente. Solo uno tiene la
#     porta; gli altri girano nel ciclo "porta occupata, aspetto" e, quando la
#     porta si libera per un istante, rispondono al posto suo - da fuori
#     l'agente sembra muto a tratti, senza una ragione visibile.
#
# Il filtro e' sulla RIGA DI COMANDO, non sul nome: fermare "powershell.exe"
# ucciderebbe qualsiasi script di chiunque stia usando il PC in quel momento.
param([switch]$WhatIfOnly)
$ErrorActionPreference = 'Continue'

$agenti = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
            Where-Object { $_.CommandLine -like '*wf-agent.ps1*' })

if (-not $agenti) { Write-Output 'nessun agente in esecuzione'; exit 0 }

foreach ($a in $agenti) {
  if ($WhatIfOnly) { Write-Output "spegnerei: pid=$($a.ProcessId)"; continue }
  try {
    Stop-Process -Id $a.ProcessId -Force -EA Stop
    Write-Output "spento: pid=$($a.ProcessId)"
  } catch {
    Write-Output "ERRORE su pid=$($a.ProcessId): $($_.Exception.Message)"
  }
}
