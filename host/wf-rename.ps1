<#
.SYNOPSIS
  Renames a WinFleet instance, which is what names the window on the Mac.

.DESCRIPTION
  Moonlight titles the stream window with the name of the host it is streaming
  from — on macOS with that name alone, to match the platform convention
  (app/streaming/session.cpp). The client refreshes it from serverinfo on every
  poll, and serverinfo reports sunshine_name.

  So an instance called "Telegram" gives a Mac window titled "Telegram": the
  window stops looking like a stream and starts looking like the app. Renaming
  means rewriting the config and restarting the instance, which is why it happens
  once when the app opens and not on every resize.

  Pairing survives: identity and paired clients live in state.json, not in the
  name, and Moonlight keys hosts by UUID.

.EXAMPLE
  .\wf-rename.ps1 -Slot 0 -Name 'Telegram'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][int]$Slot,
    [string]$Name = '',
    # Nome in base64: fra ssh, cmd e PowerShell gli apici si perdono e
    # "Microsoft Edge" arriva come due argomenti, di cui il secondo posizionale.
    [string]$NameB64 = ''
)
$ErrorActionPreference = 'Stop'

if ($NameB64) { $Name = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($NameB64)) }
if (-not $Name) { throw 'Serve -Name o -NameB64.' }

$conf = "C:\winfleet\sun$Slot\sunshine.conf"
if (-not (Test-Path $conf)) { throw "Istanza $Slot non configurata ($conf)." }

# Sunshine reads the value up to the end of the line, so anything goes except a
# newline; only the leading and trailing spaces it would keep are trimmed.
$clean = ($Name -replace '[\r\n]', ' ').Trim()
if (-not $clean) { throw 'Nome vuoto.' }

$lines = @(Get-Content $conf)
$cur = ''
foreach ($l in $lines) { if ($l -match '^\s*sunshine_name\s*=\s*(.*)$') { $cur = $Matches[1].Trim() } }
if ($cur -eq $clean) { Write-Host "slot $Slot : gia' '$clean'"; exit 0 }

$out = @()
$seen = $false
foreach ($l in $lines) {
    if ($l -match '^\s*sunshine_name\s*=') { $out += "sunshine_name = $clean"; $seen = $true }
    else { $out += $l }
}
if (-not $seen) { $out += "sunshine_name = $clean" }
# UTF-8 senza BOM: in ASCII un nome con un accento diventa "Gestione attivit?" sulla
# barra del titolo, e col BOM Sunshine scarta il file.
[IO.File]::WriteAllText($conf, ($out -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $false))

& 'C:\winfleet\wf-inst-ctl.ps1' -Slot $Slot -Action restart | Out-Null

# The client only picks up the new name from a serverinfo reply, so hand back a
# started instance and not just a rewritten file.
# .Content di Invoke-WebRequest con -UseBasicParsing e' un Byte[], non una
# stringa: confrontarlo con una espressione regolare NON solleva un errore, non
# corrisponde mai e basta. Il ciclo quindi esauriva sempre tutti i tentativi, e
# ogni rinomina pagava quattordici secondi di attesa inutile - misurati - su una
# istanza che rispondeva gia' dopo un secondo. Era il costo dominante di ogni
# apertura a freddo, ed e' il genere di guasto che non lascia traccia: nessun
# errore, solo lentezza.
$port = 48089 + ($Slot * 100)
$ok = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/serverinfo?uniqueid=winfleet" -UseBasicParsing -TimeoutSec 2
        $txt = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
        if ($txt -match '<hostname>([^<]*)</hostname>' -and $Matches[1] -eq $clean) { $ok = $true; break }
    } catch { }
    Start-Sleep -Milliseconds 200
}
if (-not $ok) { Write-Host "slot $Slot : il nome non risulta ancora applicato" }
Write-Host "slot $Slot : '$clean'"
