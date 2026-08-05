<#
.SYNOPSIS
  Starts an app and gives it the whole of one virtual monitor.

.DESCRIPTION
  Run through the winfleet-place<slot> task when the client asks for an app; the exe
  to start is read from C:\winfleet\app<slot>.txt.

  Sunshine does not launch the app itself on purpose. To put a window in the
  interactive session it duplicates the console token, which needs a privilege only
  LocalSystem holds — an instance running as you, elevated or not, fails with
  ACCESS_DENIED. Launching from a scheduled task in your own session sidesteps that
  entirely, and leaves Sunshine doing only what it is good at: streaming a screen.

  The window is then stripped of its frame and stretched over the virtual monitor
  bound to this slot, so the stream carries the app and nothing else. Isolation comes
  from the screen: nothing else ever draws on it.

  The window is found by watching for one that appears after the launch rather than
  through the process we started: Store-packaged apps, Chromium and Electron hand
  their window to another process, so MainWindowHandle stays 0 forever.

.EXAMPLE
  powershell -File wf-place.ps1 -Slot 0
#>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][int]$Slot)

$Exe = ''
$req = "C:\winfleet\app$Slot.txt"
if (Test-Path $req) { $Exe = (Get-Content $req -Raw).Trim() }
if (-not $Exe) { return }

$LOG = "C:\winfleet\place$Slot.log"
function Note($m) { "$(Get-Date -f 'HH:mm:ss')  $m" | Add-Content $LOG }
trap { Note "ERRORE: $_"; break }
Set-Content $LOG ''

$sig = @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public class P {
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
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

  static bool Candidate(IntPtr h) {
    if (!IsWindowVisible(h)) return false;
    if (GetWindow(h, 4) != IntPtr.Zero) return false;      // GW_OWNER: dialoghi e tooltip
    if (GetWindowTextLength(h) == 0) return false;
    RECT r; if (!GetWindowRect(h, out r)) return false;
    return (r.R - r.L) * (r.B - r.T) >= 40000;
  }
  public static List<IntPtr> Candidates() {
    List<IntPtr> found = new List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr p) { if (Candidate(h)) found.Add(h); return true; }, IntPtr.Zero);
    return found;
  }
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

# La geometria si rilegge a ogni giro: quando il client ridimensiona la finestra il
# monitor virtuale cambia forma, e la finestra deve seguirlo.
function Get-Monitor {
    $parsed = ConvertFrom-Json ((Get-Content 'C:\winfleet\vdd.json' -Raw).TrimStart([char]0xFEFF))
    $vdd = @(); foreach ($e in $parsed) { $vdd += $e }
    $vdd | Where-Object { $_.slot -eq $Slot }
}
$mon = Get-Monitor
if (-not $mon) { throw "Slot $Slot senza monitor virtuale." }
Note "slot $Slot -> $($mon.device) $($mon.width)x$($mon.height) @ $($mon.x),$($mon.y)"

# Le app dello Store non hanno un eseguibile da avviare, solo un identificativo: si
# passa dalla cartella virtuale delle applicazioni, come fa il menu Start.
$packaged = $Exe -like 'shell:AppsFolder\*'

if (-not $packaged) {
    # Single-instance apps would otherwise just raise their existing window on another
    # screen instead of opening one here.
    $name = [IO.Path]::GetFileNameWithoutExtension($Exe)
    Get-Process $name -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep 1
}

$before = [P]::Candidates()
if ($packaged) { Start-Process 'explorer.exe' -ArgumentList $Exe | Out-Null }
else           { Start-Process -FilePath $Exe | Out-Null }
Note "avviata $Exe"

$h = [IntPtr]::Zero
for ($i = 0; $i -lt 75 -and $h -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 400
    $h = [P]::FindNew($before.ToArray())
}
if ($h -eq [IntPtr]::Zero) { Note 'nessuna finestra comparsa'; return }

$appPid = 0
[P]::GetWindowThreadProcessId($h, [ref]$appPid) | Out-Null
Set-Content "C:\winfleet\pid$Slot.txt" $appPid
Note "finestra $h (pid $appPid)"

# Via il frame: sul Mac la finestra e' gia' una finestra, quella di Windows dentro
# sarebbe una cornice dentro una cornice.
$GWL_STYLE = -16
$rm = 0x00C00000 -bor 0x00040000 -bor 0x00800000   # WS_CAPTION | WS_THICKFRAME | WS_BORDER
$st = [int64][P]::GetWindowLongPtr($h, $GWL_STYLE)
[P]::SetWindowLongPtr($h, $GWL_STYLE, [IntPtr]($st -band (-bnot $rm))) | Out-Null

$SWP_SHOWWINDOW = 0x0040
$gone = 0
while ($true) {
    if (-not [P]::IsWindow($h) -or -not [P]::IsWindowVisible($h)) {
        $h2 = [P]::FindNew($before.ToArray())          # splash -> finestra vera
        if ($h2 -ne [IntPtr]::Zero) { $h = $h2; $gone = 0 }
        elseif (++$gone -ge 3) { break }
    } else { $gone = 0 }

    $m = Get-Monitor
    if ($m) { $mon = $m }
    [P]::ShowWindow($h, 9) | Out-Null                  # SW_RESTORE
    [P]::SetWindowPos($h, [IntPtr]::Zero, $mon.x, $mon.y, $mon.width, $mon.height, $SWP_SHOWWINDOW) | Out-Null
    Start-Sleep -Milliseconds 800
}
Note 'finestra chiusa'
Remove-Item "C:\winfleet\pid$Slot.txt" -Force -EA SilentlyContinue
