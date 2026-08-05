# WinFleet safety reset — switches the screen back to the user's real desktop.
# Run via the `winfleet-reset` scheduled task (it must run inside the interactive
# session; a remote shell lives in session 0 and cannot switch desktops).
$sig = @'
using System; using System.Runtime.InteropServices;
public class R {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr OpenDesktop(string name, int flags, bool inherit, uint access);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SwitchDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr h);
}
'@
Add-Type -TypeDefinition $sig

# Close the app left running on the dedicated desktop; otherwise it lingers
# invisibly and confuses the next session.
$f = 'C:\winfleet\current-pid.txt'
if (Test-Path $f) {
    $appPid = (Get-Content $f -Raw).Trim()
    if ($appPid -match '^\d+$' -and [int]$appPid -gt 0) {
        Stop-Process -Id ([int]$appPid) -Force -EA SilentlyContinue
    }
    Remove-Item $f -Force -EA SilentlyContinue
}

$h = [R]::OpenDesktop('Default', 0, $false, 0x10000000)
if ($h -ne [IntPtr]::Zero) { [R]::SwitchDesktop($h) | Out-Null; [R]::CloseDesktop($h) | Out-Null }
