<#
.SYNOPSIS
  Ridimensiona la finestra di un'app streamata, subito, e conferma di averlo fatto.

.DESCRIPTION
  Serve a due cose che un file su disco non puo' dare.

  La prima e' la latenza. Trascinando una finestra sul Mac la misura nuova va detta a
  Windows decine di volte al secondo; un comando ssh per volta costa un paio di
  decimi e il ridimensionamento resta indietro rispetto al video. Qui la richiesta e'
  una GET su LAN: pochi millisecondi.

  La seconda e' la conferma. Il client mostra solo il rettangolo dell'app: se lo
  allarga prima che la finestra su Windows sia cresciuta, in quella frazione di
  secondo si vede il desktop intorno. Questa risposta arriva DOPO la SetWindowPos, ed
  e' cio' che permette al client di allargare il ritaglio solo quando c'e' davvero
  qualcosa da mostrare.

  L'handle della finestra lo pubblica wf-place.ps1, che e' quello che l'ha trovata.

  Fa anche da sportello per il pannello sul Mac: elencare le finestre aperte sul PC e
  aprirne una, senza dover passare da ssh (che per una tendina che si apre e si chiude
  costerebbe mezzo secondo a colpo).

  Endpoint (solo LAN, nessun dato personale, nessuna scrittura fuori da C:\winfleet):
    GET /rect?slot=0&w=1200&h=800   ->  "ok 1200 800"   (misura davvero applicata)
    GET /hwnd?slot=0                ->  handle della finestra, o "no"
    GET /vdd                        ->  il vdd.json (monitor virtuali)
    GET /mode?slot=0                ->  "1800x1200"  misura attuale del monitor
    GET /show?slot=0&how=min        ->  "ok"  riduce a icona l'app su Windows
    GET /show?slot=0&how=restore    ->  "ok"  la rimette com'era
    GET /windows                    ->  una riga per finestra: "<hwnd>\t<titolo>"
    GET /raise?hwnd=123             ->  "ok"  porta quella finestra in primo piano
    GET /ping                       ->  "ok"

.EXAMPLE
  powershell -File wf-agent.ps1 -Port 48088
#>
[CmdletBinding()]
param([int]$Port = 48088)

$ErrorActionPreference = 'Stop'
$LOG = 'C:\winfleet\agent.log'
function Note($m) { "$(Get-Date -f 'HH:mm:ss')  $m" | Add-Content $LOG }
trap { Note "ERRORE: $_"; break }
Set-Content $LOG ''

# Un agente alla volta: gli altri si spengono ADESSO.
#
# "schtasks /end /tn winfleet-agent" chiude il task, non il processo
# powershell che ci gira dentro: quello resta vivo e continua ad ascoltare.
# Ogni riavvio ne lasciava quindi uno in piu' - trovati TRE agenti insieme il
# 26/08, avviati alle 00:00, alle 12:39 e alle 19:19, tutti convinti di essere
# l'agente.
#
# Non e' innocuo come sembra: solo uno tiene la porta, gli altri girano nel
# ciclo "porta occupata, aspetto" oppure - peggio - rispondono a meta' dopo un
# riavvio della porta, e da fuori l'agente sembra a tratti muto. E' proprio il
# guasto che agent-revive.sh voleva provare e non riusciva a riprodurre: il
# test spegneva il task, l'agente rispondeva lo stesso, e il test si arrendeva
# con uno SKIP.
#
# Si guarda la riga di comando, non il nome: "powershell.exe" da solo
# ucciderebbe qualsiasi script di chiunque.
try {
    $mio = $PID
    $vecchi = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
                Where-Object { $_.CommandLine -like '*wf-agent.ps1*' -and $_.ProcessId -ne $mio })
    foreach ($v in $vecchi) {
        Note "spengo un agente precedente (pid $($v.ProcessId))"
        Stop-Process -Id $v.ProcessId -Force -EA SilentlyContinue
    }
    if ($vecchi.Count -gt 0) { Start-Sleep -Milliseconds 500 }
} catch { Note "non sono riuscito a cercare agenti vecchi: $_" }

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class A {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

  // Le finestre che una persona chiamerebbe "aperte": visibili, con un titolo, non
  // di proprieta' di un'altra (dialoghi e tooltip) e non larghe due pixel.
  public static string ListWindows() {
    System.Text.StringBuilder outp = new System.Text.StringBuilder();
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      if (!IsWindowVisible(h)) return true;
      if (GetWindow(h, 4) != IntPtr.Zero) return true;
      int len = GetWindowTextLength(h);
      if (len == 0) return true;
      RECT r; if (!GetWindowRect(h, out r)) return true;
      if ((r.R - r.L) < 200 || (r.B - r.T) < 120) return true;
      System.Text.StringBuilder t = new System.Text.StringBuilder(len + 1);
      GetWindowText(h, t, len + 1);
      outp.Append(h.ToInt64()).Append('\t').Append(t.ToString()).Append('\n');
      return true;
    }, IntPtr.Zero);
    return outp.ToString();
  }

  // Come ListWindows, ma dice anche DOVE sta ogni finestra e di che processo e'.
  //
  // Serve a riconoscere le finestre che un'app ha aperto per conto suo su uno
  // schermo virtuale - il classico "Salva con nome" di Esplora file lanciato da
  // Arc. Sono finestre vere, sullo schermo giusto, che nessuno sta mostrando: da
  // fuori l'utente ha cliccato "scarica" e non e' successo niente.
  //
  // Righe: hwnd \t x \t y \t w \t h \t pid \t titolo
  public static string ListWindowsFull() {
    System.Text.StringBuilder outp = new System.Text.StringBuilder();
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      if (!IsWindowVisible(h)) return true;
      if (GetWindow(h, 4) != IntPtr.Zero) return true;
      int len = GetWindowTextLength(h);
      if (len == 0) return true;
      RECT r; if (!GetWindowRect(h, out r)) return true;
      if ((r.R - r.L) < 200 || (r.B - r.T) < 120) return true;
      System.Text.StringBuilder t = new System.Text.StringBuilder(len + 1);
      GetWindowText(h, t, len + 1);
      int wpid = 0; GetWindowThreadProcessId(h, out wpid);
      outp.Append(h.ToInt64()).Append('\t')
          .Append(r.L).Append('\t').Append(r.T).Append('\t')
          .Append(r.R - r.L).Append('\t').Append(r.B - r.T).Append('\t')
          .Append(wpid).Append('\t')
          .Append(t.ToString()).Append('\n');
      return true;
    }, IntPtr.Zero);
    return outp.ToString();
  }
}
'@

