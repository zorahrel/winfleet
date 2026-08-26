#!/opt/homebrew/bin/bash
# Il percorso VERO: si fa doppio clic sull'icona e compare una finestra che
# mostra qualcosa.
#
# Tutti gli altri test guardano i file di stato di winfleet: dicono che lo slot
# risulta occupato e di che misura, cioe' cosa winfleet CREDE. Non dicono che
# l'utente veda un'immagine. Ed e' la differenza che gia' mi e' costata cara -
# "ma non vedi anche tu che non esce Arc?" - quando dichiaravo successi
# leggendo i log invece di guardare il risultato.
#
# Qui si prova la catena intera, dai due capi:
#
#   1. si lancia il .app del Dock, non "winfleet open": e' quello che fa
#      l'utente, e passa da LaunchServices con un ambiente diverso (il PATH
#      minimo dal Dock ha gia' rotto tutto una volta, con un python fallato).
#   2. dal lato MAC si controlla che Moonlight abbia RICEVUTO pacchetti video e
#      DECODIFICATO frame: sono righe del suo log, scritte dal decoder, non da
#      noi.
#   3. dal lato HOST si controlla che Sunshine abbia agganciato lo schermo alla
#      misura giusta e creato l'encoder: se catturasse lo schermo sbagliato o
#      non codificasse, la finestra sarebbe nera con tutti i file di stato in
#      ordine.
#
# Cosa NON prova, e va detto: nessuno qui guarda i pixel. Servirebbe il
# permesso Screen Recording, che questa shell non ha. "Frame decodificati" e
# "encoder creato" sono le due prove piu' vicine all'immagine che si possano
# raccogliere senza vederla.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fail=0
ok(){ printf '  \033[32mok\033[0m   %s\n' "$1"; }
ko(){ printf '  \033[31mNO\033[0m   %s\n' "$1"; fail=1; }

CONFIG="$HOME/.config/winfleet/config.env"
[ -f "$CONFIG" ] || { echo "  SKIP: nessuna configurazione"; exit 0; }
LAN="$(awk -F'"' '/^HOST_LAN=/{print $2}' "$CONFIG")"
# L'indirizzo ssh si legge dalla CONFIG, non si ricostruisce da HOST_LAN: la
# chiave dell'host e' nota per l'indirizzo Tailscale, e "zorah@192.168.1.9"
# fallisce con «Host key verification failed» - due controlli su quattro
# rossi per una ragione che non c'entrava niente con winfleet.
SSHH="$(awk -F'"' '/^HOST_SSH=/{print $2}' "$CONFIG")"
curl -s --max-time 3 "http://${LAN}:48089/serverinfo?uniqueid=winfleet" >/dev/null 2>&1 || {
  echo "  SKIP: host non raggiungibile"; exit 0; }

# Non si sequestra il PC: se ci sono finestre aperte potrebbero essere di chi
# lo sta usando adesso.
aperte="$(./bin/winfleet windows 2>/dev/null | grep -cE '✓' || true)"
if [ "${aperte:-0}" -gt 0 ]; then
  echo "  SKIP: $aperte finestre gia' aperte, non le chiudo per un test"
  exit 0
fi

APP="$HOME/Applications/WinFleet/Blocco note.app"
[ -d "$APP" ] || APP="$(ls -d "$HOME"/Applications/WinFleet/*.app 2>/dev/null | grep -v 'WinFleet' | head -1)"
[ -d "$APP" ] || { echo "  SKIP: nessun lanciatore (winfleet dock)"; exit 0; }

prima="$(ls -t /tmp/Moonlight-*.log 2>/dev/null | head -1)"

# --- 1. si lancia l'icona, come farebbe l'utente ----------------------------
open -a "$APP" 2>/dev/null || { ko "il lanciatore non parte"; echo FAIL; exit 1; }

vivo=0
for _ in $(seq 1 45); do
  sleep 1
  if pgrep -f "Moonlight stream" >/dev/null 2>&1; then vivo=1; break; fi
done
if [ "$vivo" = 1 ]; then
  ok "il lanciatore del Dock avvia uno stream"
else
  ko "dal lanciatore non parte niente (dal Dock il PATH e' minimo: python rotto?)"
  echo FAIL; exit 1
fi

sleep 8

