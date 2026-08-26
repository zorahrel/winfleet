#!/opt/homebrew/bin/bash
# I "push" che restano appesi devono essere chiusi, non accumularsi.
#
# "winfleet push" carica gli script cosi': base64 sul Mac, pipe in ssh, e di la'
# un powershell che legge stdin con [Console]::In.ReadToEnd(). Quando ssh muore
# male - e succede, perche' sshd si satura dopo una sessione fitta - quel
# processo resta ad aspettare un EOF che non arrivera' mai. Uccidere l'ssh dalla
# parte del Mac non lo tocca: il push aveva gia' un tetto di tempo, ma copriva
# solo META' del problema.
#
# Il 26/08 ne sono stati trovati VENTUNO, i piu' vecchi appesi da quattro ore.
# E il costo peggiore non e' la memoria: la loro riga di comando contiene il
# nome del file caricato, quindi sembrano processi di winfleet. Cercando "chi
# tocca wf-vdd.ps1" ne saltavano fuori tre, e per un quarto d'ora ho creduto
# che il pinger dei monitor virtuali si stesse moltiplicando - un guasto che
# non esisteva, inseguito perche' i nomi ingannavano.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fail=0
ok(){ printf '  \033[32mok\033[0m   %s\n' "$1"; }
ko(){ printf '  \033[31mNO\033[0m   %s\n' "$1"; fail=1; }

# --- le regole nel codice ---------------------------------------------------
if grep -q "AbsolutePath -eq '/push-clean'" host/wf-agent.ps1; then
  ok "l'agente ha la rotta per chiudere i push appesi"
else
  ko "nessuna rotta /push-clean: i push appesi restano li' per ore"
fi

# Il push deve CHIAMARLA quando abbandona un tentativo, altrimenti la rotta
# esiste e non la usa nessuno.
if awk '/kill -9 "\$sp"/,/^      fi$/' bin/winfleet | grep -q 'push-clean'; then
  ok "il push chiude anche il processo rimasto sull'host"
else
  ko "il push uccide solo il suo ssh: quello di la' resta appeso"
fi

# E deve passare dall'AGENTE, non da ssh: si arriva li' proprio quando ssh non
# risponde, e usarlo per rimediare a se stesso non funziona.
if awk '/kill -9 "\$sp"/,/^      fi$/' bin/winfleet | grep -q 'curl .*push-clean'; then
  ok "la pulizia passa da HTTP, non da ssh che e' quello rotto"
else
  ko "la pulizia usa ssh: e' il cane che si morde la coda"
fi

# La rotta non deve essere un esecutore generico: questo agente ascolta su tutta
# la rete locale, e un endpoint che esegue quello che gli si dice sarebbe una
# porta aperta sul PC.
if awk "/AbsolutePath -eq '\/push-clean'/,/^        }$/" host/wf-agent.ps1 | grep -qE 'QueryString|Invoke-Expression|iex'; then
  ko "la rotta accetta parametri da fuori: e' un esecutore remoto"
else
  ok "il bersaglio e' nel codice, non arriva dalla rete"
fi

# --- la prova dal vivo ------------------------------------------------------
CONFIG="$HOME/.config/winfleet/config.env"
[ -f "$CONFIG" ] || { echo "  SKIP: nessuna configurazione"; [ "$fail" = 0 ] && echo PASS || echo FAIL; exit "$fail"; }
LAN="$(awk -F'"' '/^HOST_LAN=/{print $2}' "$CONFIG")"
r="$(curl -s --max-time 8 "http://${LAN}:48088/push-clean" 2>/dev/null || true)"
if [ -z "$r" ]; then
  echo "  SKIP: agente non raggiungibile, provate solo le regole nel codice"
elif [ "$r" = no ]; then
  ko "la rotta risponde 'no': la pulizia fallisce sull'host"
elif [ "$r" -eq "$r" ] 2>/dev/null; then
  ok "la rotta risponde con un numero ($r processi chiusi): funziona"
else
  ko "risposta inattesa dalla rotta: [$r]"
fi

# Chiamandola due volte di fila la seconda deve trovare zero: se trovasse ancora
# qualcosa, non li starebbe chiudendo davvero.
if [ -n "$r" ] && [ "$r" != no ]; then
  sleep 1
  r2="$(curl -s --max-time 8 "http://${LAN}:48088/push-clean" 2>/dev/null || true)"
  if [ "${r2:-1}" = 0 ]; then
    ok "alla seconda chiamata non ne resta nessuno"
  else
    ko "la seconda chiamata ne trova ancora $r2: non li chiude davvero"
  fi
fi

[ "$fail" = 0 ] && echo PASS || echo FAIL
exit "$fail"