# Rileggere e riparsare il JSON dei monitor a ogni richiesta costava duecento
# millisecondi buoni — piu' di tutto il resto messo insieme, e abbastanza da far
# sentire il ridimensionamento in ritardo rispetto al video. Si rilegge solo quando
# il file cambia davvero.
$script:monCache = @{}
$script:monStamp = [DateTime]::MinValue

function Get-Monitor($slot) {
    try { $t = (Get-Item 'C:\winfleet\vdd.json' -EA Stop).LastWriteTimeUtc } catch { return $null }
    if ($t -ne $script:monStamp) {
        try {
            $raw = (Get-Content 'C:\winfleet\vdd.json' -Raw -EA Stop).TrimStart([char]0xFEFF)
            $parsed = ConvertFrom-Json $raw
        } catch { return $null }
        $c = @{}
        foreach ($e in $parsed) { if ([int]$e.width -gt 0) { $c[[int]$e.slot] = $e } }
        $script:monCache = $c
        $script:monStamp = $t
    }
    if ($script:monCache.ContainsKey([int]$slot)) { $script:monCache[[int]$slot] } else { $null }
}

# Anche l'handle: il file cambia solo quando l'app riapre una finestra.
$script:hwndCache = @{}
$script:hwndStamp = @{}

function Get-Hwnd($slot) {
    $f = "C:\winfleet\hwnd$slot.txt"
    try { $t = (Get-Item $f -EA Stop).LastWriteTimeUtc } catch { return [IntPtr]::Zero }
    if (-not $script:hwndStamp.ContainsKey($slot) -or $script:hwndStamp[$slot] -ne $t) {
        try { $script:hwndCache[$slot] = [IntPtr][int64](Get-Content $f -Raw).Trim() } catch { return [IntPtr]::Zero }
        $script:hwndStamp[$slot] = $t
    }
    $h = $script:hwndCache[$slot]

    # Il file lo scrive wf-place, che aggiorna l'handle solo quando la vecchia
    # finestra SPARISCE. Un'app che ne apre una nuova mentre la prima e' ancora in
    # piedi (la Calcolatrice lo fa) lascia il file indietro, e quando il task place
    # termina non lo aggiorna piu' nessuno: /show agiva su una finestra morta e non
    # succedeva niente, in silenzio.
    #
    # Qui NON si indovina. Provato a cercare "la finestra sul monitor dello slot" e
    # sul monitor c'era anche un terminale: si sarebbe minimizzata quella. Un
    # recupero che prende la finestra sbagliata e' peggio del guasto che cura.
    # L'handle giusto lo conosce wf-place, che ha lanciato l'app: e' li' che va
    # tenuto aggiornato. Qui ci si limita a non fingere che vada tutto bene.
    if (-not [A]::IsWindow($h)) {
        Note "hwnd$slot stale ($($h.ToInt64())): la finestra non esiste piu'"
        return [IntPtr]::Zero
    }
    $h
}

