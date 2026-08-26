# Rimette i monitor virtuali se il loro processo e' morto.
#
# I monitor virtuali esistono finche' vive il processo wf-vdd: se muore - un
# aggiornamento del driver, una sessione che si riduce, un kill andato male -
# restano morti fino al prossimo riavvio del PC. Il sintomo e' il piu'
# ingannevole di tutti: le finestre continuano ad aprirsi, winfleet dice
# "Arc -> finestra 1", ogni controllo e' verde, e sul Mac si vede il DESKTOP di
# Windows invece dell'app.
#
# Si CONTROLLA prima di avviare, invece di lanciare e sperare. La prima
# versione faceva "schtasks /run" a ogni giro fidandosi di
# MultipleInstances=IgnoreNew: non funziona, /run avvia comunque, e in poche
# ore si erano accumulate TRE istanze con OTTO monitor virtuali al posto di
# quattro. Il doppio degli schermi da disegnare per la GPU, e quattro slot che
# winfleet non usera' mai.
$vivo = Get-CimInstance Win32_Process -Filter 'Name="powershell.exe"' -EA SilentlyContinue |
        Where-Object { $_.CommandLine -like '*wf-vdd*' }
if ($vivo) { return }
"$(Get-Date -f 'HH:mm:ss')  nessun wf-vdd vivo: lo riavvio" | Add-Content 'C:\winfleet\vdd.log'
schtasks /run /tn winfleet-vdd | Out-Null
