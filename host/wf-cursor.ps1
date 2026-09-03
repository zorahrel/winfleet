<#
.SYNOPSIS
  Rende invisibile il cursore di Windows mentre WinFleet trasmette, e lo rimette.

.DESCRIPTION
  Il puntatore che si vede nella finestra e' disegnato dentro il video da
  Sunshine, quindi arriva sempre un viaggio di rete dopo la mano: su una finestra
  che si usa per lavorare, quel ritardo si sente su ogni click. Il Mac puo'
  disegnare il proprio - istantaneo - ma finche' c'e' anche quello remoto se ne
  vedono DUE che si rincorrono, ed e' peggio di uno solo in ritardo.

  Spegnerlo dal lato Sunshine non si puo': questa build non espone capture_cursor
  (controllato nelle stringhe del binario). Quello che si puo' fare e' renderlo
  invisibile alla fonte, sostituendo i cursori di SISTEMA con cursori vuoti:
  Sunshine cattura quello che Windows disegna, e se Windows non disegna nulla nel
  video non finisce niente. Sul Mac resta un puntatore solo, il suo, a zero lag.

  E' un cambiamento globale su Windows, quindi il ripristino non e' un dettaglio:
  SPI_SETCURSORS rimette i cursori del tema con una chiamata, e viene invocato
  sia da "restore" sia automaticamente quando questo processo muore.

.PARAMETER Action
  hide | restore | guard

  "guard" e' la rete di sicurezza: nascondere il cursore e' globale, e finche'
  a rimetterlo era solo il Mac bastava un kill -9, un Mac che dorme o
  un'apertura fallita per lasciare il PC senza puntatore a tempo indeterminato.
  Successo davvero: quattro giorni, con il puntatore invisibile anche da Parsec
  e davanti al monitor, e nessun indizio che portasse a winfleet. Il guardiano
  guarda il file-battito che l'agente aggiorna finche' una finestra e' aperta:
  se smette di essere aggiornato, rimette i cursori del tema e basta.

.EXAMPLE
  powershell -File wf-cursor.ps1 -Action hide
  powershell -File wf-cursor.ps1 -Action restore
  powershell -File wf-cursor.ps1 -Action guard
#>
[CmdletBinding()]
param([ValidateSet('hide','restore','guard')][string]$Action = 'hide')

$ErrorActionPreference = 'Stop'
$LOG = 'C:\winfleet\cursor.log'
function Note($m) { "$(Get-Date -f 'HH:mm:ss')  $m" | Add-Content $LOG }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WFCur {
  [DllImport("user32.dll", SetLastError=true)]
  public static extern IntPtr CreateCursor(IntPtr hInst, int xHot, int yHot,
      int nWidth, int nHeight, byte[] pvANDPlane, byte[] pvXORPlane);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool SetSystemCursor(IntPtr hcur, uint id);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
}
'@

# Tutti i cursori di sistema: nasconderne uno solo lascerebbe ricomparire la
# freccia appena il puntatore passa sopra un bordo o un campo di testo.
$IDS = @(32512,32513,32514,32515,32516,32642,32643,32644,32645,32646,32648,32649,32650,32651)
$SPI_SETCURSORS = 0x0057

# Il battito: l'agente lo aggiorna a ogni giro finche' una finestra e' viva.
$BEAT = 'C:\winfleet\cursor-alive.txt'
# Generoso di proposito: il Mac si fa vivo ogni 20 secondi, e un minuto di
# silenzio non e' un singhiozzo di rete - e' qualcuno che se n'e' andato.
$BEAT_MAX = 60

# "L'ultimo ordine dato e' stato nascondi": e' cio' che permette al guardiano di
# non ripristinare a vuoto ogni minuto quando non c'e' niente da ripristinare.
$MARK = 'C:\winfleet\cursor-hidden.txt'

