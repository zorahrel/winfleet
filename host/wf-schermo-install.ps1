# wf-schermo-install: registra il task wf-schermo clonando quello di wf-idleguard (stesso utente,
# stesso trigger al logon, stesso modo di lanciare: wf-run-hidden.vbs, senza console), cosi' gira
# nella sessione della console come l'altro e non serve conoscere l'utente dell'accesso automatico.
# Idempotente. Va lanciato via ssh dopo aver copiato wf-schermo.ps1 e la cartella schermo.
$ErrorActionPreference = 'Stop'
$dir = 'C:\winfleet'
foreach ($f in "$dir\wf-schermo.ps1", "$dir\wf-schermo-ctl.ps1", "$dir\wf-run-hidden.vbs", "$dir\schermo\index.html") {
  if (-not (Test-Path $f)) { throw "manca $f" }
}
$src = Get-ScheduledTask | Where-Object {
  @($_.Actions | Where-Object { "$($_.Execute) $($_.Arguments)" -match 'wf-idleguard' }).Count -gt 0 } | Select-Object -First 1
if (-not $src) { throw 'task di wf-idleguard non trovato: non so da quale clonare' }
$xml = [xml](Export-ScheduledTask -TaskName $src.TaskName -TaskPath $src.TaskPath)
$ex = @($xml.Task.Actions.Exec)[0]
$ex.Arguments = ("$($ex.Arguments)" -replace 'wf-idleguard\.ps1', 'wf-schermo.ps1')
if ("$($ex.Arguments)$($ex.Command)" -notmatch 'wf-schermo\.ps1') { throw "azione inattesa: $($ex.Command) $($ex.Arguments)" }
# il nodo puo' mancare nell'XML esportato: va creato prima di assegnarlo
function Set-XmlChild($parent, $name, $value) {
  $n = $parent.GetElementsByTagName($name) | Select-Object -First 1
  if (-not $n) { $n = $parent.OwnerDocument.CreateElement($name, $parent.NamespaceURI); [void]$parent.AppendChild($n) }
  $n.InnerText = $value
}
Set-XmlChild $xml.Task.RegistrationInfo 'Description' 'wf-schermo: schermata a tutto campo del PC quando nessuno lo usa (Edge kiosk, si chiude al primo tocco)'
# un guardiano che il sistema ferma dopo 72 ore non e' un guardiano
Set-XmlChild $xml.Task.Settings 'ExecutionTimeLimit' 'PT0S'
Register-ScheduledTask -TaskName 'wf-schermo' -Xml $xml.OuterXml -Force | Out-Null
Remove-Item "$dir\schermo.off" -Force -EA SilentlyContinue
Start-ScheduledTask -TaskName 'wf-schermo'
"registrato wf-schermo (clone di $($src.TaskName)): $($ex.Command) $($ex.Arguments)"
