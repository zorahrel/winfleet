#!/opt/homebrew/bin/bash
# L'agente sull'host, se smette di rispondere, torna da solo.
#
# E' successo TRE volte in un pomeriggio: il processo c'e', la porta e' in
# ascolto, e ogni richiesta scade. Da fuori sembra un PC spento, e da li' in poi
# ogni apertura e' lenta e ogni ridimensionamento non arriva - senza che niente
# lo dica.
#
# La causa probabile (connessioni lasciate in CLOSE_WAIT da una risposta che non
# veniva chiusa) e' stata corretta, ma NON e' dimostrata: quaranta richieste
# abbandonate a meta' non l'hanno riprodotta. Quindi oltre al fix c'e' una rete:
# se l'agente non risponde, winfleet riavvia il task che lo ospita.
#
# Qui si spegne l'agente VERO e si guarda se torna.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0
CONFIG="$HOME/.config/winfleet/config.env"
[ -f "$CONFIG" ] || { echo "  SKIP: nessuna configurazione"; exit 0; }
LAN="$(awk -F'"' '/^HOST_LAN=/{print $2}' "$CONFIG")"
SSHH="$(awk -F'"' '/^HOST_SSH=/{print $2}' "$CONFIG")"
[ -n "$LAN" ] && [ -n "$SSHH" ] || { echo "  SKIP: configurazione incompleta"; exit 0; }

if [ "$(curl -s --max-time 3 "http://$LAN:48088/ping" 2>/dev/null)" != ok ]; then
  echo "  SKIP: agente gia' non raggiungibile, non c'e' niente da provare"
  exit 0
fi

# --- 1. il codice c'e' ------------------------------------------------------
if grep -q 'agent_revive' bin/winfleet; then
  echo "  ok   codice: un agente muto viene riavviato invece che aggirato"
else
  echo "  NO   codice: nessun tentativo di rimettere in piedi l'agente"
  fail=1
fi

# --- 2. e la risposta si chiude SEMPRE, anche se scriverla fallisce ---------
# E' la causa probabile del blocco: senza il finally, una scrittura fallita
# salta la Close() e la connessione resta appesa per sempre.
if grep -q 'finally {' host/wf-agent.ps1 && grep -q '\$ctx.Response.Close()' host/wf-agent.ps1; then
  echo "  ok   host: la risposta si chiude anche quando scriverla fallisce"
else
  echo "  NO   host: una risposta fallita puo' lasciare la connessione appesa"
  fail=1
fi

# --- 3. la prova vera: spento e ritornato -----------------------------------
# Si spegne il PROCESSO, non solo il task.
#
# "schtasks /end" chiude il task e lascia vivo il powershell che ci gira
# dentro: l'agente continuava a rispondere, il test si arrendeva con uno SKIP,
# e per mesi ha finto di provare qualcosa. Lo stesso difetto lasciava sull'host
# un agente in piu' a ogni riavvio - trovati TRE processi vivi insieme il
# 26/08, avviati alle 00:00, alle 12:39 e alle 19:19.
#
# Si filtra sulla riga di comando: "powershell.exe" e basta ucciderebbe
# qualsiasi script di chiunque stia usando il PC.
ssh -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=8 "$SSHH" \
  'schtasks /end /tn winfleet-agent' >/dev/null 2>&1
ssh -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=10 "$SSHH" \
  "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\winfleet\\wf-agent-stop.ps1" \
  >/dev/null 2>&1
sleep 3
if [ "$(curl -s --max-time 3 "http://$LAN:48088/ping" 2>/dev/null)" = ok ]; then
  echo "  SKIP: non riesco a spegnere l'agente, non posso provare che torni"
  exit 0
fi
echo "  ok   agente spento davvero (processo, non solo task)"

# Un comando qualunque che parli con l'host: deve accorgersene e rimediare.
rm -f "$HOME/.config/winfleet/agent-revived" 2>/dev/null || true
/opt/homebrew/bin/bash -c 'source bin/winfleet >/dev/null 2>&1; refresh_vdd' >/dev/null 2>&1 || true

tornato=no
for i in $(seq 1 15); do
  [ "$(curl -s --max-time 2 "http://$LAN:48088/ping" 2>/dev/null)" = ok ] && { tornato=si; break; }
  sleep 1
done

if [ "$tornato" = si ]; then
  echo "  ok   dal vivo: spento l'agente, un comando qualunque lo rimette in piedi"
else
  echo "  NO   dal vivo: l'agente resta muto e nessuno lo rimette"
  fail=1
  # Si prova comunque a rimetterlo: il test non deve lasciare il sistema rotto.
  ssh -o BatchMode=yes -o ControlPath=none "$SSHH" 'schtasks /run /tn winfleet-agent' >/dev/null 2>&1 || true
fi

# --- 4. un agente ALLA VOLTA ------------------------------------------------
# "schtasks /end" chiude il task e lascia vivo il powershell: ogni riavvio
# lasciava dietro un agente in piu'. Trovati tre processi insieme il 26/08
# (avviati alle 00:00, alle 12:39 e alle 19:19). Solo uno tiene la porta; gli
# altri aspettano che si liberi, e quando succede rispondono al posto suo - da
# fuori l'agente sembra muto a tratti, senza una ragione visibile.
quanti="$(ssh -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=10 "$SSHH" \
  "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\winfleet\\wf-agent-stop.ps1 -WhatIfOnly" \
  2>/dev/null | tr -d '\r' | grep -c '^spegnerei:' || true)"
if [ "${quanti:-0}" -le 1 ]; then
  echo "  ok   un solo agente in esecuzione sull'host ($quanti)"
else
  echo "  NO   ci sono $quanti agenti insieme: si contendono la porta 48088"
  fail=1
fi

# E la regola dev'essere nell'agente, non solo qui: e' lui che deve fare
# pulizia all'avvio, perche' e' l'unico che c'e' sempre.
if grep -q 'spengo un agente precedente' host/wf-agent.ps1; then
  echo "  ok   l'agente spegne i predecessori quando parte"
else
  echo "  NO   l'agente non spegne i predecessori: si accumulano a ogni riavvio"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
