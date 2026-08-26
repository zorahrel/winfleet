#!/opt/homebrew/bin/bash
# I monitor virtuali si contano CHIEDENDO A WINDOWS, non leggendo un file.
#
# Il doctor contava le voci di vdd.json, che e' la MEMORIA di cosa il pinger
# aveva agganciato: un file sul disco, che resta li' anche quando i monitor non
# ci sono piu'. Provato il 26/08 uccidendo il pinger e disattivando il
# guardiano: gli schermi veri erano scesi a uno e il doctor continuava a dire
# «4 monitor virtuali, nessuno di troppo». La riga piu' rassicurante nel momento
# peggiore - le finestre si aprono NERE, e la diagnosi dice che va tutto bene.
#
# La correzione ha avuto due errori suoi, ed entrambi valgono piu' del fix:
#
#  1. [Windows.Forms.Screen]::AllScreens e' una CACHE. .NET la riempie al primo
#     accesso e non la aggiorna piu' per la vita del processo; l'agente vive per
#     giorni, quindi rispondeva con la fotografia di com'era il PC all'avvio.
#     Risultato: il controllo nuovo gridava «i monitor sono STACCATI, le
#     finestre si aprono nere» mentre le finestre si aprivano benissimo. Un
#     allarme falso che descrive un guasto grave e' peggio di nessun allarme:
#     manda a cercare dove non c'e' niente. Un'ora persa. La prova che fosse una
#     cache: riavviando l'agente, senza toccare altro, la stessa chiamata e'
#     passata da 1 a 5.
#
#  2. Il confronto era "diverso da SLOTS". Ma Windows vede i virtuali PIU' i
#     fisici, e quanti siano i fisici non lo sappiamo: "5 schermi con 4 slot" e'
#     normale. Un controllo di uguaglianza avrebbe gridato al guasto su
#     qualsiasi PC con due monitor veri.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fail=0
ok(){ printf '  \033[32mok\033[0m   %s\n' "$1"; }
ko(){ printf '  \033[31mNO\033[0m   %s\n' "$1"; fail=1; }

# --- le regole nel codice ---------------------------------------------------
if grep -q "AbsolutePath -eq '/schermi'" host/wf-agent.ps1; then
  ok "l'agente sa dire quanti schermi vede Windows adesso"
else
  ko "nessuna rotta /schermi: il doctor puo' solo fidarsi di vdd.json"
fi

# La cache non deve tornare: e' invisibile finche' non serve, e serve solo
# quando qualcosa e' gia' andato storto.
if awk "/AbsolutePath -eq '\/schermi'/,/^        }$/" host/wf-agent.ps1 | grep -vE '^\s*#' | grep -q 'AllScreens'; then
  ko "e' tornato AllScreens: e' una cache, risponde con lo stato dell'avvio"
else
  ok "niente AllScreens: si chiede a Windows a ogni richiesta"
fi

if awk "/AbsolutePath -eq '\/schermi'/,/^        }$/" host/wf-agent.ps1 | grep -q 'EnumDisplayMonitors'; then
  ok "usa EnumDisplayMonitors, che non ha cache"
else
  ko "non usa EnumDisplayMonitors: la misura potrebbe essere vecchia"
fi

# Il doctor deve CONFRONTARE i due numeri: uno solo non basta. vdd.json senza
# schermi non si accorge che sono spariti, gli schermi senza vdd.json non sanno
# quanti dovrebbero essercene.
if awk '/Quanti monitor virtuali ci sono davvero/,/^  # Il cursore/' bin/winfleet | grep -q '/schermi'; then
  ok "il doctor confronta l'elenco con gli schermi veri"
else
  ko "il doctor si fida solo di vdd.json: non vede i monitor staccati"
fi

# --- il confronto giusto ----------------------------------------------------
# Simula la regola: guasto solo se gli schermi sono MENO degli slot.
verdetto(){ # schermi slot -> ok|guasto
  if [ "$1" -lt "$2" ]; then echo guasto; else echo ok; fi
}
for caso in "5:4:ok" "4:4:ok" "7:4:ok" "2:4:guasto" "1:4:guasto" "0:4:guasto"; do
  scr="${caso%%:*}"; r="${caso#*:}"; slot="${r%%:*}"; att="${r##*:}"
  got="$(verdetto "$scr" "$slot")"
  if [ "$got" = "$att" ]; then
    ok "$scr schermi con $slot slot -> $got"
  else
    ko "$scr schermi con $slot slot: atteso $att, ottenuto $got"
  fi
