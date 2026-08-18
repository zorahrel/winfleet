#!/opt/homebrew/bin/bash
# Un'istanza che non risponde non e' un'istanza occupata.
#
# Il guasto vero, trovato dopo una notte: il rifornitore ha scritto "nessuno slot
# libero, non preparo" ogni due minuti per quaranta minuti, con tutti e quattro
# gli slot vuoti e nessuna app aperta. Da fuori: ogni apertura tornava a costare
# quindici secondi, senza un errore da nessuna parte.
#
# La causa: slot_state chiede lo stato all'istanza Sunshine e torna una stringa
# VUOTA quando quella non risponde entro due secondi (riavviata da poco, rete con
# un singhiozzo, PC sotto carico). Una stringa vuota non contiene "FREE", quindi
# lo slot veniva contato come occupato - e se tacciono tutte, il rifornitore si
# ferma per sempre.
#
# Qui si verifica la distinzione: FREE e muto contano come disponibili, BUSY no.
# Il test e' capace di fallire: con la vecchia riga il caso "tutte mute" torna 0.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0

conta(){ # risposta_finta -> quanti slot risultano liberi con la logica NUOVA
  /opt/homebrew/bin/bash -c '
    source bin/winfleet 2>/dev/null
    slot_state(){ echo "'"$1"'"; }
    slot_live(){ return 1; }
    n=0; for i in 0 1 2 3; do if slot_free_ish "$i"; then n=$((n+1)); fi; done
    echo "N=$n"
  ' 2>/dev/null | sed -n 's/^N=//p'
}

conta_vecchio(){ # la logica di prima, per dimostrare che il test discrimina
  /opt/homebrew/bin/bash -c '
    source bin/winfleet 2>/dev/null
    slot_state(){ echo "'"$1"'"; }
    slot_live(){ return 1; }
    n=0
    for i in 0 1 2 3; do
      slot_live "$i" || case "$(slot_state "$i")" in *FREE*) n=$((n+1));; esac
    done
    echo "N=$n"
  ' 2>/dev/null | sed -n 's/^N=//p'
}

verifica(){ # descrizione risposta atteso
  local desc="$1" risp="$2" atteso="$3" got
  got="$(conta "$risp")"
  if [ "${got:-x}" = "$atteso" ]; then
    echo "  ok   $desc: $got slot disponibili"
  else
    echo "  NO   $desc: attesi $atteso, ottenuti ${got:-(niente)}"
    fail=1
  fi
}

verifica "istanze libere"        "SUNSHINE_SERVER_FREE" 4
verifica "istanze MUTE"          ""                     4
verifica "istanze occupate"      "SUNSHINE_SERVER_BUSY" 0

# Discriminante: e' il caso "mute" che prima si comportava male.
vecchio="$(conta_vecchio "")"
if [ "${vecchio:-x}" = 0 ]; then
  echo "  ok   il test discrimina: con la logica vecchia le mute davano 0 slot liberi"
else
  echo "  NO   il test non discrimina: anche la logica vecchia da' ${vecchio:-(niente)}"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
