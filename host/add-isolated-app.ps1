<#
.SYNOPSIS
  Registers a Windows app for WinFleet "isolated window" mode.

.DESCRIPTION
  Run on the host (after setup-isolated.ps1). Creates a tiny launcher .cmd and a
  Sunshine app entry so `winfleet open <name>` on the Mac opens this app as a
  window that fills the frame.

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

# .cmd (single path, no args → no Sunshine command-parsing issues): writes the
# target exe, then triggers the in-session task.
@"
@echo off
echo $Path> C:\winfleet\current-app.txt
schtasks /run /tn winfleet-app >nul 2>&1
"@ | Set-Content -Path $cmdFile -Encoding ASCII
Write-Host "Launcher: $cmdFile"

# Sunshine app entry (auto-detach: stream the display while the client is connected)
$conf = 'C:\Program Files\Sunshine\config\apps.json'
$j = Get-Content $conf -Raw | ConvertFrom-Json
$j.apps = @($j.apps | Where-Object { $_.name -ne $Name })
$j.apps += [pscustomobject]([ordered]@{ name = $Name; cmd = $cmdFile; 'auto-detach' = $true })
$j | ConvertTo-Json -Depth 8 | Set-Content $conf -Encoding UTF8
Restart-Service SunshineService
Start-Sleep 3

Write-Host "Registrata app isolata: $Name" -ForegroundColor Green
Write-Host "Sul Mac:  winfleet add $slug `"$Name`"  &&  winfleet open $Name"
