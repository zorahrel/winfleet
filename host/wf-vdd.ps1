<#
.SYNOPSIS
  Plugs and unplugs virtual monitors on the Parsec Virtual Display Adapter.

.DESCRIPTION
  A virtual monitor lets WinFleet stream an app on a screen of its own: the PC's
  real desktop stays untouched, and several apps can be streamed at once, one per
  virtual monitor.

  The adapter ships with Parsec and is already present on most gaming PCs, so
  nothing new is installed here — this only speaks its control protocol
  (documented at github.com/nomi-san/parsec-vdd). The driver unplugs its monitors
  unless it is pinged more often than every 100 ms, so this script stays resident
  and keeps pinging until stopped; that also means a crash can never strand a
  virtual monitor on the PC.

.PARAMETER Count
  How many virtual monitors to plug (default 1).

.EXAMPLE
  powershell -File wf-vdd.ps1 -Count 2
#>
[CmdletBinding()]
param([int]$Count = 1)

$ErrorActionPreference = 'Stop'
$sig = @'
using System; using System.Runtime.InteropServices;
public class Vdd {
  [StructLayout(LayoutKind.Sequential)] public struct GUID {
    public uint a; public ushort b, c; [MarshalAs(UnmanagedType.ByValArray, SizeConst=8)] public byte[] d;
  }
  [StructLayout(LayoutKind.Sequential)] public struct SP_DEVICE_INTERFACE_DATA {
    public int cbSize; public GUID InterfaceClassGuid; public int Flags; public IntPtr Reserved;
  }
  [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr SetupDiGetClassDevs(ref GUID g, IntPtr enumerator, IntPtr hwnd, int flags);
  [DllImport("setupapi.dll", SetLastError=true)]
  public static extern bool SetupDiEnumDeviceInterfaces(IntPtr devInfo, IntPtr devInfoData, ref GUID g, int i, ref SP_DEVICE_INTERFACE_DATA data);
  [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr devInfo, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, int size, ref int required, IntPtr devInfoData);
  [DllImport("setupapi.dll")] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr devInfo);

  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr CreateFile(string path, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, int inSize, out uint outBuf, int outSize, IntPtr bytes, IntPtr overlapped);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);

  // Interface GUID of the Parsec Virtual Display Adapter.
  public static GUID AdapterGuid() {
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
          // cbSize of SP_DEVICE_INTERFACE_DETAIL_DATA_W: 8 on x64, 6 on x86.
          Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
          if (!SetupDiGetDeviceInterfaceDetail(info, ref d, buf, need, ref need, IntPtr.Zero)) continue;
          string path = Marshal.PtrToStringUni((IntPtr)(buf.ToInt64() + 4));
          IntPtr h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0x20000080 | 0x80000000, IntPtr.Zero);
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
    byte[] b = new byte[2];               // 16-bit big-endian index
    b[0] = (byte)(index & 0xFF); b[1] = (byte)((index >> 8) & 0xFF);
    Ctl(h, REMOVE, b); Ctl(h, UPDATE, null);
  }
}
'@
Add-Type -TypeDefinition $sig

$h = [Vdd]::Open()
if ($h -eq [IntPtr](-1)) { throw 'Parsec Virtual Display Adapter non raggiungibile (driver assente o in uso).' }

$ver = [Vdd]::Version($h)
Write-Host "VDD pronto (versione minore $ver)"

$added = @()
try {
    for ($i = 0; $i -lt $Count; $i++) {
        $idx = [Vdd]::Add($h)
        $added += [int]$idx
        Write-Host "monitor virtuale aggiunto (indice $idx)"
        Start-Sleep -Milliseconds 400
    }
    Set-Content 'C:\winfleet\vdd-active.txt' ($added -join ',')
    Write-Host 'PING - i monitor restano finché questo processo vive.'
    while ($true) { [Vdd]::Ping($h); Start-Sleep -Milliseconds 50 }
}
finally {
    foreach ($i in $added) { [Vdd]::Remove($h, $i) }
    Remove-Item 'C:\winfleet\vdd-active.txt' -Force -EA SilentlyContinue
    [Vdd]::CloseHandle($h) | Out-Null
}