# --- 2. lato MAC: sono arrivati pacchetti video, e sono stati decodificati ---
log="$(ls -t /tmp/Moonlight-*.log 2>/dev/null | head -1)"
if [ -z "$log" ] || [ "$log" = "$prima" ]; then
  ko "nessun log nuovo di Moonlight: lo stream non e' nemmeno partito"
else
  if grep -q 'Received first video packet' "$log"; then
    ok "il Mac ha ricevuto video: $(grep -o 'Received first video packet after .*' "$log" | tail -1)"
  else
    ko "nessun pacchetto video ricevuto: la finestra sarebbe NERA"
  fi
  nf="$(grep -c 'Decoded frame' "$log" 2>/dev/null || echo 0)"
  if [ "${nf:-0}" -gt 0 ]; then
    ok "il Mac ha decodificato $nf frame (c'e' un'immagine, non solo una cornice)"
  else
    ko "zero frame decodificati: nessuna immagine"
  fi
  if grep -qiE 'Control stream connection failed|has not been paired' "$log"; then
    ko "errore nello stream: $(grep -iE 'Control stream connection failed|has not been paired' "$log" | tail -1)"
  fi
fi

# --- 3. lato HOST: Sunshine cattura lo schermo giusto e codifica -------------
# Senza questo, un guasto sull'host (schermo 0x0, encoder mancante) darebbe
# comunque una finestra "aperta" secondo i nostri file.
res="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSHH" \
  "powershell -NoProfile -Command \"(Select-String -Path 'C:\\winfleet\\sun0\\sunshine.log' -Pattern 'Desktop resolution' | Select-Object -Last 1).Line\"" \
  2>/dev/null | tr -d '\r' | grep -o '\[[0-9]*x[0-9]*\]' | tr -d '[]' || true)"
# E dev'essere lo schermo CHIESTO, non uno qualsiasi.
#
# Con i monitor virtuali caduti, Sunshine ripiega sul desktop fisico e continua
# a mandare video: il test vedeva «schermo 3440x1440», frame decodificati,
# tutto verde - e l'utente si sarebbe trovato il desktop del PC dentro la
# finestra invece della sua app. Scoperto rompendo apposta i monitor: il
# controllo passava lo stesso, quindi non stava controllando niente.
#
# La misura chiesta e' quella che winfleet ha scelto per lo slot (vdd.json).
atteso="$(curl -s --max-time 4 "http://${LAN}:48088/vdd" 2>/dev/null \
  | /usr/bin/python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
s=[x for x in d if x.get('slot')==0]
print(f\"{s[0]['width']}x{s[0]['height']}\" if s else '')" 2>/dev/null || true)"

case "${res:-}" in
  ""|0x0|0x*|*x0)
    ko "Sunshine non ha uno schermo utile (${res:-nessuna risposta}): la finestra sarebbe nera"
    ;;
  *)
    if [ -n "$atteso" ] && [ "$res" != "$atteso" ]; then
      ko "l'host cattura $res ma lo schermo dello slot 0 e' $atteso: e' il desktop sbagliato"
      echo "       (con i monitor virtuali caduti Sunshine ripiega sul desktop fisico:"
      echo "        video ne arriva, ma e' il PC di qualcun altro dentro la tua finestra)"
    else
      ok "l'host cattura lo schermo giusto ($res)"
    fi
    ;;
esac

enc="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSHH" \
  "powershell -NoProfile -Command \"(Select-String -Path 'C:\\winfleet\\sun0\\sunshine.log' -Pattern 'Creating encoder' | Select-Object -Last 1).Line\"" \
  2>/dev/null | tr -d '\r' | grep -o '\[[a-z0-9_]*\]' | tr -d '[]' || true)"
if [ -n "$enc" ]; then
  ok "l'host codifica con $enc"
else
  ko "nessun encoder creato sull'host: niente video da mandare"
fi

# --- 4. e la finestra sul Mac ha una misura vera ----------------------------
# La scrive la libreria iniettata da dentro il processo (NSWindow.frame), non
# un file di configurazione: se e' li' la finestra esiste davvero.
sz="$(cat "$HOME/.config/winfleet/slot0.size" 2>/dev/null || true)"
case "${sz:-}" in
  ""|0x0) ko "la finestra sul Mac non ha una misura: non e' mai comparsa";;
  *)      ok "la finestra sul Mac misura $sz";;
esac

./bin/winfleet stop >/dev/null 2>&1 || true

[ "$fail" = 0 ] && echo PASS || echo FAIL
exit "$fail"
