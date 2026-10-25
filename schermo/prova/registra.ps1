# Prova a vista: registra il vero schermo del PC con ffmpeg (gdigrab) nella sessione della console.
#   registra.ps1 -Secondi 120 -Out C:\winfleet\schermo-video.mp4   video (5 fps, meta' risoluzione)
#   registra.ps1 -Foto -Out C:\winfleet\schermo-foto.png            un fotogramma
# Parte come task una tantum (da ssh gdigrab non vede il desktop) e torna subito; il file si copia a fine registrazione.
param([int]$Secondi = 120, [string]$Out = 'C:\winfleet\schermo-video.mp4', [switch]$Foto)
$ff = (Get-Command ffmpeg -EA SilentlyContinue).Source
if (-not $ff) { $ff = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe" }
Remove-Item $Out -Force -EA SilentlyContinue
$args = if ($Foto) { "-y -f gdigrab -i desktop -frames:v 1 `"$Out`"" }
        else { "-y -f gdigrab -framerate 5 -t $Secondi -i desktop -vf scale=1720:-2 -c:v libx264 -preset veryfast -crf 30 -pix_fmt yuv420p `"$Out`"" }
$a = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "C:\winfleet\wf-run-hidden.vbs `"$ff`" $args"
$p = New-ScheduledTaskPrincipal -UserId (whoami) -LogonType Interactive
Register-ScheduledTask -TaskName 'wf-schermo-registra' -Action $a -Principal $p -Force | Out-Null
Start-ScheduledTask -TaskName 'wf-schermo-registra'
Start-Sleep 3
Unregister-ScheduledTask -TaskName 'wf-schermo-registra' -Confirm:$false
"registrazione avviata: $Out"