done

# E nel codice il confronto dev'essere "minore", non "diverso".
if awk '/Quanti monitor virtuali ci sono davvero/,/^  # Il cursore/' bin/winfleet | grep -q '"\$n_scr" -lt "\$SLOTS"'; then
  ok "il confronto e' 'meno di SLOTS': gli schermi fisici non danno falsi allarmi"
else
  ko "il confronto non e' '-lt': un PC con due monitor veri urlerebbe al guasto"
fi

# --- anche il GUARDIANO deve vedere davvero --------------------------------
# La stessa cache che ha ingannato il doctor rendeva cieco il guardiano dei
# monitor: il 26/08 sono rimasti staccati per otto minuti - winfleet non apriva
# piu' niente, l'apertura si fermava a "risoluzione chiesta" - e nel suo log non
# c'era una sola riga "rifaccio il VDD". Guardava, e vedeva sempre la stessa
# fotografia.
if grep -vE '^\s*#' host/wf-vdd-guard.ps1 | grep -q 'AllScreens'; then
  ko "il guardiano usa AllScreens: e' una cache, non vedra' mai i monitor cadere"
else
  ok "il guardiano non usa la cache"
fi

if grep -q 'EnumDisplayMonitors' host/wf-vdd-guard.ps1; then
  ok "il guardiano chiede a Windows quanti schermi ci sono adesso"
else
  ko "il guardiano non interroga Windows: non puo' accorgersi di niente"
fi

# E zero schermi non deve far scattare la riparazione: vuol dire che stiamo
# guardando da una sessione senza desktop (via ssh e' la sessione 0), non che i
# monitor siano caduti. Rifare il VDD li' spegnerebbe monitor funzionanti.
if grep -q 'totale -le 0' host/wf-vdd-guard.ps1; then
  ok "zero schermi = sessione senza desktop, non un guasto"
else
  ko "zero schermi fa scattare la riparazione: spegnerebbe monitor sani"
fi

# Il log del pinger non deve cancellare la storia degli interventi.
#
# "Set-Content $LOG ''" azzerava tutto a ogni avvio, e chi riavvia il pinger e'
# proprio il guardiano: la sua riga «solo N monitor virtuali su 4: rifaccio il
# VDD», scritta un istante prima, spariva insieme al resto. Il 26/08 questo mi
# ha fatto concludere che il guardiano non fosse MAI intervenuto, mentre stava
# funzionando - i monitor tornavano su e nel log non c'era traccia del perche'.
# Una diagnosi sbagliata costruita da noi, cancellando la nostra unica prova.
if grep -qE "^Set-Content \\\$LOG ''" host/wf-vdd.ps1; then
  ko "il pinger azzera il log all'avvio: cancella gli interventi del guardiano"
else
  ok "il log del pinger si tronca, non si azzera"
fi

# --- la prova dal vivo ------------------------------------------------------
CONFIG="$HOME/.config/winfleet/config.env"
[ -f "$CONFIG" ] || { echo "  SKIP: nessuna configurazione"; [ "$fail" = 0 ] && echo PASS || echo FAIL; exit "$fail"; }
LAN="$(awk -F'"' '/^HOST_LAN=/{print $2}' "$CONFIG")"
SLOTS="$(awk -F'"' '/^SLOTS=/{print $2}' "$CONFIG" 2>/dev/null)"
[ -n "$SLOTS" ] || SLOTS="$(awk -F'=' '/^SLOTS=/{gsub(/[^0-9]/,"",$2); print $2}' "$CONFIG" 2>/dev/null)"
[ -n "$SLOTS" ] || SLOTS=4

n="$(curl -s --max-time 6 "http://${LAN}:48088/schermi" 2>/dev/null | tr -d '\r')"
if [ -z "$n" ] || [ "$n" = no ]; then
  echo "  SKIP: agente non raggiungibile o senza la rotta"
elif ! [ "$n" -eq "$n" ] 2>/dev/null; then
  ko "la rotta non risponde con un numero: [$n]"
elif [ "$n" -ge "$SLOTS" ]; then
  ok "dal vivo: Windows vede $n schermi con $SLOTS slot (i monitor ci sono)"
else
  ko "dal vivo: solo $n schermi per $SLOTS slot — i monitor sono staccati"
  echo "       rimedio:  schtasks /run /tn winfleet-vdd"
fi

[ "$fail" = 0 ] && echo PASS || echo FAIL
exit "$fail"
