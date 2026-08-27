# Sunshine e' un dettaglio interno: non deve farsi vedere da nessuna parte.
#
# winfleet ci gira sopra - e' il motore che cattura lo schermo e codifica in
# NVENC - quindi disinstallarlo spegnerebbe tutto. Ma chi usa il PC non deve
# incontrarlo mai: niente icona nella barra (ne verrebbero QUATTRO, una per
# istanza), niente servizio che parte da solo, niente voce nel menu Start che
# invita ad aprire una web UI da cui si puo' solo rompere la configurazione.
# L'unica faccia visibile del sistema e' l'icona di winfleet.
#
# Elenca cosa trova e cosa ha fatto, invece di lavorare in silenzio: "ho
# nascosto Sunshine" senza dire dove significa non poter piu' verificare niente.
$fatto = @()
$visto = @()

# --- il servizio -----------------------------------------------------------
# L'installer di Sunshine registra un servizio che parte all'avvio e prende la
# porta 47990. winfleet non lo usa: le sue istanze sono processi separati con
# porte proprie (48089+). Lasciarlo acceso vuol dire un Sunshine in piu' che
# cattura lo schermo, con la sua icona e le sue notifiche.
$svc = Get-Service SunshineService -EA SilentlyContinue
if ($svc) {
    $visto += "servizio SunshineService: $($svc.Status), avvio $((Get-CimInstance Win32_Service -Filter "Name='SunshineService'").StartMode)"
    if ($svc.Status -ne 'Stopped') {
        Stop-Service SunshineService -Force -EA SilentlyContinue
        $fatto += 'servizio fermato'
    }
    if ((Get-CimInstance Win32_Service -Filter "Name='SunshineService'").StartMode -ne 'Disabled') {
        Set-Service SunshineService -StartupType Disabled -EA SilentlyContinue
        $fatto += 'servizio disabilitato (non ripartira. al riavvio)'
    }
} else {
    $visto += 'servizio SunshineService: non installato'
}

# --- l'icona nella barra ---------------------------------------------------
# Ogni istanza ha la sua configurazione: la riga deve esserci in tutte, o al
# prossimo riavvio quella dimenticata ricompare nella barra. Si CONTROLLA invece
# di assumere che setup l'abbia messa: e' esattamente il genere di riga che si
# perde riscrivendo un file di configurazione a mano.
Get-ChildItem 'C:\winfleet' -Directory -Filter 'sun*' -EA SilentlyContinue | ForEach-Object {
    $conf = Join-Path $_.FullName 'sunshine.conf'
    if (Test-Path $conf) {
        # Select-String e non "-notmatch": su un ARRAY di righe, "-notmatch"
        # non risponde vero/falso - restituisce le righe che NON corrispondono,
        # cioe' quasi sempre un elenco non vuoto, che in un if vale VERO. La
        # riga veniva quindi aggiunta anche quando c'era gia': prima esecuzione
        # su un host sano, e sun0..sun3 si sono ritrovate "system_tray =
        # disabled" scritto DUE volte (verificato leggendo il file dopo).
        # Innocuo per Sunshine, che legge l'ultima, ma e' un file che cresce a
        # ogni controllo - e un controllo che modifica cio' che osserva.
        $gia = Select-String -Path $conf -Pattern 'system_tray\s*=\s*disabled' -Quiet
        if (-not $gia) {
            # Si aggiunge in coda, senza toccare il resto: questi file hanno
            # dentro percorsi e certificati, e riscriverli per intero e' il modo
            # in cui si perde output_name (gia' successo).
            Add-Content $conf "`nsystem_tray = disabled"
            $fatto += "$($_.Name): tray disattivata (serve un riavvio dell'istanza)"
        } else {
            $visto += "$($_.Name): tray gia. disattivata"
        }
    }
}

# --- le scorciatoie --------------------------------------------------------
# Menu Start e desktop: sono i posti da cui si apre una cosa per sbaglio.
# Si SPOSTANO in una cartella di riserva invece di cancellarle - se un giorno
# serve la web UI di Sunshine per una diagnosi, si rimettono al loro posto.
$riserva = 'C:\winfleet\collegamenti-nascosti'
$cartelle = @(
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
    (Join-Path $env:APPDATA     'Microsoft\Windows\Start Menu\Programs'),
    (Join-Path $env:USERPROFILE 'Desktop'),
    (Join-Path $env:PUBLIC      'Desktop')
)
foreach ($c in $cartelle) {
    if (-not (Test-Path $c)) { continue }
    Get-ChildItem $c -Recurse -Filter '*.lnk' -EA SilentlyContinue |
      Where-Object { $_.Name -match 'Sunshine|Moonlight' } |
      ForEach-Object {
        if (-not (Test-Path $riserva)) { New-Item -ItemType Directory -Path $riserva -Force | Out-Null }
        Move-Item $_.FullName (Join-Path $riserva $_.Name) -Force -EA SilentlyContinue
        $fatto += "collegamento tolto: $($_.Name)  (in $riserva)"
      }
}

# --- l'avvio automatico ----------------------------------------------------
$avvii = Get-CimInstance Win32_StartupCommand -EA SilentlyContinue |
         Where-Object { $_.Command -match 'sunshine|moonlight' }
if ($avvii) {
    foreach ($a in $avvii) { $visto += "avvio automatico ancora presente: $($a.Name) -> $($a.Command)" }
} else {
    $visto += 'avvio automatico: nessuna voce Sunshine/Moonlight'
}

# --- quanti Sunshine girano adesso -----------------------------------------
# Devono essere tanti quanti gli slot: uno in piu' e' il Sunshine di sistema
# tornato su, e da fuori il sintomo sarebbe un'icona che ricompare nella barra.
$n = @(Get-Process sunshine -EA SilentlyContinue).Count
$visto += "processi sunshine attivi: $n"

''
'--- trovato ---'
$visto | ForEach-Object { "  $_" }
''
if ($fatto.Count -gt 0) { '--- fatto ---'; $fatto | ForEach-Object { "  $_" } }
else { 'niente da fare: Sunshine era gia. invisibile.' }
