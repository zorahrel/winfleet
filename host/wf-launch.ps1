# WinFleet launcher — runs in the interactive session (scheduled task `winfleet-app`).
# Creates a dedicated Windows desktop object and switches to it, so the streamed
# display contains ONLY the target app: no taskbar, no icons, no other windows.
# On app exit it switches back to the user's real desktop.

$ErrorActionPreference = 'Stop'
$log = 'C:\winfleet\launch.log'
function Note($m) { "$(Get-Date -f 'HH:mm:ss')  $m" | Add-Content $log }
trap { Note "ERROR: $_"; Note $_.ScriptStackTrace; break }

$exe = (Get-Content 'C:\winfleet\current-app.txt' -Raw).Trim()
Note "launch $exe"
if (-not $exe) { return }

$sig = @'
using System; using System.Runtime.InteropServices;
public class D {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateDesktop(string name, IntPtr dev, IntPtr dm, int flags, uint access, IntPtr sa);
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr OpenDesktop(string name, int flags, bool inherit, uint access);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SwitchDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr h);

  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct STARTUPINFO {
    public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
    public IntPtr hStdInput, hStdOutput, hStdError;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit,
    uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
}
'@
Add-Type -TypeDefinition $sig

$DESK = 'WinFleet'
$GENERIC_ALL = 0x10000000

# Create (or reuse) the dedicated desktop.
$hDesk = [D]::CreateDesktop($DESK, [IntPtr]::Zero, [IntPtr]::Zero, 0, $GENERIC_ALL, [IntPtr]::Zero)
if ($hDesk -eq [IntPtr]::Zero) { $hDesk = [D]::OpenDesktop($DESK, 0, $false, $GENERIC_ALL) }
if ($hDesk -eq [IntPtr]::Zero) { throw 'CreateDesktop failed' }
Note "desktop handle $hDesk"

# Launch the inner manager ON that desktop; the app it spawns inherits the desktop.
$si = New-Object 'D+STARTUPINFO'
$si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
$si.lpDesktop = "WinSta0\$DESK"
$pi = New-Object 'D+PROCESS_INFORMATION'
$ps  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cmd = "`"$ps`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\winfleet\wf-inner.ps1"
$CREATE_NEW_CONSOLE = 0x00000010
$ok = [D]::CreateProcess($ps, $cmd, [IntPtr]::Zero, [IntPtr]::Zero, $false, $CREATE_NEW_CONSOLE, [IntPtr]::Zero, 'C:\winfleet', [ref]$si, [ref]$pi)
if (-not $ok) {
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    [D]::CloseDesktop($hDesk) | Out-Null
    throw "CreateProcess failed (win32 $err)"
}
Note "inner pid $($pi.dwProcessId)"

# Show the dedicated desktop: from here the captured display holds only the app.
Start-Sleep -Milliseconds 400
$sw = [D]::SwitchDesktop($hDesk)
Note "SwitchDesktop -> $sw"

try { [D]::WaitForSingleObject($pi.hProcess, ([uint32]::MaxValue)) | Out-Null }
finally {
    # Always hand the screen back to the real desktop.
    $hDef = [D]::OpenDesktop('Default', 0, $false, $GENERIC_ALL)
    if ($hDef -ne [IntPtr]::Zero) { [D]::SwitchDesktop($hDef) | Out-Null; [D]::CloseDesktop($hDef) | Out-Null }
    [D]::CloseHandle($pi.hThread)  | Out-Null
    [D]::CloseHandle($pi.hProcess) | Out-Null
    [D]::CloseDesktop($hDesk)      | Out-Null
    Note 'back to Default desktop'
}
