<#
.SYNOPSIS
  Enables WinFleet "isolated window" mode on the host: one Windows app streamed
  alone, on a dedicated desktop — no taskbar, no other windows.

.DESCRIPTION
  Run once, in PowerShell as Administrator, after setup.ps1. It installs the
  launcher scripts and registers the scheduled tasks they need:

    winfleet-app    starts an app on a dedicated Windows desktop and switches
                    the screen to it (Sunshine then captures only that app)
    winfleet-reset  closes the app and returns the screen to the real desktop

  Both tasks must run *inside* the logged-in session: Sunshine is a service in
  session 0, and neither launching an app nor switching desktops crosses that
  boundary. Register apps afterwards with add-isolated-app.ps1.

.NOTES
  The interactive user must be logged in (a locked screen is fine).
#>
[CmdletBinding()]
param([string]$User = "$env:COMPUTERNAME\$env:USERNAME")

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Esegui in PowerShell come Amministratore.'
}

New-Item -ItemType Directory -Force -Path 'C:\winfleet' | Out-Null
foreach ($f in 'wf-launch.ps1', 'wf-inner.ps1', 'wf-reset.ps1') {
    Copy-Item "$PSScriptRoot\$f" "C:\winfleet\$f" -Force
}
Write-Host 'Launcher installati in C:\winfleet\'

$tasks = @{
    'winfleet-app'   = 'C:\winfleet\wf-launch.ps1'
    'winfleet-reset' = 'C:\winfleet\wf-reset.ps1'
}
foreach ($t in $tasks.GetEnumerator()) {
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $($t.Value)"
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $t.Key -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Task '$($t.Key)' registrato (sessione di $User)"
}

Write-Host 'Modalita isolata pronta.' -ForegroundColor Green
Write-Host "Ora registra un'app:  .\add-isolated-app.ps1 -Name Blender -Path 'C:\...\blender.exe' -WebPass '<pw>'"
