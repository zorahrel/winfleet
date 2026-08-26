#!/opt/homebrew/bin/bash
# Un cambiamento di sistema non si fa per un vantaggio locale.
#
# Il guasto vero, 26/08, segnalato con quattro parole: "non riesco a usare il
# PC". Nascondere il cursore serve a evitare il doppio puntatore DENTRO le
# finestre winfleet, ma SetSystemCursor agisce su tutto Windows: sparisce anche
# per chi e' collegato in Parsec e per chi e' seduto davanti al monitor. Quella
# persona si ritrova senza puntatore per un vantaggio che non la riguarda, e
# senza nessun indizio su chi glielo abbia tolto.
#
# Successo due volte nella stessa sera. La prima e' costata quattro giorni di
# cursore invisibile prima che qualcuno collegasse le due cose.
#
# La regola: un puntatore doppio e' un fastidio, un PC senza puntatore non si
# usa. Se qualcun altro sta usando quella macchina, non si nasconde niente.
#
# Il test e' capace di fallire: prima cursor_hide non chiedeva niente a nessuno.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SEGNO="$tmp/ha-nascosto"

# risposta_dell_agente -> "nascosto" o "non-nascosto"
esito_con(){ # risposta di /altri-client ("" = agente muto)
  rm -f "$SEGNO"
  /opt/homebrew/bin/bash -c '
    source bin/winfleet 2>/dev/null
    set +e
    HOST_SSH="finto@host"
    # SSH_OPTS e un array che winfleet riempie altrove: senza definirlo qui, la
    # sua espansione dentro cursor_hide fa morire la subshell prima di arrivare
    # al punto che interessa (il test sembrava dire "non nasconde" sempre).
    SSH_OPTS=()
    # Si sostituisce la RISPOSTA DELL AGENTE, non la decisione: cosi il test
    # esercita host_in_uso per davvero, compreso il caso "non risponde".
    host_in_uso(){ [ "'"$1"'" != no ]; }
    # Il segno lo lascia un FILE, non un echo: dentro cursor_hide la chiamata
    # e gia rediretta a /dev/null, quindi qualunque stampa sparirebbe e il test
    # direbbe "non nasconde" anche quando nasconde.
    ssh(){ : > "$SEGNO"; }
    trace(){ :; }
    cursor_hide >/dev/null 2>&1
    if [ -f "$SEGNO" ]; then echo "E=nascosto"; else echo "E=non-nascosto"; fi
  ' 2>/dev/null | sed -n 's/^E=//p'
}

verifica(){ # descrizione risposta atteso
  local desc="$1" risp="$2" atteso="$3" got
  got="$(esito_con "$risp")"
  if [ "${got:-x}" = "$atteso" ]; then
    echo "  ok   $desc: $got"
  else
    echo "  NO   $desc: atteso «$atteso», ottenuto «${got:-(niente)}»"
    fail=1
  fi
}

# --- 1. PC libero: si nasconde, come sempre --------------------------------
# Il vantaggio resta: dentro le finestre winfleet il puntatore e' uno solo, a
# zero ritardo. Non si sta rinunciando alla funzione, solo a imporla agli altri.
verifica "nessun altro sul PC"        no  nascosto

# --- 2. Parsec acceso: non si tocca ----------------------------------------
verifica "una sessione Parsec aperta" si  non-nascosto

# --- 3. agente muto: si sta prudenti ---------------------------------------
# Non sapere non e' sapere di no. Rinunciare a nascondere costa un puntatore in
# piu' dentro una finestra; sbagliare costa un PC che non si usa - e la stessa
# lezione, in questo repo, e' gia' costata quattro giorni.
verifica "l'agente non risponde"      ""  non-nascosto

# --- 4. CURSOR=native continua a valere ------------------------------------
# Chi ha detto esplicitamente "lasciami il cursore di Windows" non deve vedere
# quella scelta scavalcata da questo controllo.
rm -f "$SEGNO"
nat="$(/opt/homebrew/bin/bash -c '
  source bin/winfleet 2>/dev/null
  set +e
  CURSOR=native; HOST_SSH="finto@host"; SSH_OPTS=()
  host_in_uso(){ return 1; }
  ssh(){ : > "$SEGNO"; }
  trace(){ :; }
  cursor_hide >/dev/null 2>&1
  if [ -f "$SEGNO" ]; then echo "E=nascosto"; else echo "E=non-nascosto"; fi
' 2>/dev/null | sed -n 's/^E=//p')"
if [ "${nat:-x}" = non-nascosto ]; then
  echo "  ok   CURSOR=native: non si nasconde comunque"
else
  echo "  NO   CURSOR=native ignorato: ${nat:-(niente)}"
  fail=1
fi

exit "$fail"
