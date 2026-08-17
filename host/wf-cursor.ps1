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
  hide | restore

.EXAMPLE
  powershell -File wf-cursor.ps1 -Action hide
  powershell -File wf-cursor.ps1 -Action restore
#>
[CmdletBinding()]
param([ValidateSet('hide','restore')][string]$Action = 'hide')

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

if ($Action -eq 'restore') {
    [void][WFCur]::SystemParametersInfo($SPI_SETCURSORS, 0, [IntPtr]::Zero, 0)
    Note 'cursori di sistema ripristinati'
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
Note "cursore nascosto ($n cursori sostituiti)"
