#!/opt/homebrew/bin/bash
# Un'app che su Windows non apre nessuna finestra lo dice subito.
#
# La finestra di Moonlight si apre SEMPRE, anche quando dall'altra parte non e'
# partito niente: da parte del Mac un'app lenta e un'app che non partira' mai
# sono indistinguibili. Si aspettavano quindi 45 secondi per la finestra, poi
# altri 20 per chiedere all'agente se esisteva - 56 secondi misurati - per una
# risposta che su Windows era gia' nota dopo 35.
#
# Trovato con la Calcolatrice: su quel PC e' rotta e non apre finestre comunque
# la si lanci (verificato anche a mano, dalla sessione interattiva). winfleet ci
# metteva 56 secondi per dire "non ha aperto una finestra entro 45 secondi" - un
# numero per giunta sbagliato, che manda a cercare nel posto sbagliato.
#
# Ora wf-place, quando smette di cercare, lascia un segnale che l'agente espone
# su /nowin, e le due attese lato Mac si interrompono appena lo vedono.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0

# --- 1. il segnale esiste da entrambe le parti ------------------------------
# Non basta che il Mac sappia chiedere: qualcuno deve scrivere la risposta.
if grep -q 'nowin\$Slot.txt' host/wf-place.ps1; then
  echo "  ok   host: chi cerca la finestra segnala quando si arrende"
else
  echo "  NO   host: la resa non viene segnalata a nessuno"
  fail=1
fi
if grep -q "AbsolutePath -eq '/nowin'" host/wf-agent.ps1; then
  echo "  ok   agente: il segnale e' leggibile dal Mac"
else
  echo "  NO   agente: nessun modo di chiedere se l'app ha aperto qualcosa"
  fail=1
fi

# --- 2. il segnale viene CANCELLATO quando la finestra c'e' -----------------
# Senza, resterebbe dall'apertura precedente e farebbe fallire quella dopo:
# un'app sana dichiarata rotta e' peggio del difetto di partenza.
if grep -q 'Remove-Item "C:\\winfleet\\nowin' host/wf-place.ps1; then
  echo "  ok   host: il segnale si cancella appena una finestra compare"
else
  echo "  NO   host: il segnale resta e farebbe fallire l'apertura successiva"
  fail=1
fi

# --- 3. ENTRAMBE le attese si interrompono ----------------------------------
# Le attese sono due in fila: quella sulla finestra del Mac e quella sulla
# finestra di Windows. Interromperne una sola dimezza il tempo invece di
# toglierlo - era 45+20, ed e' rimasto 20.
n="$(grep -c 'slot_gave_up' bin/winfleet)"
if [ "$n" -ge 3 ]; then
  echo "  ok   Mac: entrambe le attese si interrompono alla resa"
else
  echo "  NO   Mac: solo $((n-1)) attesa su 2 tiene conto della resa"
  fail=1
fi

# --- 4. il messaggio dice quale dei due casi e' -----------------------------
# "non ha aperto una finestra entro 45 secondi" dopo 13 secondi manda a cercare
# nel posto sbagliato: sono due situazioni diverse e portano a cose diverse.
if grep -q 'l.app potrebbe essere rotta sull.host' bin/winfleet; then
  echo "  ok   messaggio: distingue l'app rotta dall'app lenta"
else
  echo "  NO   messaggio: dice sempre la stessa cosa"
  fail=1
fi

# --- 5. il segnale scade ----------------------------------------------------
# Un file vecchio e' di un'apertura precedente: fidarsene vorrebbe dire
# dichiarare rotta un'app che sta partendo adesso.
if grep -q 'TotalSeconds' host/wf-agent.ps1 && \
   grep -A 4 "AbsolutePath -eq '/nowin'" host/wf-agent.ps1 >/dev/null 2>&1; then
  echo "  ok   scadenza: un segnale vecchio non vale"
else
  echo "  NO   scadenza: un segnale vecchio farebbe fallire un'apertura buona"
  fail=1
fi

# --- 6. la prova vera: il giro completo, contro l'host ----------------------
# I controlli qui sopra guardano il CODICE. Servono, ma da soli resterebbero
# verdi anche se il segnale non arrivasse mai a destinazione: il file scritto
# dalla parte sbagliata, l'agente vecchio ancora in memoria, il nome dello slot
# sbagliato. Qui si scrive il segnale sull'host e si controlla che il Mac lo
# veda.
CONFIG="$HOME/.config/winfleet/config.env"
if [ ! -f "$CONFIG" ]; then
  echo "  SKIP: nessuna configurazione, salto la prova contro l'host"
  [ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
  exit "$fail"
fi
LAN="$(awk -F'"' '/^HOST_LAN=/{print $2}' "$CONFIG")"
SSHH="$(awk -F'"' '/^HOST_SSH=/{print $2}' "$CONFIG")"
if [ -z "$LAN" ] || ! curl -s --max-time 3 "http://$LAN:48088/ping" 2>/dev/null | grep -q ok; then
  echo "  SKIP: agente non raggiungibile, salto la prova contro l'host"
  [ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
  exit "$fail"
fi

# Uno slot che non e' in uso, cosi' non si disturba una finestra vera.
prova=3
ssh -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=8 "$SSHH" \
  "powershell -NoProfile -Command \"Remove-Item C:\\winfleet\\nowin${prova}.txt -EA SilentlyContinue\"" >/dev/null 2>&1

if [ "$(curl -s --max-time 4 "http://$LAN:48088/nowin?slot=$prova" 2>/dev/null | tr -d '\r\n')" = no ]; then
  echo "  ok   giro completo: senza segnale l'host risponde «no»"
else
  echo "  NO   giro completo: risponde «si» anche senza segnale"
  fail=1
fi

ssh -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=8 "$SSHH" \
  "powershell -NoProfile -Command \"Set-Content C:\\winfleet\\nowin${prova}.txt (Get-Date -Format o)\"" >/dev/null 2>&1

if [ "$(curl -s --max-time 4 "http://$LAN:48088/nowin?slot=$prova" 2>/dev/null | tr -d '\r\n')" = si ]; then
  echo "  ok   giro completo: il segnale scritto sull'host arriva al Mac"
else
  echo "  NO   giro completo: il segnale non arriva (agente vecchio? push non fatto?)"
  fail=1
fi

ssh -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=8 "$SSHH" \
  "powershell -NoProfile -Command \"Remove-Item C:\\winfleet\\nowin${prova}.txt -EA SilentlyContinue\"" >/dev/null 2>&1

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
