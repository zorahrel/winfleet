#!/opt/homebrew/bin/bash
# Col PC spento winfleet lo dice, invece di fingere che vada tutto bene.
#
# Il guasto peggiore trovato oggi: "winfleet open" con l'host irraggiungibile
# usciva con codice ZERO, senza una riga di output, e non apriva niente. La
# causa era una pipe: con "pipefail" attivo, curl che non raggiunge l'host esce
# 28, la pipe vale quanto lui, e "set -e" termina il comando a meta' - senza
# messaggio, perche' quello sarebbe arrivato dopo.
#
# Poi il tempo: si andava avanti lo stesso fino ad avviare lo stream, e la
# risposta arrivava dopo mezzo minuto. Ora si scopre prima e si dice.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0
CONFIG="$HOME/.config/winfleet/config.env"
[ -f "$CONFIG" ] || { echo "  SKIP: nessuna configurazione"; exit 0; }

# Si lavora su una COPIA della configurazione, in una casa tutta sua: toccare
# quella vera vorrebbe dire lasciare l'utente scollegato se il test muore a
# meta'.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/winfleet"
# Serve anche il resto della casa: i runner e la libreria stanno li' dentro, e
# senza winfleet si ferma per un motivo diverso da quello che si sta provando.
for d in runners icons; do
  [ -d "$HOME/.config/winfleet/$d" ] && ln -s "$HOME/.config/winfleet/$d" "$TMP/winfleet/$d" 2>/dev/null || true
done
[ -f "$HOME/.config/winfleet/wf-chrome.dylib" ] && \
  ln -s "$HOME/.config/winfleet/wf-chrome.dylib" "$TMP/winfleet/wf-chrome.dylib" 2>/dev/null || true
[ -f "$HOME/.config/winfleet/host-apps.tsv" ] && \
  cp "$HOME/.config/winfleet/host-apps.tsv" "$TMP/winfleet/" 2>/dev/null || true
sed -e 's/^HOST_LAN=.*/HOST_LAN="192.168.99.99"/' \
    -e 's/^HOST_TS=.*/HOST_TS="100.99.99.99"/' \
    -e 's/^HOST_NAME=.*/HOST_NAME="nonesiste.local"/' \
    "$CONFIG" > "$TMP/winfleet/config.env"

# WINFLEET_CONFIG sposta CONFIG_DIR: winfleet leggera' la copia, non
# l'originale. (XDG_CONFIG_HOME non c'entra: il percorso e' scritto a mano.)
out="$(WINFLEET_CONFIG="$TMP/winfleet" ./bin/winfleet open Paint 2>&1)"
esito=$?

# --- 1. lo dice ------------------------------------------------------------
if printf '%s' "$out" | grep -qi "host non risponde\|irraggiungibile\|PC è spento\|PC e. spento"; then
  echo "  ok   PC spento: lo dice, e nomina la causa"
else
  echo "  NO   PC spento: nessun messaggio utile -> $(printf '%s' "$out" | tail -1 | cut -c1-70)"
  fail=1
fi

# --- 2. e non finge di avere funzionato -------------------------------------
# E' il difetto vero: uscita zero e nessun output. Uno script che chiama
# winfleet e guarda il codice di uscita andrebbe avanti convinto.
if [ "$esito" != 0 ]; then
  echo "  ok   PC spento: esce con errore, non fingendo di aver funzionato"
else
  echo "  NO   PC spento: esce con codice 0 come se fosse andato tutto bene"
  fail=1
fi

# --- 3. il curl fallito non uccide il comando -------------------------------
# La causa radice, dove sta: senza "|| true" la pipe con pipefail porta giu'
# tutto.
if grep -q 'tr -d .\\r. >"$VDD_CACHE.tmp" || true' bin/winfleet; then
  echo "  ok   pipe: un host che non risponde non termina il comando"
else
  echo "  NO   pipe: curl fallito puo' ancora uccidere l'apertura in silenzio"
  fail=1
fi

# --- 4. non si interrogano tutti gli slot uno per uno -----------------------
# Ognuno paga il proprio timeout: con quattro finestre erano quindici secondi
# per scoprire una cosa che si sa alla prima domanda.
if grep -q 'host non raggiungibile: nessuno slot da cercare' bin/winfleet; then
  echo "  ok   attesa: una domanda sola invece di una per finestra"
else
  echo "  NO   attesa: si interroga ogni slot, e ognuno aspetta il suo timeout"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
