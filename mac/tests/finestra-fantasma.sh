#!/opt/homebrew/bin/bash
# Un "ok" che non sposta niente e' un rifiuto, non una correzione.
#
# Il guasto vero, 26/08: la finestra sul Mac c'era, 1209x806, opaca, e non
# mostrava niente. Su Windows Arc era uscita lasciando sette processi senza
# nessuna finestra vera e un residuo di 160x28 ancora attaccato allo slot.
#
# winfleet lo inseguiva: chiedeva 1209x806, Windows rispondeva "ok 160 28" -
# SetWindowPos riesce, ma l'app rimette la finestra dov'era - e il giro dopo
# ricominciava. Per ore, tre righe di traccia al minuto, uno slot occupato da
# qualcosa che non avrebbe mai mostrato niente, e sul Mac una finestra vuota
# senza un errore da nessuna parte.
#
# Due regole, e questo file verifica entrambe:
#   1. "no" NON e' una misura: e' l'agente che dice "non l'ho trovata".
#   2. Se la misura confermata non e' quella chiesta, insistere non serve.
#
# Il test e' capace di fallire: con la logica vecchia il caso "ok ma non si
# muove" gira all'infinito e "no" viene preso per una misura.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0

# --- 1. "no" non viene scambiato per una misura ----------------------------
# E' il filtro che winfleet applica alla risposta di /appsize. Deve lasciar
# passare "1209x806" e fermare tutto il resto.
filtra(){ # risposta -> "" se non e' una misura
  local v="$1"
  case "$v" in
    ''|no|*[!0-9x]*) echo "";;
    *) echo "$v";;
  esac
}
for coppia in "1209x806:1209x806" "no:" ":" "160x28:160x28" "errore:" "12x:12x"; do
  ingresso="${coppia%%:*}"; atteso="${coppia#*:}"
  got="$(filtra "$ingresso")"
  if [ "$got" = "$atteso" ]; then
    echo "  ok   «${ingresso:-(vuoto)}» -> «${got:-(scartata)}»"
  else
    echo "  NO   «${ingresso}» doveva dare «${atteso:-(scartata)}», ha dato «${got:-(scartata)}»"
    fail=1
  fi
done

# --- 2. un "ok" che conferma la misura chiesta e' una correzione ------------
# Il caso normale: si chiede 1209x806 e Windows conferma 1209x806.
esito(){ # risposta_di_rect_set chiesta_w chiesta_h -> riuscita|rifiuto
  local got="$1" aw="$2" ah="$3" rw rh
  rw="$(echo "$got" | awk '{print $2}')"; rh="$(echo "$got" | awk '{print $3}')"
  if [ "$rw" = "$aw" ] && [ "$rh" = "$ah" ]; then echo riuscita; else echo rifiuto; fi
}
if [ "$(esito "ok 1209 806" 1209 806)" = riuscita ]; then
  echo "  ok   «ok 1209 806» per 1209x806: correzione riuscita"
else
  echo "  NO   una correzione riuscita viene letta come rifiuto"
  fail=1
fi

# --- 3. e un "ok" con un'altra misura e' un RIFIUTO ------------------------
# E' il guasto vero: "ok 160 28" quando si erano chiesti 1209x806.
if [ "$(esito "ok 160 28" 1209 806)" = rifiuto ]; then
  echo "  ok   «ok 160 28» per 1209x806: riconosciuto come rifiuto"
else
  echo "  NO   «ok 160 28» viene preso per una correzione riuscita"
  fail=1
fi

# --- 4. dopo tre rifiuti si smette ------------------------------------------
# Senza un limite si insegue per sempre: misurato, ore di "la rimetto" ogni
# dodici secondi su una finestra che non esisteva piu'.
rifiuti=0; giri=0; mollato=0
while [ "$giri" -lt 50 ]; do
  giri=$(( giri + 1 ))
  if [ "$(esito "ok 160 28" 1209 806)" = rifiuto ]; then
    rifiuti=$(( rifiuti + 1 ))
    if [ "$rifiuti" -ge 3 ]; then mollato=1; break; fi
  else
    rifiuti=0
  fi
done
if [ "$mollato" = 1 ] && [ "$giri" = 3 ]; then
  echo "  ok   si smette dopo 3 rifiuti, non si insegue all'infinito"
else
  echo "  NO   dopo $giri giri mollato=$mollato: il ciclo non si ferma"
  fail=1
fi

# --- 5. e un rifiuto isolato non fa mollare --------------------------------
# Una correzione puo' non aver ancora fatto effetto: un solo "no" non deve
# far buttare via una finestra viva.
rifiuti=0; mollato=0
for r in "ok 160 28" "ok 1209 806" "ok 160 28" "ok 1209 806"; do
  if [ "$(esito "$r" 1209 806)" = rifiuto ]; then
    rifiuti=$(( rifiuti + 1 )); [ "$rifiuti" -ge 3 ] && mollato=1
  else
    rifiuti=0
  fi
done
if [ "$mollato" = 0 ]; then
  echo "  ok   rifiuti isolati non fanno abbandonare la finestra"
else
  echo "  NO   una finestra viva verrebbe abbandonata"
  fail=1
fi

# --- 6. il codice vero contiene entrambe le regole -------------------------
# Le regole sopra sono la copia di quelle in follow_resize: se qualcuno le
# toglie da li', questo file continuerebbe a passare senza accorgersene.
if grep -q "''|no|\*\[!0-9x\]\*" bin/winfleet && grep -q 'rifiuti" -ge 3' bin/winfleet; then
  echo "  ok   winfleet contiene il filtro e il limite dei rifiuti"
else
  echo "  NO   le regole non sono piu' in bin/winfleet"
  fail=1
fi

exit "$fail"
