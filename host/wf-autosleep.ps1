# wf-autosleep: sospende il PC quando nessuno lo usa da N minuti (20, oppure il numero in
# C:\winfleet\autosleep.minutes). Gira ogni minuto come SYSTEM (task wf-autosleep), si
# risveglia con `winwake` dal Mac (Wake-on-LAN da S3, misurato 23/10: ssh di nuovo su in 25 s).
#
# Perche' non basta il timer di Windows: non scattava mai (3,6 giorni acceso a vuoto), e se
# scattasse interromperebbe un job di offload, perche' una sessione ssh non trattiene il sonno.
# Quindi qui si decide, e quando c'e' lavoro si azzera il timer di Windows a ogni giro.
#
# La versione del 01/10 non sospendeva MAI: contava come "in uso" la sessione console, che con
# l'accesso automatico esiste sempre, e il node residente avviato al login. Ora "in uso" vuol
# dire lavoro vero, non processi presenti:
#   - una sessione ssh con un comando dentro (offload, drwin, una shell). I tunnel -N/-L tenuti
#     aperti dal Mac (llama di jcode) non contano: da soli tenevano sveglio il PC dal 29/09;
#   - input alla console negli ultimi N minuti (lo scrive wf-idleguard, che gira nella sessione
#     utente: da SYSTEM GetLastInputInfo non vede la console);
#   - uno stream Parsec/Sunshine connesso, o l'encoder della GPU acceso;
#   - CPU: 15% del totale, oppure un processo solo sopra mezzo core (un test single-thread su
#     20 core e' il 5% del totale, e la soglia sul totale non lo vedrebbe);
#   - GPU sopra 10% in due letture a 5 s (un campione singolo a 40% con la GPU ferma c'e');
#   - una richiesta di alimentazione SYSTEM/AWAYMODE/EXECUTION (aggiornamenti, download):
#     chi la chiede vuole il PC sveglio, e powercfg /requestsoverride resta il modo di zittirla.
#
# Dati per lo schermo a tutto campo (C:\winfleet\schermo\index.html): a OGNI uscita di questo
# script, anche quando c'e' lavoro, scrive C:\winfleet\schermo\stato.js (window.STATO = {...}) in
# modo atomico. Non decide niente: la logica di sospensione qui sopra non lo legge. Gli ingressi
# li scrive `offload` dal Mac: lavoro-<pid>.json (un giro in corso) e fine-<pid>.json (l'exit code,
# scritto dal PC stesso a fine comando, cosi' non serve una seconda ssh). Qui il fine-*.json
# diventa una riga di esiti.jsonl (ultime 50) e il lavoro-*.json sparisce.
# Questo file e' UTF-8 con BOM: le frasi per lo schermo hanno le lettere accentate, e
# PowerShell 5.1 senza BOM le leggerebbe come ANSI. Il resto resta in ASCII.
# Uso: wf-autosleep.ps1 [-Dry]
param([switch]$Dry)
$dir = 'C:\winfleet'; $log = "$dir\autosleep.log"; $state = "$dir\autosleep.state"
function Log($m) {
  $r = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $m
  Add-Content -Path $log -Value $r
  # l'ultima decisione da sola, per pc-state sul Mac: un `type` via ssh dura decine di ms,
  # leggere la coda del log con powershell ne dura 2000 e conterebbe come lavoro
  Set-Content -Path "$dir\autosleep.now" -Value $r
  if ((Get-Item $log -EA SilentlyContinue).Length -gt 512KB) { Get-Content $log -Tail 300 | Set-Content $log }
}
$soglia = 20
# Un file vuoto o illeggibile vale 0, e 0 vorrebbe dire "dormi al primo minuto fermo": si ignora.
if (Test-Path "$dir\autosleep.minutes") { $m = 0; [void][int]::TryParse(("" + (Get-Content "$dir\autosleep.minutes" -TotalCount 1)).Trim(), [ref]$m); if ($m -ge 1) { $soglia = $m } }

function Gpu {
  $q = & nvidia-smi --query-gpu=utilization.gpu,utilization.encoder --format=csv,noheader,nounits 2>$null | Select-Object -First 1
  if (-not $q) { return @(0, 0) }
  return @($q -split ',' | ForEach-Object { [int]($_.Trim()) })
}

