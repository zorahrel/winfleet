#!/opt/homebrew/bin/bash
# Un'istanza che tace non e' un'istanza da riaccoppiare.
#
# Il guasto vero, 25/08: "Tutte le 4 finestre sono occupate" per ore, con
# "winfleet windows" che elencava quattro finestre LIBERE nello stesso minuto.
# I quattro file slotN.paired contenevano "no", scritti tutti insieme alle
# 22:34-22:35 - cioe' subito dopo che reap_stuck_slots aveva riavviato le
# istanze dichiarate BUSY. Interrogate mentre ripartivano, quelle non hanno
# risposto; slot_paired ha trattato il silenzio come "non ti conosco" e lo ha
# MEMORIZZATO per cinque minuti. Da li' in poi pick_slot scartava ogni slot per
# un pairing che c'era eccome (verificato: uuid presenti nel plist, con
# certificato, e serverinfo che rispondeva benissimo un minuto dopo).
#
# La distinzione che si verifica qui: "si" e "no" si ricordano perche' li ha
# detti l'istanza; il silenzio no, perche' e' uno stato della rete e non una
# proprieta' dello slot.
#
# Il test e' capace di fallire: con la vecchia riga il caso "muta" lascia "no".

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# esito_ask -> cosa resta scritto nel memo
memo_dopo(){ # codice_uscita_di_slot_paired_ask [contenuto_iniziale]
  local code="$1" pre="${2:-}"
  rm -rf "$tmp/cfg"; mkdir -p "$tmp/cfg"
  # Il memo va SCADUTO, altrimenti slot_paired risponde dalla memoria e non
  # arriva mai a interrogare l'istanza: il caso che interessa e' proprio il
  # rinnovo di un ricordo vecchio.
  if [ -n "$pre" ]; then
    printf '%s\n' "$pre" > "$tmp/cfg/slot0.paired"
    touch -t "$(date -v-1H '+%Y%m%d%H%M')" "$tmp/cfg/slot0.paired"
  fi
  /opt/homebrew/bin/bash -c '
    source bin/winfleet 2>/dev/null
    CONFIG_DIR="'"$tmp"'/cfg"
    slot_paired_ask(){ return '"$code"'; }
    slot_paired 0 >/dev/null 2>&1 || true
    if [ -f "$CONFIG_DIR/slot0.paired" ]; then
      echo "M=$(cat "$CONFIG_DIR/slot0.paired")"
    else
      echo "M=(assente)"
    fi
  ' 2>/dev/null | sed -n 's/^M=//p'
}

verifica(){ # descrizione codice atteso [pre]
  local desc="$1" code="$2" atteso="$3" pre="${4:-}" got
  got="$(memo_dopo "$code" "$pre")"
  if [ "${got:-x}" = "$atteso" ]; then
    echo "  ok   $desc: memo = $got"
  else
    echo "  NO   $desc: atteso «$atteso», ottenuto «${got:-(niente)}»"
    fail=1
  fi
}

# --- 1. cio' che l'istanza dice si ricorda ---------------------------------
verifica "risponde «accoppiata»"     0 "si"
verifica "risponde «non ti conosco»" 1 "no"

# --- 2. il silenzio no ------------------------------------------------------
# Il caso del guasto: l'istanza sta ripartendo e non risponde. Prima qui
# finiva "no", e ci restava per SLOT_PAIRED_TTL.
verifica "non risponde (memo nuovo)" 2 "(assente)"

# --- 3. e cancella un «no» che era nato dal silenzio ------------------------
# Un memo scaduto che valeva "no" non va confermato da un secondo silenzio:
# sarebbe lo stesso stallo, rinnovato ogni cinque minuti.
verifica "non risponde (memo vecchio)" 2 "(assente)" "no"

# --- 4. e uno slot muto non e' utilizzabile ADESSO --------------------------
# Non ricordarsi il silenzio non vuol dire fingere che sia accoppiato: chi
# chiede deve comunque sentirsi dire di no, per questo giro.
esito="$(/opt/homebrew/bin/bash -c '
  source bin/winfleet 2>/dev/null
  CONFIG_DIR="'"$tmp"'/cfg2"; mkdir -p "$CONFIG_DIR"
  slot_paired_ask(){ return 2; }
  set +e
  if slot_paired 0 >/dev/null 2>&1; then echo E=si; else echo E=no; fi
' 2>/dev/null | sed -n 's/^E=//p')"
if [ "${esito:-x}" = no ]; then
  echo "  ok   uno slot muto non viene offerto come accoppiato"
else
  echo "  NO   uno slot muto risulta accoppiato (${esito:-niente})"
  fail=1
fi

# --- 5. e con set -e lo script non muore ------------------------------------
# slot_paired_ask torna non-zero per progetto, e winfleet gira con "set -e":
# una chiamata nuda terminerebbe il comando invece di scrivere il memo.
vivo="$(/opt/homebrew/bin/bash -c '
  set -euo pipefail
  source bin/winfleet 2>/dev/null
  CONFIG_DIR="'"$tmp"'/cfg3"; mkdir -p "$CONFIG_DIR"
  slot_paired_ask(){ return 1; }
  slot_paired 0 >/dev/null 2>&1 || true
  echo V=vivo
' 2>/dev/null | sed -n 's/^V=//p')"
if [ "${vivo:-x}" = vivo ]; then
  echo "  ok   con set -e il comando sopravvive a un esito non-zero"
else
  echo "  NO   con set -e il comando muore dentro slot_paired"
  fail=1
fi

exit "$fail"
