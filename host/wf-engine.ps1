# Dove sta il motore di cattura, per tutti gli script dell'host.
#
# winfleet usa Sunshine come MOTORE (cattura DXGI + encode NVENC), non come
# programma: le sue istanze sono processi con configurazioni proprie, e
# dell'installazione servono solo i file. Tenerli dentro C:\winfleet vuol dire
# che il PC non ha piu' "Sunshine installato" - niente voce fra i programmi,
# niente servizio, niente cartella in Program Files da cui qualcuno puo' aprire
# una web UI e rompere la configurazione.
#
# La scelta e' UNA SOLA e sta qui, non ripetuta in tre script: il percorso era
# scritto a mano in wf-instance.ps1, wf-inst-ctl.ps1 e setup.ps1, e un motore
# spostato avrebbe funzionato per alcune cose e non per altre.
#
# Ordine: prima il motore locale, poi l'installazione. Non il contrario - se
# esistono entrambi si usa il nostro, che e' quello di cui conosciamo la
# versione; l'altro puo' essere aggiornato da sotto senza che nessuno lo sappia.
function Get-WinfleetEngine {
    $locale = 'C:\winfleet\engine\sunshine.exe'
    if (Test-Path $locale) { return $locale }
    $installato = 'C:\Program Files\Sunshine\sunshine.exe'
    if (Test-Path $installato) { return $installato }
    throw "Nessun motore di cattura: manca sia C:\winfleet\engine\sunshine.exe sia l'installazione."
}
