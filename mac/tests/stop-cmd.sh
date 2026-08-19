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

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
