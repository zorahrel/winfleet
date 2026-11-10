# Registra e avvia la gabbia delle card (card-jail.ps1) come task "topics-card-jail":
# all'accesso, senza finestra, stesso utente dei CLI delle card, elevato: i processi nati da ssh sono elevati e un job Limited non li apre (OpenProcess 5).
$u = "$env:COMPUTERNAME\$env:USERNAME"
$a = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '//B //Nologo C:\winfleet\wf-run-hidden.vbs powershell.exe -NoProfile -ExecutionPolicy Bypass -File E:\topics-nodo\card-jail.ps1'
$t = New-ScheduledTaskTrigger -AtLogOn -User $u
$pr = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Highest
$st = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'topics-card-jail' -Action $a -Trigger $t -Principal $pr -Settings $st -Force | Out-Null
Start-ScheduledTask -TaskName 'topics-card-jail'
'registrato'
