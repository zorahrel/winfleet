<#
.SYNOPSIS
  Starts, stops and inspects a WinFleet Sunshine instance.

.DESCRIPTION
  Sunshine is a console program. Run straight from a scheduled task it owns a console,
  and when that console goes away — a remote shell disconnecting is enough — Sunshine
  gets CTRL_CLOSE and shuts itself down mid-session. So the task only launches it,
  detached and hidden, and lifetime is managed here by process instead: each instance
  is identified by the config file on its command line.

.EXAMPLE
  .\wf-inst-ctl.ps1 -Slot 0 -Action restart
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][int]$Slot,
    [ValidateSet('start','stop','restart','status')][string]$Action = 'status',
    # Usato dal task pianificato: avvia davvero il processo invece di delegare.
    [switch]$Direct
)
$ErrorActionPreference = 'Stop'

$exe  = 'C:\Program Files\Sunshine\sunshine.exe'
$conf = "C:\winfleet\sun$Slot\sunshine.conf"

function Get-Instance {
    Get-CimInstance Win32_Process -Filter "Name='sunshine.exe'" -EA SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains("sun$Slot\sunshine.conf") }
}

function Stop-Instance {
    foreach ($p in @(Get-Instance)) { Stop-Process -Id $p.ProcessId -Force -EA SilentlyContinue }
    for ($i = 0; $i -lt 20 -and @(Get-Instance).Count -gt 0; $i++) { Start-Sleep -Milliseconds 250 }
}

function Start-Instance {
    if (@(Get-Instance).Count -gt 0) { return }
    if (-not (Test-Path $conf)) { throw "Istanza $Slot non configurata ($conf)." }
    if ($Direct) {
        # Working directory obbligatoria: gli shader DirectX sono caricati per
        # percorso relativo e senza di essa Sunshine muore in avvio.
        Start-Process -FilePath $exe -ArgumentList "`"$conf`"" `
            -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Hidden
    } else {
        # Deve nascere nella sessione interattiva: avviata da una shell remota
        # finirebbe in sessione 0, dove non vede schermi e non puo' aprire finestre.
        schtasks /run /tn "winfleet-sun$Slot" | Out-Null
    }
    for ($i = 0; $i -lt 60 -and @(Get-Instance).Count -eq 0; $i++) { Start-Sleep -Milliseconds 250 }
}

switch ($Action) {
    'start'   { Start-Instance }
    'stop'    { Stop-Instance }
    'restart' { Stop-Instance; Start-Instance }
}

$p = @(Get-Instance)
if ($p.Count -gt 0) { Write-Host "slot $Slot : attiva (pid $($p[0].ProcessId))" }
else                { Write-Host "slot $Slot : ferma" }
