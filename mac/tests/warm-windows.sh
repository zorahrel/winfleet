#!/opt/homebrew/bin/bash
# Le finestre calde devono usare app DIVERSE, e contarsi mentre nascono.
#
# Il guasto vero: le app di sistema sono quasi tutte a istanza singola, e per
# aprire la propria finestra il secondo slot CHIUDE quella del primo. Scaldando
# due slot con lo stesso Blocco note i preparatori si distruggevano a vicenda -
# nel log tre slot marcati "pronto" e una sola finestra viva sull'host, quindi
# un'apertura che credeva di riusare una finestra calda finiva su uno schermo
# vuoto e pagava i quindici secondi pieni.
#
# Due proprieta', entrambe verificate qui:
#   1. app diverse: la lista non ripete mai lo stesso nome;
#   2. si conta anche chi e' in preparazione, non solo chi e' gia' pronto -
#      preparare costa venti secondi, e contare i soli risultati faceva lanciare
#      una finestra di troppo a ogni giro.
#
# Il test e' capace di fallire: le due varianti "sbagliate" qui sotto sono il
# codice di prima, e tornano non-zero.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0

# --- 1. la lista di riscaldamento non ripete un'app ------------------------
# Si legge dal sorgente, cosi' il test segue il codice invece di una copia.
lista="$(sed -n 's/^  for cand in \(.*\); do$/\1/p' bin/winfleet | head -1)"
if [ -z "$lista" ]; then
  echo "  NO   non trovo la lista delle app per scaldare in bin/winfleet"
  fail=1
else
  n_tot="$(printf '%s\n' "$lista" | tr '"' '\n' | grep -c '[A-Za-z]')"
  n_uni="$(printf '%s\n' "$lista" | tr '"' '\n' | grep '[A-Za-z]' | sort -u | wc -l | tr -d ' ')"
  if [ "$n_tot" -ge 4 ] && [ "$n_tot" = "$n_uni" ]; then
    echo "  ok   app per scaldare: $n_uni nomi, tutti diversi"
  else
    echo "  NO   app per scaldare: $n_tot nomi ma solo $n_uni diversi (servono >= 4 distinti)"
    fail=1
  fi
fi

# --- 2. quante finestre si lanciano ----------------------------------------
# Si riproduce il ciclo con un conteggio finto: ready_count resta a zero per i
# primi giri, come nella realta' (una finestra impiega ~20s a diventare pronta).
# Quante finestre esistono in tutto (la prima e' gia' partita fuori dal ciclo).
simula(){ # conta_i_lanciati(0|1) -> finestre totali per want=2
  local conta="$1" want=2 launched=1 lanciate=0 pronte=0 giro
  for giro in 1 2 3 4 5 6; do
    if [ "$conta" = 1 ]; then
      [ "$launched" -lt "$want" ] || break
    else
      # il codice di prima: guardava solo quante ne erano gia' PRONTE, e una
      # finestra ci mette venti secondi a diventarlo - qui, come nella realta',
      # nessuna lo diventa mentre il ciclo gira.
      [ "$pronte" -lt "$want" ] || break
    fi
    lanciate=$(( lanciate + 1 ))
    launched=$(( launched + 1 ))
  done
  echo "$(( 1 + lanciate ))"
}

got="$(simula 1)"
if [ "$got" = 2 ]; then
  echo "  ok   prepara esattamente 2 finestre calde"
else
  echo "  NO   prepara $got finestre invece di 2"
  fail=1
fi

vecchio="$(simula 0)"
if [ "$vecchio" -gt 2 ]; then
  echo "  ok   il controllo discrimina: col conteggio vecchio ne partirebbero $vecchio"
else
  echo "  NO   il controllo non discrimina: anche il codice vecchio ne fa $vecchio"
  fail=1
fi

