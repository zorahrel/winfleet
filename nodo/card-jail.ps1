# Gabbia delle card del nodo: ogni CLI claude/codex lanciato da Topics finisce
# in un Job Object di Windows. Quando il CLI della card esce, TerminateJobObject
# uccide ogni nipote rimasto (find, bash, node).
# Niente KILL_ON_JOB_CLOSE apposta: con quello, la morte della gabbia stessa
# (riavvio, aggiornamento) ucciderebbe le card vive. Se la gabbia muore, i job
# restano senza padrone: li copre la pulizia degli orfani di pc-nodo-prep.
# Perche': il 10/11 un `find / -type d` lanciato da una card e' sopravvissuto
# alla card per 4 ore, 15.784 s di CPU e 9,66 milioni di handle; il pool
# paginato del kernel e' arrivato a 30 GB.
# Tetti per ogni processo della gabbia: 1 ora di CPU (limite del job) e
# 200 mila handle (controllato da noi: i job non hanno un limite di handle).
#
# Uso: card-jail.ps1            residente (task pianificato "topics-card-jail")
#      card-jail.ps1 -Test      rosso/verde: senza gabbia il nipote resta, con la gabbia muore
#      card-jail.ps1 -Test -NoJail   solo il ramo rosso
param([switch]$Test, [switch]$NoJail, [string]$Log = "E:\topics-nodo\logs\card-jail.log",
      [int]$MaxHandles = 200000, [int]$CpuSeconds = 3600)
$ErrorActionPreference = "Continue"
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class Jail {
  [StructLayout(LayoutKind.Sequential)] struct BASIC { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinWS, MaxWS; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
  [StructLayout(LayoutKind.Sequential)] struct IOC { public ulong a,b,c,d,e,f; }
  [StructLayout(LayoutKind.Sequential)] struct EXT { public BASIC Basic; public IOC Io; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a, string n);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr j, int c, ref EXT i, int l);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr j, uint code);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
  // Uccide tutto cio' che e' rimasto nel job della card e chiude il job
  public static bool Kill(IntPtr j) { bool ok = TerminateJobObject(j, 1); CloseHandle(j); return ok; }
  // 0x2 PROCESS_TIME
  public static IntPtr Wrap(int pid, long cpuSeconds, string name) {
    IntPtr j = CreateJobObject(IntPtr.Zero, name);
    if (j == IntPtr.Zero) throw new Exception("CreateJobObject " + Marshal.GetLastWin32Error());
    EXT e = new EXT(); e.Basic.LimitFlags = 0x2; e.Basic.PerProcessUserTimeLimit = cpuSeconds * 10000000L;
    if (!SetInformationJobObject(j, 9, ref e, Marshal.SizeOf(typeof(EXT)))) { CloseHandle(j); throw new Exception("SetInformationJobObject " + Marshal.GetLastWin32Error()); }
    IntPtr p = OpenProcess(0x0101, false, pid); // SET_QUOTA | TERMINATE
    if (p == IntPtr.Zero) { CloseHandle(j); throw new Exception("OpenProcess " + Marshal.GetLastWin32Error()); }
    bool ok = AssignProcessToJobObject(j, p); int err = Marshal.GetLastWin32Error(); CloseHandle(p);
    if (!ok) { CloseHandle(j); throw new Exception("AssignProcessToJobObject " + err); }
    return j;
  }
}
"@
function Say($t) { $l = "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) $t"; if ($Test) { Write-Output $l } else { $l | Add-Content $Log } }

# discendenti di un pid (per il tetto di handle)
function Descendants($rootPid, $all) {
  $out = @(); $q = @($rootPid)
  while ($q.Count) { $x = $q[0]; $q = @($q | Select-Object -Skip 1); foreach ($c in $all | Where-Object { $_.ParentProcessId -eq $x }) { $out += $c; $q += $c.ProcessId } }
  $out
}

if ($Test) {
  # card finta: la radice nasce, viene ingabbiata, lancia un figlio che dorme e poi esce
  $marker = "cardjail-test-$PID"
  $root = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList "-NoProfile -Command `"Start-Sleep 2; Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile -Command Start-Sleep 600 # $marker'; Start-Sleep 3`""
  if (-not $NoJail) { $job = [Jail]::Wrap($root.Id, $CpuSeconds, $null) }
  $root.WaitForExit()
  if (-not $NoJail) { [Jail]::Kill($job) | Out-Null } # la card e' finita: uccido il job
  Start-Sleep 2
  $alive = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match $marker -and $_.ProcessId -ne $PID })
  $mode = if ($NoJail) { "senza gabbia" } else { "con gabbia" }
  if ($alive.Count) { $alive | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Write-Output "ROSSO ($mode): $($alive.Count) nipote vivo dopo la fine della card"; exit 1 }
  Write-Output "VERDE ($mode): nessun nipote dopo la fine della card"; exit 0
}

$jobs = @{}  # pid radice -> handle del job
Say "parto (cpu $CpuSeconds s/processo, handle max $MaxHandles)"
while ($true) {
  $all = @(Get-CimInstance Win32_Process)
  $roots = $all | Where-Object { ($_.ExecutablePath -match '\\claude\\versions\\|\\codex' -or $_.Name -match '^(claude|codex)\.exe$') }
  # un CLI figlio di un altro CLI e' gia' nella gabbia del padre
  $rootPids = @($roots | ForEach-Object { $_.ProcessId })
  foreach ($r in $roots) {
    if ($jobs.ContainsKey($r.ProcessId) -or ($rootPids -contains $r.ParentProcessId)) { continue }
    try { $jobs[$r.ProcessId] = [Jail]::Wrap($r.ProcessId, $CpuSeconds, $null); Say "ingabbiato $($r.Name) pid $($r.ProcessId)" }
    catch { $jobs[$r.ProcessId] = [IntPtr]::Zero; Say "non ingabbiato pid $($r.ProcessId): $($_.Exception.Message)" }
  }
  foreach ($k in @($jobs.Keys)) {
    if (-not ($all | Where-Object { $_.ProcessId -eq $k })) {
      if ($jobs[$k] -ne [IntPtr]::Zero -and [Jail]::Kill($jobs[$k])) { Say "card finita (pid $k): job terminato, nipoti uccisi" }
      $jobs.Remove($k); continue
    }
    foreach ($d in (Descendants $k $all)) {
      if ($d.HandleCount -gt $MaxHandles) { Stop-Process -Id $d.ProcessId -Force -ErrorAction SilentlyContinue; Say "ucciso $($d.Name) pid $($d.ProcessId): $($d.HandleCount) handle oltre $MaxHandles ($($d.CommandLine))" }
    }
  }
  Start-Sleep 5
}
