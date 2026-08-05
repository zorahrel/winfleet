<#
.SYNOPSIS
  Enables WinFleet "isolated window" mode on the host: one Windows app streamed
  as a window that fills the frame (no desktop around it).

.DESCRIPTION
  Run once, in PowerShell as Administrator, after setup.ps1.
  Creates the plumbing that makes per-app windows work despite Sunshine running
  as a session-0 service:
    - installs the launcher (host\wf-launch.ps1 → C:\winfleet\)
    - registers the `winfleet-app` scheduled task that runs the launcher INSIDE
      the logged-in user's session (so the app shows on the streamed display)
  Then register apps with add-isolated-app.ps1.

.NOTES
  The interactive user must be logged in for the task to run in their session.
#>
[CmdletBinding()]
param([string]$User = "$env:COMPUTERNAME\$env:USERNAME")

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Esegui in PowerShell come Amministratore.'
}

New-Item -ItemType Directory -Force -Path 'C:\winfleet' | Out-Null
Copy-Item "$PSScriptRoot\wf-launch.ps1" 'C:\winfleet\wf-launch.ps1' -Force
Write-Host "Launcher installato in C:\winfleet\"

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-launch.ps1'
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'winfleet-app' -Action $action -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Task 'winfleet-app' registrato (gira nella sessione di $User)" -ForegroundColor Green
Write-Host "Ora registra un'app:  .\add-isolated-app.ps1 -Name Blender -Path 'C:\...\blender.exe' -WebPass '<pw>'"
