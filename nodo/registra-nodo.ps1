# Registra il task "topics-nodo": parte al BOOT, senza accesso e senza password (S4U), e subito.
# S4U = "esegui che l'utente sia connesso o no" senza salvare la password: niente credenziali
# di rete Windows (SMB), ma HTTPS, claude, git e gh (token in %APPDATA%) funzionano: provato il 10/11.
param([string]$Dir = "E:\topics-nodo", [string]$User = "$env:COMPUTERNAME\$env:USERNAME")
$ErrorActionPreference = "Stop"
$arg = "//B //Nologo C:\winfleet\wf-run-hidden.vbs powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Dir\avvia-nodo.ps1"
$a = New-ScheduledTaskAction -Execute "wscript.exe" -Argument $arg
$tr = New-ScheduledTaskTrigger -AtStartup
$pr = New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited
$st = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "topics-nodo" -Action $a -Trigger $tr -Principal $pr -Settings $st -Force | Out-Null
Start-ScheduledTask -TaskName "topics-nodo"
"registrato e avviato"
