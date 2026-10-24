# wf-schermo: mostra a tutto schermo la pagina C:\winfleet\schermo\index.html (cosa fa il PC per il
# Mac, o quanto manca allo standby) quando nessuno sta usando il PC, e la toglie al primo tocco.
# Gira nella sessione utente della console, lanciato da wf-run-hidden.vbs come wf-idleguard (da
# powershell.exe nudo alloca una console visibile; il task e' clonato da quello di wf-idleguard
# da wf-schermo-install.ps1, quindi stesso utente, stesso trigger al logon).
#
# Quando compare: input della console fermo da 5 minuti (GetLastInputInfo, lo stesso dato di
# wf-idleguard) E nessuno stream E nessuna app a schermo intero in primo piano.
#  - L'input di uno stream (Sunshine/Parsec) e' INIETTATO e non resetta il timer: per questo lo
#    stream si cerca a parte, con la stessa regola di wf-autosleep (connessione TCP stabilita sulle
#    porte di Parsec 8000-8010 e di Sunshine 47984-48500, oppure encoder della GPU >= 5%). Si
#    controlla prima di mostrare e ogni 5 s mentre e' mostrata: se parte uno stream, sparisce.
#  - "App a schermo intero" = SHQueryUserNotificationState (gioco D3D esclusivo, finestra a tutto
#    schermo, modalita' presentazione): lo stesso segnale con cui Windows tiene zittite le notifiche.
# Quando sparisce: al primo input vero (si guarda dwTime di GetLastInputInfo, che cambia a ogni
# tocco; si controlla ogni mezzo secondo), per stream, per un'altra finestra che prende il primo
# piano (poi 5 minuti di pausa), o dopo un risveglio dal sonno. Si chiudono SOLO i processi Edge
# col profilo C:\winfleet\schermo\edge-profilo: l'Edge di Attilio non si tocca.
#
# Non deve tenere sveglio il PC: la pagina non chiede veglia (powercfg /requests lo si logga una
# volta per ogni comparsa) e scende da sola di fps. Qui sopra c'e' la seconda cintura: con lo schermo
# mostrato e il PC senza lavori, la mediana della GPU (nvidia-smi, 12 letture a 10 s) deve stare
# sotto il 5%; se no si rilancia la pagina con ?fps=6 e poi con ?fermo=1 (fondo fermo).
#
# Spegnere tutto: wf-schermo-ctl.ps1 off (riaccendere: on).
# Prove: C:\winfleet\schermo.secondi (numero) cambia i 300 s; -Dry scrive solo nel log.
# Log: C:\winfleet\schermo.log
param([switch]$Dry)

$dir = 'C:\winfleet'
$pagina = "$dir\schermo\index.html"
$profilo = "$dir\schermo\edge-profilo"
$log = "$dir\schermo.log"
$flagOff = "$dir\schermo.off"

$mutex = New-Object System.Threading.Mutex($false, 'Local\wf-schermo')
if (-not $mutex.WaitOne(0)) { exit 0 }

function Log($m) {
  "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $m" | Add-Content $log
  if ((Get-Item $log -EA SilentlyContinue).Length -gt 512KB) { Get-Content $log -Tail 300 | Set-Content $log }
}

$sig = @'
[StructLayout(LayoutKind.Sequential)] public struct LII { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LII p);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int state);
'@
$W = @(Add-Type -MemberDefinition $sig -Name Win -Namespace WFS -PassThru)[0]

# dwTime dell'ultimo input (ms di orologio di sistema, a 32 bit) e secondi di quiete.
function Input-Raw {
  $li = New-Object WFS.Win+LII; $li.cbSize = 8
  if (-not $W::GetLastInputInfo([ref]$li)) { return $null }
  $li
}
function Input-Idle($li) {
  $d = ([int64][Environment]::TickCount -band 0xFFFFFFFFL) - [int64]$li.dwTime
  if ($d -lt 0) { $d += 4294967296 }
  [int]($d / 1000)
}

# [utilizzo GPU %, utilizzo encoder %, sessioni NVENC aperte]. Un campo che il driver non da' ([N/A]) vale 0.
function Gpu-Util {
  $q = & nvidia-smi --query-gpu=utilization.gpu,utilization.encoder,encoder.stats.sessionCount --format=csv,noheader,nounits 2>$null | Select-Object -First 1
  $out = @(0, 0, 0)
  if (-not $q) { return $out }
  $p = @("$q" -split ',')
  for ($i = 0; $i -lt 3 -and $i -lt $p.Count; $i++) { $v = 0; if ([int]::TryParse($p[$i].Trim(), [ref]$v)) { $out[$i] = $v } }
  $out
}

