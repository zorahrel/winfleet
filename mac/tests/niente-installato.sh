#!/opt/homebrew/bin/bash
# Winfleet e' l'unica cosa installata: ne' Sunshine ne' Moonlight, da nessuna parte.
#
# E' il punto di tutto il sistema, e non e' una preferenza estetica.
#
# Un Moonlight in /Applications e' un'app che si apre per sbaglio dal Launchpad o
# da Spotlight - e aprendola SCOLLEGA gli stream in corso, perche' un host
# Sunshine parla con un client alla volta: da fuori, le finestre delle app
# diventano nere tutte insieme senza un motivo visibile.
#
# Un Sunshine installato sul PC porta con se' un servizio che puo' riprendersi la
# 47990, una voce fra i programmi, una web UI da cui si puo' cambiare la
# configurazione e rompere winfleet senza sapere di averlo fatto, e un
# aggiornatore che puo' sostituire il binario sotto le istanze in esecuzione.
#
# I due pezzi vivono dentro casa: il client in ~/.local/share/winfleet, il motore
# in C:\winfleet\engine. E' una proprieta' che si perde da sola - basta un
# "brew install --cask moonlight" o un reinstall - quindi va CONTROLLATA.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0
CONFIG="$HOME/.config/winfleet/config.env"
[ -f "$CONFIG" ] || { echo "  SKIP: nessuna configurazione"; exit 0; }
# Le righe si LEGGONO, non si esegue il file: contiene nomi con accenti
# (size_gestioneattività=...) che bash non puo' assegnare, e il "." li
# eseguirebbe come comandi sporcando l'output del test.
leggi(){ sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$CONFIG" | tail -1; }
HOST_LAN="$(leggi HOST_LAN)"
HOST_TS="$(leggi HOST_TS)"
AGENT_PORT="$(leggi AGENT_PORT)"; AGENT_PORT="${AGENT_PORT:-48088}"

# --- 1. il Mac --------------------------------------------------------------
if [ -d "/Applications/Moonlight.app" ]; then
  echo "  NO   Moonlight e' installato in /Applications: aprirlo scollega gli stream"
  fail=1
else
  echo "  ok   Mac: nessun Moonlight in /Applications"
fi

# Il client di winfleet deve esserci ED essere autosufficiente: se dipendesse
# dall'installazione, toglierla lo romperebbe - e il sintomo arriverebbe alla
# prima apertura, non adesso.
CLIENT="$HOME/.local/share/winfleet/Moonlight.app/Contents/MacOS/Moonlight"
if [ ! -x "$CLIENT" ]; then
  echo "  NO   manca il client di winfleet ($CLIENT): costruiscilo con fork/build.sh"
  fail=1
else
  v="$("$CLIENT" --version 2>/dev/null | grep -oE 'Moonlight [0-9.]+' | head -1)"
  if [ -n "$v" ]; then
    echo "  ok   client di winfleet autosufficiente ($v)"
  else
    echo "  NO   il client di winfleet non parte da solo: dipende da qualcosa che non c'e'"
    fail=1
  fi
fi

# --- 2. il codice non pretende l'installazione ------------------------------
# Il controllo strutturale: se qualcuno rimette "Program Files\Sunshine" come
# percorso fisso, il motore locale smette di essere usato e il PC torna a
# dipendere da un pacchetto installato.
if grep -q "^\. C:.winfleet.wf-engine.ps1" host/wf-instance.ps1 host/wf-inst-ctl.ps1; then
  echo "  ok   gli script dell'host chiedono il percorso a wf-engine.ps1"
else
  echo "  NO   qualche script ha di nuovo il percorso del motore scritto a mano"
  fail=1
fi
if [ -f host/wf-engine-adopt.ps1 ]; then
  echo "  ok   c'e' il comando che adotta il motore e disinstalla Sunshine"
else
  echo "  NO   manca host/wf-engine-adopt.ps1"
  fail=1
fi
# La rete di sicurezza che conta: adopt non deve disinstallare mentre qualche
# istanza gira ancora dal vecchio percorso, o le ammazza tutte insieme.
if grep -q "Non disinstallo con istanze vive sul vecchio percorso" host/wf-engine-adopt.ps1; then
  echo "  ok   l'adozione rifiuta di disinstallare con istanze sul vecchio percorso"
else
  echo "  NO   l'adozione puo' disinstallare sotto istanze in esecuzione"
  fail=1
fi

# --- 3. il PC, dal vivo -----------------------------------------------------
addr=""
for h in "${HOST_LAN:-}" "${HOST_TS:-}"; do
  [ -n "$h" ] || continue
  if nc -z -G 1 "$h" "$AGENT_PORT" >/dev/null 2>&1; then addr="$h"; break; fi
done
if [ -z "$addr" ]; then
  echo "  SKIP dal vivo: l'agente non risponde (PC spento?)"
else
  stato="$(curl -s --max-time 4 "http://$addr:$AGENT_PORT/engine" 2>/dev/null)"
  case "$stato" in
    '')
      echo "  NO   l'agente non conosce /engine: aggiorna l'host (winfleet push)"
      fail=1;;
    *installato=1*)
      echo "  NO   Sunshine risulta installato sul PC: «$stato»"
      fail=1;;
    *fuori=0*)
      echo "  ok   dal vivo: motore dentro C:\\winfleet, nessun Sunshine installato  ($stato)"
      # Il numero va guardato, non solo la sua forma.
      #
      # La prima versione dell'endpoint deduplicava i percorsi prima di contarli
      # ("Sort-Object -Unique"): quattro istanze identiche collassavano in una,
      # e la risposta diceva "istanze=1" con quattro processi vivi. Tutti i
      # controlli qui sopra passavano lo stesso, perche' guardavano "fuori" e
      # "installato". Un numero sbagliato dentro un controllo verde e' peggio
      # di nessun numero: la prossima volta che serve, si crede.
      slots="$(leggi SLOTS)"; slots="${slots:-4}"
      n="$(printf '%s' "$stato" | sed -n 's/.*istanze=\([0-9]*\).*/\1/p')"
      if [ "${n:-0}" -ge "$slots" ] 2>/dev/null; then
        echo "  ok   conta tutte le istanze ($n, attese >= $slots)"
      else
        echo "  NO   conta $n istanze ma dovrebbero essere almeno $slots (sono tutte vive?)"
        fail=1
      fi;;
    *)
      echo "  NO   qualche istanza gira fuori da C:\\winfleet: «$stato»"
      fail=1;;
  esac
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