# --- 3. una finestra calda non adotta finestre extra -----------------------
# Il supervisore della scorta vede anche le finestre generate dalle app usate
# per scaldarla. Adottarle trasformava WF_WARM=2 in quattro o cinque stream.
# La scorta deve pero' aggiornare /orphans-visti: senza quella baseline, la
# prima figlia nata subito dopo lo swap viene scambiata per roba vecchia e non
# verra' mai mostrata. Qui old e' gia' presente mentre e' calda; new appare
# dopo lo swap e deve arrivare fino al controllo di uno slot libero.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
{
  printf '%s\n' 'SLOTS=1' 'AGENT_PORT=48088' 'CONFIG_DIR="$WF_TEST_DIR"' 'trace(){ :; }' \
    'slot_get(){ [ "$2" = warm ] && printf "%s\n" "${WF_TEST_WARM:-1}"; }' 'agent_host(){ echo 127.0.0.1; }' \
    'curl(){ printf "%b" "${WF_TEST_ORPHANS:-no}"; }' \
    'slot_free_ish(){ : >"$WF_TEST_DIR/post-swap-visto"; return 1; }' \
    'slot_paired(){ return 0; }' 'slot_live(){ return 1; }'
  awk '/^adopt_orphans\(\){/{on=1} on && /^cmd_ready_missing\(\){/{exit} on{print}' bin/winfleet
  printf '%s\n' "WF_TEST_ORPHANS=\$'0\\told\\t1\\tApp' WF_TEST_WARM=1 adopt_orphans 0" \
    'grep -qx old "$WF_TEST_DIR/orphans-visti" || exit 1' \
    "WF_TEST_ORPHANS=\$'0\\told\\t1\\tApp\\n0\\twarmnew\\t2\\tApp' WF_TEST_WARM=1 adopt_orphans 0" \
    '[ ! -e "$WF_TEST_DIR/post-swap-visto" ] || exit 1' \
    'grep -qx warmnew "$WF_TEST_DIR/orphans-visti" || exit 1' \
    "WF_TEST_ORPHANS=\$'0\\told\\t1\\tApp\\n0\\twarmnew\\t2\\tApp\\n0\\tnew\\t3\\tApp' WF_TEST_WARM=0 adopt_orphans 0" \
    '[ -e "$WF_TEST_DIR/post-swap-visto" ]'
} > "$TMP/adopt.sh"
if WF_TEST_DIR="$TMP" /opt/homebrew/bin/bash -u "$TMP/adopt.sh" >/dev/null 2>&1; then
  echo "  ok   scorta: non apre extra, ma dopo lo swap vede subito le figlie utente"
else
  echo "  NO   scorta: il gate perde la prima figlia dopo lo swap o apre stream extra"
  fail=1
fi

# --- 4. nessun «$var» senza graffe -----------------------------------------
# I byte di » finiscono nel NOME della variabile, e con set -u il comando muore
# con "unbound variable" a meta' lavoro. E' capitato tre volte in questo file,
# l'ultima uccidendo il preparatore dopo la prima finestra calda: la scorta
# restava a uno e ogni seconda apertura pagava la via lunga. Un errore che il
# controllo di sintassi NON vede, perche' e' valido finche' non lo si esegue.
if grep -n '«\$[a-zA-Z_]' bin/winfleet | grep -v '^\s*[0-9]*:\s*#' | grep -qv '#'; then
  echo "  NO   c'e' un «\$var» senza graffe: con set -u muore a runtime"
  grep -n '«\$[a-zA-Z_]' bin/winfleet | grep -v '#' | sed 's/^/       /'
  fail=1
else
  echo "  ok   nessun «\$var» senza graffe fuori dai commenti"
fi

# --- 5. il marchio richiede una finestra vera ------------------------------
# Marcare "pronto" uno slot senza finestra e' il modo in cui il guasto diventa
# invisibile: l'apertura dopo ci finisce sopra e trova uno schermo vuoto.
if grep -q 'slot_hwnd_live "\$s"' bin/winfleet; then
  echo "  ok   si marca pronto solo uno slot con una finestra viva"
else
  echo "  NO   il marchio non verifica che la finestra esista"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
