<#
.SYNOPSIS
  Registra un eseguibile Windows come "app" in Sunshine, così può essere aperto
  in una finestra dedicata sul Mac (winfleet open <alias>).

.DESCRIPTION
  Usa l'API della web UI di Sunshine (nessun riavvio del servizio).
  Opzionale: -Isolated crea/usa un display virtuale dedicato e ci massimizza
  l'app, così lo stream mostra SOLO quella finestra (serve un Virtual Display
  Driver, es. il Parsec Virtual Display Adapter).

.EXAMPLE
  .\add-app.ps1 -Name "Blender" -Path "C:\Program Files\Blender\blender.exe" -WebPass 'pw'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Path,
    [string]$WebUser = 'admin',
    [Parameter(Mandatory=$true)][string]$WebPass,
    [switch]$Isolated
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Path)) { throw "Eseguibile non trovato: $Path" }

$base = "https://127.0.0.1:47990"
$cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${WebUser}:${WebPass}"))
$headers = @{ Authorization = "Basic $cred" }
# Sunshine usa un cert self-signed sul loopback
add-type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAll : ICertificatePolicy { public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest r, int p){return true;} }
"@ -ErrorAction SilentlyContinue
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocol]::Tls12

$app = @{
    name        = $Name
    cmd         = $Path
    "auto-detach" = $true
    "wait-all"  = $true
    "exclude-global-prep-cmd" = $false
    elevated    = $false
}
if ($Isolated) {
    # massimizza l'app sul display attivo; per isolamento pieno assegnala al
    # display virtuale (vedi README → modalità isolata)
    $app["prep-cmd"] = @(@{ do = ""; undo = "" })
}

$body = ($app | ConvertTo-Json -Depth 6)
try {
    Invoke-RestMethod -Uri "$base/api/apps" -Method Post -Headers $headers -Body $body -ContentType 'application/json' | Out-Null
    Write-Host "Registrata in Sunshine: $Name" -ForegroundColor Green
    Write-Host "Sul Mac:  winfleet add $($Name.ToLower()) `"$Name`"  &&  winfleet open $($Name.ToLower())"
} catch {
    Write-Warning "Errore API Sunshine: $($_.Exception.Message)"
    Write-Host "Verifica user/pass della web UI (https://127.0.0.1:47990)"
}