# ---------------------------------------------------------------------------------------------
# Schermo: stato.js + gestione di lavoro-*.json / fine-*.json / esiti.jsonl
# ---------------------------------------------------------------------------------------------
$sch = "$dir\schermo"
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Read-Json($p) { try { Get-Content $p -Raw -EA Stop | ConvertFrom-Json } catch { $null } }
function Iso([datetime]$d) { $d.ToString("yyyy-MM-dd'T'HH:mm:sszzz") }
function Epoch-Ms([datetime]$d) { ([DateTimeOffset]$d).ToUnixTimeMilliseconds() }
function When($v, $fallback) { try { [datetime]$v } catch { $fallback } }

# Una riga in esiti.jsonl, tenendo solo le ultime 50.
function Add-Esito($lav, $esito, [datetime]$fine) {
  $da = When $lav.da $fine
  $rec = [ordered]@{
    progetto = "$($lav.progetto)"; cosa = "$($lav.cosa)"; esito = $esito
    secondi = [math]::Max(0, [int]($fine - $da).TotalSeconds); fine = (Iso $fine)
  }
  $f = "$sch\esiti.jsonl"
  $righe = @(); if (Test-Path $f) { $righe = @([IO.File]::ReadAllLines($f, $utf8) | Where-Object { $_.Trim() }) }
  $righe += ($rec | ConvertTo-Json -Compress)
  if ($righe.Count -gt 50) { $righe = $righe[($righe.Count - 50)..($righe.Count - 1)] }
  [IO.File]::WriteAllLines("$f.tmp", [string[]]$righe, $utf8)
  Move-Item "$f.tmp" $f -Force
}

# Porta a termine i giri: fine-<pid>.json (scritto dal PC al termine del comando) -> esito;
# un lavoro-<pid>.json senza fine e senza nessuna sessione ssh e' morto (kill -9, rete caduta).
# Il pid e' quello di offload sul Mac: qui non si puo' controllare, quindi "morto" vuol dire
# che non c'e' piu' nemmeno una ssh aperta (un giro e' sempre dentro una ssh), da almeno 2 minuti
# per non confondere il buco fra la copia e l'esecuzione. Piu' vecchi di 6 ore: avanzi.
function Sync-Giri {
  $ora = Get-Date; $vivi = @()
  foreach ($ff in @(Get-ChildItem "$sch\fine-*.json" -EA SilentlyContinue)) {
    $id = $ff.BaseName.Substring(5); $lf = "$sch\lavoro-$id.json"; $lav = Read-Json $lf
    if ($lav) {
      $fj = Read-Json $ff.FullName; $rc = if ($fj -and $null -ne $fj.rc) { [int]$fj.rc } else { 255 }
      $esito = if ($rc -eq 0) { 'ok' } elseif ($rc -in 130, 143, 255) { 'interrotto' } else { 'fallito' }
      Add-Esito $lav $esito $ff.LastWriteTime
      Remove-Item $lf -EA SilentlyContinue
    }
    Remove-Item $ff.FullName -EA SilentlyContinue
  }
  foreach ($lf in @(Get-ChildItem "$sch\lavoro-*.json" -EA SilentlyContinue)) {
    $lav = Read-Json $lf.FullName
    if (-not $lav) { if (($ora - $lf.LastWriteTime).TotalMinutes -gt 10) { Remove-Item $lf.FullName -EA SilentlyContinue }; continue }
    $da = When $lav.da $lf.LastWriteTime
    if (($ora - $da).TotalHours -gt 6) { Remove-Item $lf.FullName -EA SilentlyContinue; continue }
    if ($ssh -eq 0 -and ($ora - $da).TotalSeconds -gt 120) { Add-Esito $lav 'interrotto' $ora; Remove-Item $lf.FullName -EA SilentlyContinue; continue }
    $vivi += [ordered]@{ progetto = "$($lav.progetto)"; cosa = "$($lav.cosa)"; chi = "$($lav.chi)"; da = (Iso $da); secondi = [math]::Max(0, [int]($ora - $da).TotalSeconds) }
  }
  return $vivi
}

