<#
.SYNOPSIS
  Registers the WinFleet virtual-monitor manager as a scheduled task.

.DESCRIPTION
  wf-vdd.ps1 must run inside the logged-in session: plugging a monitor works from
  anywhere, but reading and setting display modes only sees the console session's
  screens, so a remote shell (session 0) would find nothing to configure.

.PARAMETER Slots
  How many virtual monitors to keep plugged — this is the ceiling on how many app
  windows can be streamed at once.

.EXAMPLE
  .\setup-vdd.ps1 -Slots 2
#>
[CmdletBinding()]
param(
    [int]$Slots  = 2,
    [string]$User = "$env:COMPUTERNAME\$env:USERNAME"
)
$ErrorActionPreference = 'Stop'

$arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-vdd.ps1 ' +
       "-Count $Slots"
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
# Niente -RestartCount qui: senza un trigger registrato rende il task invalido
# e Task Scheduler lo fa fallire con risultato 1 senza eseguire nulla.
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'winfleet-vdd' -Action $action -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Task 'winfleet-vdd' registrato: $Slots monitor virtuali" -ForegroundColor Green
Write-Host "Avvia con:  schtasks /run /tn winfleet-vdd     (stato in C:\winfleet\vdd.json)"

# --- agente per il ridimensionamento ------------------------------------------
# Sta nella sessione interattiva perche' deve toccare finestre, e risponde in
# millisecondi: e' la differenza fra un ridimensionamento che segue il trascinamento
# e uno che arriva mezzo secondo dopo.
$agentAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-agent.ps1'
# Elevato: mettersi in ascolto su una porta per tutte le interfacce e' un privilegio,
# e senza si otterrebbe un rifiuto di accesso invece di un errore comprensibile.
$agentPrincipal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName 'winfleet-agent' -Action $agentAction -Principal $agentPrincipal `
    -Settings $settings -Force | Out-Null
Remove-NetFirewallRule -DisplayName 'WinFleet agent' -EA SilentlyContinue
New-NetFirewallRule -DisplayName 'WinFleet agent' -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort 48088 -RemoteAddress @('192.168.0.0/16','100.64.0.0/10') | Out-Null
Write-Host "Agente registrato (winfleet-agent, porta 48088)." -ForegroundColor Green
