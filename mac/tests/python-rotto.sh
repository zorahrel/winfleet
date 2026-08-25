#!/opt/homebrew/bin/bash
# Un python che c'e' non e' un python che funziona.
#
# Il guasto vero, 26/08: dal Dock ogni apertura moriva con "Tutte le 4 finestre
# sono occupate" mentre "winfleet windows", lanciato nello stesso minuto, ne
# elencava quattro LIBERE. Da terminale lo stesso comando funzionava, il che
# rendeva il guasto quasi impossibile da inseguire.
#
# La differenza era l'AMBIENTE. Il Dock lancia con un PATH minimo, li' "python3"
# e' quello di Homebrew, e quel python aveva un pyexpat rotto: "Symbol not
# found: _XML_SetAllocTrackerActivationThreshold", compilato contro un libexpat
# piu' nuovo di quello di sistema. Non riusciva nemmeno a fare "import
# plistlib". slot_paired_ask legge proprio il plist di Moonlight per sapere se
# un'istanza e' accoppiata: falliva per tutti e quattro gli slot, pick_slot li
# scartava tutti, e il messaggio incolpava finestre occupate che non esistevano.
#
# La lezione, che in questo file torna per la terza volta: uno strumento che non
# risponde non e' una risposta negativa. Qui si verifica che winfleet scelga un
# interprete PROVANDOLO, invece di fidarsi del primo che trova nel PATH.
#
# Il test e' capace di fallire: con "python3" nudo il caso "il primo del PATH e'
# rotto" sceglie comunque quello rotto.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Un finto python3 rotto esattamente come quello vero: esiste, e' eseguibile,
# risponde a --version, e fallisce solo quando gli si chiede il modulo che
# serve. E' il caso che "command -v python3" non sa distinguere.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/python3" <<'ROTTO'
#!/bin/sh
case "$*" in
  *"import plistlib"*) echo "ImportError: pyexpat" >&2; exit 1;;
  *--version*) echo "Python 3.14.7";;
  *) echo "ImportError: pyexpat" >&2; exit 1;;
esac
ROTTO
chmod +x "$tmp/bin/python3"

# --- 1. con un python3 rotto in testa al PATH si sceglie un altro -----------
scelto="$(PATH="$tmp/bin:/usr/bin:/bin" /opt/homebrew/bin/bash -c '
  source bin/winfleet 2>/dev/null
  echo "P=$WF_PY"
' 2>/dev/null | sed -n 's/^P=//p')"
if [ "${scelto:-x}" = /usr/bin/python3 ]; then
  echo "  ok   python3 rotto in testa al PATH: sceglie $scelto"
else
  echo "  NO   ha scelto «${scelto:-(niente)}» invece di /usr/bin/python3"
  fail=1
fi

# --- 2. e quello scelto sa fare il lavoro ----------------------------------
# Non basta che sia "un altro": deve importare plistlib, che e' l'unica cosa
# per cui serve qui.
if PATH="$tmp/bin:/usr/bin:/bin" /opt/homebrew/bin/bash -c '
     source bin/winfleet 2>/dev/null
     "$WF_PY" -c "import plistlib, json"
   ' >/dev/null 2>&1; then
  echo "  ok   l'interprete scelto importa plistlib"
else
  echo "  NO   l'interprete scelto non riesce a importare plistlib"
  fail=1
fi

# --- 3. il controllo del pairing sopravvive al python rotto -----------------
# E' il pezzo che si era rotto davvero: con l'interprete sbagliato tornava "non
# accoppiata" per ogni slot, e l'apertura moriva incolpando le finestre.
# Il programma sta in un FILE e non dentro tre livelli di virgolette: il primo
# tentativo annidava bash-in-bash-in-python e non compilava piu'.
cat > "$tmp/leggi.py" <<'PYEOF'
import os, plistlib, sys
p = os.path.expanduser("~/Library/Preferences/com.moonlight-stream.Moonlight.plist")
try:
    d = plistlib.load(open(p, "rb"))
except FileNotFoundError:
    print("NOPLIST"); sys.exit(0)
except Exception:
    print("ROTTO"); sys.exit(0)
print("LETTO", int(d.get("hosts.size", 0) or 0))
PYEOF
esito="$(PATH="$tmp/bin:/usr/bin:/bin" /opt/homebrew/bin/bash -c '
  source bin/winfleet 2>/dev/null
  "$WF_PY" "'"$tmp"'/leggi.py" 2>&1
' 2>/dev/null | tail -1)"
case "$esito" in
  LETTO*|NOPLIST) echo "  ok   il controllo del pairing arriva a una risposta: $esito";;
  *)              echo "  NO   il controllo del pairing non funziona: ${esito:-(niente)}"; fail=1;;
esac

# --- 4. un PATH sano non paga il prezzo del ripiego -------------------------
# Il controllo deve scegliere un interprete che funziona, non punire chi ha
# tutto a posto: se anche il python del PATH e' sano si sceglie comunque uno che
# importa plistlib, e nessuno resta senza interprete.
sano="$(PATH="/usr/bin:/bin:/opt/homebrew/bin" /opt/homebrew/bin/bash -c '
  source bin/winfleet 2>/dev/null
  echo "P=$WF_PY"
' 2>/dev/null | sed -n 's/^P=//p')"
if [ -n "$sano" ] && "$sano" -c 'import plistlib' >/dev/null 2>&1; then
  echo "  ok   con un PATH sano l'interprete scelto funziona: $sano"
else
  echo "  NO   PATH sano ma interprete inutilizzabile: ${sano:-(niente)}"
  fail=1
fi

# --- 5. la scelta non costa un'apertura ------------------------------------
# Si paga a ogni avvio del comando, compreso ogni click dal Dock: provare gli
# interpreti uno per uno deve restare trascurabile.
#
# Si misura SOLO la scelta, non il "source" del comando intero: quello fa
# tutt'altro (misurato: 12 secondi, perche' senza argomenti winfleet esegue il
# doctor) e annegherebbe il dato che interessa.
#
# E si misura con "date +%s", non con TIMEFORMAT: su un sistema in italiano
# "time" stampa "0,123" con la virgola, e l'aritmetica di bash su quella
# stringa fallisce con "value too great for base". Il primo tentativo dava
# -408ms, cioe' un avvio finito prima di cominciare.
#
# Dieci giri, per non misurare il rumore di uno solo.
t0="$(date +%s)"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  PATH="$tmp/bin:/usr/bin:/bin" /opt/homebrew/bin/bash -c '
    for p in /usr/bin/python3 python3; do
      command -v "$p" >/dev/null 2>&1 || continue
      "$p" -c "import plistlib, json" >/dev/null 2>&1 && { command -v "$p"; break; }
    done' >/dev/null 2>&1
done
secondi=$(( $(date +%s) - t0 ))
if [ "$secondi" -ge 0 ] && [ "$secondi" -le 5 ]; then
  echo "  ok   la scelta dell'interprete e' trascurabile (10 giri in ${secondi}s)"
else
  echo "  NO   10 giri costano ${secondi}s: troppo per un click dal Dock"
  fail=1
fi

exit "$fail"
