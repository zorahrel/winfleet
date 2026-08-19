#!/opt/homebrew/bin/bash
# Il rifornitore delle finestre pronte torna da solo.
#
# Trovato scaricato: "service inactive" nei log di sistema, sparito da
# launchctl list, senza nessun riavvio del Mac. Nessun danno visibile oggi,
# perche' la scorta e' spenta di proposito (WF_WARM=0) e quindi l'agente non
# aveva niente da fare comunque - ma il meccanismo esiste per essere riacceso, e
# riacceso senza agente vuol dire scorta sempre a zero: quindici secondi ad
# apertura invece di due, col sintomo indistinguibile da "oggi e' lento".
#
# Due dettagli lo rendevano definitivo:
#   - il plist era stato copiato a mano una volta: nessun comando lo installava,
#     quindi una volta perso restava perso, e su una macchina nuova non c'e';
#   - il codice che risveglia il rifornitore dopo ogni apertura faceva
#     "kickstart ... || true", cioe' ingoiava esattamente questo errore.
#
# Qui si verifica che, tolto l'agente, winfleet lo rimetta da solo.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0
LABEL="gui/$(id -u)/com.winfleet.ready"
PLIST="$HOME/Library/LaunchAgents/com.winfleet.ready.plist"

# Lo stato di partenza va restituito com'era: questo test tocca un agente vero
# dell'utente, non una copia.
era_caricato=0
launchctl print "$LABEL" >/dev/null 2>&1 && era_caricato=1
backup=""
if [ -f "$PLIST" ]; then
  backup="$(mktemp)"
  cp "$PLIST" "$backup"
fi

ripristina(){
  if [ -n "$backup" ]; then
    cp "$backup" "$PLIST" 2>/dev/null || true
    rm -f "$backup"
  fi
  if [ "$era_caricato" = 1 ]; then
    launchctl print "$LABEL" >/dev/null 2>&1 || \
      launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  fi
}
trap ripristina EXIT

# --- 1. la funzione carica un agente assente -------------------------------
launchctl bootout "$LABEL" >/dev/null 2>&1 || true
sleep 0.5
if launchctl print "$LABEL" >/dev/null 2>&1; then
  echo "  SKIP: non riesco a scaricare l'agente, non posso provare che torni"
  exit 0
fi

# La funzione va provata DA SOLA. "source bin/winfleet" non isola niente: il
# file finisce con un case che, senza argomenti, lancia il doctor - e il doctor
# a sua volta ricarica l'agente. Il test sembrava fallire e in realta' stava
# misurando l'effetto di un altro pezzo di codice.
estrai_e_chiama(){
  local f
  f="$(mktemp)"
  {
    echo '#!/opt/homebrew/bin/bash'
    echo 'set -u'
    # trace() e le variabili che la funzione usa: prese dal file vero, cosi' il
    # test non ne tiene una copia che invecchia per conto suo.
    echo 'trace(){ :; }'
    printf 'WF_ROOT=%q\n' "$PWD"
    sed -n '/^ensure_ready_agent(){/,/^}/p' bin/winfleet
    echo 'ensure_ready_agent'
  } > "$f"
  /opt/homebrew/bin/bash "$f" >/dev/null 2>&1
  local esito=$?
  rm -f "$f"
  return $esito
}

if estrai_e_chiama && launchctl print "$LABEL" >/dev/null 2>&1; then
  echo "  ok   rifornitore: se manca, torna da solo"
else
  echo "  NO   rifornitore: scaricato e non rimesso"
  fail=1
fi

# --- 2. il plist installato punta a QUESTA macchina ------------------------
# Nel repo i percorsi sono scritti per esteso: copiato tale e quale su un altro
# Mac punterebbe alla home di qualcun altro e l'agente partirebbe a vuoto.
if [ -f "$PLIST" ]; then
  prog="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST" 2>/dev/null)"
  if [ -n "$prog" ] && [ -x "$prog" ]; then
    echo "  ok   percorso: il rifornitore punta a un comando che esiste ($prog)"
  else
    echo "  NO   percorso: il plist punta a «${prog:-?}», che non e' eseguibile qui"
    fail=1
  fi
else
  echo "  NO   percorso: nessun plist installato"
  fail=1
fi

# --- 3. chiamarla due volte non fa danni -----------------------------------
# Viene invocata a ogni apertura e da doctor: se ricaricasse l'agente ogni volta
# butterebbe via il preparatore in corso, cioe' proprio la finestra che sta
# nascendo.
estrai_e_chiama
stato_dopo=0
launchctl print "$LABEL" >/dev/null 2>&1 && stato_dopo=1
if [ "$stato_dopo" = 1 ]; then
  echo "  ok   ripetibile: richiamarla lascia l'agente al suo posto"
else
  echo "  NO   ripetibile: la seconda chiamata ha scaricato l'agente"
  fail=1
fi

# --- 4. lo rimette anche chi APRE, non solo doctor --------------------------
# ensure_ready_agent era chiamata da doctor e dal risveglio dopo il riuso di una
# finestra calda. Ma con la scorta spenta quel riuso non avviene mai, e chi apre
# le app dal Dock - cioe' l'uso normale - non lancia mai "winfleet" a mano:
# verificato che un'apertura vera NON rimetteva l'agente, e restava assente per
# sempre.
if grep -q 'rifornitore assente: lo rimetto' bin/winfleet; then
  echo "  ok   apertura: anche chi apre una finestra rimette il rifornitore"
else
  echo "  NO   apertura: solo doctor lo rimette, e dal Dock non passa da li'"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
