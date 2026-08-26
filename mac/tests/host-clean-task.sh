#!/opt/homebrew/bin/bash
# La pulizia dell'host deve togliere i TASK di diagnosi e non quelli veri.
#
# host-clean puliva i file e ignorava i task pianificati: sull'host ne sono
# rimasti otto dal 16/08, fermi ma registrati, che puntavano a script
# cancellati da un pezzo. Uno era "wf-lock", cioe' LockWorkStation: un task
# che BLOCCA la sessione del PC, che e' esattamente la condizione in cui i
# monitor virtuali smettono di disegnare e ogni finestra si apre nera.
#
# Ma il primo tentativo di filtro era peggio del problema: "togli tutto cio'
# che comincia per wf-, i veri cominciano per winfleet-". Sbagliato:
# "wf-nolock" E' del repo e lo lancia il doctor. Cancellarlo avrebbe rotto il
# sistema per fare pulizia, con il danno visibile un'ora dopo e altrove.
#
# Da qui la regola provata sotto: i task da tenere si elencano per NOME.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fail=0
ok(){ printf '  \033[32mok\033[0m   %s\n' "$1"; }
ko(){ printf '  \033[31mNO\033[0m   %s\n' "$1"; fail=1; }

# L'elenco dei protetti, letto dal programma: se qualcuno lo cambia, il test
# guarda quello nuovo e non una sua copia rimasta indietro.
VERI="$(grep -oE 'local task_veri="[^"]*"' bin/winfleet | sed 's/.*="//; s/"$//')"
[ -n "$VERI" ] || { ko "non trovo l'elenco dei task protetti in winfleet"; exit 1; }

sopravvive(){ # nome -> si (tenuto) | no (rimosso)
  local n="$1"
  case "$n" in wf-*|winfleet-*) ;; *) echo si; return;; esac   # non nostro, non si tocca
  printf '%s\n' "$VERI" | tr ',' '\n' | grep -qxF "$n" && echo si || echo no
}

verifica(){ # nome atteso motivo
  local got; got="$(sopravvive "$1")"
  if [ "$got" = "$2" ]; then ok "$1 -> $([ "$2" = si ] && echo tenuto || echo rimosso)  ($3)"
  else ko "$1: atteso $2, ottenuto ${got} ($3)"; fi
}

# I residui di diagnosi trovati davvero sull'host il 26/08.
verifica wf-lock    no "LockWorkStation: blocca la sessione, i monitor si spengono"
verifica wf-probe   no "residuo del 16/08, lo script non esiste piu'"
verifica wf-shot    no "residuo del 16/08"
verifica wf-why     no "residuo del 16/08"
verifica wf-scr     no "residuo del 16/08"
verifica wf-raise   no "residuo del 16/08"
verifica wf-probe2  no "residuo del 16/08"

# Il caso che rendeva il filtro sui prefissi una trappola.
verifica wf-nolock  si "E' del repo: lo lancia il doctor, evita il blocco schermo"

# I task veri, che devono restare tutti.
for t in winfleet-agent winfleet-vdd winfleet-vdd-guard winfleet-place0 \
         winfleet-place3 winfleet-sun0 winfleet-sun3 winfleet-cursor-guard; do
  verifica "$t" si "task di winfleet"
done

# "winfleet-run" aveva il prefisso giusto e NON e' del repo: nessuno lo crea e
# punta a run-now.ps1, che sull'host non esiste (Test-Path False). Un filtro
# sui prefissi l'avrebbe protetto per sempre.
verifica winfleet-run no "prefisso giusto ma non e' del repo: punta a un file inesistente"

# E cio' che non e' nostro non si tocca MAI, comunque si chiami.
verifica GoogleUpdateTaskMachine si "di qualcun altro: fuori dal nostro perimetro"
verifica OneDrive\ Reporting     si "di qualcun altro"

