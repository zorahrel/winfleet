#!/opt/homebrew/bin/bash
# Cmd+W in una finestra di stream VERA, non in una finestra di prova.
#
# Il resto dei controlli sul menu gira in un processo di test: dice che la voce
# esiste, che ha la scorciatoia giusta e che punta all'azione giusta. Non dice
# se quell'azione, dentro un Moonlight vero, chiude davvero la finestra - ed e'
# li' che si nascondeva il difetto: il delegate di SDL risponde NO a
# windowShouldClose:, quindi performClose: non chiudeva niente e lo stream
# finiva per una strada sua 4.6 secondi dopo.
#
# Qui si avvia uno stream vero con una sonda iniettata accanto alla libreria: la
# sonda manda Cmd+W come lo manda AppKit e cronometra quanto ci mette la
# finestra a sparire.
#
# Serve un host acceso: senza, si salta.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

CONFIG="$HOME/.config/winfleet/config.env"
[ -f "$CONFIG" ] || { echo "  SKIP: nessuna configurazione"; exit 0; }
LAN="$(awk -F'"' '/^HOST_LAN=/{print $2}' "$CONFIG")"
NAME="$(awk -F'"' '/^HOST_NAME=/{print $2}' "$CONFIG")"
LIB="$HOME/.config/winfleet/wf-chrome.dylib"
[ -f "$LIB" ] || { echo "  SKIP: libreria non compilata"; exit 0; }
if ! curl -s --max-time 3 "http://${LAN}:48089/serverinfo?uniqueid=winfleet" >/dev/null 2>&1; then
  echo "  SKIP: host non raggiungibile"
  exit 0
fi

# Uno slot libero: non si disturba una finestra in uso.
slot=""
for i in 0 1 2 3; do
  if ! pgrep -f "Moonlight stream.*:48$((i))89" >/dev/null 2>&1; then slot="$i"; break; fi
done
[ -n "$slot" ] || { echo "  SKIP: nessuna finestra libera"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; pkill -f "cmdw-probe" 2>/dev/null || true' EXIT

clang -dynamiclib -framework Cocoa -o "$TMP/probe.dylib" mac/tests/cmdw-probe.m 2>/dev/null || {
  echo "  SKIP: sonda non compilabile"; exit 0; }
codesign --force -s - "$TMP/probe.dylib" >/dev/null 2>&1 || true

bin="$HOME/.config/winfleet/runners/Paint.app/Contents/MacOS/Moonlight"
[ -x "$bin" ] || bin="$(ls "$HOME"/.config/winfleet/runners/*/Contents/MacOS/Moonlight 2>/dev/null | head -1)"
[ -x "$bin" ] || { echo "  SKIP: nessun runner"; exit 0; }

port=$(( 48089 + slot * 100 ))
DYLD_INSERT_LIBRARIES="$LIB:$TMP/probe.dylib" \
WF_WIN=1209x806 WF_SIZE="$HOME/.config/winfleet/slot$slot.size" WF_SLOT="$slot" \
  "$bin" stream "${NAME}:${port}" Desktop --display-mode windowed --fps 60 \
  --bitrate 50000 --absolute-mouse --no-vsync --quit-after --resolution 1800x1200 \
  >"$TMP/stream.log" 2>&1 &
mpid=$!

# Si aspetta l'esito della sonda, non un tempo fisso.
esito=""
for i in $(seq 1 60); do
  # process == "Moonlight": senza, "log show" cattura anche la PROPRIA riga di
  # comando (che contiene il testo cercato) e il test legge quella invece
  # dell'esito - visto succedere, con la sonda che aveva gia' riportato 0.14s.
  riga="$(log show --predicate 'process == "Moonlight" AND eventMessage CONTAINS "CRONO finestra"' \
          --last 2m --style compact 2>/dev/null | tail -1)"
  case "$riga" in *"sparita dopo"*) esito="$riga"; break;; *"ancora li'"*) esito="$riga"; break;; esac
  kill -0 "$mpid" 2>/dev/null || break
  sleep 1
done
kill "$mpid" 2>/dev/null || true

if [ -z "$esito" ]; then
  echo "  SKIP: la sonda non ha riportato (stream non partito?)"
  exit 0
fi

secondi="$(printf '%s' "$esito" | sed -n 's/.*sparita dopo \([0-9.]*\)s.*/\1/p')"
if [ -z "$secondi" ]; then
  echo "  NO   Cmd+W dal vivo: la finestra NON si e' chiusa"
  echo "FAIL"; exit 1
fi

# Sotto il secondo e' "istantaneo" per chi guarda. Con performClose: erano 4.6.
if [ "$(printf '%s\n' "$secondi < 1.5" | bc -l 2>/dev/null || echo 0)" = 1 ]; then
  echo "  ok   Cmd+W dal vivo: la finestra si chiude in ${secondi}s"
  echo "PASS"; exit 0
fi
echo "  NO   Cmd+W dal vivo: ci mette ${secondi}s (con performClose: erano 4.6)"
echo "FAIL"; exit 1
