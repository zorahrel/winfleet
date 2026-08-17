<#
.SYNOPSIS
  Starts an app and gives it the whole of one virtual monitor.

.DESCRIPTION
  Run through the winfleet-place<slot> task when the client asks for an app; the exe
  to start is read from C:\winfleet\app<slot>.txt.

  Sunshine does not launch the app itself on purpose. To put a window in the
  interactive session it duplicates the console token, which needs a privilege only
  LocalSystem holds — an instance running as you, elevated or not, fails with
  ACCESS_DENIED. Launching from a scheduled task in your own session sidesteps that
  entirely, and leaves Sunshine doing only what it is good at: streaming a screen.

  The window is then stripped of its frame and put in the top-left corner of the
  virtual monitor bound to this slot, at whatever size C:\winfleet\rect<slot>.txt
  asks for ("<width> <height>"), defaulting to the whole monitor. Isolation comes from
  the screen: nothing else ever draws on it.

  That file is how a Mac window resize reaches Windows. Resizing a window is immediate
  — one SetWindowPos, one frame — while changing the screen RESOLUTION costs about a
  second (mode set plus the host rebuilding its encoder), which is what used to make
  resizing feel like a series of jumps. The client crops to this same rectangle, so
  what arrives on the Mac is the app and nothing around it.

  The window is found by watching for one that appears after the launch rather than
  through the process we started: Store-packaged apps, Chromium and Electron hand
  their window to another process, so MainWindowHandle stays 0 forever.

.EXAMPLE
  powershell -File wf-place.ps1 -Slot 0
#>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][int]$Slot)

$Exe = ''
$req = "C:\winfleet\app$Slot.txt"
if (Test-Path $req) { $Exe = (Get-Content $req -Raw).Trim() }
if (-not $Exe) { return }

$LOG = "C:\winfleet\place$Slot.log"
# Con i soli secondi non si misura niente: un passo da 300 ms e uno da 1200
# sembrano uguali, e i millisecondi sono esattamente cio' che si sta cercando
# quando si vuole capire dove va il tempo di un'apertura.
function Note($m) { "$(Get-Date -f 'HH:mm:ss.fff')  $m" | Add-Content $LOG }
trap { Note "ERRORE: $_"; break }
Set-Content $LOG ''

$sig = @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public class P {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

  static bool Candidate(IntPtr h) {
    if (!IsWindowVisible(h)) return false;
    if (GetWindow(h, 4) != IntPtr.Zero) return false;      // GW_OWNER: dialoghi e tooltip
    if (GetWindowTextLength(h) == 0) return false;
    RECT r; if (!GetWindowRect(h, out r)) return false;
    return (r.R - r.L) * (r.B - r.T) >= 40000;
  }
  public static List<IntPtr> Candidates() {
    List<IntPtr> found = new List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr p) { if (Candidate(h)) found.Add(h); return true; }, IntPtr.Zero);
    return found;
  }
  // "La finestra piu' grande comparsa dopo il lancio" non basta quando due slot
  // aprono un'app nello stesso momento: la finestra di uno e' nuova anche per
  // l'altro, e chi arriva secondo se la prende. Visto dal vivo: hwnd0 e hwnd1
  // con lo STESSO handle, due schermi che mostravano entrambi Arc, e uno slot
  // marcato "pronto" che in realta' guardava la finestra di un'altra app.
  //
  // Il filtro NON puo' essere la posizione: quando la finestra compare sta dove
  // Windows ha deciso, ed e' questo script a spostarla sul monitor giusto un
  // istante dopo. Guardare le coordinate scarterebbe proprio la finestra che si
  // sta aspettando.
  //
  // Si escludono invece gli handle che un ALTRO slot ha gia' rivendicato: sono
  // fatti registrati, non ipotesi.
  public static IntPtr FindNew(IntPtr[] before, IntPtr[] taken) {
    IntPtr best = IntPtr.Zero; int bestArea = 0;
    foreach (IntPtr h in Candidates()) {
      if (Array.IndexOf(before, h) >= 0) continue;
      if (taken != null && Array.IndexOf(taken, h) >= 0) continue;
      RECT r; GetWindowRect(h, out r);
      int area = (r.R - r.L) * (r.B - r.T);
      if (area > bestArea) { bestArea = area; best = h; }
    }
    return best;
  }
}
'@
Add-Type -TypeDefinition $sig