# Stream davvero in corso: stessa regola di wf-autosleep. Il ritorno e' il motivo, o $null.
function Stream-Motivo {
  $c = @(Get-NetTCPConnection -State Established -EA SilentlyContinue |
    Where-Object { $_.RemoteAddress -notlike '127.*' -and $_.RemoteAddress -ne '::1' -and
                   ($_.LocalPort -in 8000..8010 -or $_.LocalPort -in 47984..48500) })
  if ($c.Count) { return "stream porta $($c[0].LocalPort)" }
  # Uno stream Moonlight/Parsec a regime non tiene connessioni TCP aperte (video, audio e controllo
  # viaggiano su UDP) e su un desktop fermo l'encoder puo' stare sotto il 5%: la sessione NVENC
  # aperta c'e' invece per tutta la durata dello stream, anche a immagine ferma.
  $g = Gpu-Util
  if ($g[2] -ge 1) { return "sessioni NVENC $($g[2])" }
  if ($g[1] -ge 5) { return "encoder GPU $($g[1])%" }
  $null
}

# 5 = Windows accetta notifiche (nessuna app a schermo intero), 6 = ore di silenzio. Tutto il resto
# (1 schermo non presente/bloccato, 2 app a schermo intero, 3 gioco D3D, 4 presentazione, 7 app) = no.
function Schermo-Libero {
  $st = 0
  if ($W::SHQueryUserNotificationState([ref]$st) -ne 0) { return $false }
  $st -in 5, 6
}

function Edge-Exe {
  foreach ($p in "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") {
    if (Test-Path $p) { return $p }
  }
  $r = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -EA SilentlyContinue).'(default)'
  if ($r -and (Test-Path $r)) { return $r }
  $null
}

# Chiude l'albero del processo che abbiamo lanciato e poi tutto cio' che ha il nostro profilo.
# Mai "taskkill /im msedge.exe": spegnerebbe anche l'Edge di Attilio.
$script:edge = $null
function Edge-Chiudi {
  if ($script:edge) {
    & taskkill /PID $script:edge.Id /T /F 2>&1 | Out-Null
    $script:edge = $null
  }
  $avanzi = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -EA SilentlyContinue |
    Where-Object { $_.CommandLine -like '*schermo\edge-profilo*' })
  foreach ($p in $avanzi) { Stop-Process -Id $p.ProcessId -Force -EA SilentlyContinue }
}

function Edge-Apri($extra) {
  $exe = Edge-Exe
  if (-not $exe) { Log 'Edge non trovato: non posso mostrare la schermata'; return $false }
  $url = 'file:///C:/winfleet/schermo/index.html' + $extra
  $argv = @('--kiosk', $url, '--edge-kiosk-type=fullscreen', '--no-first-run', "--user-data-dir=$profilo",
            '--noerrdialogs', '--disable-session-crashed-bubble', '--hide-crash-restore-bubble',
            '--no-default-browser-check', '--disable-background-mode')
  if ($Dry) { Log "DRY: aprirei Edge $url"; return $true }
  $script:edge = Start-Process -FilePath $exe -ArgumentList $argv -PassThru
  $true
}

$soglia = 300
function Leggi-Soglia {
  $f = "$dir\schermo.secondi"
  if (Test-Path $f) { $v = 0; if ([int]::TryParse(("" + (Get-Content $f -TotalCount 1)).Trim(), [ref]$v) -and $v -ge 5) { return $v } }
  300
}

# L'ultima riga di stato.js dice se un lavoro e' in corso: con un lavoro la GPU non e' tutta nostra
# e la lettura non conta per la cintura.
function Lavori-In-Corso {
  try { (Get-Content "$dir\schermo\stato.js" -Raw -EA Stop) -notmatch '"lavori":\s*\[\s*\]' } catch { $false }
}

# Livelli della cintura GPU: 0 = auto (la pagina scende da sola), 1 = tetto 6 fps, 2 = fondo fermo.
$parametri = @('', '?fps=6', '?fermo=1')
$livello = 0
$visibile = $false; $baseDw = 0; $dal = $null; $ultimoCheck = [datetime]::MinValue
$pausaFino = [datetime]::MinValue; $gpuLetture = New-Object System.Collections.Generic.List[int]; $ultimaGpu = [datetime]::MinValue
$fgRubato = 0; $loggatoReq = $false; $ultimoGiro = Get-Date; $falliti = 0; $spinte = 0

Log "avviato (soglia $(Leggi-Soglia) s)$(if ($Dry) { ' DRY' })"

function Nascondi($perche, [int]$pausaSec = 0) {
  Edge-Chiudi
  $script:visibile = $false
  if ($pausaSec -gt 0) { $script:pausaFino = (Get-Date).AddSeconds($pausaSec) }
  Log "nascosta: $perche (mostrata da $([int]((Get-Date) - $script:dal).TotalSeconds) s)"
}

