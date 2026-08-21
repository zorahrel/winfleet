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
trap_body="$(sed -n "s/^[[:space:]]*trap '\\(slot_unhold.*\\)' RETURN$/\\1/p" bin/winfleet | tail -1)"
if [ -n "$trap_body" ] && TRAP_BODY="$trap_body" /opt/homebrew/bin/bash -u -c '
  released=""
  slot_unhold(){ released="$1"; }
  cmd_open(){ local slot=7; local WF_SLOT_HOLD="$slot"; trap "$TRAP_BODY" RETURN; }
  cmd_ready(){ cmd_open; return 0; }
  cmd_ready
  another_return(){ return 0; }
  another_return
  [ "$released" = 7 ] && [ -z "$(trap -p RETURN)" ]
'; then
  echo "  ok   rilascio: il trap usa lo slot giusto e si disarma al ritorno"
else
  echo "  NO   rilascio: il trap resta fuori scope o non libera la prenotazione"
  fail=1
fi

# RETURN non viene eseguito da exit. die deve quindi vedere la prenotazione
# anche se arriva da una funzione annidata (il percorso refresh_vdd → need_ssh).
awk '/^die\(\)/{on=1} on && /^need_config\(\)/{exit} on{print}' bin/winfleet > "$TMP/die.sh"
die_out="$(/opt/homebrew/bin/bash -u -c '
  c_red=""; c_off=""
  slot_unhold(){ echo "release:$1"; }
  . "$1"
  nested(){ die "errore finto"; }
  cmd_open(){ local slot=7; local WF_SLOT_HOLD="$slot"; nested; }
  cmd_open
' bash "$TMP/die.sh" 2>&1)"
die_rc=$?
if [ "$die_rc" = 1 ] && printf '%s\n' "$die_out" | grep -q '^release:7$'; then
  echo "  ok   rilascio fatale: anche un die annidato libera lo slot"
else
  echo "  NO   rilascio fatale: die non ha liberato lo slot (rc=$die_rc, $die_out)"
  fail=1
fi

# --- 7. un worker in background possiede davvero la sua prenotazione --------
# Dentro una subshell Bash $$ resta il pid del padre. Se lo si registra nel
# .hold, il padre puo' uscire mentre il worker e' vivo e il giro dopo lo ruba
# come "orfano". BASHPID e $! devono invece coincidere.
rm -f "$TMP/slot3.hold"
if /opt/homebrew/bin/bash -u -c '
  . "$1"
  ( slot_hold 3; if slot_held 3; then exit 2; fi; sleep 1 ) &
  worker=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$WF_TEST_DIR/slot3.hold" ] && break
    sleep 0.05
  done
  [ -f "$WF_TEST_DIR/slot3.hold" ] || exit 1
  read -r owner _ < "$WF_TEST_DIR/slot3.hold"
  [ "$owner" = "$worker" ] && kill -0 "$owner" 2>/dev/null || exit 1
  wait "$worker"
' bash "$TMP/lib.sh"; then
  echo "  ok   owner: un worker sullo sfondo non perde ne' ruba il proprio slot"
else
  echo "  NO   owner: il .hold non appartiene al worker vivo"
  fail=1
fi

# --- 8. il ripiego prenota anche lo slot di riserva -------------------------
# cmd_open, se non riesce a prenotare lo slot scelto, ne cerca un altro: se quel
# giro non prenotasse, due comandi tornerebbero a scontrarsi - solo un po' piu'
# tardi. (Il controllo guarda che la prenotazione stia DENTRO il ciclo di
# ripiego: contare le occorrenze non bastava piu' quando i due tentativi sono
# diventati un ciclo.)
if grep -A 3 'for tent in 1 2 3 4 5 6 7 8; do' bin/winfleet | grep -q 'slot_hold "\$slot"'; then
  echo "  ok   ripiego: ogni tentativo prenota prima di procedere"
else
  echo "  NO   ripiego: un tentativo procede senza prenotare, la corsa si ripresenta"
  fail=1
fi

# --- 9. il ripiego RIPROVA, non si arrende al primo scontro ----------------
# Con due comandi insieme un solo ripiego basta. Con quattro no: i perdenti
# ripiegano tutti sullo stesso secondo slot, e chi perde di nuovo moriva
# dicendo "un'altra apertura sta usando le finestre libere" mentre due finestre
# erano libere davvero. Misurato aprendo quattro app dal Dock insieme: due
# aperte, due sparite. Col ciclo: quattro su quattro.
if grep -q 'for tent in 1 2 3 4 5 6 7 8; do' bin/winfleet; then
  echo "  ok   ripiego: riprova finche' ci sono finestre libere"
else
  echo "  NO   ripiego: si arrende al primo scontro, e con 4 aperture ne perde 2"
  fail=1
fi

# --- 10. il messaggio di resa e' vero --------------------------------------
# "sta usando le finestre libere" ha senso solo se le finestre sono davvero
# tutte prenotate: si controlla lo stato invece di dedurlo dal fallimento.
if grep -q 'slot_held "\$slot" && die' bin/winfleet; then
  echo "  ok   resa: si arrende solo se lo slot e' davvero prenotato da altri"
else
  echo "  NO   resa: si arrende senza guardare se e' vero"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
