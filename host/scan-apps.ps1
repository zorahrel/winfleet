<#
.SYNOPSIS
  Lists the GUI applications installed on this PC, as "Name<TAB>Path".

.DESCRIPTION
  Walks the Start Menu (both the user's and the machine's) and resolves each
  shortcut to its target .exe. That is what WinFleet's `winfleet search` reads
  to offer apps to open, so the list matches what a person would see in the
  Start menu rather than every binary on disk.

  Uninstallers, updaters, help and documentation links are dropped: they are
  never what you want on a remote screen.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$roots = @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
)
$skip = 'uninstall|disinstalla|readme|help|guida|manual|documentation|release note|' +
        'website|sito web|licen[sz]|update|updater|crash|report|debug|safe mode|' +
        'command prompt|powershell|prompt dei comandi'

$shell = New-Object -ComObject WScript.Shell
$seen  = @{}

foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Recurse -Filter *.lnk -EA SilentlyContinue | ForEach-Object {
        $name = [IO.Path]::GetFileNameWithoutExtension($_.Name)
        if ($name -match $skip) { return }
        try { $target = $shell.CreateShortcut($_.FullName).TargetPath } catch { return }
        if (-not $target -or $target -notmatch '\.exe$') { return }
        if (-not (Test-Path -LiteralPath $target)) { return }
        # System32 holds mostly consoles and applets, not apps people launch.
        if ($target -like "$env:SystemRoot\System32\*" -and $name -notmatch 'notepad|paint|character map|mappa caratteri') { return }
        if ($seen.ContainsKey($name)) { return }
        $seen[$name] = $true
        Write-Output ("{0}`t{1}" -f $name, $target)
    }
}
