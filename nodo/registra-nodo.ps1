# Registra il task "topics-nodo": parte al login dell'utente e subito, senza finestra.
param([string]$Dir = "E:\topics-nodo", [string]$User = "$env:COMPUTERNAME\$env:USERNAME")
$ErrorActionPreference = "Stop"
$arg = "//B //Nologo C:\winfleet\wf-run-hidden.vbs powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Dir\avvia-nodo.ps1"
$a = New-ScheduledTaskAction -Execute "wscript.exe" -Argument $arg
$tr = New-ScheduledTaskTrigger -AtLogOn -User $User
$pr = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
$st = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "topics-nodo" -Action $a -Trigger $tr -Principal $pr -Settings $st -Force | Out-Null
Start-ScheduledTask -TaskName "topics-nodo"
"registrato e avviato"
