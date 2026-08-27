# Fotografa la barra di Windows dove sta l'icona di winfleet.
#
# Serve a una cosa sola: un log che dice "stato: attenzione" prova che il
# CONTROLLO funziona, non che qualcuno lo VEDA. L'icona vive nella barra, e
# l'unico modo di sapere se c'e' davvero e' guardarla.
#
# Le coordinate si CHIEDONO alla barra, non si calcolano dallo schermo.
# Primo tentativo fatto cosi': "in basso a destra dello schermo primario",
# 460x60 da (564,708) - e l'immagine e' venuta fuori tutta marrone, cioe' lo
# sfondo del desktop. Su questo PC lo schermo primario e' WinDisc 1024x768 (un
# display fantasma: la macchina e' headless e si usa in streaming), la barra
# sta altrove e la sua WorkingArea coincide con Bounds. Un calcolo che assume
# dove sta la barra fotografa il posto sbagliato senza dirlo.
param([string]$Out = 'C:\winfleet\tray.png')
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WFShot {
  [DllImport("user32.dll", CharSet=CharSet.Auto)]
  public static extern IntPtr FindWindow(string cls, string win);
  [DllImport("user32.dll", CharSet=CharSet.Auto)]
  public static extern IntPtr FindWindowEx(IntPtr p, IntPtr c, string cls, string win);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
}
'@

# Shell_TrayWnd e' la barra. Dentro c'e' TrayNotifyWnd, che e' l'area di
# notifica vera e propria: si fotografa quella, perche' l'icona e' 16 pixel e
# in una barra da 3440 sarebbe introvabile.
$barra = [WFShot]::FindWindow('Shell_TrayWnd', $null)
if ($barra -eq [IntPtr]::Zero) { throw 'nessuna barra di Windows trovata (Explorer non gira?)' }
$area = [WFShot]::FindWindowEx($barra, [IntPtr]::Zero, 'TrayNotifyWnd', $null)
$target = if ($area -ne [IntPtr]::Zero) { $area } else { $barra }

$r = New-Object WFShot+RECT
[void][WFShot]::GetWindowRect($target, [ref]$r)
$w = $r.R - $r.L
$h = $r.B - $r.T
if ($w -le 0 -or $h -le 0) { throw "l'area di notifica ha misura zero ($w x $h)" }

$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"salvato $Out : ${w}x${h} da $($r.L),$($r.T)"
