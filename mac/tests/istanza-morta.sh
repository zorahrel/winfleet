#!/opt/homebrew/bin/bash
# Un'istanza Sunshine morta non e' un PC spento.
#
# Il guasto (27/08, tredici ore): l'istanza sun0 e' morta di notte da sola
# ("Hang detected! Session failed to terminate in 10 seconds" nel suo log) e da
# quel momento winfleet ha risposto «il PC e' spento o la rete non c'e'» a ogni
# tentativo. Il PC era acceso, le altre TRE istanze rispondevano, l'agente pure
# - e nello stesso minuto "winfleet doctor" scriveva «agente sull'host:
# risponde». Due parti dello stesso programma, due risposte opposte.
#
# La causa: pick_slot decideva "host raggiungibile?" interrogando SOLO la porta
# dello slot 0. Il commento nel codice lo giustificava ("se quella non c'e', non
# c'e' nemmeno il PC - girano tutte sulla stessa macchina"), ed e' vero solo se
# le istanze non muoiono mai una alla volta. Muoiono.
#
# Costo reale: 395 righe identiche nel log del rifornitore, nessuna letta da
# nessuno, e ogni apertura fallita indicando la rete come colpevole.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0

# --- 1. la decisione non si appoggia a una sola istanza ---------------------
# Il controllo strutturale: se qualcuno rimette "reachable ... slot_port 0" come
# unico criterio, il guasto torna identico e senza sintomi nuovi.
if grep -q 'if ! host_up; then' bin/winfleet; then
  echo "  ok   host_up: il PC si dichiara spento solo se non risponde NESSUNO"
else
  echo "  NO   host_up assente: una sola istanza morta puo' spegnere tutto"
  fail=1
fi
if grep -qE 'reachable "\$\(agent_host\)" "\$\(slot_port 0\)"' bin/winfleet; then
  echo "  NO   c'e' ancora un controllo che guarda solo lo slot 0"
  fail=1
else
  echo "  ok   nessun controllo si affida al solo slot 0"
fi

# --- 2. host_up dice di si' con l'agente vivo e le istanze morte -------------
# La prova dal vivo, in isolamento: due porte locali, una che risponde
# (l'agente) e nessuna istanza. E' esattamente la forma del guasto.
srv="$(mktemp -d)"; trap 'rm -rf "$srv"; [ -n "${np:-}" ] && kill "$np" 2>/dev/null' EXIT
# Una porta alta e libera, presa lasciando che sia il sistema a sceglierla:
# fissarla a mano fa fallire il test sulla macchina di chi ha gia' qualcosa li'.
python3 - "$srv/porta" <<'PY' &
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
t = time.time()
while time.time() - t < 30:
    s.settimeout(1)
    try: s.accept()[0].close()
    except Exception: pass
PY
np=$!
for _ in $(seq 1 20); do [ -s "$srv/porta" ] && break; sleep 0.2; done
porta="$(cat "$srv/porta" 2>/dev/null || true)"

if [ -z "$porta" ]; then
  echo "  SKIP host_up dal vivo: non sono riuscito ad aprire una porta di prova"
else
  # Si estrae la funzione dal comando invece di lanciare tutto winfleet: qui
  # interessa la DECISIONE, e farla passare da un'apertura vera vorrebbe dire
  # dipendere dall'host, dalla rete e dai tempi di Moonlight.
  probe="$srv/probe.sh"
  {
    echo '#!/opt/homebrew/bin/bash'
    echo 'set -u'
    echo 'reachable(){ nc -z -G "${3:-2}" "$1" "$2" >/dev/null 2>&1; }'
    echo 'agent_host(){ echo 127.0.0.1; }'
    echo "AGENT_PORT=$porta"
    echo 'SLOTS=4'
    # host_up scrive la sua cache in CONFIG_DIR: senza, finirebbe nella
    # configurazione VERA dell'utente e questo test sporcherebbe il sistema.
    echo "CONFIG_DIR=$srv"
    # Le istanze su porte che non risponde nessuno: e' il caso "tutte morte",
    # cioe' il piu' severo. Se host_up regge qui, regge con una sola morta.
    echo 'slot_port(){ echo $(( 59990 + $1 )); }'
    sed -n '/^host_up(){/,/^}/p' bin/winfleet
    echo 'if host_up; then echo VIVO; else echo SPENTO; fi'
  } >"$probe"
  chmod +x "$probe"
  esito="$("$probe" 2>/dev/null || echo ERRORE)"
  if [ "$esito" = VIVO ]; then
    echo "  ok   agente vivo + istanze morte: il PC risulta acceso"
  else
    echo "  NO   agente vivo + istanze morte: winfleet dice ancora «${esito}»"
    fail=1
  fi
