# WinFleet inner manager — runs ON the dedicated `WinFleet` desktop.
# Starts the target app (which inherits this desktop) and keeps its window
# borderless and filling the display. Exits when the app's window is gone,
# which returns the screen to the user's real desktop.
#
# The window is found by enumerating this desktop rather than through the
# process we spawned: modern apps (Store-packaged Notepad, Chrome, Electron)
# hand off to another process, so MainWindowHandle is often 0 forever. On a
# dedicated desktop there is nothing else running, so any visible top-level
# window is the app.

$log = 'C:\winfleet\launch.log'
function Note($m) { "$(Get-Date -f 'HH:mm:ss')  [inner] $m" | Add-Content $log }
trap { Note "ERROR: $_"; break }

$exe = (Get-Content 'C:\winfleet\current-app.txt' -Raw).Trim()
if (-not $exe) { return }

$sig = @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public class W {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);

  static bool Candidate(IntPtr h) {
    if (!IsWindowVisible(h)) return false;
    if (GetWindow(h, 4) != IntPtr.Zero) return false;       // GW_OWNER: skip dialogs/tooltips
    if (GetWindowTextLength(h) == 0) return false;
    RECT r; if (!GetWindowRect(h, out r)) return false;
    return (r.R - r.L) * (r.B - r.T) >= 40000;
  }

  // Every candidate window currently on this desktop.
  public static List<IntPtr> Candidates() {
    List<IntPtr> found = new List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr p) { if (Candidate(h)) found.Add(h); return true; }, IntPtr.Zero);
    return found;
  }

  // The largest candidate that was not already there before we launched.
  public static IntPtr FindNew(IntPtr[] before) {
    IntPtr best = IntPtr.Zero; int bestArea = 0;
    foreach (IntPtr h in Candidates()) {
      if (Array.IndexOf(before, h) >= 0) continue;
      RECT r; GetWindowRect(h, out r);
      int area = (r.R - r.L) * (r.B - r.T);
      if (area > bestArea) { bestArea = area; best = h; }
    }
    return best;
  }
}
'@
Add-Type -TypeDefinition $sig

# Single-instance apps would otherwise just activate their existing window on
# the user's desktop instead of opening one here.
$name = [IO.Path]::GetFileNameWithoutExtension($exe)
Get-Process $name -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 1

# Anything already on this desktop is left over from an earlier session; the
# app's window is the one that appears after this point.
$before = [W]::Candidates()
Start-Process -FilePath $exe | Out-Null
Note "started $exe (windows already present: $($before.Count))"

$h = [IntPtr]::Zero
for ($i = 0; $i -lt 75 -and $h -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 400
    $h = [W]::FindNew($before.ToArray())
}
if ($h -eq [IntPtr]::Zero) { Note 'no window appeared'; return }

# Record the owning process so teardown can close the app.
$appPid = 0
[W]::GetWindowThreadProcessId($h, [ref]$appPid) | Out-Null
Set-Content 'C:\winfleet\current-pid.txt' $appPid
Note "window $h (pid $appPid)"

# Strip caption / resize frame / border so the app has no chrome.
$GWL_STYLE = -16
$rm = 0x00C00000 -bor 0x00040000 -bor 0x00800000
$st = [int64][W]::GetWindowLongPtr($h, $GWL_STYLE)
[W]::SetWindowLongPtr($h, $GWL_STYLE, [IntPtr]($st -band (-bnot $rm))) | Out-Null

# Sunshine resizes the display when a client connects, so keep refitting the
# window to whatever the display currently is.
$TOP = [IntPtr](-1)
$SWP_SHOWWINDOW = 0x0040
$gone = 0
while ($true) {
    if (-not [W]::IsWindow($h) -or -not [W]::IsWindowVisible($h)) {
        # The app may swap its top-level window (splash → main); re-find once.
        $h2 = [W]::FindNew($before.ToArray())
        if ($h2 -ne [IntPtr]::Zero) { $h = $h2; $gone = 0 }
        elseif (++$gone -ge 3) { break }
    } else { $gone = 0 }

    $sw = [W]::GetSystemMetrics(0); $sh = [W]::GetSystemMetrics(1)
    [W]::ShowWindow($h, 9) | Out-Null
    [W]::SetWindowPos($h, $TOP, 0, 0, $sw, $sh, $SWP_SHOWWINDOW) | Out-Null
    [W]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 1000
}
Note 'app window gone'
