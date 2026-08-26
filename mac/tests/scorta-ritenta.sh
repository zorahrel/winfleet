#!/opt/homebrew/bin/bash
# La scorta deve RIPROVARE quando l'app scelta non apre finestre.
#
# Il 26/08, riverificando, il preparatore ha scritto nel log:
#     ready: «Calcolatrice» non ha aperto finestre: le do' un'altra occasione
#     ready: finestre preparate, esco
# ...e si e' fermato li'. Zero finestre pronte, e l'apertura successiva pagava
# nove secondi invece di tre. La "seconda occasione" era annunciata e mai presa:
# il codice registrava lo scarto, chiudeva lo slot e usciva.
#
# Questo file verifica le due meta' della correzione:
#   1. la logica di scelta dell'app di ripiego (simulata qui),
#   2. che la ritentata sia DAVVERO nel codice, non solo nel messaggio.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fallite=0
ok(){   printf '  \033[32mok\033[0m   %s\n' "$1"; }
ko(){   printf '  \033[31mKO\033[0m   %s\n' "$1"; fallite=$(( fallite + 1 )); }

# --- la scelta del ripiego -------------------------------------------------
# candidati | gia' aperte sugli slot | gia' bocciate  ->  chi si prova adesso
ripiego(){
  local cands="$1" aperte="$2" bocciate="$3" c presa
  local IFS='|'
  for c in $cands; do
    presa=0
    printf '%s\n' "$aperte"   | tr '|' '\n' | grep -qxF "$c" && presa=1
    printf '%s\n' "$bocciate" | tr '|' '\n' | grep -qxF "$c" && presa=1
    [ "$presa" = 0 ] && { printf '%s\n' "$c"; return 0; }
  done
  printf 'nessuno\n'
}

verifica(){
  local nome="$1" aperte="$2" bocciate="$3" atteso="$4"
  local got; got="$(ripiego "Blocco note|Calcolatrice|Memo|Fotocamera" "$aperte" "$bocciate")"
  if [ "$got" = "$atteso" ]; then ok "$nome: sceglie «${got}»"
  else ko "$nome: sceglie «${got}», doveva essere «${atteso}»"; fi
}

# Il caso vero del 26/08: Blocco note occupa uno slot, la Calcolatrice ha
# appena fallito. Il ripiego e' Memo, e senza la ritentata non si provava.
verifica "il caso del 26/08" "Blocco note" "Calcolatrice" "Memo"

# L'app appena bocciata non si ripesca: e' la ragione per cui siamo qui.
verifica "non ripesca la bocciata" "" "Blocco note" "Calcolatrice"

# Quando non resta niente si dice, invece di riprovare la stessa a vuoto.
verifica "candidati esauriti" "Blocco note|Calcolatrice" "Memo|Fotocamera" "nessuno"

# Una sola bocciatura non basta a bandire un'app per i giri FUTURI (serve la
# seconda), ma dentro QUESTO giro non la si riprova comunque.
verifica "bocciata una volta, saltata adesso" "" "Calcolatrice" "Blocco note"

# --- la ritentata e' nel codice, non solo nel messaggio ---------------------
# Senza questo, togliere la ritentata lascerebbe il file verde: le verifiche
# sopra provano una copia della logica, non il programma.
if grep -q 'ready: riprovo davvero, con' bin/winfleet; then
  ok "winfleet riprova davvero dopo un'app che non apre"
else
  ko "winfleet NON riprova: il log promette una seconda occasione che non arriva"
fi

# E la ritentata deve APRIRE qualcosa, non limitarsi a scriverlo.
if awk '/ready: riprovo davvero, con/,/^  fi$/' bin/winfleet | grep -q 'cmd_open "$rimasta"'; then
  ok "la ritentata apre davvero una finestra"
else
  ko "la ritentata non chiama cmd_open: e' di nuovo un messaggio e basta"
fi

# L'attesa di marcatura dev'essere riusabile: se torna in linea dentro
# cmd_ready, la ritentata non aspetta e le finestre restano non marcate.
if grep -q '^ready_mark_settled(){' bin/winfleet &&
   [ "$(grep -c 'ready_mark_settled ' bin/winfleet)" -ge 2 ]; then
  ok "l'attesa di marcatura e' condivisa fra tentativo e ritentata"
else
  ko "l'attesa di marcatura non e' condivisa: la ritentata non marca niente"
fi

if [ "$fallite" = 0 ]; then exit 0; fi
printf '\033[31m%s verifiche fallite\033[0m\n' "$fallite"; exit 1