# La geometria si rilegge a ogni giro: quando il client ridimensiona la finestra il
# monitor virtuale cambia forma, e la finestra deve seguirlo.
# Il file lo riscrive un altro processo: leggerlo mentre e' a meta' da un oggetto
# senza misure, e prendere quello per buono significa ridurre la finestra a zero e
# perderla. Meglio non rispondere che rispondere 0x0.
function Get-Monitor {
    try {
        $raw = (Get-Content 'C:\winfleet\vdd.json' -Raw -EA Stop).TrimStart([char]0xFEFF)
        $parsed = ConvertFrom-Json $raw
    } catch { return $null }
    $vdd = @(); foreach ($e in $parsed) { $vdd += $e }
    $m = $vdd | Where-Object { $_.slot -eq $Slot }
    if (-not $m -or [int]$m.width -le 0 -or [int]$m.height -le 0) { return $null }
    $m
}
$mon = $null
for ($t = 0; $t -lt 20 -and -not $mon; $t++) { $mon = Get-Monitor; if (-not $mon) { Start-Sleep -Milliseconds 300 } }
if (-not $mon) { throw "Slot $Slot senza monitor virtuale." }
Note "slot $Slot -> $($mon.device) $($mon.width)x$($mon.height) @ $($mon.x),$($mon.y)"

# Le app dello Store non hanno un eseguibile da avviare, solo un identificativo: si
# passa dalla cartella virtuale delle applicazioni, come fa il menu Start.
$packaged = $Exe -like 'shell:AppsFolder\*'

# Mai per explorer: e' la shell di Windows, non un'app. Chiuderlo fa sparire barra
# delle applicazioni, icone e desktop dell'utente — un prezzo assurdo per aprire una
# finestra di Esplora file, che tra l'altro si apre benissimo senza.
$isShell = $Exe -match '(^|\\)explorer\.exe$'

# L'agente puo' aver gia' chiuso e rilanciato l'app: lui e' gia' in esecuzione,
# mentre questo script paga un secondo e mezzo solo per avviare powershell. In
# quel caso lascia un biglietto, e qui si salta il lavoro gia' fatto per andare
# dritti a quello che solo questo script fa: trovare la finestra, toglierle la
# cornice, e seguirne la geometria finche' vive.
#
# Il biglietto vale solo se e' per QUESTA app e se e' fresco: un file vecchio di
# un minuto e' di un'apertura precedente, e fidarsene vorrebbe dire non lanciare
# affatto l'app chiesta adesso.
$preLaunched = $false
$flag = "C:\winfleet\launched$Slot.txt"
if (Test-Path $flag) {
    try {
        $f = Get-Item $flag
        $same = ((Get-Content $flag -Raw).Trim() -eq $Exe.Trim())
        $fresh = ((Get-Date) - $f.LastWriteTime).TotalSeconds -lt 20
        if ($same -and $fresh) { $preLaunched = $true }
    } catch { }
    Remove-Item $flag -Force -EA SilentlyContinue
}

# La cartella del pacchetto si ricava SEMPRE, anche quando la chiusura la salta:
# serve piu' avanti per riconoscere quali finestre sono di questa app. Calcolarla
# solo dentro il ramo che chiude i processi la lasciava vuota proprio nel caso in
# cui l'app l'ha lanciata l'agente - e allora nessuna finestra veniva riconosciuta.
$root = $null
if ($packaged) {
    $fam = ($Exe -replace '^shell:AppsFolder\\', '') -replace '!.*$', ''
    try {
        $ap = Get-AppxPackage | Where-Object { $_.PackageFamilyName -eq $fam } | Select-Object -First 1
        if ($ap) { $root = $ap.InstallLocation }
    } catch { }
} else {
    $name = [IO.Path]::GetFileNameWithoutExtension($Exe)
}


