<#
.SYNOPSIS
  Plugs virtual monitors on the Parsec Virtual Display Adapter and keeps them alive.

.DESCRIPTION
  A virtual monitor gives WinFleet a screen per app: the PC's real desktop is left
  alone, each streamed app owns a screen nobody else draws on, and several apps can
  be streamed at once — one Sunshine instance per monitor.

  The adapter ships with Parsec and is already present on most gaming PCs, so nothing
  is installed here; this only speaks its documented control protocol
  (github.com/nomi-san/parsec-vdd). The driver unplugs its monitors unless it is
  pinged more often than every 100 ms, so this script stays resident and pings. That
  watchdog is a feature: a crash, a kill or a reboot can never strand a phantom
  monitor on the PC.

  Windows attaches the monitors at 1920x1080 and lays them out to the right of the
  real desktop, which is the shape an app window wants. Their modes are deliberately
  left alone: an indirect display driver answers DISP_CHANGE_FAILED to
  ChangeDisplaySettingsEx, so switching resolution would mean going through the modern
  CCD API — not worth it when the default is already the size we would ask for.

  The layout is published as C:\winfleet\vdd.json for the rest of WinFleet.

.EXAMPLE
  powershell -File wf-vdd.ps1 -Count 2
#>
[CmdletBinding()]
param([int]$Count = 1)

$ErrorActionPreference = 'Stop'
$STATE   = 'C:\winfleet\vdd.json'
$REQUEST = 'C:\winfleet\vdd-request.txt'
$LOG   = 'C:\winfleet\vdd.log'
function Note($m) { "$(Get-Date -f 'HH:mm:ss')  $m" | Add-Content $LOG; Write-Host $m }
trap { Note "ERRORE: $_"; break }
Set-Content $LOG ''

