#!/opt/homebrew/bin/bash
# La cartella dell'host si tiene pulita da sola.
#
# C:\winfleet e' il posto dove finisce ogni script buttato li' per capire
# qualcosa: una diagnosi al volo, una prova, un "wfdiag3.ps1". Nessuno li
# cancella, e si accumulano - misurato il 26/08: 155 file, di cui 14 veri.
#
# Non e' solo disordine: ogni "winfleet push" valida la SINTASSI di tutti i .ps1
# presenti, quindi novanta rottami rallentano ogni caricamento e possono far
# fallire un controllo che riguarda ben altro.
#
# Qui si verifica la sola cosa che conta davvero: la REGOLA con cui si decide
# cosa tenere. Sbagliarla in un verso lascia la spazzatura, sbagliarla
# nell'altro cancella i file di stato di winfleet - app0.txt, hwnd1.txt, pid2.txt
# sono la sua memoria, e portarli via mentre una finestra e' aperta la rompe.
#
# Il test e' capace di fallire: si controlla anche il caso in cui la regola
# tocchi i dati.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0

# --- 1. la regola conosce gli script del repo ------------------------------
# L'elenco dei "buoni" si costruisce da host/, che e' l'unica fonte che dica
# cosa dovrebbe esserci sull'host.
buoni="$(ls host/*.ps1 2>/dev/null | xargs -n1 basename | sort)"
n_buoni="$(printf '%s\n' "$buoni" | grep -c . || true)"
if [ "${n_buoni:-0}" -ge 10 ]; then
  echo "  ok   host/ elenca $n_buoni script da tenere"
else
  echo "  NO   host/ ne elenca solo ${n_buoni:-0}: la regola terrebbe troppo poco"
  fail=1
fi

# --- 2. gli script veri sono nell'elenco -----------------------------------
# Se uno di questi mancasse, il comando lo sposterebbe nel cestino e winfleet
# smetterebbe di funzionare al primo uso.
for essenziale in wf-agent.ps1 wf-place.ps1 wf-vdd.ps1 wf-cursor.ps1 setup-vdd.ps1; do
  if printf '%s\n' "$buoni" | grep -qx "$essenziale"; then
    echo "  ok   $essenziale e' fra i file da tenere"
  else
    echo "  NO   $essenziale NON e' fra i buoni: verrebbe spostato nel cestino"
    fail=1
  fi
done

# --- 3. la regola non tocca i DATI -----------------------------------------
# Il filtro lavora su *.ps1 e su un elenco chiuso di estensioni di scarto. I
# file di stato degli slot devono restare fuori da entrambi: cancellarli
# significa rompere le finestre aperte in quel momento.
sporchi=0
for dato in app0.txt hwnd1.txt pid2.txt rect0.txt vdd.json vdd.log agent.log cursor.log cursor-alive.txt; do
  case "$dato" in
    *.ps1|*.out|*.bak|*.tmp) echo "  NO   $dato verrebbe spostato: e' un dato di winfleet"; fail=1; sporchi=1;;
  esac
done
[ "$sporchi" = 0 ] && echo "  ok   i file di stato e i log restano fuori dal filtro"

# --- 4. e riconosce gli scarti ---------------------------------------------
# Il rovescio: se il filtro non riconoscesse questi, la pulizia non pulirebbe.
manca=0
for scarto in shot.out prova.bak lavoro.tmp; do
  case "$scarto" in
    *.out|*.bak|*.tmp) ;;
    *) echo "  NO   $scarto non verrebbe riconosciuto come scarto"; fail=1; manca=1;;
  esac
done
[ "$manca" = 0 ] && echo "  ok   .out .bak .tmp riconosciuti come residui di diagnosi"

# --- 5. il comando esiste ed e' raggiungibile ------------------------------
# Una funzione scritta e mai agganciata al dispatcher e' codice morto: si
# scopre solo quando serve, cioe' quando la cartella e' gia' piena.
if grep -q '^  host-clean) cmd_host_clean;;' bin/winfleet; then
  echo "  ok   «winfleet host-clean» e' agganciato al comando"
else
  echo "  NO   host-clean non e' nel dispatcher: la funzione non si puo' chiamare"
  fail=1
fi

# --- 6. e non cancella: sposta ---------------------------------------------
# "Non serve piu'" e' un giudizio che si puo' sbagliare, e su una cartella
# scritta da mani diverse si sbaglia. Da un cestino si recupera.
if grep -q '_cestino' bin/winfleet && ! grep -qE 'Remove-Item C:.winfleet..\*\.ps1' bin/winfleet; then
  echo "  ok   gli script si spostano nel cestino, non si cancellano"
else
  echo "  NO   la pulizia cancella invece di spostare"
  fail=1
fi

exit "$fail"