# Il motivo per cui il PC resta sveglio, in italiano semplice (e' scritto per essere letto da 3 metri).
function Motivo-Italiano($w, $nLavori) {
  switch -Regex ($w) {
    '^ssh attivo'                { if ($nLavori -gt 0) { 'Un lavoro mandato dal Mac è in corso' } else { 'Il Mac è collegato al PC' }; break }
    '^stream porta'              { 'Qualcuno sta usando il PC in streaming'; break }
    '^processo (\S+) a '         { "Un programma sta lavorando ($($Matches[1]))"; break }
    '^cpu (\d+)%'                { "Il processore è occupato al $($Matches[1])%"; break }
    '^gpu (\d+)%'                { "La scheda video è occupata al $($Matches[1])%"; break }
    '^encoder'                   { 'Lo streaming sta usando la scheda video'; break }
    '^richiesta di alimentazione' { 'Windows o un programma chiede di restare acceso'; break }
    '^topics nodo'               { 'Una card di Topics sta lavorando su questo PC'; break }
    default                      { $w }
  }
}

# stato.js a ogni uscita. Mai fatale: un errore qui finisce nel log e basta, la decisione di
# sospendere e' gia' presa (o non presa) da chi chiama. $sospendeAlle = datetime, o $null se sveglio.
function Write-Stato([string[]]$why, $sospendeAlle, [string[]]$extra = @()) {
  try {
    if (-not (Test-Path $sch)) { New-Item -ItemType Directory -Force -Path $sch | Out-Null }
    $lavori = @(Sync-Giri)
    $esiti = @()
    if (Test-Path "$sch\esiti.jsonl") {
      $esiti = @([IO.File]::ReadAllLines("$sch\esiti.jsonl", $utf8) | Where-Object { $_.Trim() } | Select-Object -Last 3 |
        ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
      [array]::Reverse($esiti)
    }
    $motivi = @(@($why | Where-Object { $_ } | ForEach-Object { Motivo-Italiano $_ $lavori.Count }) + @($extra | Where-Object { $_ }) | Select-Object -Unique)
    $stato = [ordered]@{
      versione = 1
      ora = (Iso (Get-Date))
      sogliaMinuti = $soglia
      sospendeAlle = $(if ($sospendeAlle -and $why.Count -eq 0) { Epoch-Ms $sospendeAlle } else { $null })
      motivi = $motivi
      lavori = $lavori
      esiti = @($esiti | ForEach-Object { [ordered]@{ progetto = $_.progetto; cosa = $_.cosa; esito = $_.esito; secondi = [int]$_.secondi; fine = $_.fine } })
    }
    $json = $stato | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText("$sch\stato.js.tmp", "window.STATO = $json;`n", $utf8)
    Move-Item "$sch\stato.js.tmp" "$sch\stato.js" -Force
  } catch { Log "stato.js non scritto: $($_.Exception.Message)" }
}

$why = @()

$sshPids = @(Get-Process sshd -EA SilentlyContinue | Select-Object -ExpandProperty Id)
$ssh = @(Get-CimInstance Win32_Process | Where-Object { $sshPids -contains $_.ParentProcessId -and $_.Name -ne 'sshd.exe' }).Count
if ($ssh -gt 0) { $why += "ssh attivo ($ssh sessioni)" }

# input-idle.txt = secondi senza input al momento della scrittura; vale solo se fresco.
# L'input non e' un motivo "in uso" ma sposta in avanti l'inizio dell'inattivita': contarlo
# come motivo sommerebbe due attese, e dopo un winwake (che Windows registra come input)
# il PC resterebbe acceso 2N minuti invece di N.
$lastInput = [datetime]::MinValue
$f = Get-Item "$dir\input-idle.txt" -EA SilentlyContinue
if ($f -and ((Get-Date) - $f.LastWriteTime).TotalMinutes -lt 3) {
  $lastInput = $f.LastWriteTime.AddSeconds(-[int](Get-Content $f.FullName -TotalCount 1))
}

$stream = Get-NetTCPConnection -State Established -EA SilentlyContinue |
  Where-Object { $_.RemoteAddress -notlike '127.*' -and ($_.LocalPort -in 8000..8010 -or $_.LocalPort -in 47984..48500) }
if ($stream) { $why += "stream porta $(@($stream)[0].LocalPort)" }

# CPU per processo su una finestra di 5 s (TotalProcessorTime, non localizzato come Get-Counter).
$g1 = Gpu
$t0 = @{}; Get-Process | ForEach-Object { if ($_.TotalProcessorTime) { $t0[$_.Id] = $_.TotalProcessorTime.TotalSeconds } }
Start-Sleep -Seconds 5
$g2 = Gpu
$top = Get-Process | Where-Object { $_.Id -ne $PID -and $_.Name -ne 'Idle' -and $t0.ContainsKey($_.Id) -and $_.TotalProcessorTime } |
  ForEach-Object { [pscustomobject]@{ Name = $_.Name; Core = ($_.TotalProcessorTime.TotalSeconds - $t0[$_.Id]) / 5 } } |
  Sort-Object Core -Descending | Select-Object -First 1
if ($top -and $top.Core -ge 0.5) { $why += ("processo {0} a {1:N1} core" -f $top.Name, $top.Core) }
$cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
if ($cpu -ge 15) { $why += "cpu $cpu%" }
if ($g1[0] -ge 10 -and $g2[0] -ge 10) { $why += "gpu $($g2[0])%" }
if ($g1[1] -ge 5 -and $g2[1] -ge 5) { $why += "encoder $($g2[1])% (stream)" }

# powercfg /requests e' localizzato, ma l'ordine delle sezioni no: DISPLAY, SYSTEM, AWAYMODE,
# EXECUTION, PERFBOOST, ACTIVELOCKSCREEN. Una richiesta vera e' una riga che comincia con "[".
$sez = -1; $req = @()
foreach ($r in (powercfg /requests 2>$null)) {
  if ($r -match '^\S+:\s*$') { $sez++; continue }
  if ($r -like '[[]*' -and $sez -in 1, 2, 3) { $req += $r.Trim() }
}
if ($req) { $why += "richiesta di alimentazione: $($req[0])" }

# Una card della Topics del Mac in corsa sul nodo (nodo/avvia-nodo.ps1, porta 3333 su
# loopback). Il CLI aspetta il modello per lunghi tratti a CPU quasi zero, e il tunnel
# ssh -N del Mac non e' una sessione con figli: senza questo il PC dormirebbe a meta' card.
try {
  $tn = Invoke-RestMethod -UseBasicParsing -TimeoutSec 3 'http://127.0.0.1:3333/api/all-boards/tasks?status=in_progress'
  $nc = @($tn.tasks | Where-Object { $_ }).Count
  if ($nc -gt 0) { $why += "topics nodo ($nc card in corso)" }
} catch { }  # nodo spento o porta libera: nessuna card, nessun motivo

if ($why.Count -gt 0) {
  # ES_SYSTEM_REQUIRED senza ES_CONTINUOUS: azzera il timer di Windows una volta, e il
  # prossimo giro (fra un minuto) lo riazzera se il lavoro c'e' ancora.
  $k = Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);' -Name Pwr -Namespace WFAS -PassThru
  [void]$k::SetThreadExecutionState(0x00000001)
  if (Test-Path $state) { Remove-Item $state -EA SilentlyContinue }
  Log ("in uso: " + ($why -join '; '))
  Write-Stato $why $null
  exit 0
}
# Il file di stato dice da quando e' inattivo; la sua data di modifica, quando l'ha visto
# l'ultimo giro. Un buco di piu' di 3 minuti vuol dire che il PC ha dormito (o il task era
# fermo): si riconta da zero, se no al risveglio da winwake si riaddormenterebbe al primo
# giro, prima che arrivi la sessione ssh del job.
$s = Get-Item $state -EA SilentlyContinue
if (-not $s -or ((Get-Date) - $s.LastWriteTime).TotalMinutes -gt 3) {
  Set-Content $state (Get-Date).ToString('o'); Log "inattivo: inizio conteggio (soglia $soglia min)"
  Write-Stato @() (Get-Date).AddMinutes($soglia); exit 0
}
$since = [datetime](Get-Content $state -TotalCount 1)
Set-Content $state $since.ToString('o')
if ($lastInput -gt $since) { $since = $lastInput }
$min = [int][math]::Floor(((Get-Date) - $since).TotalMinutes)
if ($min -lt $soglia) {
  Log "inattivo da $min min (soglia $soglia; ultimo input $($lastInput.ToString('HH:mm')))"
  Write-Stato @() $since.AddMinutes($soglia) $(if ($lastInput -gt (Get-Date).AddMinutes(-$soglia)) { 'Qualcuno ha usato il PC da poco' })
  exit 0
}
if ($Dry) { Log "DRY: sospenderei (inattivo da $min min)"; Write-Stato @() (Get-Date); exit 0 }
Log "sospensione (inattivo da $min min)"; Remove-Item $state -EA SilentlyContinue
Write-Stato @() (Get-Date)
Add-Type -AssemblyName System.Windows.Forms
[void][System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false)