if (-not $isShell -and -not $preLaunched) {
    # Un'app a istanza singola non aprirebbe una finestra qui: riporterebbe in primo
    # piano quella che ha gia', su un altro schermo. Vale anche per le app dello
    # Store — anzi soprattutto per quelle, che sono quasi tutte a istanza singola:
    # saltarle significava streammare uno schermo vuoto mentre la finestra restava
    # sul desktop vero, ed e' il motivo per cui si vedeva un rettangolo nero.
    #
    # Il nome del processo non si ricava dal percorso quando l'app e' pacchettizzata:
    # 'shell:AppsFolder\Microsoft.WindowsNotepad_...!App' non contiene 'Notepad.exe'.
    # Si prende dall'identificativo del pacchetto, che e' la parte prima del punto.
    if ($packaged) {
        # I processi dell'app si trovano dalla CARTELLA del pacchetto, non
        # indovinando il nome dall'identificativo.
        #
        # Prima si confrontavano i nomi, con la regola "almeno quattro lettere"
        # messa li' per evitare che un processo dal nome cortissimo facesse
        # coppia con mezzo mondo. Quella soglia pero' esclude le app che si
        # chiamano davvero con tre lettere: Arc non veniva mai chiusa, quindi non
        # apriva nessuna finestra nuova (e' a istanza singola), quindi il monitor
        # continuava a mostrare la finestra di prima. Sul Mac si apriva Arc e si
        # vedeva il Blocco note con l'icona di Arc: il sintomo era lontanissimo
        # dalla causa.
        #
        # Il percorso invece non si presta a equivoci - o l'eseguibile sta nella
        # cartella di quel pacchetto o no - e non ha bisogno di nessuna soglia.
        if ($root) {
            Note "chiudo i processi sotto $root"
            Get-Process -EA SilentlyContinue | Where-Object {
                $exePath = $null
                try { $exePath = $_.Path } catch { }
                $exePath -and $exePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
            } | Stop-Process -Force -EA SilentlyContinue
        } else {
            # Senza il pacchetto si torna al confronto sui nomi, che e' impreciso
            # ma meglio di niente: qui la soglia resta, perche' senza percorso un
            # nome di due lettere aggancerebbe processi che non c'entrano.
            $leaf = ($fam -split '_')[0]
            Note "pacchetto $fam non trovato: ripiego sul nome"
            Get-Process -EA SilentlyContinue |
                Where-Object { $_.ProcessName.Length -gt 2 -and $leaf -match [regex]::Escape($_.ProcessName) } |
                Stop-Process -Force -EA SilentlyContinue
        }
    } else {
        Get-Process $name -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    }
    # Si aspetta che i processi siano DAVVERO finiti, invece di dormire un
    # secondo a occhio. Il secondo fisso si pagava a ogni apertura anche quando
    # non c'era niente da chiudere - misurato, era un quarto del tempo di uno
    # scambio su finestra calda - e nei casi lenti non bastava comunque.
    #
    # Si guarda la stessa cosa che si e' chiusa: la lista dei processi da
    # terminare viene ricalcolata, e appena e' vuota si prosegue.
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
        $vivi = 0
        if ($packaged -and $root) {
            $vivi = @(Get-Process -EA SilentlyContinue | Where-Object {
                $p = $null; try { $p = $_.Path } catch { }
                $p -and $p.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
            }).Count
        } elseif (-not $packaged) {
            $vivi = @(Get-Process $name -EA SilentlyContinue).Count
        }
        if ($vivi -eq 0) { break }
        Start-Sleep -Milliseconds 50
    }
}

# L'handle della finestra PRECEDENTE si cancella PRIMA di lanciare la nuova app.
#
# Senza questo, hwnd<slot>.txt continua a indicare la finestra di prima finche'
# quella nuova non compare - e se non compare mai (app che non parte, che chiede
# un aggiornamento, che apre solo un dialogo) resta li' per sempre. Il Mac chiede
# "c'e' una finestra su questo slot?", gli si risponde di si' mostrando la
# vecchia, e l'utente vede il Blocco note con sopra il nome e l'icona dell'app che
# ha appena aperto. Meglio un file vuoto per qualche secondo, che e' una risposta
# onesta, di un handle che mente.
Remove-Item "C:\winfleet\hwnd$Slot.txt" -Force -EA SilentlyContinue

$before = [P]::Candidates()

