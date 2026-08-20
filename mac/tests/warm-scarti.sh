#!/opt/homebrew/bin/bash
# Un guasto passeggero non bandisce per sempre un'app dalla scorta.
#
# Il rifornitore tiene un elenco di app che "non aprono finestre su questo PC":
# la Calcolatrice qui lo fa davvero (MainWindowHandle resta 0), e ricordarselo
# evita di bruciare uno slot per mezzo minuto a ogni giro.
#
# Ma bastava UNA prova andata male per condannare un'app sana, e succede: il
# Blocco note e' finito nell'elenco mentre una libreria non firmata faceva
# fallire OGNI apertura. Passato il guasto, il rifornitore aveva una sola app
# buona rimasta e preparava una finestra invece di due, senza dire perche'.
#
# Ora servono DUE bocciature, e ogni riga porta la propria data.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
fail=0

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sc="$TMP/scarti"

conta(){ awk -F'\t' -v n="$1" 'NF==2 && $2==n' "$sc" 2>/dev/null | wc -l | tr -d ' '; }

# --- 1. una bocciatura sola non basta --------------------------------------
printf '%s\t%s\n' "$(date +%s)" "Blocco note" > "$sc"
if [ "$(conta "Blocco note")" -lt 2 ]; then
  echo "  ok   scorta: una bocciatura sola non bandisce l'app"
else
  echo "  NO   scorta: basta un guasto passeggero per perdere un'app sana"
  fail=1
fi

# --- 2. due bocciature bandiscono ------------------------------------------
# Il rovescio: un'app DAVVERO rotta deve uscire, altrimenti il rifornitore
# ricomincia a bruciare mezzo minuto per giro.
printf '%s\t%s\n' "$(date +%s)" "Blocco note" >> "$sc"
if [ "$(conta "Blocco note")" -ge 2 ]; then
  echo "  ok   scorta: due bocciature bandiscono davvero"
else
  echo "  NO   scorta: un'app rotta resta in lista per sempre e brucia uno slot ogni giro"
  fail=1
fi

# --- 3. le righe vecchie di un giorno scadono ------------------------------
# Un'app puo' essere rotta oggi e a posto domani. Prima la scadenza era sul
# FILE, quindi aggiungere un'app rimandava la scadenza di tutte: una bocciata a
# torto restava dentro all'infinito finche' un'altra la teneva in vita.
{ printf '%s\t%s\n' "$(( $(date +%s) - 90000 ))" "Vecchia"
  printf '%s\t%s\n' "$(date +%s)" "Recente"; } > "$sc"
ora=$(date +%s)
awk -F'\t' -v ora="$ora" 'NF==2 && (ora-$1)<86400' "$sc" > "$sc.p" && mv "$sc.p" "$sc"
if ! grep -q "Vecchia" "$sc" && grep -q "Recente" "$sc"; then
  echo "  ok   scorta: le bocciature scadono una per una, non tutte insieme"
else
  echo "  NO   scorta: la scadenza non e' per riga -> una bocciatura a torto resta per sempre"
  fail=1
fi

# --- 4. il codice si comporta cosi' ----------------------------------------
# I controlli qui sopra provano la regola su un file finto: questo verifica che
# sia la regola che winfleet applica davvero.
#
# Si ancora alla riga che DECIDE - quella che conta le bocciature dell'app
# candidata - e non a un frammento che compare anche altrove: il file ha pure
# "$bocciature -ge 2", che serve solo a scegliere il messaggio in traccia. Con
# un grep generico ("ge 2 ]; then") il test restava verde anche riportando a UNO
# la soglia vera. Verificato rimettendo il guasto.
if grep -qF 'n="$cand"' bin/winfleet &&
   grep -qF '| wc -l)" -ge 2 ]; then' bin/winfleet &&
   grep -qF 'date +%s)" "$rotta" >>"$scarti"' bin/winfleet; then
  echo "  ok   scorta: winfleet conta le bocciature e le data"
else
  echo "  NO   scorta: winfleet usa ancora l'elenco di soli nomi"
  fail=1
fi

# --- 5. si annota SEMPRE, anche se l'app c'e' gia' -------------------------
# Sottigliezza che vale il difetto opposto: con "aggiungi solo se manca" il
# conto resterebbe a uno per sempre e NESSUNA app verrebbe mai scartata, cioe'
# la Calcolatrice tornerebbe a bruciare uno slot a ogni giro.
if ! grep -q 'if ! grep -qxF "$rotta" "$scarti"' bin/winfleet; then
  echo "  ok   scorta: la seconda bocciatura viene annotata, non ignorata"
else
  echo "  NO   scorta: la seconda bocciatura si perde -> nessuna app viene mai scartata"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