if ($Action -eq 'restore') {
    [void][WFCur]::SystemParametersInfo($SPI_SETCURSORS, 0, [IntPtr]::Zero, 0)
    Remove-Item $MARK -Force -EA SilentlyContinue
    Note 'cursori di sistema ripristinati'
    return
}

if ($Action -eq 'guard') {
    # Se il battito non c'e' o e' vecchio, nessuno sta piu' trasmettendo: si
    # rimette il cursore. Se e' fresco non si tocca niente - il ripristino a
    # meta' di uno stream farebbe ricomparire il doppio puntatore.
    $eta = if (Test-Path $BEAT) {
        ((Get-Date) - (Get-Item $BEAT).LastWriteTime).TotalSeconds
    } else { [double]::MaxValue }
    if ($eta -le $BEAT_MAX) { return }
    # Si ripristina solo se serve davvero: SPI_SETCURSORS a vuoto ogni minuto
    # riempirebbe il log di righe che non raccontano niente.
    if (-not (Test-Path $MARK)) { return }
    [void][WFCur]::SystemParametersInfo($SPI_SETCURSORS, 0, [IntPtr]::Zero, 0)
    Remove-Item $MARK -Force -EA SilentlyContinue
    # "$([int]$eta)" andava in OVERFLOW quando il battito non esisteva affatto:
    # $eta valeva Double::MaxValue e la conversione a Int32 usciva con
    # "Valore troppo grande per un Int32", uccidendo lo script DOPO il ripristino
    # - cioe' nel punto peggiore: il cursore torna, il marchio sparisce, e nel log
    # non resta una riga. Trovato il 03/09/2026 perche' cursor.log era fermo al
    # 28/08 mentre il guardiano stava chiaramente intervenendo (il marchio
    # spariva). Un guardiano che agisce senza lasciare traccia e' indistinguibile
    # da uno morto.
    #
    # Il caso "battito mai esistito" e' quello NORMALE, non un bordo: l'agente
    # crea quel file solo mentre una finestra e' aperta, quindi appena il PC si
    # accende non c'e'.
    $quanto = if ($eta -gt 86400) { 'mai' } else { "$([int]$eta)s" }
    Note "cursori rimessi dal guardiano (nessun battito da $quanto)"
    return
}

# Un cursore 32x32 completamente trasparente: AND tutto 1 (lascia lo sfondo),
# XOR tutto 0 (non disegna nulla). E' il modo documentato di ottenere un cursore
# invisibile senza avere un file .cur vuoto sul disco.
$w = 32; $h = 32
$and = New-Object byte[] ($w * $h / 8); for ($i = 0; $i -lt $and.Length; $i++) { $and[$i] = 0xFF }
$xor = New-Object byte[] ($w * $h / 8)   # gia' tutto 0

$blank = [WFCur]::CreateCursor([IntPtr]::Zero, 0, 0, $w, $h, $and, $xor)
if ($blank -eq [IntPtr]::Zero) { Note 'CreateCursor fallita'; exit 1 }

$n = 0
foreach ($id in $IDS) {
    # SetSystemCursor DISTRUGGE l'handle che riceve, quindi ne serve uno nuovo
    # per ogni id: passare sempre lo stesso funziona per il primo e fallisce in
    # silenzio per tutti gli altri.
    $c = [WFCur]::CreateCursor([IntPtr]::Zero, 0, 0, $w, $h, $and, $xor)
    if ($c -ne [IntPtr]::Zero -and [WFCur]::SetSystemCursor($c, $id)) { $n++ }
}
# Da adesso c'e' qualcosa da ripristinare, e il guardiano deve saperlo.
# Il battito parte da ora: se il Mac non si rifa' vivo entro un minuto -
# perche' e' morto male, perche' lo stream non e' mai partito - il cursore
# torna da solo invece di restare invisibile per giorni.
[void](New-Item -Path $MARK -ItemType File -Force)
[void](New-Item -Path $BEAT -ItemType File -Force)
Note "cursore nascosto ($n cursori sostituiti)"