# Gli handle che gli ALTRI slot hanno gia' rivendicato, riletti a ogni giro: due
# slot che lanciano un'app nello stesso momento vedono l'uno la finestra
# dell'altro come "nuova", e senza questo se la contendono. I file li scrive
# questo stesso script, uno per slot.
function Get-TakenHwnds {
    $taken = New-Object 'System.Collections.Generic.List[IntPtr]'
    foreach ($f in Get-ChildItem 'C:\winfleet\hwnd*.txt' -EA SilentlyContinue) {
        if ($f.Name -eq "hwnd$Slot.txt") { continue }
        try {
            $v = [int64]((Get-Content $f.FullName -Raw -EA Stop).Trim())
            if ($v -ne 0) { $taken.Add([IntPtr]$v) }
        } catch { }
    }
    return $taken.ToArray()
}

if ($preLaunched) {
    Note "app gia' avviata dall'agente: non la rilancio"
    # ATTENZIONE all'ordine: $before e' stato preso ADESSO, cioe' dopo che
    # l'agente ha lanciato l'app. Se la finestra e' gia' comparsa sta gia' in
    # quell'elenco, e "la finestra comparsa dopo" non la troverebbe MAI - lo
    # script aspetterebbe trenta secondi una finestra che e' li' da un pezzo.
    #
    # Si toglie quindi da $before tutto cio' che appartiene ai processi di
    # QUESTA app: sono nate ora, per noi, e vanno considerate nuove.
    $mine = New-Object 'System.Collections.Generic.List[IntPtr]'
    foreach ($w in $before) {
        $wp = 0; [P]::GetWindowThreadProcessId($w, [ref]$wp) | Out-Null
        $keep = $true
        try {
            $pr = Get-Process -Id $wp -EA Stop
            $pth = $null; try { $pth = $pr.Path } catch { }
            if ($packaged -and $root -and $pth -and $pth.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $keep = $false }
            elseif (-not $packaged -and $pth -and $pth.Equals($Exe, [StringComparison]::OrdinalIgnoreCase)) { $keep = $false }
        } catch { }
        if ($keep) { $mine.Add($w) }
    }
    $before = $mine
} elseif ($packaged) {
    Start-Process 'explorer.exe' -ArgumentList $Exe | Out-Null
    Note "avviata $Exe"
} else {
    Start-Process -FilePath $Exe | Out-Null
    Note "avviata $Exe"
}

$h = [IntPtr]::Zero
for ($i = 0; $i -lt 75 -and $h -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 400
    $h = [P]::FindNew($before.ToArray(), (Get-TakenHwnds))
}
if ($h -eq [IntPtr]::Zero) { Note 'nessuna finestra comparsa'; return }

$appPid = 0
[P]::GetWindowThreadProcessId($h, [ref]$appPid) | Out-Null
Set-Content "C:\winfleet\pid$Slot.txt" $appPid
# L'handle serve all'agente, che e' quello che risponde alle richieste di
# ridimensionamento: qui la finestra la si trova e la si tiene, la geometria la muove
# lui perche' deve poter rispondere in millisecondi.
Set-Content "C:\winfleet\hwnd$Slot.txt" ([int64]$h)
Note "finestra $h (pid $appPid)"

# Via il frame: sul Mac la finestra e' gia' una finestra, quella di Windows dentro
# sarebbe una cornice dentro una cornice.
$GWL_STYLE = -16
$rm = 0x00C00000 -bor 0x00040000 -bor 0x00800000   # WS_CAPTION | WS_THICKFRAME | WS_BORDER
$st = [int64][P]::GetWindowLongPtr($h, $GWL_STYLE)
[P]::SetWindowLongPtr($h, $GWL_STYLE, [IntPtr]($st -band (-bnot $rm))) | Out-Null

