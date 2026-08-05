<#
  WinFleet app launcher — runs INSIDE the user's interactive session (via the
  winfleet-app scheduled task), so the launched app appears on the streamed
  display (Sunshine runs as a service in session 0 and cannot do this itself).

  Reads the target exe from C:\winfleet\current-app.txt, launches it, and keeps
  re-maximizing it for ~20s to fill the screen even after Sunshine switches the
  virtual display to the client's resolution on connect.
#>
$exe = (Get-Content 'C:\winfleet\current-app.txt' -Raw).Trim()
if (-not $exe) { return }

$sig = @'
using System; using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
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

# SW_RESTORE(9) then SW_MAXIMIZE(3): forces a re-fit to the CURRENT resolution,
# covering the display resize Sunshine performs when the client connects.
for ($k=0; $k -lt 40; $k++){
  [W]::ShowWindow($h, 9) | Out-Null
  [W]::ShowWindow($h, 3) | Out-Null
  [W]::SetForegroundWindow($h) | Out-Null
  Start-Sleep -Milliseconds 500
}
