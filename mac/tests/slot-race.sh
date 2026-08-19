#!/opt/homebrew/bin/bash
# Due aperture insieme non finiscono sulla stessa finestra.
#
# Il guasto, visto dal vivo: due "winfleet open" a pochi secondi l'uno dall'altro
# hanno messo Paint e Arc sulla STESSA istanza (:48189). pick_slot guarda lo
# stato e dice un numero, ma fra quel numero e il momento in cui lo stream lo
# occupa passano secondi - rename dell'istanza, scelta della modalita', avvio del
# binario - e in quella finestra il secondo comando vede lo stesso slot ancora
# libero.
#
# Il risultato non e' un errore: e' che chi ha chiesto Paint si vede aprire Arc,
# e resta in giro un processo orfano senza slot registrato. Nessun messaggio da
# nessuna parte.
#
# Qui si prova il meccanismo di prenotazione senza aprire finestre vere: due
# processi che scelgono nello stesso istante devono ottenere numeri diversi.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# La funzione si prova isolata: "source bin/winfleet" senza argomenti esegue il
# doctor, che parla con l'host e ci mette secondi.
cat > "$TMP/lib.sh" <<'SH'
CONFIG_DIR="$WF_TEST_DIR"
trace(){ :; }
SH
# Dalla costante fino alla fine di slot_held: un solo blocco, cosi' non si
# spezza una funzione a meta' (successo: il file estratto non compilava e sei
# processi su sei fallivano per errore di sintassi, non per la corsa).
awk '/^SLOT_HOLD_SECS=/{on=1} on{print} on && /^slot_held\(\)/{inh=1} inh && /^}/{exit}' \
  bin/winfleet >> "$TMP/lib.sh"
if ! /opt/homebrew/bin/bash -n "$TMP/lib.sh" 2>/dev/null; then
  echo "  NO   estrazione: il pezzo di codice da provare non e' valido"
  echo "FAIL"; exit 1
fi

# --- 1. due processi insieme: uno solo ottiene la prenotazione -------------
cat > "$TMP/gara.sh" <<'SH'
#!/opt/homebrew/bin/bash
set -u
. "$1"
# Tutti partono allo stesso istante: senza questo il primo finisce prima che il
# secondo cominci, e la corsa non si riprodurrebbe.
while [ ! -f "$WF_TEST_DIR/via" ]; do sleep 0.01; done
if slot_hold 0; then
  echo "preso" > "$WF_TEST_DIR/esito.$$"
  # Chi vince RESTA VIVO, come un'apertura vera che sta avviando lo stream.
  # Uscendo subito il processo muore, gli altri vedono una prenotazione di un pid
  # morto - che e' proprio la condizione per rilevarla - e se la prendono a
  # ragione: il test misurava la pulizia delle prenotazioni orfane, non la corsa.
  sleep 3
else
  echo "no" > "$WF_TEST_DIR/esito.$$"
fi
SH
chmod +x "$TMP/gara.sh"

export WF_TEST_DIR="$TMP"
for i in 1 2 3 4 5 6; do
  "$TMP/gara.sh" "$TMP/lib.sh" &
done
sleep 0.4
touch "$TMP/via"
wait

presi=$(grep -l preso "$TMP"/esito.* 2>/dev/null | wc -l | tr -d ' ')
if [ "$presi" = 1 ]; then
  echo "  ok   corsa: su 6 processi insieme, uno solo prende la finestra"
else
  echo "  NO   corsa: $presi processi hanno preso la STESSA finestra"
  fail=1
fi

# --- 2. pick_slot salta gli slot prenotati ---------------------------------
# E' l'altra meta': prenotare non serve se chi sceglie non ne tiene conto.
if grep -q 'slot_held "$i" && continue' bin/winfleet; then
  echo "  ok   scelta: chi cerca una finestra salta quelle gia' prenotate"
else
  echo "  NO   scelta: pick_slot ignora le prenotazioni"
  fail=1
fi

# --- 3. una prenotazione orfana non blocca la finestra per sempre ----------
# Un comando ucciso a meta' lascerebbe lo slot inutilizzabile: il sintomo
# sarebbe "le finestre sono tutte occupate" con tutte le finestre libere.
rm -f "$TMP/slot1.hold"
printf '999999 %s\n' "$(date +%s)" > "$TMP/slot1.hold"   # pid che non esiste
if /opt/homebrew/bin/bash -c ". '$TMP/lib.sh'; slot_hold 1" >/dev/null 2>&1; then
  echo "  ok   orfane: una prenotazione di un comando morto viene rilevata"
else
  echo "  NO   orfane: la finestra resta bloccata da un comando che non c'e' piu'"
  fail=1
fi

# --- 4. una prenotazione viva viene rispettata -----------------------------
rm -f "$TMP/slot2.hold"
printf '%s %s\n' "$$" "$(date +%s)" > "$TMP/slot2.hold"  # un processo vivo di sicuro
if /opt/homebrew/bin/bash -c ". '$TMP/lib.sh'; slot_hold 2" >/dev/null 2>&1; then
  echo "  NO   viva: rubata una finestra prenotata da un comando ancora attivo"
  fail=1
else
  echo "  ok   viva: una prenotazione attiva non viene rubata"
fi

# --- 5. il trap rilascia la prenotazione anche se l'apertura fallisce -------
# La prenotazione si prende alla scelta dello slot e si toglie con un trap: se
# quel trap non ci fosse, ogni apertura fallita lascerebbe uno slot bloccato per
# 90 secondi, e il sintomo sarebbe "le finestre sono tutte occupate" con tutte
# le finestre libere.
if grep -q "trap 'slot_unhold" bin/winfleet; then
  echo "  ok   rilascio: la prenotazione si toglie comunque finisca l'apertura"
else
  echo "  NO   rilascio: un'apertura fallita lascerebbe lo slot bloccato"
  fail=1
fi

# --- 6. chi sceglie tiene conto delle prenotazioni ANCHE al secondo giro ----
# cmd_open, se non riesce a prenotare lo slot scelto, ne cerca un altro: se quel
# secondo giro non prenotasse, due comandi tornerebbero a scontrarsi - solo un
# po' piu' tardi.
if [ "$(grep -c 'slot_hold "$slot"' bin/winfleet)" -ge 2 ]; then
  echo "  ok   ripiego: anche lo slot di riserva viene prenotato"
else
  echo "  NO   ripiego: il secondo tentativo non prenota, la corsa si ripresenta"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