# --- la lista non deve mentire --------------------------------------------
# Ogni task che il repo CREA dev'essere fra i protetti, o la prima pulizia lo
# disinstalla e rompe cio' che ha appena installato.
creati="$(grep -rhoE '/tn +"?[A-Za-z0-9_-]+' bin/winfleet host/*.ps1 2>/dev/null \
          | awk '{print $2}' | tr -d '"' | grep -v '^$' | sort -u)"
mancanti=""
for c in $creati; do
  case "$c" in
    # I nomi con lo slot appeso (winfleet-place, winfleet-sun) compaiono
    # troncati perche' nel codice sono seguiti da una variabile: si verificano
    # per esteso qui sopra, uno per uno.
    winfleet-place|winfleet-sun|winfleet-cursor) continue;;
  esac
  printf '%s\n' "$VERI" | tr ',' '\n' | grep -qxF "$c" || mancanti="$mancanti $c"
done
if [ -n "$mancanti" ]; then
  ko "il repo crea task che la pulizia cancellerebbe:$mancanti"
else
  ok "ogni task creato dal repo e' fra i protetti"
fi

# --- il parametro che arriva male non deve autorizzare una strage ----------
# Successo davvero, ed e' il difetto piu' caro della giornata: host-clean ha
# disinstallato TUTTI e 23 i task dell'host, i 15 veri compresi, stampando
# «23 task di diagnosi rimossi» come se fosse andato tutto bene. Il PC ha
# continuato a funzionare solo perche' i processi erano gia' avviati: al primo
# riavvio non sarebbe ripartito niente.
#
# La causa: -Keep dichiarato [string] mentre PowerShell tratta "a,b,c" su una
# riga di comando come un ARRAY. La conversione ad array-a-stringa unisce con
# SPAZI, Split(',') non trova piu' niente, e -notcontains diventa vero per
# tutti. Un errore di TIPO, invisibile: nessuna eccezione, nessun avviso.
#
# Le tre difese sotto sono in ordine di specificita': la prima toglie la causa,
# le altre due fermano il danno anche per la prossima causa, che sara' diversa.
if grep -q '\[string\[\]\]\$Keep' host/wf-task-clean.ps1; then
  ok "il parametro -Keep e' un array: PowerShell non lo appiattisce"
else
  ko "-Keep e' [string]: PowerShell spezza sulle virgole e la protezione salta"
fi

if grep -q "nessuno dei .* task da tenere esiste" host/wf-task-clean.ps1; then
  ok "si ferma se nessun task da tenere esiste (parametro arrivato male)"
else
  ko "un -Keep malformato passa per «non c'e' niente da tenere» e cancella tutto"
fi

if grep -q 'Sproporzione sospetta' host/wf-task-clean.ps1; then
  ok "si ferma se toglierebbe piu' task di quanti ne tiene"
else
  ko "nessun tetto: un bug futuro puo' di nuovo disinstallare tutto"
fi

# E la rimozione dev'essere contata, non dedotta dal codice di uscita:
# Unregister fallisce su un singolo task senza far fallire il comando.
if grep -q "grep -c '\^tolto: '" bin/winfleet; then
  ok "si contano i task tolti davvero, non si crede al codice di uscita"
else
  ko "si fida del codice di uscita: direbbe «rimossi» anche a meta' lavoro"
fi

# --- e la regola dev'essere nel programma ---------------------------------
if grep -q 'task pianificati di diagnosi' bin/winfleet; then
  ok "host-clean guarda anche i task, non solo i file"
else
  ko "host-clean ignora i task pianificati"
fi

# Il filtro cieco sul prefisso non deve tornare: e' la trappola di prima.
if grep -qE "TaskName -match '\^wf-' \} \| Unregister" bin/winfleet; then
  ko "e' tornato il filtro cieco '^wf-': cancellerebbe wf-nolock"
else
  ok "nessun filtro cieco sul prefisso"
fi

[ "$fail" = 0 ] && echo PASS || echo FAIL
exit "$fail"