# La misura applicata si RILEGGE dalla finestra invece di ripetere quella chiesta:
# un'app con una dimensione minima propria (ce ne sono molte) darebbe altrimenti una
# conferma falsa, e il client scoprirebbe il desktop proprio dove l'app non arriva.
function Set-AppSize($slot, $w, $h) {
    $hwnd = Get-Hwnd $slot
    if ($hwnd -eq [IntPtr]::Zero -or -not [A]::IsWindow($hwnd)) { return $null }

    $mon = Get-Monitor $slot
    if (-not $mon) { return $null }
    $w = [Math]::Max(200, [Math]::Min([int]$w, [int]$mon.width))
    $h = [Math]::Max(150, [Math]::Min([int]$h, [int]$mon.height))

    [void][A]::SetWindowPos($hwnd, [IntPtr]::Zero, [int]$mon.x, [int]$mon.y, $w, $h, 0x0040)
    $r = New-Object A+RECT
    if (-not [A]::GetWindowRect($hwnd, [ref]$r)) { return "$w $h" }
    "$($r.R - $r.L) $($r.B - $r.T)"
}

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")

# Se l'agente precedente e' morto male, Windows tiene la registrazione HTTP per
# qualche secondo e Start() fallisce con "Conflitto con una registrazione
# esistente". L'agente moriva li', e restava giu': winfleet smetteva di aprire
# qualsiasi cosa, con un timeout di curl come unico sintomo. Ora si aspetta che
# la porta si liberi - succede da solo, in una decina di secondi.
$avviato = $false
for ($t = 0; $t -lt 30 -and -not $avviato; $t++) {
    try { $listener.Start(); $avviato = $true }
    catch {
        if ($t -eq 0) { Note "porta $Port ancora occupata da un'istanza precedente: aspetto" }
        Start-Sleep -Seconds 2
    }
}
if (-not $avviato) { Note "porta $Port occupata dopo un minuto: esco"; exit 1 }
Note "in ascolto su $Port"

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    # Il flusso della richiesta va chiuso quanto quello della risposta: se resta
    # aperto la connessione non si libera, ed e' l'altra meta' dei CLOSE_WAIT.
    try { if ($req.InputStream) { $req.InputStream.Close() } } catch { }
    $body = 'no'
    try {
        if ($req.Url.AbsolutePath -eq '/rect') {
            $slot = [int]$req.QueryString['slot']
            $w    = [int]$req.QueryString['w']
            $h    = [int]$req.QueryString['h']
            $got  = Set-AppSize $slot $w $h
            $body = if ($got) { "ok $got" } else { 'no' }
        }
        elseif ($req.Url.AbsolutePath -eq '/place') {
            # Metti QUESTA app sul monitor di QUESTO slot.
            #
            # Lo faceva un giro ssh che avviava powershell.exe sull'host, e il
            # lavoro vero - scrivere una riga, riavviare un'attivita' - dura
            # pochi millisecondi: erano 1.2 secondi di AVVIO dell'interprete,
            # misurati, pagati a ogni apertura. L'agente e' gia' acceso e gia'
            # nella sessione giusta, quindi qui la stessa cosa costa quanto una
            # richiesta HTTP (128 ms misurati).
            #
            # L'eseguibile arriva in base64: fra URL, query string e percorsi di
            # Windows ci sono troppi caratteri che vogliono dire altro.
            $slot = $req.QueryString['slot']
            $b64  = "$($req.QueryString['exe'])"
            if ($null -eq $slot -or -not $b64) {
                $body = 'no'
            } else {
                $slot = [int]$slot
                try {
                    $exe = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
                    # Prima si SCRIVE, poi si ferma il task e lo si rilancia: se
                    # il task riparte da solo trova gia' il valore nuovo, e non
                    # serve nessuna pausa di sicurezza in mezzo.
                    #
                    # NON "Set-Content -Encoding UTF8": quello scrive il BOM, e
                    # wf-place leggerebbe un percorso che comincia con tre byte
                    # invisibili - l'app non parte e non si capisce perche'.
                    [IO.File]::WriteAllText("C:\winfleet\app$slot.txt", $exe,
                                            (New-Object Text.UTF8Encoding $false))

                    # L'app la si CHIUDE e la si RILANCIA da qui, subito, invece
                    # di lasciar fare tutto al task.
                    #
                    # Il task ci mette 1.5 secondi solo a partire - e' powershell
                    # che si avvia, misurato tre volte: 1480, 1600, 1441 ms - e
                    # in quel tempo non succede niente di utile. L'agente e' gia'
                    # in esecuzione nella sessione interattiva, quindi puo' fare
                    # le due cose che contano mentre il task sta ancora nascendo.
                    # Al task resta il suo lavoro vero: trovare la finestra,
                    # toglierle la cornice e seguirne la geometria per sempre.
                    #
                    # wf-place NON rilancia l'app se la trova gia' avviata da
                    # qui: il file "launched<slot>.txt" e' il messaggio fra i due.
                    $packaged = $exe -like 'shell:AppsFolder\*'
                    $isShell  = $exe -match '(^|\\)explorer\.exe$'
                    if (-not $isShell) {
                        try {
                            if ($packaged) {
                                $fam = ($exe -replace '^shell:AppsFolder\\', '') -replace '!.*$', ''
                                $ap = Get-AppxPackage | Where-Object { $_.PackageFamilyName -eq $fam } | Select-Object -First 1
                                if ($ap -and $ap.InstallLocation) {
                                    $rootp = $ap.InstallLocation
                                    Get-Process -EA SilentlyContinue | Where-Object {
                                        $pp = $null; try { $pp = $_.Path } catch { }
                                        $pp -and $pp.StartsWith($rootp, [StringComparison]::OrdinalIgnoreCase)
                                    } | Stop-Process -Force -EA SilentlyContinue
                                }
                            } else {
                                $pn = [IO.Path]::GetFileNameWithoutExtension($exe)
                                Get-Process $pn -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
                            }
                        } catch { }
                    }

                    & schtasks /end /tn "winfleet-place$slot" 2>&1 | Out-Null
                    & schtasks /run /tn "winfleet-place$slot" 2>&1 | Out-Null

                    if (-not $isShell) {
                        try {
                            if ($packaged) { Start-Process 'explorer.exe' -ArgumentList $exe | Out-Null }
                            else           { Start-Process -FilePath $exe | Out-Null }
                            [IO.File]::WriteAllText("C:\winfleet\launched$slot.txt", $exe,
                                                    (New-Object Text.UTF8Encoding $false))
                        } catch { Note "avvio app slot $slot fallito: $_" }
                    }
                    $body = 'ok'
                } catch {
                    Note "place slot $slot fallita: $_"
                    $body = 'no'
                }
            }
        }
        elseif ($req.Url.AbsolutePath -eq '/show') {
            # Riduci a icona sul Mac deve ridurre a icona anche su Windows.
            #
            # Senza questo, minimizzare sul Mac lasciava la finestra dell'app in
            # primo piano sul suo schermo virtuale: lo stream continua a mandarla e
            # al ripristino si vedeva quello che nel frattempo Windows aveva messo
            # sopra, cioe' una finestra che l'utente non aveva mai aperto li'.
            #
            # SW_SHOWMINNOACTIVE (7) e non SW_MINIMIZE (6): minimizzare "attivando"
            # sposta il fuoco su un'altra finestra dello schermo virtuale, che e'
            # esattamente cio' che faceva emergere quella sotto.
            #
            # L'handle viene da un file che NON viene ripulito quando lo slot si
            # libera: verificato dal vivo, hwnd3.txt puntava ancora a una finestra di
            # Paint dell'utente mentre lo slot risultava libero. Agire su un handle
            # cosi' vuol dire minimizzare una finestra che non c'entra nulla. Si
            # accetta il comando solo se quell'handle sta ANCORA sul monitor virtuale
            # di questo slot: e' l'unica prova che la finestra sia la nostra.
            $slot = [int]$req.QueryString['slot']
            $how  = "$($req.QueryString['how'])"
            # Parametri mancanti o incomprensibili non devono AGIRE.
            # Misurato: "/show" senza nulla diventava slot=0 (il default di [int]
            # su stringa vuota) e "how=pippo" finiva nel ramo restore, perche' era
            # l'else. Due modi per toccare una finestra senza averlo chiesto.
            if ($null -eq $req.QueryString['slot'] -or $how -notin @('min','restore')) {
                $body = 'no'
            } else {
            $hwnd = Get-Hwnd $slot
            # La prova che la finestra sia "la nostra" e' la stessa che usa /rect:
            # l'handle pubblicato per questo slot, e che sia ancora una finestra.
            #
            # Avevo aggiunto anche "e deve stare dentro il monitor dello slot", e
            # quella riga rifiutava il caso buono: una finestra GIA' ridotta a icona
            # sta fuori da ogni monitor, quindi il ripristino diventava impossibile
            # e il minimize falliva su una finestra appena minimizzata. Misurato:
            # /rect rispondeva "ok 1209 755" sullo stesso handle su cui /show
            # rispondeva "no". Una guardia che blocca il lavoro vero non protegge
            # niente: protegge chi la scrive dal pensarci.
            if ([A]::IsWindow($hwnd)) {
                if ($how -eq 'min') { [void][A]::ShowWindow($hwnd, 7) }
                else                { [void][A]::ShowWindow($hwnd, 9) }   # SW_RESTORE
                $body = 'ok'
            }
            }
        }
        elseif ($req.Url.AbsolutePath -eq '/hwnd') {
            # L'handle della finestra di questo slot, se ne ha una viva. Serve a
            # sapere se c'e' qualcosa da mostrare SENZA toccarla: /rect lo direbbe
            # anche lui, ma ridimensiona, e un controllo non deve cambiare cio'
            # che osserva.
            $slot = [int]$req.QueryString['slot']
            $h = Get-Hwnd $slot
            if ([A]::IsWindow($h)) { $body = "$($h.ToInt64())" }
        }
        elseif ($req.Url.AbsolutePath -eq '/vdd') {
            # Il vdd.json cosi' com'e': stessa informazione che si prendeva con un
            # "type" via ssh, ma su HTTP costa millisecondi invece di due decimi.
            # Su un'apertura si legge piu' volte, e li' la differenza si sente.
            try { $body = Get-Content 'C:\winfleet\vdd.json' -Raw -EA Stop } catch { $body = 'no' }
        }
        elseif ($req.Url.AbsolutePath -eq '/mode') {
            # La misura ATTUALE del monitor virtuale di uno slot, per chi deve
            # aspettare che un cambio di risoluzione sia andato a buon fine senza
            # dormire a occhio.
            $slot = [int]$req.QueryString['slot']
            $mon = Get-Monitor $slot
            if ($mon) { $body = "$($mon.width)x$($mon.height)" }
        }
        elseif ($req.Url.AbsolutePath -eq '/nowin') {
            # "L'app non ha aperto nessuna finestra": una resa gia' constatata.
            #
            # Serve perche' il Mac altrimenti aspetta a vuoto: la finestra di
            # Moonlight si apre SEMPRE, anche quando dall'altra parte non e'
            # partito niente, quindi da li' non si distingue un'app lenta da
            # un'app che non partira' mai. Il risultato erano 56 secondi misurati
            # per arrivare a una risposta che qui si conosceva dopo 35.
            #
            # Il file lo scrive wf-place quando smette di cercare la finestra, e
            # lo cancella quando invece la trova.
            $slot = [int]$req.QueryString['slot']
            $f = "C:\winfleet\nowin$slot.txt"
            if (Test-Path $f) {
                # Solo se e' di ADESSO: un file vecchio e' di un'apertura
                # precedente, e farebbe fallire quella in corso.
                $eta = ((Get-Date) - (Get-Item $f).LastWriteTime).TotalSeconds
                if ($eta -lt 120) { $body = 'si' } else { $body = 'no' }
            } else { $body = 'no' }
        }
        elseif ($req.Url.AbsolutePath -eq '/windows') { $body = [A]::ListWindows() }
        elseif ($req.Url.AbsolutePath -eq '/cursor-alive') {
            # "Il Mac e' ancora qui, tieni pure il cursore nascosto."
            #
            # Nascondere il cursore e' un cambiamento GLOBALE su Windows, e
            # rimetterlo dipendeva SOLO dal Mac: se il sorvegliante moriva male
            # (kill -9, Mac che dorme, rete che cade, un'apertura fallita a
            # meta') il puntatore restava invisibile su tutto il PC finche'
            # qualcuno non lanciava winfleet doctor. Visto dal vivo: quattro
            # giorni senza cursore, anche da Parsec e davanti al monitor, e
            # nessuno che collegasse la cosa a winfleet.
            #
            # Ora chi nasconde deve anche farsi vivo. Questo endpoint aggiorna un
            # file-battito; se smette di arrivare, wf-cursor-guard rimette i
            # cursori del tema da solo. Un guasto sul Mac non lascia piu' il PC
            # senza puntatore.
            [void](New-Item -Path 'C:\winfleet\cursor-alive.txt' -ItemType File -Force)
            $body = 'ok'
        }
        elseif ($req.Url.AbsolutePath -eq '/orphans') {
            # Le finestre che stanno su uno schermo virtuale e che NESSUNO slot
            # sta mostrando.
            #
            # E' il caso di un'app che ne apre un'altra: si clicca "scarica" in
            # Arc, Windows apre Esplora file sullo stesso schermo virtuale, e sul
            # Mac non si vede niente - la finestra c'e', e' viva, ma il ritaglio
            # mostra solo quella dell'app principale. Da fuori sembra che il
            # click non abbia fatto nulla.
            #
            # "Orfana" e' una cosa precisa: sta dentro il rettangolo di un
            # monitor virtuale, e il suo handle non e' quello che lo slot ha
            # rivendicato. Il confronto e' con l'handle, non col titolo o col
            # processo: e' l'unico dato che non si presta a equivoci.
            $out = New-Object Text.StringBuilder
            $righe = [A]::ListWindowsFull() -split "`n"
            $vdd = @()
            # "@(ConvertFrom-Json ...)" NON basta: su un array JSON questa
            # versione di PowerShell restituisce UN oggetto le cui proprieta'
            # sono a loro volta array (slot = 0,1,2,3), e avvolgerlo in @() da'
            # un elenco di UNO. Il primo cast a [int] esplode con "Impossibile
            # convertire System.Object[] in System.Int32" e l'endpoint muore in
            # silenzio. Si scorre con foreach, che invece srotola davvero.
            try {
                $parsed = ConvertFrom-Json ((Get-Content 'C:\winfleet\vdd.json' -Raw).TrimStart([char]0xFEFF))
                foreach ($e in $parsed) { $vdd += $e }
            } catch { }
            foreach ($r in $righe) {
                if (-not $r) { continue }
                $c = $r -split "`t"
                if ($c.Count -lt 7) { continue }
                $hw = [int64]$c[0]; $x = [int]$c[1]; $y = [int]$c[2]
                $w  = [int]$c[3];   $h = [int]$c[4]; $wpid = [int]$c[5]
                $titolo = $c[6]
                # "Program Manager" e' il desktop di Windows: e' una finestra a
                # tutti gli effetti, sta ovunque, e non e' roba che l'utente ha
                # aperto. Portarla sul Mac significherebbe mostrargli lo sfondo
                # del PC al posto della sua app.
                if ($titolo -eq 'Program Manager') { continue }
                # E le finestre di Moonlight/Sunshine: sono nostre, non dell'app.
                if ($titolo -like 'NVIDIA GeForce Overlay*') { continue }
                if ($titolo -eq 'Esperienza input di Windows' -or $titolo -eq 'Windows Input Experience') { continue }
                $cx = $x + [int]($w / 2); $cy = $y + [int]($h / 2)
                foreach ($m in $vdd) {
                    if ([int]$m.width -le 0) { continue }
                    if ($cx -lt [int]$m.x -or $cx -ge ([int]$m.x + [int]$m.width))  { continue }
                    if ($cy -lt [int]$m.y -or $cy -ge ([int]$m.y + [int]$m.height)) { continue }
                    $slot = [int]$m.slot
                    $mio = Get-Hwnd $slot
                    if ($mio -ne [IntPtr]::Zero -and $mio.ToInt64() -eq $hw) { break }
                    # E nemmeno se e' la finestra principale di un ALTRO slot:
                    # due slot che mostrano la stessa finestra sono due copie
                    # della stessa cosa, e chiuderne una chiude l'altra.
                    $altrui = $false
                    foreach ($m2 in $vdd) {
                        $s2 = [int]$m2.slot
                        if ($s2 -eq $slot) { continue }
                        $h2 = Get-Hwnd $s2
                        if ($h2 -ne [IntPtr]::Zero -and $h2.ToInt64() -eq $hw) { $altrui = $true; break }
                    }
                    if ($altrui) { break }
                    # Una riga sola: in PowerShell una catena di .Append() spezzata
                    # su piu' righe NON continua - la seconda riga diventa
                    # un'istruzione a se' e l'endpoint muore in silenzio,
                    # rispondendo "no" senza dire perche'.
                    [void]$out.Append("$slot`t$hw`t$wpid`t$titolo`n")
                    break
                }
            }
            # Il prompt UAC: nasce sul monitor FISICO, quindi nessun ciclo qui
            # sopra puo' vederlo - quelli guardano dentro i monitor virtuali.
            #
            # Si azzera a ogni richiesta: senza, il valore del giro precedente
            # sopravvive nella sessione dell'agente e il file resterebbe li'
            # anche dopo che l'utente ha risposto al prompt.
            $uac_visto = $false
            #
            # E' il guasto peggiore fra quelli visti, perche' non somiglia a un
            # guasto: Windows chiede "consenti a questa app di apportare
            # modifiche", il prompt e' modale per TUTTO il sistema, e da qui in
            # poi non si clicca piu' niente - ne' nelle finestre winfleet, ne'
            # in Parsec. Nessuna finestra mostra la domanda, quindi non c'e'
            # niente da collegare al blocco: sembra che il PC si sia impiantato.
            # (Il 26/08 il prompt stava a (1492,532), sul monitor fisico, con
            # quattro finestre winfleet aperte che non rispondevano ai click.)
            #
            # Non si sposta e non si adotta: si SEGNALA, e basta.
            #
            # Le due vie ovvie sono state provate entrambe, e nessuna funziona.
            #
            # Adottarlo come orfano: il Mac risponde aprendo una finestra nuova
            # per mostrarlo, ma il prompt e' modale per tutto il sistema e
            # l'apertura si ferma subito ("cmd_open: inizio" e poi piu' niente,
            # misurato). Il sistema che dovrebbe aprire la finestra e' bloccato
            # proprio da cio' che quella finestra dovrebbe mostrare.
            #
            # Spostarlo sul monitor virtuale: SetWindowPos torna False con
            # errore 5, ACCESS_DENIED, anche dall'agente che gira con RunLevel
            # Highest nella sessione interattiva. E' UIPI: Windows protegge di
            # proposito la finestra di consenso da qualunque manipolazione
            # esterna, ed e' giusto cosi' - un prompt UAC spostabile da un
            # programma non sarebbe piu' una garanzia di niente.
            #
            # Quindi non si fa niente QUI: la domanda "c'e' un prompt aperto?"
            # la risponde /uac, che guarda direttamente il processo consent.exe
            # ed e' vero anche quando nessuno chiama /orphans. Il Mac la usa per
            # avvisare con parole sue - sapere perche' tutto e' fermo vale piu'
            # che restare a cliccare a vuoto su finestre che non rispondono.
            #
            # Resta solo l'ESCLUSIONE: il prompt non e' una finestra da adottare.
            # Il Mac ci prova - "figlia Controllo dell'account utente: la apro",
            # misurato - e l'apertura muore subito, perche' il sistema che
            # dovrebbe aprirla e' bloccato proprio da lei.
            $tenute = New-Object Text.StringBuilder
            foreach ($riga in ($out.ToString() -split "`n")) {
                if (-not $riga) { continue }
                $cc = $riga -split "`t"
                if ($cc.Count -ge 4 -and ($cc[3] -eq 'Controllo dell''account utente' -or
                                          $cc[3] -eq 'User Account Control')) { continue }
                [void]$tenute.Append("$riga`n")
            }
            $out = $tenute
            $body = $out.ToString()
            if (-not $body) { $body = '' }
        }
        elseif ($req.Url.AbsolutePath -eq '/raise') {
            $hw = [IntPtr][int64]$req.QueryString['hwnd']
            if ([A]::IsWindow($hw)) {
                [void][A]::ShowWindow($hw, 9)          # SW_RESTORE
                [void][A]::SetForegroundWindow($hw)
                $body = 'ok'
            }
        }
        elseif ($req.Url.AbsolutePath -eq '/ping') { $body = 'ok' }
        elseif ($req.Url.AbsolutePath -eq '/put') {
            # Scrivi un file in C:\winfleet, senza passare da ssh.
            #
            # Serve perche' ssh e' proprio la cosa che si rompe: quando sshd si
            # satura, "winfleet push" non arriva piu' e da li' in poi nessuna
            # correzione puo' essere caricata - compresa quella che
            # rimetterebbe in sesto ssh. Un cane che si morde la coda, visto il
            # 26/08 con un push fermo cinque minuti mentre questo agente
            # rispondeva in millisecondi.
            #
            # Il perimetro e' stretto di proposito: solo dentro C:\winfleet,
            # solo un nome di file semplice. Niente sottocartelle, niente ".."
            # - questo agente ascolta su tutta la rete locale, e un endpoint
            # che scrive dove gli si dice sarebbe una porta aperta sul PC.
            $nome = "$($req.QueryString['nome'])"
            $b64  = "$($req.QueryString['dati'])"
            if (-not $nome -or -not $b64) { $body = 'no' }
            elseif ($nome -match '[\\/:*?"<>|]' -or $nome -like '*..*') {
                Note "put rifiutato: nome sospetto '$nome'"
                $body = 'no'
            } else {
                try {
                    [IO.File]::WriteAllBytes("C:\winfleet\$nome", [Convert]::FromBase64String($b64))
                    $body = 'ok'
                } catch { $body = 'no' }
            }
        }
        elseif ($req.Url.AbsolutePath -eq '/push-clean') {
            # Chiude i "push" rimasti appesi ad aspettare stdin.
            #
            # "winfleet push" carica gli script cosi': base64 sul Mac, pipe in
            # ssh, e di la' un powershell che legge stdin con
            # [Console]::In.ReadToEnd(). Quando ssh muore male - e succede,
            # perche' sshd si satura - quel processo resta ad aspettare un EOF
            # che non arrivera' mai. Uccidere l'ssh dalla parte del Mac non lo
            # tocca.
            #
            # Trovati TRE il 26/08, appesi da quattro ore, due e due, per 129 MB
            # fermi a non fare niente. E la cosa peggiore non e' la memoria: la
            # loro riga di comando contiene il nome del file caricato, quindi
            # cercando "chi tocca wf-vdd.ps1" ne saltavano fuori tre e sembrava
            # che il pinger dei monitor si stesse moltiplicando. Un quarto d'ora
            # speso a inseguire un guasto che non esisteva.
            #
            # Perche' una rotta e non uno script generico: questo agente ascolta
            # su tutta la rete locale, e un endpoint che esegue quello che gli si
            # dice sarebbe una porta aperta sul PC. Qui il bersaglio e' scritto
            # nel codice e non arriva da fuori.
            $morti = 0
            try {
                $appesi = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
                            Where-Object { $_.CommandLine -like '*Console*In*ReadToEnd*' -and $_.ProcessId -ne $PID })
                foreach ($a in $appesi) {
                    Stop-Process -Id $a.ProcessId -Force -EA SilentlyContinue
                    Note "push appeso chiuso (pid $($a.ProcessId))"
                    $morti++
                }
                $body = "$morti"
            } catch {
                Note "push-clean fallito: $($_.Exception.Message)"
                $body = 'no'
            }
        }
        elseif ($req.Url.AbsolutePath -eq '/ssh-revive') {
            # Riavvia il server SSH di Windows.
            #
            # sshd si satura: dopo una sessione fitta di comandi - un push, una
            # diagnosi lunga - accetta la connessione TCP e poi chiude senza
            # completare il login ("Connection closed by ... port 22"), oppure
            # resta appeso a tempo indeterminato. Da fuori sembra il PC morto,
            # ma non lo e' affatto: questo agente, che parla HTTP, continua a
            # rispondere benissimo. Successo il 26/08, con "winfleet push"
            # fermo cinque minuti su quattordici file.
            #
            # E' proprio la situazione in cui NON si puo' usare ssh per
            # rimediare, quindi il rimedio deve passare da qui. Un servizio che
            # si riavvia e' reversibile e non tocca niente altro: nel peggiore
            # dei casi cadono sessioni ssh che erano gia' inutilizzabili.
            try {
                Restart-Service -Name sshd -Force -EA Stop
                Note 'sshd riavviato su richiesta'
                $body = 'ok'
            } catch {
                Note "sshd: riavvio fallito - $($_.Exception.Message)"
                $body = 'no'
            }
        }
        elseif ($req.Url.AbsolutePath -eq '/altri-client') {
            # "C'e' qualcun altro che sta usando questo PC?"
            #
            # Serve prima di nascondere il cursore, che e' un cambiamento di
            # SISTEMA: se c'e' una sessione Parsec aperta, quella persona si
            # ritrova senza puntatore per un vantaggio che riguarda solo le
            # finestre winfleet. Successo due volte in una sera, la seconda
            # segnalata con "non riesco a usare il PC".
            #
            # Parsec e' il caso concreto e l'unico rilevabile in modo
            # affidabile: chi e' seduto davanti al monitor non lascia un
            # processo da cercare. Va bene lo stesso - quello se ne accorge
            # subito, mentre una sessione remota rotta non la nota nessuno.
            $body = if (Get-Process -Name parsecd -EA SilentlyContinue) { 'si' } else { 'no' }
        }
        elseif ($req.Url.AbsolutePath -eq '/appsize') {
            # Quanto e' grande ADESSO la finestra dell'app di questo slot.
            #
            # Il Mac non puo' saperlo da solo: la sua finestra di Moonlight
            # resta della misura giusta anche quando l'app dall'altra parte si
            # e' rimpicciolita, e in mezzo resta un ritaglio che mostra
            # desktop. Successo con Arc: portata a 1209x806, tornata da sola a
            # 500x500, e sul Mac si vedeva lo sfondo di Windows con ogni
            # controllo verde.
            $slot = [int]$req.QueryString['slot']
            $hwnd = Get-Hwnd $slot
            if ($hwnd -ne [IntPtr]::Zero -and [A]::IsWindow($hwnd)) {
                $r = New-Object A+RECT
                if ([A]::GetWindowRect($hwnd, [ref]$r)) {
                    $body = "$($r.R - $r.L)x$($r.B - $r.T)"
                }
            }
        }
        elseif ($req.Url.AbsolutePath -eq '/uac') {
            # "C'e' un prompt UAC aperto adesso?"
            #
            # Si guarda il processo, non il file scritto da /orphans: il file
            # dipende da chi chiama /orphans, questo e' vero anche se nessuno
            # lo ha chiamato. E' la domanda che il Mac fa quando vuole spiegare
            # perche' i click non funzionano piu' da nessuna parte.
            $body = if (Get-Process -Name consent -EA SilentlyContinue) { 'si' } else { 'no' }
        }
    } catch { $body = 'no' }

    # La risposta si chiude SEMPRE, anche se scriverla fallisce.
    #
    # Senza il finally, un errore nella scrittura (il client se n'e' andato, la
    # rete e' caduta a meta') salta la Close() e lascia la connessione appesa.
    # Windows la mette in CLOSE_WAIT e non la libera mai: dopo un po' di queste
    # l'agente accetta ancora connessioni ma non risponde piu' a nessuna.
    #
    # E' successo TRE volte in un pomeriggio, sempre allo stesso modo: log fermo,
    # "ping" senza risposta, e nel frattempo la porta 48088 piena di CLOSE_WAIT.
    # Da fuori sembra un PC spento, e winfleet aspettava a vuoto ad ogni
    # apertura.
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
        Note "risposta non inviata: $_"
    } finally {
        try { $ctx.Response.Close() } catch { }
    }
}
