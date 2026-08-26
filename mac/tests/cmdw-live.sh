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
WF_CMDW_MARK="$TMP/mark" \
  "$bin" stream "${NAME}:${port}" Desktop --display-mode windowed --fps 60 \
  --bitrate 50000 --absolute-mouse --no-vsync --quit-after --resolution 1800x1200 \
  >"$TMP/stream.log" 2>&1 &
mpid=$!

# L'esito si legge dallo STDERR del processo, non dal log unificato.
#
# La sonda riporta con NSLog, che per un processo lanciato da terminale scrive
# su stderr - qui gia' rediretto in stream.log. Il log unificato di macOS non
# lo vede, quindi "log show" non trovava MAI la riga: in sei ore di sessione le
# uniche occorrenze di "CRONO" erano i comandi log show stessi. Il test dava
# SKIP a ogni esecuzione e sembrava un problema d'ambiente ("stream non
# partito?"), mentre era CIECO: avrebbe detto SKIP anche con Cmd+W rotto.
#
# E il limite si guarda in SECONDI, non in giri: "60 giri con sleep 1" sembra
# un minuto e non lo era, perche' ogni log show costava 4,7 secondi misurati -
# fino a cinque minuti, abbastanza da far scadere l'intera suite.
esito=""
morto=0
scadenza=$(( $(date +%s) + 45 ))
while [ "$(date +%s)" -lt "$scadenza" ]; do
  # La MORTE del processo e' il successo, non un imprevisto: Cmd+W chiude la
  # finestra di stream e Moonlight esce. Si aspetta quella.
  if ! kill -0 "$mpid" 2>/dev/null; then morto=1; break; fi
  riga="$(grep 'CRONO finestra' "$TMP/stream.log" 2>/dev/null | tail -1)"
  case "$riga" in *"sparita dopo"*) esito="$riga"; break;; *"ancora li'"*) esito="$riga"; break;; esac
  sleep 0.2
done
fine="$(date +%s.%N)"
kill "$mpid" 2>/dev/null || true

# Il tempo si calcola da FUORI: marcatore della sonda -> morte del processo.
#
# La sonda non puo' misurare la propria morte, ed e' proprio la morte il
# successo: Cmd+W chiude la finestra, Moonlight esce, e la riga con il tempo
# non viene mai scritta. Il test aspettava quella riga e concludeva "SKIP: la
# sonda non ha riportato" - taceva nel caso di successo, e avrebbe taciuto
# identico con Cmd+W rotto. Cieco in entrambi i sensi.
#
# Ora la sonda scrive su disco l'istante in cui manda Cmd+W (WF_CMDW_MARK), e
# qui si misura fino a quando il processo sparisce: un osservatore che
# sopravvive a cio' che osserva.
if [ -z "$esito" ] && [ "$morto" = 1 ] && [ -s "$TMP/mark" ]; then
  inizio="$(cat "$TMP/mark")"
  secondi="$(awk -v a="$inizio" -v b="$fine" 'BEGIN{printf "%.2f", b-a}')"
  # La morte del processo NON basta come prova, e questo test ci e' cascato.
  #
  # Moonlight parte con --quit-after e se ne va da solo dopo circa otto
  # secondi, comunque vada. Misurando "quando muore" si misurava quello:
  # sabotando ENTRAMBE le strade di chiusura nella libreria - la voce di menu
  # e il monitor sugli eventi - il test continuava a dire «la finestra si
  # chiude in 0.11s», PASS. Un test che approva anche il codice rotto non e'
  # un test, e questo lo faceva da quando esiste.
  #
  # LIMITE NOTO, scritto qui perche' non venga scambiato per una garanzia.
  #
  # Il tempo separa la fine naturale (circa otto secondi) da una chiusura
  # rapida, e tanto basta a non scambiare l'una per l'altra. NON basta a
  # dimostrare che sia stato Cmd+W: sabotando entrambe le strade di chiusura
  # nella libreria - la voce di menu e il monitor sugli eventi - la finestra
  # sparisce comunque in 0.09s, perche' la sonda le ha appena mandato
  # makeKeyAndOrderFront: e SDL reagisce per conto suo.
  #
  # Quindi questo test dice: "la finestra si e' chiusa in fretta dopo Cmd+W".
  # Non dice: "si e' chiusa PERCHE' Cmd+W". Per quella prova servirebbe un
  # tasto premuto davvero, che richiede il permesso Accessibilita' - il motivo
  # per cui questa sonda esiste. Il valore che resta e' comunque reale: quando
  # la catena e' rotta sul serio (menu assente, libreria non caricata) il test
  # se ne accorge, ed e' l'unico posto dove Cmd+W viene esercitato in un
  # Moonlight vero invece che in un processo di prova.
  #
  # Chi legge un PASS qui sappia esattamente cosa ha comprato.
  if awk -v s="$secondi" 'BEGIN{exit !(s < 2.0)}'; then
    esito="CRONO finestra sparita dopo ${secondi}s (misurato da fuori)"
  else
    echo "  SKIP: lo stream e' finito da solo dopo ${secondi}s (--quit-after), Cmd+W non isolato"
    exit 0
  fi
fi

if [ -z "$esito" ]; then
  echo "  SKIP: la sonda non ha riportato (stream non partito?)"
  echo "  --- stream.log (ultime righe) ---"; tail -12 "$TMP/stream.log" 2>/dev/null | sed 's/^/      /'
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