$sig = @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public class Vdd {
  // ---- Parsec VDD control -------------------------------------------------
  [StructLayout(LayoutKind.Sequential)] public struct GUID {
    public uint a; public ushort b, c; [MarshalAs(UnmanagedType.ByValArray, SizeConst=8)] public byte[] d;
  }
  [StructLayout(LayoutKind.Sequential)] public struct SP_DEVICE_INTERFACE_DATA {
    public int cbSize; public GUID InterfaceClassGuid; public int Flags; public IntPtr Reserved;
  }
  [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr SetupDiGetClassDevs(ref GUID g, IntPtr enumerator, IntPtr hwnd, int flags);
  [DllImport("setupapi.dll", SetLastError=true)]
  static extern bool SetupDiEnumDeviceInterfaces(IntPtr devInfo, IntPtr devInfoData, ref GUID g, int i, ref SP_DEVICE_INTERFACE_DATA data);
  [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr devInfo, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, int size, ref int required, IntPtr devInfoData);
  [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr devInfo);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr CreateFile(string path, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, int inSize, out uint outBuf, int outSize, IntPtr bytes, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);

  static GUID AdapterGuid() {
    GUID g = new GUID();
    g.a = 0x00b41627; g.b = 0x04c4; g.c = 0x429e;
    g.d = new byte[] { 0xa2, 0x6e, 0x02, 0x65, 0xcf, 0x50, 0xc8, 0xfa };
    return g;
  }

  public static IntPtr Open() {
    GUID g = AdapterGuid();
    IntPtr info = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12); // PRESENT | DEVICEINTERFACE
    if (info == (IntPtr)(-1)) return (IntPtr)(-1);
    try {
      SP_DEVICE_INTERFACE_DATA d = new SP_DEVICE_INTERFACE_DATA();
      d.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
      for (int i = 0; SetupDiEnumDeviceInterfaces(info, IntPtr.Zero, ref g, i, ref d); i++) {
        int need = 0;
        SetupDiGetDeviceInterfaceDetail(info, ref d, IntPtr.Zero, 0, ref need, IntPtr.Zero);
        if (need == 0) continue;
        IntPtr buf = Marshal.AllocHGlobal(need);
        try {
          Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);   // cbSize of the detail struct
          if (!SetupDiGetDeviceInterfaceDetail(info, ref d, buf, need, ref need, IntPtr.Zero)) continue;
          string path = Marshal.PtrToStringUni((IntPtr)(buf.ToInt64() + 4));
          // Opened without FILE_FLAG_OVERLAPPED: the ioctls below are synchronous.
          IntPtr h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0xA0000080, IntPtr.Zero);
          if (h != (IntPtr)(-1)) return h;
        } finally { Marshal.FreeHGlobal(buf); }
      }
    } finally { SetupDiDestroyDeviceInfoList(info); }
    return (IntPtr)(-1);
  }

  const uint ADD = 0x0022e004, REMOVE = 0x0022a008, UPDATE = 0x0022a00c, VERSION = 0x0022e010;
  static uint Ctl(IntPtr h, uint code, byte[] data) {
    byte[] inBuf = new byte[32];
    if (data != null) Array.Copy(data, inBuf, data.Length);
    uint outBuf = 0;
    DeviceIoControl(h, code, inBuf, inBuf.Length, out outBuf, 4, IntPtr.Zero, IntPtr.Zero);
    return outBuf;
  }
  public static uint Version(IntPtr h) { return Ctl(h, VERSION, null); }
  public static void Ping(IntPtr h)    { Ctl(h, UPDATE, null); }
  public static uint Add(IntPtr h)     { uint i = Ctl(h, ADD, null); Ctl(h, UPDATE, null); return i; }
  public static void Remove(IntPtr h, int index) {
    byte[] b = new byte[2];                       // 16-bit big-endian index
    b[0] = (byte)(index & 0xFF); b[1] = (byte)((index >> 8) & 0xFF);
    Ctl(h, REMOVE, b); Ctl(h, UPDATE, null);
  }

  // ---- Display enumeration ------------------------------------------------
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)]  public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey;
  }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public uint dmFields;
    public int dmPositionX, dmPositionY; public uint dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public ushort dmLogPixels;
    public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern bool EnumDisplayDevices(string device, uint num, ref DISPLAY_DEVICE dd, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);

  // Attached screens driven by the Parsec adapter, in \\.\DISPLAYn order.
  public static string[] VirtualDisplays() {
    List<string> found = new List<string>();
    DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
    dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
    for (uint i = 0; EnumDisplayDevices(null, i, ref dd, 0); i++) {
      if ((dd.StateFlags & 0x1) != 0 && dd.DeviceString.IndexOf("Parsec", StringComparison.OrdinalIgnoreCase) >= 0)
        found.Add(dd.DeviceName);                                   // ATTACHED_TO_DESKTOP
      dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
    }
    return found.ToArray();
  }

  // Modalita' supportate dallo schermo: un monitor indiretto ne espone una lista
  // fissa e rifiuta in silenzio tutto il resto.
  public static string Modes(string device) {
    List<string> all = new List<string>();
    DEVMODE dm = new DEVMODE(); dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
    for (int i = 0; EnumDisplaySettings(device, i, ref dm); i++) {
      if (dm.dmBitsPerPel >= 32 && dm.dmDisplayFrequency == 60)
        all.Add(dm.dmPelsWidth + "x" + dm.dmPelsHeight);
      dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
    }
    return string.Join(" ", all.ToArray());
  }

  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  static extern int ChangeDisplaySettingsEx(string device, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr param);

  // Cambio di modalita' immediato. Niente DM_POSITION e niente CDS_NORESET: con la
  // posizione Windows rifiuta l'intero cambio (i desktop devono restare contigui e
  // ci penserebbe da solo), e in staging il driver indiretto risponde
  // DISP_CHANGE_FAILED. Cosi' invece torna 0 e il monitor cambia davvero.
  public static int SetMode(string device, int w, int h) {
    DEVMODE dm = new DEVMODE(); dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
    bool found = false;
    for (int i = 0; EnumDisplaySettings(device, i, ref dm); i++) {
      if (dm.dmPelsWidth == w && dm.dmPelsHeight == h && dm.dmBitsPerPel >= 32 && dm.dmDisplayFrequency == 60) { found = true; break; }
      dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
    }
    if (!found) return -100;
    dm.dmFields = 0x80000 | 0x100000 | 0x400000 | 0x40000;   // WIDTH | HEIGHT | FREQUENCY | BITSPERPEL
    return ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero, 0, IntPtr.Zero);
  }

  // width, height, x, y of a screen's current mode.
  public static int[] Geometry(string device) {
    DEVMODE dm = new DEVMODE(); dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(device, -1, ref dm)) return new int[] { 0, 0, 0, 0 };
    return new int[] { (int)dm.dmPelsWidth, (int)dm.dmPelsHeight, dm.dmPositionX, dm.dmPositionY };
  }
}
'@
Add-Type -TypeDefinition $sig

function Publish-State($devices) {
    $modes = if ($devices.Count) { [Vdd]::Modes($devices[0]) } else { '' }
    $out = @()
    for ($i = 0; $i -lt $devices.Count; $i++) {
        $g = [Vdd]::Geometry($devices[$i])
        $out += [pscustomobject]@{
            slot = $i; device = $devices[$i]
            width = $g[0]; height = $g[1]; x = $g[2]; y = $g[3]
            modes = $modes
        }
    }
    # Windows PowerShell 5.1 non ha -AsArray e degrada un elemento singolo a oggetto.
    $json = $out | ConvertTo-Json -Depth 4
    if ($out.Count -le 1) { $json = "[$json]" }
    # Senza questo Set-Content ci mette un BOM, che ConvertFrom-Json non digerisce.
    [IO.File]::WriteAllText($STATE, $json, (New-Object Text.UTF8Encoding $false))
}

