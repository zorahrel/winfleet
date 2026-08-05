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

# minimizza tutto UNA VOLTA (chiamarlo di nuovo farebbe UndoMinimizeAll = sfarfallio)
(New-Object -ComObject Shell.Application).MinimizeAll()
Start-Sleep -Milliseconds 300

$GWL_STYLE=-16; $rm = 0x00C00000 -bor 0x00040000 -bor 0x00800000
$st=[int64][W]::GetWindowLongPtr($h,$GWL_STYLE)
[W]::SetWindowLongPtr($h,$GWL_STYLE,[IntPtr]($st -band (-bnot $rm)))|Out-Null
$TOP=[IntPtr](-1)

# loop: SOLO tiene l'app fullscreen topmost (niente MinimizeAll nel loop)
while (-not $p.HasExited) {
  $sw=[W]::GetSystemMetrics(0); $sh=[W]::GetSystemMetrics(1)
  [W]::ShowWindow($h,9)|Out-Null
  [W]::SetWindowPos($h,$TOP,0,0,$sw,$sh,0x0040)|Out-Null
  [W]::SetForegroundWindow($h)|Out-Null
  Start-Sleep -Milliseconds 1000
  $p.Refresh()
}
