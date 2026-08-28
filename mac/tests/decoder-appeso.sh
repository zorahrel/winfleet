#!/opt/homebrew/bin/bash
# Un decoder video appeso viene visto e detto, invece di bruciare CPU in silenzio.
#
# Il 28/08 su questo Mac c'era un VTDecoderXPCService al 71% di CPU da 25 ore:
# 1204 minuti di processore bruciati, contro i 5 secondi degli altri decoder sani
# sulla stessa macchina. Il suo processo padre era morto (adottato da launchd) e
# non aveva piu' nessun file di lavoro aperto: stava decodificando il nulla, con
# le ventole accese.
#
# Nessuno poteva accorgersene. Il nome del processo non dice "winfleet" da
# nessuna parte, e chi lo trova in cima ad Activity Monitor non ha modo di
# collegarlo a uno stream finito il giorno prima.
#
# Non e' un guasto DI winfleet: macOS di solito chiude quel decoder da solo -
# verificato aprendo e chiudendo una finestra, e anche uccidendo il client con
# kill -9. Ma quando non lo fa, winfleet e' l'unico che sa cosa cercare.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- 1. il doctor lo guarda -------------------------------------------------
if grep -q "decoder video appesi" bin/winfleet; then
  echo "  ok   il doctor cerca i decoder appesi"
else
  echo "  NO   nessuno guarda i decoder appesi"
  fail=1
fi
# Non deve ucciderli: un decoder puo' essere di Chrome o di un video in corso.
if grep -q "non li chiudo io" bin/winfleet; then
  echo "  ok   li segnala senza ucciderli (potrebbero essere di altre app)"
else
  echo "  NO   il doctor potrebbe uccidere decoder che non sono suoi"
  fail=1
fi

# --- 2. i formati di "ps -o time" -------------------------------------------
# Il punto delicato, e non e' teoria: il decoder trovato riportava "1204:03.93",
# cioe' MM:SS - una lettura che assumesse HH:MM:SS avrebbe detto "1204 ore".
# E il formato coi giorni letto come MM:SS SOTTOSTIMA, quindi il caso piu' grave
# sarebbe proprio quello che passa inosservato.
leggi(){ echo "1 $1 5.0 x" | awk '{ s=$2; g=0;
    if (index(s,"-")>0) { split(s,d,"-"); g=d[1]+0; s=d[2] }
    n=split(s,t,":");
    if(n==3) min=g*1440+t[1]*60+t[2];
    else if(n==2) min=g*1440+(g>0?t[1]*60:t[1]);
    else min=0;
    print min }'; }

prova(){ # formato attesi descrizione
  local got; got="$(leggi "$1")"
  if [ "$got" = "$2" ]; then
    echo "  ok   «$1» = $got minuti  ($3)"
  else
    echo "  NO   «$1» letto $got minuti invece di $2  ($3)"
    fail=1
  fi
}
prova "0:00.95"    "0"    "decoder sano"
prova "1204:03.93" "1204" "il caso reale trovato sul Mac"
prova "20:15.00"   "20"   "sotto la soglia, non si dice niente"
prova "3-01:02:03" "4382" "tre giorni: il caso piu' grave"
prova "150:30:00"  "9030" "oltre le 99 ore, ps passa a HH:MM:SS"

# --- 3. dal vivo, con un ps finto -------------------------------------------
# Si sostituisce "ps" nel PATH invece di aspettare che il guasto ricapiti: e'
# raro, e un test che non si puo' eseguire non protegge niente.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/ps" <<'FINTO'
#!/bin/sh
echo "45255 1204:03.93  71.2 /System/Library/Frameworks/VideoToolbox.framework/Versions/A/XPCServices/VTDecoderXPCService.xpc/Contents/MacOS/VTDecoderXPCService"
echo "12905   0:00.95   0.0 /System/Library/Frameworks/VideoToolbox.framework/Versions/A/XPCServices/VTDecoderXPCService.xpc/Contents/MacOS/VTDecoderXPCService"
FINTO
chmod +x "$tmp/bin/ps"

out="$(PATH="$tmp/bin:$PATH" ./bin/winfleet doctor 2>&1 || true)"
if printf '%s' "$out" | grep -q "1 decoder video appesi"; then
  echo "  ok   dal vivo: ne conta UNO (quello sano non lo tocca)"
else
  echo "  NO   dal vivo: non lo segnala, o conta anche i decoder sani"
  fail=1
fi
# Il numero e il pid devono esserci: "c'e' un problema" senza dire dove non
# serve a nessuno.
if printf '%s' "$out" | grep -q "pid 45255: 1204 minuti"; then
  echo "  ok   dice quale pid e quanto ha bruciato"
else
  echo "  NO   non dice il pid o i minuti: impossibile agire"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
