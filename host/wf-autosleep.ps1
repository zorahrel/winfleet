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

if ($why.Count -gt 0) {
  # ES_SYSTEM_REQUIRED senza ES_CONTINUOUS: azzera il timer di Windows una volta, e il
  # prossimo giro (fra un minuto) lo riazzera se il lavoro c'e' ancora.
  $k = Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);' -Name Pwr -Namespace WFAS -PassThru
  [void]$k::SetThreadExecutionState(0x00000001)
  if (Test-Path $state) { Remove-Item $state -EA SilentlyContinue }
  Log ("in uso: " + ($why -join '; '))
  exit 0
}
# Il file di stato dice da quando e' inattivo; la sua data di modifica, quando l'ha visto
# l'ultimo giro. Un buco di piu' di 3 minuti vuol dire che il PC ha dormito (o il task era
# fermo): si riconta da zero, se no al risveglio da winwake si riaddormenterebbe al primo
# giro, prima che arrivi la sessione ssh del job.
$s = Get-Item $state -EA SilentlyContinue
if (-not $s -or ((Get-Date) - $s.LastWriteTime).TotalMinutes -gt 3) {
  Set-Content $state (Get-Date).ToString('o'); Log "inattivo: inizio conteggio (soglia $soglia min)"; exit 0
}
$since = [datetime](Get-Content $state -TotalCount 1)
Set-Content $state $since.ToString('o')
if ($lastInput -gt $since) { $since = $lastInput }
$min = [int][math]::Floor(((Get-Date) - $since).TotalMinutes)
if ($min -lt $soglia) { Log "inattivo da $min min (soglia $soglia; ultimo input $($lastInput.ToString('HH:mm')))"; exit 0 }
if ($Dry) { Log "DRY: sospenderei (inattivo da $min min)"; exit 0 }
Log "sospensione (inattivo da $min min)"; Remove-Item $state -EA SilentlyContinue
Add-Type -AssemblyName System.Windows.Forms
[void][System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false)
