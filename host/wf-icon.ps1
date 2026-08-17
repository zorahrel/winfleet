<#
.SYNOPSIS
  Prints the icon of a Windows program as base64 PNG.

.DESCRIPTION
  Used by "winfleet dock" to give each Mac launcher the icon of the app it opens.

  Not ExtractAssociatedIcon: that returns whatever 32x32 the shell hands out, which
  on a Retina Mac is a blurry stamp. The Shell's image factory is asked instead —
  the same path Explorer uses for large icons — so packaged apps, shortcuts and
  executables with a modern icon group all come back at up to 256x256.

.EXAMPLE
  .\wf-icon.ps1 -Path 'C:\Program Files\Telegram Desktop\Telegram.exe'
#>
[CmdletBinding()]
param(
    [string]$Path = '',
    # Percorso in base64: attraversare ssh, cmd e PowerShell mangia gli apici, e
    # "...\Telegram Desktop\Telegram.exe" arriva spezzato in due argomenti.
    [string]$PathB64 = '',
    [int]$Size = 256
)
$ErrorActionPreference = 'Stop'

if ($PathB64) { $Path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PathB64)) }
if (-not $Path) { throw 'Serve -Path o -PathB64.' }
Add-Type -AssemblyName System.Drawing

$sig = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public class ShellIcon {
  [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IShellItemImageFactory {
    void GetImage([In, MarshalAs(UnmanagedType.Struct)] SIZE size, [In] int flags, out IntPtr bitmap);
  }
  [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; public SIZE(int x, int y) { cx = x; cy = y; } }

  [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
  static extern void SHCreateItemFromParsingName(
      [MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr bc,
      [MarshalAs(UnmanagedType.LPStruct)] Guid iid,
      [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory f);

  [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
  [DllImport("gdi32.dll")] static extern int GetObject(IntPtr h, int size, ref BITMAP b);
  [StructLayout(LayoutKind.Sequential)] struct BITMAP {
    public int bmType, bmWidth, bmHeight, bmWidthBytes;
    public ushort bmPlanes, bmBitsPixel;
    public IntPtr bmBits;
  }

  // BIGGERSIZEOK: take a larger icon over an upscaled small one.
  const int SIIGBF_BIGGERSIZEOK = 0x01;

  public static Bitmap Get(string path, int size) {
    IShellItemImageFactory f;
    SHCreateItemFromParsingName(path, IntPtr.Zero,
        new Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), out f);
    IntPtr h;
    f.GetImage(new SIZE(size, size), SIIGBF_BIGGERSIZEOK, out h);
    try {
      // Bitmap.FromHbitmap would be the obvious call, and it throws the alpha
      // channel away: the icon comes back pasted on a black square, which on the
      // Mac is exactly what you see in the Dock. The shell hands back a top-down
      // 32bpp DIB, so its own pixels are read instead, transparency included.
      BITMAP bm = new BITMAP();
      if (GetObject(h, Marshal.SizeOf(bm), ref bm) != 0 &&
          bm.bmBitsPixel == 32 && bm.bmBits != IntPtr.Zero) {
        using (Bitmap view = new Bitmap(bm.bmWidth, bm.bmHeight, bm.bmWidthBytes,
                                        System.Drawing.Imaging.PixelFormat.Format32bppArgb, bm.bmBits)) {
          return new Bitmap(view);   // copia: il DIB muore con l'HBITMAP
        }
      }
      return Bitmap.FromHbitmap(h);
    }
    finally { DeleteObject(h); }
  }
}
'@
Add-Type -TypeDefinition $sig -ReferencedAssemblies System.Drawing

# Un'app dello Store non ha un eseguibile da interrogare: si passa da
# shell:AppsFolder, e li' la fabbrica di immagini della shell restituisce il
# riquadro del menu Start, che e' 44x44. Ingrandito a 512 per il Mac diventa una
# macchia - dodici volte la misura originale - ed e' il motivo per cui nel Dock
# le icone delle app di sistema si vedevano sfocate accanto a quelle vere.
#
# Il pacchetto pero' l'immagine grande ce l'ha. Il manifesto dichiara quale file
# e' il logo, e accanto a quello Windows tiene le varianti per ogni misura:
# NotepadAppList.targetsize-256.png sta li' da sempre. Si prende la piu' grande.
#
# "unplated" quando c'e': e' la versione senza il quadrato di fondo colorato che
# Windows disegna dietro l'icona. Sul Mac quel fondo sarebbe un rettangolo tinta
# unita dentro un'icona che dovrebbe avere la forma dell'app.
function Get-PackagedLogo($aumid) {
    $fam = ($aumid -replace '^shell:AppsFolder\\', '') -replace '!.*$', ''
    $pkg = Get-AppxPackage | Where-Object { $_.PackageFamilyName -eq $fam } | Select-Object -First 1
    if (-not $pkg) { return $null }
    $root = $pkg.InstallLocation
    if (-not $root -or -not (Test-Path $root)) { return $null }

    $mf = Join-Path $root 'AppxManifest.xml'
    if (-not (Test-Path $mf)) { return $null }
    [xml]$m = Get-Content $mf
    $ve = $m.Package.Applications.Application.VisualElements
    if ($ve -is [Array]) { $ve = $ve[0] }
    # I due loghi NON sono intercambiabili, e prendere semplicemente il piu' grande
    # da' l'immagine sbagliata: il Square150x150 e' il RIQUADRO del menu Start,
    # cioe' il simbolo piccolo al centro di un fondo colorato con i suoi margini.
    # Sul Mac diventa un'icona che sembra rimpicciolita dentro una piastrella.
    # Quello giusto e' il Square44x44, che e' l'icona dell'elenco app: e' anche
    # quello che Windows mostra sulla barra delle applicazioni, quindi e' il
    # disegno che si riconosce. Di quello esistono varianti fino a 256.
    #
    # Il riquadro si usa SOLO se dell'icona vera non esiste una versione decente
    # (Dev Home dichiara un SmallTile da 44 e nient'altro): meglio un riquadro da
    # 150 di un francobollo da 44 ingrandito dodici volte.
    $primary = @($ve.Square44x44Logo) | Where-Object { $_ }
    $fallback = @($ve.Square150x150Logo) | Where-Object { $_ }
    if ($ve.DefaultTile -and $ve.DefaultTile.Square310x310Logo) { $fallback += $ve.DefaultTile.Square310x310Logo }
    if (-not $primary -and -not $fallback) { return $null }

    # Si sceglie per la MISURA VERA del file, letta aprendolo, non per il nome ne'
    # per il peso: "targetsize-256" e' solo una promessa, e un png piu' pesante
    # puo' benissimo essere piu' piccolo e solo meno compresso. Aprire una
    # dozzina di png costa millisecondi e si fa una volta sola per app.
    $best = $null; $bestPx = 0; $bestUnplated = $false
    $logos = $primary
    if (-not $logos) { $logos = $fallback }
    foreach ($logo in $logos) {
        $dir = Join-Path $root ([IO.Path]::GetDirectoryName($logo))
        if (-not (Test-Path $dir)) { continue }
        $base = [IO.Path]::GetFileNameWithoutExtension($logo)
        foreach ($f in Get-ChildItem $dir -Filter "$base*.png" -EA SilentlyContinue) {
            # Fuori le varianti che NON sono l'icona a colori dell'app:
            #  - contrast-*: per il tema ad alto contrasto, bianco o nero pieno;
            #  - lightunplated: la sagoma monocroma per la barra chiara. E' quella
            #    che trasformava il foglietto giallo di Memo in una macchia grigia,
            #    e a occhio sembra "l'icona sbagliata" senza che si capisca perche'.
            # "unplated" senza "light" e' invece l'icona vera senza il quadrato di
            # fondo, ed e' quella che si vuole.
            if ($f.Name -match 'contrast-') { continue }
            if ($f.Name -match 'lightunplated') { continue }
            $b = $null
            try { $b = New-Object Drawing.Bitmap $f.FullName } catch { continue }
            $px = [Math]::Min($b.Width, $b.Height)
            # Un logo va usato solo se e' quadrato: le varianti larghe sono
            # striscioni col nome dell'app, e in un'icona diventano una banda.
            $square = [Math]::Abs($b.Width - $b.Height) -le ([Math]::Max($b.Width, $b.Height) * 0.1)
            # "unplated" = senza il quadrato di fondo che Windows disegna dietro:
            # sul Mac quel fondo sarebbe una tinta unita dentro l'icona.
            $unplated = $f.Name -match 'unplated'
            $win = $false
            if ($square) {
                if ($px -gt $bestPx) { $win = $true }
                elseif ($px -eq $bestPx -and $unplated -and -not $bestUnplated) { $win = $true }
            }
            if ($win) {
                if ($best) { $best.Dispose() }
                $best = $b; $bestPx = $px; $bestUnplated = $unplated
            } else { $b.Dispose() }
        }
    }
    # Sotto i 128 pixel il Mac lo ingrandisce comunque: se l'icona vera non arriva
    # a quella soglia si guarda anche il riquadro, e si tiene il migliore dei due.
    if ($bestPx -lt 128 -and $primary -and $fallback) {
        foreach ($logo in $fallback) {
            $dir = Join-Path $root ([IO.Path]::GetDirectoryName($logo))
            if (-not (Test-Path $dir)) { continue }
            $base = [IO.Path]::GetFileNameWithoutExtension($logo)
            foreach ($f in Get-ChildItem $dir -Filter "$base*.png" -EA SilentlyContinue) {
                if ($f.Name -match 'contrast-') { continue }
                if ($f.Name -match 'lightunplated') { continue }
                $b = $null
                try { $b = New-Object Drawing.Bitmap $f.FullName } catch { continue }
                $px = [Math]::Min($b.Width, $b.Height)
                $square = [Math]::Abs($b.Width - $b.Height) -le ([Math]::Max($b.Width, $b.Height) * 0.1)
                if ($square -and $px -gt $bestPx) {
                    if ($best) { $best.Dispose() }
                    $best = $b; $bestPx = $px
                } else { $b.Dispose() }
            }
        }
    }
    if (-not $best) { return $null }
    return $best
}

$bmp = $null
if ($Path -like 'shell:AppsFolder\*') {
    try { $bmp = Get-PackagedLogo $Path } catch { $bmp = $null }
}
try {
    if (-not $bmp) { $bmp = [ShellIcon]::Get($Path, $Size) }
} catch {
    # Shortcuts to packaged apps and a few installers refuse the image factory;
    # the small associated icon is better than nothing.
    $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($Path)
    if ($ico) { $bmp = $ico.ToBitmap() }
}
if (-not $bmp) { throw "Nessuna icona in $Path" }

# Alcune sorgenti (icone vecchie a 24bpp, il fallback ExtractAssociatedIcon)
# arrivano con l'alpha tutto a zero, cioe' invisibili: in quel caso e' opacita'
# mancante, non trasparenza, e si forza a 255.
$fixed = New-Object Drawing.Bitmap $bmp.Width, $bmp.Height, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
$src = $bmp.LockBits((New-Object Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height),
    [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
$dst = $fixed.LockBits((New-Object Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height),
    [Drawing.Imaging.ImageLockMode]::WriteOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
$n = $bmp.Width * $bmp.Height * 4
$buf = New-Object byte[] $n
[Runtime.InteropServices.Marshal]::Copy($src.Scan0, $buf, 0, $n)
$anyAlpha = $false
for ($i = 3; $i -lt $n; $i += 4) { if ($buf[$i] -ne 0) { $anyAlpha = $true; break } }
if (-not $anyAlpha) { for ($i = 3; $i -lt $n; $i += 4) { $buf[$i] = 255 } }
[Runtime.InteropServices.Marshal]::Copy($buf, 0, $dst.Scan0, $n)
$bmp.UnlockBits($src); $fixed.UnlockBits($dst)

$ms = New-Object IO.MemoryStream
$fixed.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
[Convert]::ToBase64String($ms.ToArray())