$SWP_SHOWWINDOW = 0x0040
$RECT = "C:\winfleet\rect$Slot.txt"
$gone = 0
$lastW = -1; $lastH = -1; $lastH2 = [IntPtr]::Zero
$lastScan = Get-Date
while ($true) {
    if (-not [P]::IsWindow($h) -or -not [P]::IsWindowVisible($h)) {
        $h2 = [P]::FindNew($before.ToArray(), (Get-TakenHwnds))          # splash -> finestra vera
        if ($h2 -ne [IntPtr]::Zero) { $h = $h2; $gone = 0; Set-Content "C:\winfleet\hwnd$Slot.txt" ([int64]$h) }
        # Conta il TEMPO, non i giri: il ciclo gira dieci volte al secondo per
        # seguire i ridimensionamenti, e tre giri sarebbero tre decimi — meno di
        # quanto ci mette un'app a sostituire la sua finestra di avvio con quella
        # vera. Tre secondi senza nessuna finestra vogliono dire chiusa davvero.
        elseif (++$gone -ge 30) { break }
    } else {
        $gone = 0
        # La finestra vecchia puo' restare viva mentre l'app ne apre un'altra:
        # succede con le app in pacchetto (la Calcolatrice lo fa) e con Electron.
        # Il ramo sopra non scatta - la vecchia c'e' ancora - quindi l'handle
        # pubblicato restava indietro e l'agente comandava una finestra che non si
        # vede piu': "riduci a icona" non faceva nulla, senza un errore.
        #
        # Ogni due secondi si guarda se e' comparsa una finestra NUOVA dello stesso
        # processo: se c'e', quella e' la finestra buona e si aggiorna il file.
        if (((Get-Date) - $lastScan).TotalSeconds -ge 2) {
            $lastScan = Get-Date
            $h3 = [P]::FindNew($before.ToArray(), (Get-TakenHwnds))
            if ($h3 -ne [IntPtr]::Zero -and $h3 -ne $h) {
                $p3 = 0; [P]::GetWindowThreadProcessId($h3, [ref]$p3) | Out-Null
                if ($p3 -eq $appPid) {
                    $h = $h3
                    Set-Content "C:\winfleet\hwnd$Slot.txt" ([int64]$h)
                    Note "finestra sostituita: ora $h"
                }
            }
        }
    }

    $m = Get-Monitor
    if ($m) { $mon = $m }

    # Misura richiesta dal Mac, se c'e'. Mai piu' grande dello schermo: oltre il bordo
    # la finestra verrebbe tagliata e il ritaglio lato client mostrerebbe il vuoto.
    $tw = $mon.width; $th = $mon.height
    if (Test-Path $RECT) {
        try {
            $r = (Get-Content $RECT -Raw -EA Stop).Trim() -split '\s+'
            if ($r.Count -ge 2) {
                $rw = [int]$r[0]; $rh = [int]$r[1]
                if ($rw -gt 0 -and $rh -gt 0) {
                    $tw = [Math]::Min($rw, $mon.width)
                    $th = [Math]::Min($rh, $mon.height)
                }
            }
        } catch { }
    }

    # Si tocca la finestra solo quando serve davvero: rifare SetWindowPos dieci volte
    # al secondo su misure identiche fa sfarfallare le app che ridisegnano al resize.
    #
    # E non si tocca affatto se l'utente l'ha RIDOTTA A ICONA dal Mac: lo
    # SW_RESTORE qui sotto la farebbe risalire entro un decimo di secondo, cioe'
    # il pulsante giallo non funzionerebbe mai. Chi e' a icona resta a icona
    # finche' non lo si chiede: al ripristino l'agente fa SW_RESTORE e da li' in
    # poi questo ciclo riprende a occuparsi della geometria.
    if ([P]::IsIconic($h)) { Start-Sleep -Milliseconds 100; continue }

    if ($tw -ne $lastW -or $th -ne $lastH -or $h -ne $lastH2) {
        [P]::ShowWindow($h, 9) | Out-Null              # SW_RESTORE
        [P]::SetWindowPos($h, [IntPtr]::Zero, $mon.x, $mon.y, $tw, $th, $SWP_SHOWWINDOW) | Out-Null
        # Posizionata non vuol dire davanti. Ogni schermo ha un suo ordine di
        # sovrapposizione, e una finestra puo' stare al posto giusto, con la misura
        # giusta, visibile e non nascosta — e avere sopra un'altra finestra a schermo
        # intero (l'overlay di NVIDIA sta esattamente li'). Sunshine cattura il
        # monitor, non la finestra: quello che si ottiene e' un rettangolo nero con
        # tutti i controlli che dicono che va bene, ed e' il caso piu' difficile da
        # diagnosticare perche' non lascia traccia da nessuna parte.
        [P]::BringWindowToTop($h) | Out-Null
        [P]::SetForegroundWindow($h) | Out-Null
        $lastW = $tw; $lastH = $th; $lastH2 = $h
    }
    Start-Sleep -Milliseconds 100
}
Note 'finestra chiusa'
Remove-Item "C:\winfleet\pid$Slot.txt" -Force -EA SilentlyContinue
Remove-Item "C:\winfleet\hwnd$Slot.txt" -Force -EA SilentlyContinue
