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
ssh -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=8 "$SSHH" \
  'schtasks /end /tn winfleet-agent' >/dev/null 2>&1
sleep 2
if [ "$(curl -s --max-time 3 "http://$LAN:48088/ping" 2>/dev/null)" = ok ]; then
  echo "  SKIP: non riesco a spegnere l'agente, non posso provare che torni"
  exit 0
fi

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

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
