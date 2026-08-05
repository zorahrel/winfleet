<#
.SYNOPSIS
  WinFleet host setup — configura Sunshine sul PC Windows per lo streaming a
  finestra verso il Mac, a piena GPU (NVENC), riusando la sessione attiva.

.DESCRIPTION
  Da eseguire una volta, in PowerShell come Amministratore.
  - imposta le credenziali della web UI di Sunshine (per pairing via API)
  - configura l'encoder hardware (NVENC/AMF/QuickSync a seconda della GPU)
  - apre il firewall per Sunshine solo su LAN + Tailscale
  - avvia il servizio

.EXAMPLE
  .\setup.ps1 -WebUser admin -WebPass 'ScegliUnaPassword'
#>
[CmdletBinding()]
param(
    [string]$WebUser = 'admin',
    [Parameter(Mandatory=$true)][string]$WebPass,
    [int]$Fps = 60
)
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Esegui in PowerShell come Amministratore.'
}

$dir = 'C:\Program Files\Sunshine'
$exe = Join-Path $dir 'sunshine.exe'
if (-not (Test-Path $exe)) {
    Write-Host 'Sunshine non trovato. Installo con winget…' -ForegroundColor Yellow
    winget install LizardByte.Sunshine --accept-package-agreements --accept-source-agreements --disable-interactivity
}

# GPU → encoder
$gpu = (Get-CimInstance Win32_VideoController).Name -join ' '
$encoder = if ($gpu -match 'NVIDIA|GeForce|RTX|GTX') { 'nvenc' }
           elseif ($gpu -match 'AMD|Radeon') { 'amdvce' }
           elseif ($gpu -match 'Intel') { 'quicksync' }
           else { 'software' }
Write-Host "GPU: $gpu  →  encoder: $encoder"

# stop, configura, riavvia
Stop-Service SunshineService -ErrorAction SilentlyContinue
Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 2

& $exe --creds $WebUser $WebPass | Out-Null
Write-Host "Credenziali web UI impostate ($WebUser)"

$conf = Join-Path $dir 'config\sunshine.conf'
@(
  "encoder = $encoder",
  'nvenc_preset = 1',
  'nvenc_twopass = quarter_res',
  "fps = [30,60,90,120]",
  'resolutions = [1280x720,1920x1080,2560x1440,3840x2160]',
  'channels = 2',
  'gamepad = disabled'
) | Set-Content -Path $conf -Encoding UTF8
Write-Host "sunshine.conf scritto"

# firewall: solo LAN + Tailscale
$nets = @('192.168.0.0/16','100.64.0.0/10')
Get-NetFirewallRule -DisplayName 'WinFleet Sunshine*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'WinFleet Sunshine TCP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 47984,47989,47990,48010 -RemoteAddress $nets | Out-Null
New-NetFirewallRule -DisplayName 'WinFleet Sunshine UDP' -Direction Inbound -Action Allow -Protocol UDP -LocalPort 47998,47999,48000,48002 -RemoteAddress $nets | Out-Null
Write-Host "Firewall aperto (LAN + Tailscale)"

Start-Service SunshineService
Start-Sleep 3
Write-Host ("Servizio Sunshine: {0}" -f (Get-Service SunshineService).Status) -ForegroundColor Green

$ts  = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '100.*' } | Select-Object -First 1).IPAddress
$lan = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1).IPv4Address.IPAddress
Write-Host ''
Write-Host 'Sul Mac configura WinFleet con questi indirizzi:' -ForegroundColor Cyan
Write-Host ("  Tailscale : {0}" -f $ts)
Write-Host ("  LAN       : {0}" -f $lan)
Write-Host '  winfleet setup   (inserisci gli indirizzi)   poi   winfleet pair'
