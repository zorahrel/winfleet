<#
.SYNOPSIS
  Registers a Windows app for WinFleet "isolated window" mode.

.DESCRIPTION
  Run on the host (after setup-isolated.ps1). Creates a small launcher .cmd and a
  Sunshine app entry so `winfleet open <name>` on the Mac streams this app alone
  on a dedicated Windows desktop — no taskbar, no other windows.

.EXAMPLE
  .\add-isolated-app.ps1 -Name Blender -Path "C:\Program Files\Blender\blender.exe" -WebPass 'pw'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Path,   # full path to the .exe
    [string]$WebUser = 'admin',
    [Parameter(Mandatory=$true)][string]$WebPass
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Path)) { throw "Eseguibile non trovato: $Path" }

$slug = ($Name -replace '[^A-Za-z0-9]', '').ToLower()
$cmdFile = "C:\winfleet\run-$slug.cmd"

# Launcher: a single path with no arguments, so Sunshine's command parser has
# nothing to trip on. Ends any session still running, then starts this app.
@"
@echo off
schtasks /end /tn winfleet-app >nul 2>&1
timeout /t 1 /nobreak >nul
echo $Path> C:\winfleet\current-app.txt
schtasks /run /tn winfleet-app >nul 2>&1
"@ | Set-Content -Path $cmdFile -Encoding ASCII
Write-Host "Launcher: $cmdFile"

# Teardown: Sunshine runs this when the client disconnects, so the PC always
# returns to the real desktop even if the app is left open.
@"
@echo off
schtasks /end /tn winfleet-app >nul 2>&1
schtasks /run /tn winfleet-reset >nul 2>&1
"@ | Set-Content -Path 'C:\winfleet\stop.cmd' -Encoding ASCII

# Sunshine app entry (auto-detach: keep streaming the display while connected)
$conf = 'C:\Program Files\Sunshine\config\apps.json'
$j = Get-Content $conf -Raw | ConvertFrom-Json
$j.apps = @($j.apps | Where-Object { $_.name -ne $Name })
$j.apps += [pscustomobject]([ordered]@{
    name          = $Name
    cmd           = $cmdFile
    'auto-detach' = $true
    'prep-cmd'    = @([pscustomobject]([ordered]@{ do = ''; undo = 'C:\winfleet\stop.cmd' }))
})
$j | ConvertTo-Json -Depth 8 | Set-Content $conf -Encoding UTF8
Restart-Service SunshineService
Start-Sleep 3

Write-Host "Registrata app isolata: $Name" -ForegroundColor Green
Write-Host "Sul Mac:  winfleet add $slug `"$Name`"  &&  winfleet open $Name"
