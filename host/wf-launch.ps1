$exe = (Get-Content 'C:\winfleet\current-app.txt' -Raw).Trim()
if (-not $exe) { return }
$sig = @'
using System; using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
}
'@
Add-Type -TypeDefinition $sig
$name = [IO.Path]::GetFileNameWithoutExtension($exe)
Get-Process $name -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 1
$p = Start-Process -FilePath $exe -PassThru
for ($i=0; $i -lt 20 -and $p.MainWindowHandle -eq 0; $i++){ Start-Sleep -Milliseconds 400; $p.Refresh() }
$h = $p.MainWindowHandle
if ($h -eq 0) { return }

$GWL_STYLE = -16
$WS_CAPTION = 0x00C00000; $WS_THICKFRAME = 0x00040000; $WS_BORDER = 0x00800000
# rimuovi bordo e barra titolo (mantieni il resto dello stile)
$style = [int64][W]::GetWindowLongPtr($h, $GWL_STYLE)
$style = $style -band (-bnot ($WS_CAPTION -bor $WS_THICKFRAME -bor $WS_BORDER))
[W]::SetWindowLongPtr($h, $GWL_STYLE, [IntPtr]$style) | Out-Null

# loop continuo: copre l'intero schermo, segue ogni cambio di risoluzione,
# finché l'app resta aperta
while (-not $p.HasExited) {
  $sw = [W]::GetSystemMetrics(0); $sh = [W]::GetSystemMetrics(1)
  [W]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, $sw, $sh, 0x0044) | Out-Null  # NOZORDER|SHOWWINDOW
  [W]::SetForegroundWindow($h) | Out-Null
  Start-Sleep -Milliseconds 700
  $p.Refresh()
}
