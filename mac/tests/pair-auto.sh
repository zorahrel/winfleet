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

# Non si tocca il plist mentre un Moonlight e' vivo.
#
# Moonlight tiene in memoria la propria lista di host e la riscrive quando
# esce: una modifica fatta nel frattempo viene semplicemente cancellata, e
# insieme a lei tutto cio' che quel processo non conosceva. Il 26/08 il plist
# e' passato da CINQUE host a UNO, perdendo anche la chiave "hosts.size" - e
# senza quella pair_slot_auto esce subito, quindi nemmeno la riparazione
# automatica funzionava piu'. Sintomo per l'utente: una finestra su quattro si
# apre vuota, senza un errore da nessuna parte.
#
# Non e' una gara che si puo' vincere con un ordine piu' furbo delle
# operazioni: finche' quel processo e' vivo, l'ultima parola e' sua. Si aspetta
# che se ne vada, e se non se ne va si rinuncia al test - che costa un SKIP,
# contro un pairing da rifare a mano.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -f "Moonlight stream" >/dev/null 2>&1 || break
  sleep 1
done
if pgrep -f "Moonlight stream" >/dev/null 2>&1; then
  echo "  SKIP: c'e' uno stream Moonlight vivo, non tocco le sue preferenze"
  exit 0
fi

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

# Il certificato si salva e si rimette con PYTHON, non con defaults.
#
# Due strade sbagliate provate prima, entrambe con danno reale il 26/08:
#
# 1. Copiare il .plist e rimetterlo: cfprefsd lo tiene in cache e riscrive la
#    sua versione sopra. Il file e' rimasto con UN host su cinque e senza la
#    chiave "hosts.size", e da li' pair_slot_auto usciva subito ("n=0"):
#    nessuna riparazione automatica funzionava piu', nemmeno per il danno che
#    il test stesso aveva fatto.
#
# 2. "defaults read <chiave>" su un dato binario: la stampa e' TRONCATA con dei
#    puntini - «{length = 1037, bytes = 0x2d2d2d2d ... 4154452d 2d2d2}» - e
#    rimetterla indietro scrive 24 byte al posto di 1037. Il certificato
#    diventava "-----BEGIN CERTIATE-----", cioe' spazzatura che SEMBRA un
#    certificato: il plist resta valido, il pairing risulta fatto, e la
#    finestra si apre vuota. Verificato leggendo i byte, non l'uscita del
#    comando - che diceva "Type is data" e sembrava a posto.
#
# plistlib legge e scrive gli stessi byte, e cfprefsd si sincronizza da solo
# perche' si passa comunque da "defaults" per la scrittura finale.
# Si salva anche una FOTOGRAFIA di tutto il plist, per accorgersi dei danni
# collaterali: il certificato puo' tornare a posto mentre il resto e' sparito,
# ed e' esattamente quello che e' successo. Verificare solo cio' che si e'
# toccato lascia invisibile tutto il resto.
prima_host="$(/usr/bin/python3 -c "
import plistlib, os
p = os.path.expanduser('~/Library/Preferences/com.moonlight-stream.Moonlight.plist')
d = plistlib.load(open(p,'rb'))
print(len({k.split('.')[1] for k in d if k.startswith('hosts.') and k.split('.')[1].isdigit()}))" 2>/dev/null || echo 0)"

cert_orig="$(mktemp)"
/usr/bin/python3 - "$idx" "$cert_orig" <<'PYEOF' || { echo "  SKIP: non riesco a salvare il certificato, non rischio"; exit 0; }
import plistlib, sys, os
idx, out = sys.argv[1], sys.argv[2]
p = os.path.expanduser("~/Library/Preferences/com.moonlight-stream.Moonlight.plist")
d = plistlib.load(open(p, "rb"))
c = d.get("hosts.%s.srvcert" % idx)
if not c: sys.exit(1)
open(out, "wb").write(c)
PYEOF
[ -s "$cert_orig" ] || { echo "  SKIP: certificato vuoto, non rischio"; exit 0; }
atteso="$(wc -c <"$cert_orig" | tr -d ' ')"

ripristina(){
  /usr/bin/python3 - "$idx" "$cert_orig" <<'PYEOF' 2>/dev/null || true
import plistlib, sys, os
idx, src = sys.argv[1], sys.argv[2]
p = os.path.expanduser("~/Library/Preferences/com.moonlight-stream.Moonlight.plist")
d = plistlib.load(open(p, "rb"))
d["hosts.%s.srvcert" % idx] = open(src, "rb").read()
plistlib.dump(d, open(p, "wb"))
PYEOF
  killall cfprefsd 2>/dev/null || true
  rm -f "$cert_orig"
  rm -f "$HOME/.config/winfleet/slot$vittima.paired"

  # Si VERIFICA di aver rimesso a posto, contando i byte: un ripristino che
  # fallisce in silenzio lascia il sistema peggio di come l'ha trovato, ed e'
  # esattamente cio' che e' successo due volte oggi.
  local ora
  ora="$(/usr/bin/python3 -c "
import plistlib, os, sys
p = os.path.expanduser('~/Library/Preferences/com.moonlight-stream.Moonlight.plist')
try: d = plistlib.load(open(p,'rb'))
except Exception: print(0); sys.exit()
print(len(d.get('hosts.$idx.srvcert', b'')))" 2>/dev/null || echo 0)"
  if [ "$ora" != "$atteso" ]; then
    echo "  ATTENZIONE: certificato dello slot $vittima non ripristinato ($ora byte invece di $atteso)."
    echo "              Riparalo con:  winfleet pair-slots"
  fi

  # E il resto del plist? Un test che ripara cio' che ha rotto e intanto perde
  # quattro host su cinque ha comunque lasciato il sistema peggio di come l'ha
  # trovato - e senza questo controllo nessuno se ne accorgerebbe fino alla
  # prossima finestra vuota.
  local dopo_host
  dopo_host="$(/usr/bin/python3 -c "
import plistlib, os, sys
p = os.path.expanduser('~/Library/Preferences/com.moonlight-stream.Moonlight.plist')
try: d = plistlib.load(open(p,'rb'))
except Exception: print(0); sys.exit()
print(len({k.split('.')[1] for k in d if k.startswith('hosts.') and k.split('.')[1].isdigit()}))" 2>/dev/null || echo 0)"
  if [ "$dopo_host" != "$prima_host" ]; then
    echo "  ATTENZIONE: le preferenze di Moonlight sono cambiate sotto il test"
    echo "              ($prima_host host prima, $dopo_host dopo). Ripara con:  winfleet pair-slots"
  fi
}
trap ripristina EXIT

# --- 1. tolto il certificato, lo slot risulta NON accoppiato ----------------
# Se non risultasse, il test non starebbe misurando niente.
defaults delete "$DOM" "hosts.$idx.srvcert" 2>/dev/null || true
killall cfprefsd 2>/dev/null || true
# Il pairing viene RICORDATO per qualche minuto (costa 113ms a chiamata e
# pick_slot lo chiede per ogni slot). Togliere il certificato senza buttare
# quella memoria vuol dire misurare cio' che winfleet ricordava, non lo stato
# vero: il test diceva "il guasto non si riproduce" mentre il guasto c'era.
rm -f "$HOME/.config/winfleet/slot$vittima.paired"
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
rm -f "$HOME/.config/winfleet/slot$vittima.paired"
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
