<#
.SYNOPSIS
  Sets the one custom resolution the virtual display will accept.

.DESCRIPTION
  The adapter ships 27 fixed modes, the smallest 1280x720. A resized Mac window has
  to land on one of them, so below 1280x720 Windows cannot follow at all and in
  between it lands on the nearest coarse step.

  The driver does read extra resolutions from HKLM\SOFTWARE\Parsec\vdd\<n>
  (width / height / hz) — that is how Parsec's own tool adds them — but its mode table
  stops at 28 entries, so exactly ONE custom resolution fits. Writing a whole ladder
  looks like it works (the registry accepts every key) and then only the first one
  ever shows up: measured twice, with 18 entries and with 2.

  Hence one resolution, replaceable. Pick the size you actually keep a window at.

  New entries are only read when a monitor arrives, so wf-vdd.ps1 is asked to re-plug
  them; the streams on those screens drop for a few seconds.

.EXAMPLE
  .\wf-modes.ps1 -Width 800 -Height 450
  .\wf-modes.ps1 -List
#>
[CmdletBinding()]
param(
    [int]$Width = 0,
    [int]$Height = 0,
    [int]$Hz = 60,
    [switch]$List
)
$ErrorActionPreference = 'Stop'

$root = 'HKLM:\SOFTWARE\Parsec\vdd'
if (-not (Test-Path $root)) { throw "Il driver del monitor virtuale non e' installato ($root assente)." }

function Get-Entries {
    $out = @()
    foreach ($k in Get-ChildItem $root -EA SilentlyContinue) {
        $p = Get-ItemProperty $k.PSPath -EA SilentlyContinue
        if ($p.width -and $p.height) {
            $out += [pscustomobject]@{ Index = [int]($k.PSChildName); W = [int]$p.width; H = [int]$p.height; Hz = [int]$p.hz }
        }
    }
    $out | Sort-Object Index
}

if ($List -or $Width -le 0 -or $Height -le 0) {
    Get-Entries | Format-Table -AutoSize
    if (-not $List) { Write-Host 'Uso: .\wf-modes.ps1 -Width <w> -Height <h>' }
    exit 0
}

# La nostra vive sempre nello stesso posto: cosi' si sostituisce invece di
# accumulare chiavi che il driver poi ignora.
$slot = Join-Path $root '4'
New-Item -Path $slot -Force | Out-Null
New-ItemProperty -Path $slot -Name width  -Value $Width  -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $slot -Name height -Value $Height -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $slot -Name hz     -Value $Hz     -PropertyType DWord -Force | Out-Null

Set-Content 'C:\winfleet\vdd-request.txt' 'replug' -Encoding ASCII
Write-Host "Risoluzione personalizzata: ${Width}x${Height}@$Hz - riaggancio richiesto."
