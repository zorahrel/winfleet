#!/opt/homebrew/bin/bash
# Le finestre che un'app apre per conto suo devono diventare finestre sul Mac.
#
# Il caso: da Arc si clicca "scarica", Windows apre Esplora file SULLO STESSO
# schermo virtuale, e sul Mac non si vede niente - il ritaglio mostra solo la
# finestra principale. La finestra esiste, e' viva, sta davanti a quella di Arc:
# semplicemente nessuno la guarda. Da fuori il click non ha fatto nulla.
#
# Qui si verifica la logica del riconoscimento, che e' la parte dove si sbaglia:
# quando una finestra e' "orfana" e quando invece NON va toccata.
#
# Il test e' capace di fallire: le regole sbagliate - prendere tutto quello che
# sta sul monitor, o confrontare per titolo invece che per handle - fanno saltare
# i casi qui sotto.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0

# La regola, isolata: una finestra e' orfana se sta dentro il rettangolo di un
# monitor virtuale, NON e' quella rivendicata da quello slot, e non e' quella
# rivendicata da nessun altro slot.
orfana(){ # cx cy mon_x mon_w hwnd mio_hwnd altrui_hwnd titolo
  local cx="$1" cy="$2" mx="$3" mw="$4" hw="$5" mio="$6" altrui="$7" tit="$8"
  # fuori dal monitor: non e' roba nostra
  [ "$cx" -lt "$mx" ] && return 1
  [ "$cx" -ge $(( mx + mw )) ] && return 1
  # la shell di Windows non si tocca mai
  [ "$tit" = "Program Manager" ] && return 1
  # e' la finestra principale di questo slot
  [ "$hw" = "$mio" ] && return 1
  # e' la finestra principale di un altro slot
  [ "$hw" = "$altrui" ] && return 1
  return 0
}

prova(){ # descrizione atteso args...
  local desc="$1" atteso="$2"; shift 2
  local got
  if orfana "$@"; then got=si; else got=no; fi
  if [ "$got" = "$atteso" ]; then
    echo "  ok   $desc"
  else
    echo "  NO   $desc: atteso $atteso, ottenuto $got"
    fail=1
  fi
}

#      descrizione                         atteso  cx    cy  mon_x mon_w  hwnd  mio  altrui titolo
prova "finestra figlia sul monitor giusto"  si    3600  200  3440  1800   999   111   222   "Salva con nome"
prova "la finestra principale non si tocca" no    3600  200  3440  1800   111   111   222   "Arc"
prova "quella di un altro slot nemmeno"     no    3600  200  3440  1800   222   111   222   "Telegram"
prova "il desktop di Windows mai"           no    3600  200  3440  1800   999   111   222   "Program Manager"
prova "fuori dal monitor: non e' nostra"    no     100  200  3440  1800   999   111   222   "Blocco note"
prova "sul bordo destro: ancora dentro"     si    5239  200  3440  1800   999   111   222   "Salva con nome"
prova "un pixel oltre: fuori"               no    5240  200  3440  1800   999   111   222   "Salva con nome"

# --- il codice esiste davvero? ---------------------------------------------
# Una regola giusta che nessuno applica non serve a niente.
if grep -q "'/orphans'" host/wf-agent.ps1 && grep -q "adopt_orphans" bin/winfleet; then
  echo "  ok   l'agente elenca le orfane e il Mac le adotta"
else
  echo "  NO   manca l'endpoint /orphans o la funzione che le adotta"
  fail=1
fi

# E la protezione contro il doppione: due slot che mostrano la stessa finestra
# sono due copie della stessa cosa, e chiuderne una chiude l'altra.
# Si cerca il CONTROLLO, non la parola: "altrui" compare anche nei commenti, e
# un grep su quella passerebbe anche col controllo rimosso.
if grep -q 'if ($altrui) { break }' host/wf-agent.ps1; then
  echo "  ok   una finestra gia' mostrata da un altro slot non viene adottata"
else
  echo "  NO   manca il controllo sulle finestre di altri slot"
  fail=1
fi

# Mai la stessa due volte: senza, a ogni giro si aprirebbe una finestra nuova
# per la stessa cosa.
if grep -q 'orphans-visti' bin/winfleet; then
  echo "  ok   una finestra gia' adottata non si riapre"
else
  echo "  NO   manca il registro delle finestre gia' adottate"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
