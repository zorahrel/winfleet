#!/opt/homebrew/bin/bash
# "winfleet stop" chiude la finestra, per nome o per numero.
#
# Il guasto: "winfleet stop Paint" moriva con «Paint: unbound variable» e non
# chiudeva niente. L'argomento finiva dritto in $(( $1 - 1 )) e bash provava a
# valutare "Paint" come una variabile; sotto set -u quello e' fatale, quindi il
# comando usciva senza fare nulla e senza spiegare perche'.
#
# Era li' dal primo commit, e nessun test toccava questo comando: si guardava
# sempre l'apertura, mai la chiusura.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0

# --- 1. un nome non viene trattato come un numero ---------------------------
# Si prova la funzione, non il giro completo: chiudere una finestra vera
# richiede un host acceso, e questo controllo deve valere sempre.
if grep -q 'if \[ "\$1" -eq "\$1" \] 2>/dev/null; then' bin/winfleet; then
  echo "  ok   stop: distingue un numero da un nome prima di fare i conti"
else
  echo "  NO   stop: l'argomento finisce in un'espressione aritmetica"
  fail=1
fi

# --- 2. il nome viene cercato fra le finestre aperte ------------------------
if grep -q 'slot_get "\$k" app' bin/winfleet; then
  echo "  ok   stop: cerca in quale finestra sta l'app chiesta"
else
  echo "  NO   stop: un nome non viene cercato da nessuna parte"
  fail=1
fi

# --- 3. il comando non muore su un nome -------------------------------------
# La prova vera: si lancia il comando con un nome, e deve rispondere invece di
# morire. Con "unbound variable" l'uscita e' 1 ma il messaggio finisce in
# stderr come errore di bash, non come una frase per chi legge.
out="$(./bin/winfleet stop NomeCheNonEsisteMai 2>&1)"
if printf '%s' "$out" | grep -q 'unbound variable'; then
  echo "  NO   stop: muore con un errore di bash su un nome"
  fail=1
elif printf '%s' "$out" | grep -qi 'non è aperta\|non e. aperta'; then
  echo "  ok   stop: su un'app non aperta risponde a parole, non si schianta"
else
  echo "  NO   stop: risposta inattesa -> $(printf '%s' "$out" | head -1)"
  fail=1
fi

# --- 4. un numero fuori intervallo resta un errore chiaro -------------------
out2="$(./bin/winfleet stop 99 2>&1)"
if printf '%s' "$out2" | grep -qi 'inesistente'; then
  echo "  ok   stop: un numero fuori intervallo lo dice chiaramente"
else
  echo "  NO   stop: numero fuori intervallo non gestito -> $(printf '%s' "$out2" | head -1)"
  fail=1
fi

# --- 5. anche i supervisori senza stato vengono spenti ---------------------
# Una chiusura precedente puo' aver rimosso lo slot ma non il figlio staccato.
# Il test esegue il vero cmd_stop con i bordi finti: dopo uno slot regolare deve
# comunque chiamare la spazzata, non fare return troppo presto.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
awk '/^stop_untracked_winfleet\(\)/{on=1} on && /^cmd_list\(\)/{exit} on{print}' \
  bin/winfleet > "$TMP/stop-lib.sh"
if [ -s "$TMP/stop-lib.sh" ] && /opt/homebrew/bin/bash -u -c '
  . "$1"
  SLOTS=1
  slot_live(){ return 0; }
  close_slot(){ closed_slot="$1"; }
  stop_untracked_winfleet(){ swept=1; return 0; }
  cmd_stop
  [ "${closed_slot:-}" = 0 ] && [ "${swept:-}" = 1 ]
' bash "$TMP/stop-lib.sh" >/dev/null 2>&1; then
  echo "  ok   stop: dopo gli slot noti spazza anche i worker senza stato"
else
  echo "  NO   stop: ritorna prima di spegnere i worker senza stato"
  fail=1
fi

# --- 6. non uccide Moonlight che non appartiene a WinFleet -----------------
# Il vecchio fallback prendeva qualunque "Moonlight stream" del Mac. Le
# sessioni dirette vengono ora registrate al lancio e fermate per pid+avvio,
# mentre i runner hanno un pattern confinato alla cartella WinFleet.
if grep -Fq 'pkill -f "Moonlight.*stream"' bin/winfleet; then
  echo "  NO   stop: c'e' ancora un pkill generico che puo' chiudere Moonlight altrui"
  fail=1
elif grep -Fq 'direct_stream_save "$mpid"' bin/winfleet &&
     grep -Fq 'stop_direct_streams' bin/winfleet; then
  echo "  ok   stop: chiude solo PID registrati da WinFleet, non Moonlight altrui"
else
  echo "  NO   stop: manca il registro dei Moonlight diretti di WinFleet"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
