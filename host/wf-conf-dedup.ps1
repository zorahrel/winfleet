# Toglie le righe doppie da sunshine.conf, tenendo la prima di ogni chiave.
#
# Nasce da un mio errore: wf-hide-sunshine.ps1 usava "$righe -notmatch ..." per
# chiedere "c'e' gia'?", ma su un ARRAY quell'operatore non risponde vero/falso -
# filtra, e un elenco non vuoto in un if vale VERO. Risultato: "system_tray =
# disabled" aggiunto anche dove c'era gia', due volte in tutte e quattro le
# istanze.
#
# Uno script e non un comando da ssh: fra ssh, cmd e PowerShell le virgolette
# collassano, e un one-liner con dentro regex e backtick e' arrivato di la'
# spezzato - "eseguito senza output" e file invariato. Trappola gia' nota su
# questo progetto (i nomi delle app viaggiano in base64 per lo stesso motivo).
$tocc = @()
Get-ChildItem 'C:\winfleet' -Directory -Filter 'sun*' -EA SilentlyContinue | ForEach-Object {
    $conf = Join-Path $_.FullName 'sunshine.conf'
    if (-not (Test-Path $conf)) { return }
    $righe = Get-Content $conf
    $out = New-Object System.Collections.Generic.List[string]
    $chiavi = New-Object System.Collections.Generic.HashSet[string]
    foreach ($l in $righe) {
        if ($l -match '^\s*([A-Za-z_]+)\s*=') {
            $k = $Matches[1]
            # La PRIMA vince: le righe che winfleet scrive stanno in cima, e una
            # ripetizione in coda e' proprio la spazzatura da togliere.
            if (-not $chiavi.Add($k)) { continue }
        }
        $out.Add($l)
    }
    if ($out.Count -ne $righe.Count) {
        # ASCII e senza BOM: "Set-Content -Encoding UTF8" scrive un BOM e
        # Sunshine SCARTA il file rimettendo i default - trappola gia' pagata,
        # e qui costerebbe la configurazione di tutte le istanze.
        Set-Content -Path $conf -Value $out -Encoding ASCII
        $tocc += "$($_.Name): $($righe.Count) -> $($out.Count) righe"
    }
}
if ($tocc.Count -eq 0) { 'niente da ripulire.' } else { $tocc }
# Il controllo dopo la scrittura: output_name e' il campo che sparisce piu'
# facilmente, e senza quello l'istanza cattura il desktop sbagliato.
Get-ChildItem 'C:\winfleet' -Directory -Filter 'sun*' | ForEach-Object {
    $conf = Join-Path $_.FullName 'sunshine.conf'
    $n = (Select-String -Path $conf -Pattern '^system_tray' | Measure-Object).Count
    $o = (Select-String -Path $conf -Pattern '^output_name' | Measure-Object).Count
    "$($_.Name): system_tray x$n, output_name x$o"
}
