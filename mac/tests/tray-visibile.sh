#!/opt/homebrew/bin/bash
# L'icona nella barra di Windows c'e', e si VEDE.
#
# Perche' esiste: il 27/08 l'istanza Sunshine dello slot 0 e' morta all'01:00 e
# nessuno se n'e' accorto per tredici ore. Sul Mac le aperture dicevano "il PC e'
# spento"; sul PC non c'era assolutamente niente da guardare - nessuna finestra,
# nessuna icona, nessun avviso. Il guasto stava scritto in tre log, tutti
# invisibili a chi stava usando il computer.
#
# Le due proprieta' sono diverse e servono entrambe:
#   viva     = il processo gira e sta controllando
#   mostrata = l'icona e' nella barra, non nel cassetto dell'overflow
# Windows 11 nasconde ogni icona nuova dietro la freccetta "^". Verificato dal
# vivo: tray avviata, log corretto, e nell'area di notifica ZERO pixel colorati.
# Un'icona nel cassetto e' viva, cambia colore e non avvisa nessuno.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0
CONFIG="$HOME/.config/winfleet/config.env"
[ -f "$CONFIG" ] || { echo "  SKIP: nessuna configurazione"; exit 0; }
# Si LEGGONO le tre righe che servono, non si esegue il file.
#
# La configurazione contiene anche righe come "size_gestioneattività=824x755",
# scritte da winfleet per ricordare la misura di ogni app: il nome ha dentro un
# accento, e bash non puo' assegnare una variabile con quel nome - il "." le
# esegue come COMANDO e stampa "command not found" in mezzo all'output del test.
# Innocuo qui, ma un test che sporca la propria uscita insegna a ignorarla.
leggi(){ sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$CONFIG" | tail -1; }
HOST_LAN="$(leggi HOST_LAN)"
HOST_TS="$(leggi HOST_TS)"
AGENT_PORT="$(leggi AGENT_PORT)"; AGENT_PORT="${AGENT_PORT:-48088}"

# --- 1. i pezzi ci sono -----------------------------------------------------
for f in host/wf-tray.ps1 host/wf-tray-show.ps1; do
  if [ -f "$f" ]; then
    echo "  ok   $f presente"
  else
    echo "  NO   manca $f"
    fail=1
  fi
done

# La tray va registrata dal setup, o esiste solo sulla macchina di chi l'ha
# installata a mano - e su un host nuovo il PC torna muto senza che nessuno se
# ne accorga (che e' esattamente il guasto di partenza).
if grep -q "winfleet-tray" host/setup-vdd.ps1; then
  echo "  ok   il setup registra la tray"
else
  echo "  NO   il setup non registra la tray: su un host nuovo non ci sarebbe"
  fail=1
fi
# E host-clean non deve cancellarla scambiandola per un residuo.
if grep -q "winfleet-tray,winfleet-tray-show" bin/winfleet; then
  echo "  ok   host-clean riconosce i task della tray"
else
  echo "  NO   host-clean cancellerebbe la tray come residuo"
  fail=1
fi

# --- 2. il doctor la controlla, e ripara ------------------------------------
# Un componente che nessuno controlla muore in silenzio: e' la lezione che ha
# generato la tray, e varrebbe anche per la tray stessa.
if grep -q "icona nella barra del PC" bin/winfleet; then
  echo "  ok   il doctor guarda l'icona"
else
  echo "  NO   il doctor non dice niente dell'icona"
  fail=1
fi
if grep -q "winfleet-tray-show" bin/winfleet; then
  echo "  ok   il doctor ripara un'icona nascosta, invece di spiegare dove cliccare"
else
  echo "  NO   il doctor non ripara l'icona nascosta"
  fail=1
fi

# --- 3. dal vivo ------------------------------------------------------------
# La parte che conta: sull'host vero, adesso.
addr=""
for h in "${HOST_LAN:-}" "${HOST_TS:-}"; do
  [ -n "$h" ] || continue
  if nc -z -G 1 "$h" "$AGENT_PORT" >/dev/null 2>&1; then addr="$h"; break; fi
done
if [ -z "$addr" ]; then
  echo "  SKIP dal vivo: l'agente non risponde (PC spento?)"
else
  stato="$(curl -s --max-time 4 "http://$addr:$AGENT_PORT/tray" 2>/dev/null)"
  case "$stato" in
    '')
      echo "  NO   l'agente non conosce /tray: aggiorna l'host (winfleet push)"
      fail=1;;
    *viva=0*)
      echo "  NO   la tray non gira sull'host: un guasto sul PC non lo vedrebbe nessuno"
      fail=1;;
    *mostrata=0*)
      # Il caso peggiore proprio perche' sembra a posto: il processo c'e', il
      # log si riempie, e l'icona e' invisibile.
      echo "  NO   l'icona e' nascosta nell'overflow: viva ma invisibile"
      fail=1;;
    *viva=1*mostrata=1*)
      echo "  ok   dal vivo: la tray gira e l'icona e' nella barra  ($stato)";;
    *)
      echo "  NO   risposta inattesa da /tray: «${stato}»"
      fail=1;;
  esac
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
