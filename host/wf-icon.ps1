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

$bmp = $null
try {
    $bmp = [ShellIcon]::Get($Path, $Size)
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