fi

# --- 2bis. e dice di NO quando il PC non c'e' davvero ----------------------
# Il controllo che mancava, e che e' costato un giro intero: abbassando il
# timeout di nc a 0.5 per guadagnare tempo, host_up ha smesso di funzionare -
# "nc -G" vuole un intero e tronca a zero, quindi nemmeno una porta viva
# risponde. Il sintomo sembrava un SUCCESSO: host-down.sh e' passato da 8 a 5
# secondi, perche' la funzione rispondeva "spento" senza guardare niente.
# Un test che misura solo il tempo applaude una funzione rotta: serve provare
# ENTRAMBE le risposte, e quella positiva su un host vero.
if [ -n "${porta:-}" ]; then
  probe2="$srv/probe2.sh"
  {
    echo '#!/opt/homebrew/bin/bash'
    echo 'set -u'
    echo 'reachable(){ nc -z -G "${3:-2}" "$1" "$2" >/dev/null 2>&1; }'
    echo 'agent_host(){ echo 127.0.0.1; }'
    # Nessuno risponde: ne' l'agente ne' le istanze.
    echo 'AGENT_PORT=59989'
    echo 'SLOTS=4'
    echo 'slot_port(){ echo $(( 59990 + $1 )); }'
    echo "CONFIG_DIR=$srv"
    sed -n '/^host_up(){/,/^}/p' bin/winfleet
    echo 'if host_up; then echo VIVO; else echo SPENTO; fi'
  } >"$probe2"
  chmod +x "$probe2"
  # La cache di host_up vale due secondi ed e' per indirizzo: il probe qui sopra
  # usa lo stesso 127.0.0.1 del precedente, quindi senza pulirla si leggerebbe
  # il "si" di prima e questo controllo passerebbe sempre.
  rm -f "$srv"/host-up-* 2>/dev/null || true
  esito2="$("$probe2" 2>/dev/null || echo ERRORE)"
  if [ "$esito2" = SPENTO ]; then
    echo "  ok   nessuno risponde: il PC risulta spento (la funzione guarda davvero)"
  else
    echo "  NO   nessuno risponde ma host_up dice «${esito2}»"
    fail=1
  fi
fi

# --- 3. un'istanza morta si RIAVVIA, non si conta e basta -------------------
# Senza questo lo slot resta perso fino al riavvio del PC: tredici ore, e la
# riparazione era un solo schtasks che nessuno sapeva di dover lanciare.
if grep -q '^slot_revive(){' bin/winfleet; then
  echo "  ok   slot_revive: un'istanza muta viene rimessa in piedi"
else
  echo "  NO   nessuno rimette in piedi un'istanza morta"
  fail=1
fi
if grep -q 'winfleet-sun\$slot' bin/winfleet; then
  echo "  ok   il riavvio usa il task che l'host ha gia'"
else
  echo "  NO   slot_revive non riavvia il task winfleet-sunN"
  fail=1
fi
# Il freno: se muore appena riavviata il problema e' un altro, e insistere ogni
# due minuti riempie il log senza curare niente (stessa forma di agent_revive).
if grep -q 'sun-revive' bin/winfleet; then
  echo "  ok   riavvio frenato: un tentativo al minuto per finestra"
else
  echo "  NO   riavvio senza freno: puo' ripartire a ogni giro del rifornitore"
  fail=1
fi

# --- 4. il doctor conta le finestre VIVE, non quelle in configurazione ------
# Diceva «4 finestre disponibili» con una morta da tredici ore: un numero preso
# dalla config, non una misura. Chi guardava il doctor per capire il guasto
# veniva rassicurato proprio sul pezzo rotto.
if grep -q 'finestre su \$SLOTS: l.istanza \$morte non risponde' bin/winfleet; then
  echo "  ok   doctor: nomina l'istanza che non risponde"
else
  echo "  NO   doctor: annuncia le finestre della config senza guardare se ci sono"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
