# Prova: lancia tocca.ps1 nella sessione interattiva dell'utente (task una tantum, tolto subito).
$a = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument 'C:\winfleet\wf-run-hidden.vbs powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\winfleet\schermo\prova\tocca.ps1'
$p = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
Register-ScheduledTask -TaskName 'wf-schermo-tocco' -Action $a -Principal $p -Force | Out-Null
Start-ScheduledTask -TaskName 'wf-schermo-tocco'
Start-Sleep -Seconds 3
Unregister-ScheduledTask -TaskName 'wf-schermo-tocco' -Confirm:$false
'tocco inviato'
