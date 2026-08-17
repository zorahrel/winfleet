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
    $script:hwndCache[$slot]
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
$listener.Start()
Note "in ascolto su $Port"

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $body = 'no'
    try {
        if ($req.Url.AbsolutePath -eq '/rect') {
            $slot = [int]$req.QueryString['slot']
            $w    = [int]$req.QueryString['w']
            $h    = [int]$req.QueryString['h']
            $got  = Set-AppSize $slot $w $h
            $body = if ($got) { "ok $got" } else { 'no' }
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
            $hwnd = Get-Hwnd $slot
            $mon  = Get-Monitor $slot
            # IsWindow da solo basta a fermare il caso peggiore: un handle di una
            # finestra CHIUSA. Se invece il numero e' stato riciclato da un'altra
            # finestra viva, serve la posizione - ma il rettangolo va guardato solo
            # se GetWindowRect ha avuto successo: quando fallisce NON tocca la
            # struttura, che resta con i valori che aveva in memoria. Misurato:
            # sporcando la struct a mano prima della chiamata, quei valori
            # sopravvivono intatti. E' cosi' che un handle morto passava per "mio",
            # perche' il centro calcolato su spazzatura cadeva dentro il monitor.
            $mine = $false
            if ($mon -and [A]::IsWindow($hwnd)) {
                $r = New-Object A+RECT
                if ([A]::GetWindowRect($hwnd, [ref]$r)) {
                    # Il centro della finestra dice su quale schermo vive. Con la
                    # finestra ridotta a icona le coordinate sono fuori da ogni
                    # schermo (Windows la parcheggia a -32000), quindi per il
                    # ripristino ci si fida dell'ultimo stato noto invece di
                    # pretendere che sia ancora al suo posto.
                    $cx = ($r.L + $r.R) / 2; $cy = ($r.T + $r.B) / 2
                    $mine = ($cx -ge $mon.x -and $cx -lt ($mon.x + $mon.width) -and
                             $cy -ge $mon.y -and $cy -lt ($mon.y + $mon.height))
                    if (-not $mine -and $r.L -le -30000) { $mine = $true }   # gia' a icona
                }
            }
            if ($mine) {
                if ($how -eq 'min') { [void][A]::ShowWindow($hwnd, 7) }
                else                { [void][A]::ShowWindow($hwnd, 9) }   # SW_RESTORE
                $body = 'ok'
            }
        }
        elseif ($req.Url.AbsolutePath -eq '/windows') { $body = [A]::ListWindows() }
        elseif ($req.Url.AbsolutePath -eq '/raise') {
            $hw = [IntPtr][int64]$req.QueryString['hwnd']
            if ([A]::IsWindow($hw)) {
                [void][A]::ShowWindow($hw, 9)          # SW_RESTORE
                [void][A]::SetForegroundWindow($hw)
                $body = 'ok'
            }
        }
        elseif ($req.Url.AbsolutePath -eq '/ping') { $body = 'ok' }
    } catch { $body = 'no' }

    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}
