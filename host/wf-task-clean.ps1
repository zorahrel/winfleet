# Toglie dall'host i task pianificati che NON sono di winfleet.
#
# Una diagnosi su Windows lascia dietro i task che lanciavano i suoi script,
# e cancellare il file non li disarma: restano registrati, puntano al vuoto, e
# chi apre l'Utilita' di pianificazione vede un elenco che sembra roba di
# winfleet. Sull'host ne sono rimasti otto dal 16/08.
#
# Uno era "wf-lock", cioe' LockWorkStation: un task che BLOCCA la sessione del
# PC, che e' esattamente la condizione in cui i monitor virtuali smettono di
# disegnare e ogni finestra si apre nera.
#
# I task da TENERE arrivano come parametro, per nome. Non si indovinano dal
# prefisso: "wf-nolock" e' del repo - lo lancia il doctor per impedire che lo
# schermo si blocchi - e un filtro su "^wf-" l'avrebbe cancellato, rompendo il
# sistema per fare pulizia.
#
# Questo script sta in un FILE e non in un "-Command" inline: fra ssh, cmd e
# PowerShell il quoting di "-Confirm:$false" si perde per strada (visto: il
# backslash arrivava letterale e PowerShell rifiutava una stringa dove voleva
# uno switch). Gli script del repo si eseguono tutti cosi', per lo stesso
# motivo.
param(
  # string[] e non string, ed e' il punto centrale di tutto questo file.
  #
  # PowerShell tratta "a,b,c" su una riga di comando come un ARRAY, non come
  # una stringa con dentro delle virgole. Dichiarando [string] lo converte, e
  # la conversione di un array a stringa unisce con SPAZI: "a b c". A quel
  # punto Split(',') non trova niente, l'elenco dei protetti e' un solo
  # elemento incollato, e -notcontains e' vero per tutti.
  #
  # Costo reale: TUTTI e 23 i task dell'host disinstallati, i 15 veri
  # compresi, con il messaggio "23 task di diagnosi rimossi" che sembrava un
  # successo. Il PC ha continuato a funzionare solo perche' i processi erano
  # gia' avviati: al primo riavvio non sarebbe ripartito niente.
  [Parameter(Mandatory=$true)][string[]]$Keep,
  [switch]$WhatIfOnly                          # elenca soltanto, non tocca
)
$ErrorActionPreference = 'Continue'

# Si accettano entrambe le forme - array vero e stringa unica - perche' chi
# chiama puo' passare l'uno o l'altra a seconda di come il quoting sopravvive
# al giro ssh -> cmd -> PowerShell. Gli apici, se arrivano attaccati al valore,
# si tolgono qui: passandoli da ssh finivano DENTRO il nome, e
# "'winfleet-agent" non corrisponde a nessun task.
$keep = @($Keep) |
  ForEach-Object { $_ -split '[,\s]+' } |
  ForEach-Object { $_.Trim().Trim("'", '"') } |
  Where-Object { $_ }
if (-not $keep) { Write-Output 'ERRORE: elenco dei task da tenere vuoto'; exit 1 }

# E se l'elenco non somiglia a quello atteso, ci si FERMA invece di cancellare.
#
# Un parametro che arriva male e' indistinguibile, per il resto dello script,
# da "non c'e' niente da tenere": in entrambi i casi la lista dei protetti e'
# vuota o senza corrispondenze, e la cancellazione procede allegramente. Se
# nessuno dei nomi da tenere esiste davvero fra i task presenti, il parametro
# e' sbagliato - non e' possibile che winfleet chieda di preservare quindici
# task che non esistono.
$presenti = @(Get-ScheduledTask | Where-Object { $_.TaskName -match '^(wf-|winfleet-)' } |
              ForEach-Object { $_.TaskName })
$corrisponde = @($keep | Where-Object { $presenti -contains $_ })
if ($presenti.Count -gt 0 -and $corrisponde.Count -eq 0) {
  Write-Output "ERRORE: nessuno dei $($keep.Count) task da tenere esiste sull'host."
  Write-Output "        Il parametro -Keep e' arrivato male; non tocco niente."
  Write-Output "        ricevuto: $($keep -join '|')"
  exit 1
}

# Il perimetro e' stretto: solo i nostri due prefissi. Un task di qualcun altro
# non si tocca mai, comunque si chiami.
$da_togliere = @(Get-ScheduledTask |
  Where-Object { $_.TaskName -match '^(wf-|winfleet-)' -and $keep -notcontains $_.TaskName })

if (-not $da_togliere) { Write-Output 'niente da togliere'; exit 0 }

# Un tetto: se sarebbero da togliere PIU' task di quanti se ne tengono, si
# rifiuta. E' l'ultima rete, quella che avrebbe fermato il disastro del 26/08
# anche senza sapere che il bug erano gli apici.
#
# La forma sana e': tanti task veri, pochi residui. "Togliere 23 e tenerne 0"
# non e' una pulizia, e' una disinstallazione - e nessuna pulizia legittima ha
# quella forma. Il controllo non guarda il perche', guarda la proporzione:
# funziona anche per il prossimo bug, che sara' diverso da questo.
if ($da_togliere.Count -gt $corrisponde.Count) {
  Write-Output "ERRORE: toglierei $($da_togliere.Count) task tenendone solo $($corrisponde.Count)."
  Write-Output "        Sproporzione sospetta: non tocco niente."
  Write-Output "        toglierei: $(($da_togliere | ForEach-Object { $_.TaskName }) -join ',')"
  exit 1
}

foreach ($t in $da_togliere) {
  if ($WhatIfOnly) { Write-Output "toglierei: $($t.TaskName)"; continue }
  try {
    Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -EA Stop
    Write-Output "tolto: $($t.TaskName)"
  } catch {
    Write-Output "ERRORE su $($t.TaskName): $($_.Exception.Message)"
  }
}