$h = [Vdd]::Open()
if ($h -eq [IntPtr](-1)) { throw 'Parsec Virtual Display Adapter non raggiungibile (driver assente o gia'' in uso).' }
Note "VDD pronto (versione minore $([Vdd]::Version($h)))"

$added = @()
try {
    # Un'istanza precedente puo' avere monitor ancora attaccati: il watchdog del
    # driver li stacca da solo, ma Windows riusa gli stessi \\.\DISPLAYn, quindi
    # distinguerli per nome non funziona — si aspetta il campo libero e si conta.
    for ($t = 0; $t -lt 60 -and @([Vdd]::VirtualDisplays()).Count -gt 0; $t++) { Start-Sleep -Milliseconds 250 }

    for ($i = 0; $i -lt $Count; $i++) {
        $added += [int][Vdd]::Add($h)
        Start-Sleep -Milliseconds 700
    }

    $devices = @()
    for ($t = 0; $t -lt 40 -and $devices.Count -lt $Count; $t++) {
        Start-Sleep -Milliseconds 300
        $devices = @([Vdd]::VirtualDisplays())
    }
    if ($devices.Count -eq 0) { throw 'Nessun monitor virtuale collegato.' }

    foreach ($d in $devices) {
        $g = [Vdd]::Geometry($d)
        Note "monitor virtuale $d  $($g[0])x$($g[1]) @ $($g[2]),$($g[3])"
    }
    Publish-State $devices

    Note "modalita' disponibili: $([Vdd]::Modes($devices[0]))"
    Note 'PING - i monitor restano finche'' questo processo vive.'

    # Oltre a tenere in vita i monitor, questo processo e' il regista delle
    # risoluzioni: il client scrive "<slot> <larghezza>x<altezza>" nel file di
    # richiesta e lo schermo di quello slot cambia forma. E' cosi' che una finestra
    # ridimensionata sul Mac ridimensiona davvero la finestra su Windows, invece di
    # limitarsi a scalare l'immagine.
    $tick = 0
    while ($true) {
        [Vdd]::Ping($h)
        Start-Sleep -Milliseconds 50
        if ((++$tick % 6) -ne 0 -or -not (Test-Path $REQUEST)) { continue }

        $req = ''
        try { $req = (Get-Content $REQUEST -Raw -EA Stop).Trim() } catch { continue }
        Remove-Item $REQUEST -Force -EA SilentlyContinue

        # Le risoluzioni aggiunte al driver le legge solo quando un monitor arriva:
        # staccarli e riattaccarli e' l'unico modo di farle comparire, e puo' farlo
        # solo questo processo, che e' l'unico che parla col driver.
        if ($req -eq 'replug') {
            Note 'riaggancio dei monitor (nuove risoluzioni)'
            foreach ($i in $added) { [Vdd]::Remove($h, $i) }
            # Lo stacco non e' immediato: riattaccare prima che siano spariti lascia
            # un monitor fantasma in piu', che poi resta li' fino al riavvio.
            for ($t = 0; $t -lt 40 -and @([Vdd]::VirtualDisplays()).Count -gt 0; $t++) {
                Start-Sleep -Milliseconds 300
            }
            Start-Sleep -Milliseconds 500
            $added = @()
            for ($i = 0; $i -lt $Count; $i++) { $added += [Vdd]::Add($h) ; Start-Sleep -Milliseconds 300 }
            $devices = @()
            for ($t = 0; $t -lt 40 -and $devices.Count -lt $Count; $t++) {
                Start-Sleep -Milliseconds 300
                $devices = @([Vdd]::VirtualDisplays())
            }
            Publish-State $devices
            Note "modalita' disponibili: $([Vdd]::Modes($devices[0]))"
            continue
        }

        if ($req -notmatch '^(\d+)\s+(\d+)x(\d+)$') { continue }

        $slot = [int]$Matches[1]
        if ($slot -ge $devices.Count) { continue }
        $rc = [Vdd]::SetMode($devices[$slot], [int]$Matches[2], [int]$Matches[3])
        Start-Sleep -Milliseconds 400
        Publish-State $devices
        $g = [Vdd]::Geometry($devices[$slot])
        Note "slot $slot -> $($g[0])x$($g[1]) (rc $rc)"
    }
}
finally {
    foreach ($i in $added) { [Vdd]::Remove($h, $i) }
    Remove-Item $STATE -Force -EA SilentlyContinue
    [Vdd]::CloseHandle($h) | Out-Null
}