while ($true) {
  $ora = Get-Date
  # Un buco nel ciclo (il PC ha dormito, il task era fermo): quello che era mostrato e' vecchio.
  if (($ora - $ultimoGiro).TotalSeconds -gt 30) {
    Log "buco di $([int](($ora - $ultimoGiro).TotalSeconds)) s nel ciclo: ricomincio"
    if ($visibile) { Nascondi 'dopo il sonno' }
    $falliti = 0
  }
  $ultimoGiro = $ora

  $li = Input-Raw
  $spento = Test-Path $flagOff
  if (-not $li -or $spento) {
    if ($visibile) { Nascondi $(if ($spento) { 'spenta (schermo.off)' } else { 'input illeggibile' }) }
    Start-Sleep -Seconds 5; continue
  }

  if ($visibile) {
    # al primo tocco: dwTime cambia a ogni input vero
    if ($li.dwTime -ne $baseDw) { $livello = 0; $falliti = 0; Nascondi 'input' 0; $gpuLetture.Clear(); Start-Sleep -Milliseconds 500; continue }

    # Edge morto da solo (crash, chiuso da altro): non si riapre in loop
    if ($script:edge -and $script:edge.HasExited -and -not $Dry) {
      Nascondi 'Edge si e'' chiuso da solo' 60
      $falliti++
      continue
    }

    if (($ora - $ultimoCheck).TotalSeconds -ge 5) {
      $ultimoCheck = $ora
      $s = Stream-Motivo
      if ($s) { Nascondi "stream ($s)" 0; continue }
      # un'altra finestra al primo piano (non Edge) per due giri di fila: la schermata si ritira
      $h = $W::GetForegroundWindow(); [uint32]$fpid = 0
      if ($h -ne [IntPtr]::Zero) { [void]$W::GetWindowThreadProcessId($h, [ref]$fpid) }
      $fp = if ($fpid) { (Get-Process -Id $fpid -EA SilentlyContinue).ProcessName } else { $null }
      if ($fp -and $fp -ne 'msedge' -and ($ora - $dal).TotalSeconds -ge 6) {
        if ($spinte -lt 3 -and $script:edge -and -not $Dry) {
          # kiosk non ancora in primo piano: si spinge fino a tre volte (l'input e' fermo da minuti)
          $script:edge.Refresh(); [void]$W::SetForegroundWindow($script:edge.MainWindowHandle); $spinte++
        } else { $fgRubato++ }
      } else { $fgRubato = 0 }
      if ($fgRubato -ge 2) { Nascondi "primo piano a $fp" 300; continue }
      if (-not $loggatoReq -and ($ora - $dal).TotalSeconds -ge 20) {
        $loggatoReq = $true
        $req = (powercfg /requests 2>$null) -join ' | '
        Log "powercfg /requests con lo schermo mostrato: $($req -replace '\s{2,}', ' ')"
      }
    }

    # cintura GPU: una lettura ogni 10 s, senza lavori in corso; 12 letture = mediana sotto il 5%
    if (($ora - $ultimaGpu).TotalSeconds -ge 10) {
      $ultimaGpu = $ora
      if (-not (Lavori-In-Corso)) {
        $gpuLetture.Add((Gpu-Util)[0])
        if ($gpuLetture.Count -ge 12) {
          $ord = @($gpuLetture | Sort-Object); $med = $ord[[int]($ord.Count / 2)]
          Log "GPU con lo schermo mostrato (livello $livello): mediana $med% su 12 letture"
          $gpuLetture.Clear()
          if ($med -gt 5 -and $livello -lt 2) {
            $livello++
            Log "GPU sopra il 5%: rilancio la pagina con '$($parametri[$livello])'"
            Edge-Chiudi
            if (Edge-Apri $parametri[$livello]) { $spinte = 0 }
          }
        }
      }
    }
    Start-Sleep -Milliseconds 500
    continue
  }

  # nascosta: si guarda solo la quiete dell'input, poi le condizioni care
  $soglia = Leggi-Soglia
  $idle = Input-Idle $li
  if ($idle -ge $soglia -and $ora -ge $pausaFino -and ($ora - $ultimoCheck).TotalSeconds -ge 10) {
    $ultimoCheck = $ora
    $s = Stream-Motivo
    if ($s) { Start-Sleep -Seconds 2; continue }
    if (-not (Schermo-Libero)) { Start-Sleep -Seconds 2; continue }
    if ($falliti -ge 3) { $pausaFino = $ora.AddMinutes(10); $falliti = 0; Log 'Edge non parte: pausa di 10 minuti'; continue }
    Log "mostro la schermata (input fermo da $idle s)"
    if (Edge-Apri $parametri[$livello]) {
      $visibile = $true; $baseDw = $li.dwTime; $dal = $ora; $ultimoCheck = $ora; $ultimaGpu = $ora
      $loggatoReq = $false; $fgRubato = 0; $spinte = 0; $gpuLetture.Clear()
    } else { $pausaFino = $ora.AddMinutes(10) }
  }
  Start-Sleep -Seconds 2
}
