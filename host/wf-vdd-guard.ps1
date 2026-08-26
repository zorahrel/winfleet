param([int]$Count = 4)

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
#
# Ma la domanda giusta non e' "il processo e' vivo": e' "i MONITOR ci sono".
# Sono due cose diverse, e il 26/08 si sono separate: un cambio di risoluzione
# e' fallito ("slot 2 -> 0x0 (rc -100)"), il driver ha spento tutti i monitor,
# e il processo e' rimasto vivo a guardia di niente. Il guardiano vedeva il
# processo, si dichiarava soddisfatto, e ogni apertura pagava diciassette
# secondi per far rinascere schermi che nessuno stava piu' tenendo su.
#
# Si contano gli schermi veri: se sono meno di quelli attesi - il monitor
# fisico piu' uno per slot - il processo va rifatto, vivo o no.
#
# ("${Count}:" con le graffe: in PowerShell "$Count:" fa parte del nome della
# variabile - e' la sintassi degli scope, tipo $env:PATH - e il file non
# compila piu'. Stessa famiglia di «${var}» in bash: un carattere attaccato
# al nome cambia cosa viene letto.)

Add-Type -AssemblyName System.Windows.Forms
$schermi = @([System.Windows.Forms.Screen]::AllScreens)
# Il monitor fisico c'e' sempre: gli altri sono i nostri.
$virtuali = $schermi.Count - 1
if ($virtuali -ge $Count) { return }

"$(Get-Date -f 'HH:mm:ss')  solo $virtuali monitor virtuali su ${Count}: rifaccio il VDD" |
    Add-Content 'C:\winfleet\vdd.log'

# Il processo vecchio va CHIUSO: se e' vivo ma non tiene su niente, lasciarlo
# in piedi significa che il nuovo non potra' prendere il suo posto.
Get-CimInstance Win32_Process -Filter 'Name="powershell.exe"' -EA SilentlyContinue |
    Where-Object { $_.CommandLine -like '*wf-vdd.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
Start-Sleep -Seconds 2
schtasks /run /tn winfleet-vdd | Out-Null
