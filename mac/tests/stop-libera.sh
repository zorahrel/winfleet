#!/opt/homebrew/bin/bash
# Dopo "winfleet stop" gli slot devono essere LIBERI, non solo chiusi.
#
# Chiudere il Moonlight sul Mac non chiude sempre la sessione dal lato di
# Sunshine: se il client muore male - ed e' il caso normale quando si chiude
# tutto insieme - l'istanza resta convinta che qualcuno stia guardando.
#
# Misurato il 26/08: dopo uno "stop" con le finestre aperte, ZERO processi
# Moonlight sul Mac e quattro slot su quattro che dicevano «in uso (da un altro
# client)» a misure assurde (0x0, 1920x1080). La prossima apertura rispondeva
# "tutte le finestre sono occupate" - lo stesso sintomo da cui e' partita
# l'intera giornata, e che sembrava tutt'altro problema.
#
# Il recupero (reap_stuck_slots) esisteva gia' ma lo chiamavano solo il
# rifornitore e l'apertura: chi spegneva e se ne andava lasciava il PC in quello
# stato, e il conto lo pagava il successivo.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fail=0
ok(){ printf '  \033[32mok\033[0m   %s\n' "$1"; }
ko(){ printf '  \033[31mNO\033[0m   %s\n' "$1"; fail=1; }

# --- la regola e' nel codice ------------------------------------------------
# Va verificata anche senza host: e' la parte che si puo' perdere in un
# refactoring, e senza di lei il guasto torna in silenzio.
# Si cerca una CHIAMATA, non la parola: il commento qui sopra a cmd_stop nomina
# reap_stuck_slots per spiegare perche' serve, e un grep sul nome passava anche
# dopo aver tolto la chiamata. Un controllo che il commento puo' soddisfare non
# controlla niente - verificato togliendo la riga: il test restava verde.
if awk '/^cmd_stop\(\)\{/,/^\}/' bin/winfleet | grep -vE '^\s*#' | grep -q '^\s*reap_stuck_slots'; then
  ok "stop libera anche le sessioni appese sull'host"
else
  ko "stop non recupera gli slot appesi: restano «in uso» senza nessun client"
fi

# E il recupero deve chiudere la sessione dell'istanza, non limitarsi a
# dimenticarla dalla nostra parte: uno slot dimenticato resta occupato per
# Sunshine, che e' chi decide se c'e' posto.
if awk '/^reap_stuck_slots\(\)\{/,/^\}/' bin/winfleet | grep -q 'wf-inst-ctl.ps1'; then
  ok "il recupero riavvia l'istanza, non si limita a scordarsene"
else
  ko "il recupero non tocca l'istanza: lo slot resta occupato per Sunshine"
fi

# --- la prova vera, se l'host c'e' ------------------------------------------
CONFIG="$HOME/.config/winfleet/config.env"
[ -f "$CONFIG" ] || { echo "  SKIP: nessuna configurazione"; [ "$fail" = 0 ] && echo PASS || echo FAIL; exit "$fail"; }
LAN="$(awk -F'"' '/^HOST_LAN=/{print $2}' "$CONFIG")"
if ! curl -s --max-time 3 "http://${LAN}:48089/serverinfo?uniqueid=winfleet" >/dev/null 2>&1; then
  echo "  SKIP: host non raggiungibile, provata solo la regola nel codice"
  [ "$fail" = 0 ] && echo PASS || echo FAIL
  exit "$fail"
fi

# Non si sequestra il PC di qualcun altro: se ci sono finestre aperte adesso,
# potrebbero essere sue.
aperte="$(./bin/winfleet windows 2>/dev/null | grep -cE '✓' || true)"
if [ "${aperte:-0}" -gt 0 ]; then
  echo "  SKIP: ci sono $aperte finestre aperte, non le chiudo per fare un test"
  [ "$fail" = 0 ] && echo PASS || echo FAIL
  exit "$fail"
fi

./bin/winfleet open "Blocco note" >/dev/null 2>&1 || true
./bin/winfleet stop >/dev/null 2>&1 || true

# Si guarda quanti slot risultano LIBERI: e' il numero che decide se la
# prossima apertura trovera' posto, ed e' l'unica cosa che conta davvero.
liberi="$(./bin/winfleet windows 2>/dev/null | grep -c 'libera' || true)"
if [ "${liberi:-0}" -ge 3 ]; then
  ok "dopo stop restano $liberi slot liberi su 4"
else
  ko "dopo stop solo $liberi slot liberi: le sessioni restano appese"
  echo "       rimedio:  winfleet doctor"
fi

[ "$fail" = 0 ] && echo PASS || echo FAIL
exit "$fail"
