#!/opt/homebrew/bin/bash
# Un pairing rimasto a meta' si ripara da solo, senza chiedere un PIN.
#
# Il guasto: l'host aveva gia' il certificato del Mac - il pairing da parte sua
# era fatto - ma il Mac aveva perso il suo. Da fuori e' identico a "mai
# accoppiata": la finestra si apre VUOTA. Due finestre su quattro sono rimaste
# cosi' per giorni, e il sintomo si vedeva altrove: le finestre che un'app apre
# per conto suo restavano su Windows con la traccia "nessuno slot libero",
# mentre di slot liberi ce n'erano due (uno slot non accoppiato non conta come
# disponibile).
#
# Qui si smonta il pairing di uno slot davvero accoppiato, si chiede a winfleet
# di ripararlo, e si controlla che ci riesca. Alla fine lo stato torna com'era
# in ogni caso.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

DOM=com.moonlight-stream.Moonlight
fail=0

# Serve un host raggiungibile: senza, non c'e' niente da provare.
CONFIG="$HOME/.config/winfleet/config.env"
[ -f "$CONFIG" ] || { echo "  SKIP: nessuna configurazione"; exit 0; }
LAN="$(awk -F'"' '/^HOST_LAN=/{print $2}' "$CONFIG")"
if ! curl -s --max-time 3 "http://${LAN}:48089/serverinfo?uniqueid=winfleet" >/dev/null 2>&1; then
  echo "  SKIP: host non raggiungibile"
  exit 0
fi

# Uno slot accoppiato su cui provare.
vittima=""
for i in 0 1 2 3; do
  if /opt/homebrew/bin/bash -c "source bin/winfleet >/dev/null 2>&1; slot_paired $i" 2>/dev/null; then
    vittima="$i"; break
  fi
done
[ -n "$vittima" ] || { echo "  SKIP: nessuno slot accoppiato da cui partire"; exit 0; }

# L'indice nel plist e il certificato attuale: vanno rimessi comunque vada.
uid="$(curl -s --max-time 4 "http://${LAN}:$(( 48089 + vittima * 100 ))/serverinfo?uniqueid=winfleet" 2>/dev/null \
      | tr '<' '\n' | awk -F'>' '/^uniqueid/{print $2}')"
[ -n "$uid" ] || { echo "  SKIP: istanza $((vittima+1)) non risponde"; exit 0; }

idx=""
n="$(defaults read "$DOM" hosts.size 2>/dev/null || echo 0)"
for i in $(seq 1 "$n"); do
  u="$(defaults read "$DOM" "hosts.$i.uuid" 2>/dev/null)"
  if [ "$(printf '%s' "$u" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$uid" | tr 'A-Z' 'a-z')" ]; then
    idx="$i"; break
  fi
done
[ -n "$idx" ] || { echo "  SKIP: istanza non trovata nelle preferenze"; exit 0; }

backup="$(mktemp)"
cp "$HOME/Library/Preferences/$DOM.plist" "$backup" 2>/dev/null || true
ripristina(){
  if [ -s "$backup" ]; then
    cp "$backup" "$HOME/Library/Preferences/$DOM.plist" 2>/dev/null || true
    killall cfprefsd 2>/dev/null || true
  fi
  rm -f "$backup"
}
trap ripristina EXIT

# --- 1. tolto il certificato, lo slot risulta NON accoppiato ----------------
# Se non risultasse, il test non starebbe misurando niente.
defaults delete "$DOM" "hosts.$idx.srvcert" 2>/dev/null || true
killall cfprefsd 2>/dev/null || true
sleep 1
if /opt/homebrew/bin/bash -c "source bin/winfleet >/dev/null 2>&1; slot_paired $vittima" 2>/dev/null; then
  echo "  NO   il guasto non si riproduce: senza certificato risulta comunque accoppiata"
  echo "FAIL"
  exit 1
fi
echo "  ok   guasto riprodotto: senza certificato la finestra risulta spaiata"

# --- 2. winfleet lo ripara da solo ------------------------------------------
if /opt/homebrew/bin/bash -c "source bin/winfleet >/dev/null 2>&1; pair_slot_auto $vittima" >/dev/null 2>&1; then
  echo "  ok   riparato senza chiedere un PIN"
else
  echo "  NO   non riparato: servirebbe ancora il PIN a mano"
  fail=1
fi

# --- 3. e lo stato e' davvero tornato buono ---------------------------------
# Non basta che la funzione dica di si': deve dirlo il criterio che usa il resto
# del programma per decidere se aprire una finestra.
sleep 1
if /opt/homebrew/bin/bash -c "source bin/winfleet >/dev/null 2>&1; slot_paired $vittima" 2>/dev/null; then
  echo "  ok   la finestra risulta accoppiata al criterio normale"
else
  echo "  NO   la finestra risulta ancora spaiata"
  fail=1
fi

# --- 4. il certificato e' scritto come DATO, non come stringa ---------------
# Scritto con -string finisce nel plist come blocco vuoto: il pairing sembra
# fatto e non funziona. E' l'errore che ho commesso scrivendolo la prima volta.
tipo="$(defaults read-type "$DOM" "hosts.$idx.srvcert" 2>/dev/null)"
if [ "$tipo" = "Type is data" ]; then
  echo "  ok   scritto come dato binario, come gli host accoppiati davvero"
else
  echo "  NO   scritto come «${tipo:-niente}»: Moonlight non lo usera'"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
