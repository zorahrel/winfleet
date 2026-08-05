<#
.SYNOPSIS
  Lists the GUI applications installed on this PC, as "Name<TAB>Path".

.DESCRIPTION
  Walks the Start Menu (both the user's and the machine's) and resolves each
  shortcut to its target .exe. That is what WinFleet's `winfleet search` reads
  to offer apps to open, so the list matches what a person would see in the
  Start menu rather than every binary on disk.

  Packaged apps are added on top of that. Notepad, Calculator, Photos and the rest
  of what ships with Windows 11 have no shortcut on disk at all — they exist only as
  an application id — so a Start Menu walk alone silently misses half the Start menu.
  Those come out as "shell:AppsFolder\<id>", which wf-place.ps1 knows how to open.

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

# Superfici della shell, non applicazioni: non hanno una finestra da mostrare e
# aprirle fa comparire un overlay a schermo intero (Game Bar) o l'app Giochi. In un
# elenco di "app da aprire in una finestra" non hanno posto.
$skipId = 'XboxGamingOverlay|Windows\.CBSPreview|InputApp|Windows\.PrintDialog|' +
          'WindowsFeedbackHub|Microsoft\.Windows\.Cortana|Client\.CBS|ShellExperienceHost|' +
          'Microsoft\.549981C3F5F10'   # Cortana

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

# Le app impacchettate: Get-StartApps le elenca tutte, e quelle dello Store hanno un
# AppUserModelID (col "!" dentro) invece di un percorso. Le voci gia' trovate come
# collegamento restano quelle: un .exe si avvia in modo piu' diretto.
Get-StartApps -EA SilentlyContinue | ForEach-Object {
    $name = $_.Name
    $id   = $_.AppID
    if (-not $name -or -not $id) { return }
    if ($name -match $skip) { return }
    if ($id -match $skipId) { return }
    if ($id -notmatch '!') { return }
    if ($seen.ContainsKey($name)) { return }
    $seen[$name] = $true
    Write-Output ("{0}`tshell:AppsFolder\{1}" -f $name, $id)
}
