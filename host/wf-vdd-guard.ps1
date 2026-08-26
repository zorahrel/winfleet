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

# NON [Windows.Forms.Screen]::AllScreens: e' una CACHE.
#
# .NET la riempie al primo accesso e non la aggiorna piu' per la vita del
# processo. Qui il processo dura un istante, quindi sembrerebbe innocuo - e
# invece questo guardiano NON E' MAI INTERVENUTO: il 26/08 i monitor sono
# rimasti staccati per otto minuti, con winfleet che non apriva piu' niente
# (l'apertura si fermava a "risoluzione chiesta"), e nel log non c'e' una sola
# riga "rifaccio il VDD". Il guardiano guardava e vedeva sempre la stessa
# fotografia.
#
# Lo stesso identico difetto ha ingannato ME per un'ora dall'altra parte, nel
# doctor: e' il motivo per cui questa nota e' cosi' lunga. Una cache che mente
# non da' errori, da' rassicurazioni.
#
# EnumDisplayMonitors chiede a Windows adesso, ogni volta.
if (-not ('MonG' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class MonG {
  public delegate bool Proc(IntPtr h, IntPtr dc, IntPtr r, IntPtr d);
  [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, Proc cb, IntPtr data);
  public static int Count() {
    int n = 0;
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr h, IntPtr dc, IntPtr r, IntPtr d) { n++; return true; }, IntPtr.Zero);
    return n;
  }
}
'@
}
$totale = [MonG]::Count()
# Zero schermi non vuol dire "tutti staccati": vuol dire che stiamo guardando
# da una sessione senza desktop (via ssh e' la sessione 0, e li' non si vede
# niente). Rifare il VDD in quel caso spegnerebbe monitor funzionanti.
if ($totale -le 0) { return }
# Il monitor fisico c'e' sempre: gli altri sono i nostri.
$virtuali = $totale - 1
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
