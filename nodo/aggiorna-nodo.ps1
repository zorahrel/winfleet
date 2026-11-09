# Aggiorna il nodo Topics alla versione data e lo riavvia. Lo lancia il task pianificato
# "topics-nodo-aggiorna" (Interactive, creato da pc-nodo-prep): via ssh l'installer NSIS fallisce muto.
param([Parameter(Mandatory = $true)][string]$Version, [string]$Dir = "E:\topics-nodo")
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Dir\installa.ps1" -Version $Version -Dir $Dir
$rc = $LASTEXITCODE
# installa.ps1 ferma topics-server: il nodo riparte dal suo task, aggiornato o no.
Start-ScheduledTask -TaskName "topics-nodo"
"$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) aggiorna $Version exit $rc" | Add-Content "$Dir\logs\aggiorna.log"
exit $rc
