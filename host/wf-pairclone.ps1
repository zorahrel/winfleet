# Copia il client gia' accoppiato dallo slot 0 agli altri.
#
# Il pairing di Moonlight e' un certificato salvato nello stato di Sunshine: farlo a
# mano significa aprire la GUI e digitare un PIN per OGNI istanza, e le istanze sono
# una per finestra. Copiare il certificato ottiene lo stesso risultato senza
# cerimonia: la fiducia e' gia' stata concessa a questo client, e le istanze sono
# processi diversi dello stesso PC.
param([int]$From = 0, [int[]]$To = @(1,2,3))

$src = "C:\winfleet\sun$From\state.json"
if (-not (Test-Path $src)) { Write-Output "sorgente assente: $src"; exit 1 }
$s = Get-Content $src -Raw | ConvertFrom-Json
if (-not $s.root -or -not $s.root.named_devices) { Write-Output "lo slot $From non ha client accoppiati"; exit 1 }

foreach ($i in $To) {
    $dst = "C:\winfleet\sun$i\state.json"
    if (-not (Test-Path $dst)) { Write-Output "slot ${i}: assente"; continue }
    $d = Get-Content $dst -Raw | ConvertFrom-Json
    # uniqueid resta quello dell'istanza: e' l'identita' del SERVER, non del client,
    # e due server con lo stesso id si confondono fra loro nella lista di Moonlight.
    $keep = if ($d.root -and $d.root.uniqueid) { $d.root.uniqueid } else { [guid]::NewGuid().ToString().ToUpper() }
    $d | Add-Member -NotePropertyName root -NotePropertyValue ([pscustomobject]@{
        uniqueid      = $keep
        named_devices = $s.root.named_devices
    }) -Force
    $d | ConvertTo-Json -Depth 12 | Set-Content $dst -Encoding UTF8
    Write-Output "slot ${i}: accoppiato ($($s.root.named_devices.Count) client)"
}
