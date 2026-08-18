#!/opt/homebrew/bin/bash
# Aprire un'app deve mostrare QUELLA app, mai quella di prima.
#
# Il guasto vero, visto dal vivo: si apriva Arc e compariva il Blocco note con
# sopra il nome e l'icona di Arc. Il riuso di una finestra calda cambia l'app
# sopra un monitor gia' acceso, e per sapere se e' andata bene si chiedeva "c'e'
# una finestra su questo monitor?" - domanda che su una finestra calda ha sempre
# risposta si', perche' la finestra di prima e' ancora li'. Uno scambio mai
# avvenuto veniva quindi dichiarato riuscito.
#
# Qui si riproduce la logica di swap_app con un agente finto che risponde
# handle scelti da noi, e si verificano i tre casi che contano:
#   1. finestra cambiata            -> riuscito
#   2. finestra RIMASTA la stessa   -> deve fallire (e si torna alla via lunga)
#   3. finestra uguale a un altro slot -> deve fallire (mostrerebbe l'app altrui)
#
# Il caso 2 e' quello che il codice vecchio sbagliava: senza il confronto con
# l'handle precedente questo file torna PASS su tutto e non prova niente.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

SLOTS=4
declare -A HWND        # stato finto dell'host: slot -> handle

slot_hwnd_live(){ # slot
  local v="${HWND[$1]:-}"
  case "$v" in ''|no|0) return 1;; *) echo "$v";; esac
}

# Il cuore di swap_app, isolato: la parte che decide se lo scambio e' riuscito.
swap_ok(){ # slot handle_dopo
  local slot="$1" dopo="$2"
  local before_hwnd; before_hwnd="$(slot_hwnd_live "$slot" || true)"

  HWND[$slot]="$dopo"          # al posto di place_app: l'host ha risposto cosi'

  local now; now="$(slot_hwnd_live "$slot" || true)"
  [ -n "$now" ] || return 1
  [ "$now" != "$before_hwnd" ] || return 1

  local other
  for other in $(seq 0 $(( SLOTS - 1 ))); do
    [ "$other" = "$slot" ] && continue
    [ "$(slot_hwnd_live "$other" 2>/dev/null || true)" = "$now" ] || continue
    return 1
  done
  return 0
}

fail=0
prova(){ # descrizione atteso slot prima dopo [altro_slot altro_handle]
  local desc="$1" atteso="$2" slot="$3" prima="$4" dopo="$5"
  HWND=( [0]="" [1]="" [2]="" [3]="" )
  HWND[$slot]="$prima"
  [ "${6:-}" ] && HWND[$6]="${7:-}"
  if swap_ok "$slot" "$dopo"; then got=riuscito; else got=fallito; fi
  if [ "$got" = "$atteso" ]; then
    echo "  ok   $desc"
  else
    echo "  NO   $desc: atteso $atteso, ottenuto $got"
    fail=1
  fi
}

# L'app chiesta e' gia' quella sulla finestra: niente da scambiare, si accetta
# subito. Prima falliva - Windows non apre una seconda istanza di un'app a
# istanza singola, quindi nessuna finestra nuova, quindi "scambio non riuscito" -
# e dal Dock il click sull'icona non faceva proprio nulla. Capita con l'app usata
# per scaldare le finestre, che e' anche fra le piu' aperte (il Blocco note).
gia_sopra(){ # simula il ramo "e' gia' li'": real == app chiesta e finestra viva
  local real="$1" chiesta="$2" hwnd="$3"
  [ "$real" = "$chiesta" ] && [ -n "$hwnd" ]
}
if gia_sopra "Blocco note" "Blocco note" 555; then
  echo "  ok   stessa app gia' sulla finestra: accettata senza scambiare"
else
  echo "  NO   stessa app gia' sulla finestra: non riconosciuta"
  fail=1
fi
if gia_sopra "Blocco note" "Arc" 555; then
  echo "  NO   app diversa: non doveva essere accettata senza scambio"
  fail=1
else
  echo "  ok   app diversa: si passa dallo scambio vero"
fi
if gia_sopra "Blocco note" "Blocco note" ""; then
  echo "  NO   senza finestra viva non si puo' accettare"
  fail=1
else
  echo "  ok   stessa app ma nessuna finestra: non si accetta"
fi

prova "finestra nuova: lo scambio vale"            riuscito 2 111 222
prova "finestra invariata: si torna alla via lunga" fallito  2 111 111
prova "nessuna finestra: fallisce"                  fallito  2 111 ""
prova "finestra di un altro slot: fallisce"         fallito  2 111 999 3 999
prova "da slot vuoto una finestra nuova va bene"    riuscito 1 ""  555

# Un'app che non apre nessuna finestra su Windows non va dichiarata aperta.
#
# La misura che si aspettava e' quella della finestra di MOONLIGHT sul Mac, e
# quella compare sempre - anche quando l'app di la' non e' partita affatto.
# Risultato: winfleet diceva "Calcolatrice - finestra 1 sul Mac" e l'utente si
# ritrovava una finestra vuota, senza che niente spiegasse perche'. (La
# Calcolatrice, su questo host, e' rotta davvero: non parte nemmeno lanciata a
# mano.)
if grep -q 'non ha aperto nessuna finestra su Windows' bin/winfleet; then
  echo "  ok   un'app senza finestra non viene dichiarata aperta"
else
  echo "  NO   manca il controllo: si dichiarerebbe aperta una finestra vuota"
  fail=1
fi

# I due controlli sopra provano la LOGICA; questo prova che sia davvero nel
# codice - una logica giusta che nessuno chiama non serve a niente.
if grep -q 'slot_get "\$slot" real' bin/winfleet && grep -q 'real=%s' bin/winfleet; then
  echo "  ok   il codice ricorda l'app sulla finestra e la controlla"
else
  echo "  NO   manca il campo real o il suo controllo in swap_app"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
