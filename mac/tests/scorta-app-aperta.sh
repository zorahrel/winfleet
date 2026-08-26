#!/opt/homebrew/bin/bash
# Un'app gia' aperta non scalda niente.
#
# Il guasto vero, 26/08: il rifornitore sceglieva la Calcolatrice per preparare
# la finestra pronta, ma la Calcolatrice era GIA' aperta su Windows da qualche
# parte. Le app a istanza singola non ne aprono una seconda: lo stream partiva,
# il monitor restava vuoto, e il rifornitore aspettava invano.
#
# Misurato: 73 secondi per accorgersene, uno slot bruciato per tutto quel tempo,
# e l'app finiva negli "scarti" - bandita per un guasto che non era suo, mentre
# il vero problema era solo che qualcuno l'aveva lasciata aperta.
#
# Il controllo che c'era guardava solo i NOSTRI slot: "questa app e' gia' in una
# finestra winfleet?". Non basta - la finestra puo' stare sul desktop del PC,
# aperta a mano, e da li' nessuno slot la vede.
#
# Qui si verifica la regola: si scarta un candidato se una finestra con quel
# nome esiste sull'host, e si scende al successivo finche' se ne trova uno
# libero.
#
# Il test e' capace di fallire: senza il filtro, il primo candidato viene scelto
# anche quando e' gia' aperto.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0

# La stessa scelta che fa cmd_ready, isolata: dato l'elenco delle finestre gia'
# aperte sull'host, quale candidato si usa per scaldare?
scegli(){ # "finestre host separate da |" "candidati separati da |"
  local aperte="$1" cands="$2" c
  local IFS='|'
  for c in $cands; do
    printf '%s\n' "$aperte" | tr '|' '\n' | grep -qiF -- "$c" && continue
    echo "$c"; return 0
  done
  echo ""
}

verifica(){ # descrizione aperte candidati atteso
  local desc="$1" got
  got="$(scegli "$2" "$3")"
  if [ "${got:-}" = "$4" ]; then
    echo "  ok   $desc: sceglie «${got:-nessuno}»"
  else
    echo "  NO   $desc: atteso «$4», scelto «${got:-nessuno}»"
    fail=1
  fi
}

# --- 1. nessuna aperta: si prende il primo ---------------------------------
verifica "host senza finestre nostre" \
  "NVIDIA Overlay|Program Manager" \
  "Blocco note|Calcolatrice|Memo" \
  "Blocco note"

# --- 2. il primo e' gia' aperto: si scende --------------------------------
# E' il caso vero: la Calcolatrice lasciata aperta da chiunque.
verifica "primo candidato gia' aperto" \
  "Calcolatrice|NVIDIA Overlay" \
  "Calcolatrice|Memo|Blocco note" \
  "Memo"

# --- 3. e si scende PIU' VOLTE se serve ------------------------------------
# Successo dal vivo: Calcolatrice aperta, poi Fotocamera aperta, e solo il
# terzo candidato era libero.
verifica "primi due gia' aperti" \
  "Calcolatrice|Fotocamera" \
  "Calcolatrice|Fotocamera|Blocco note" \
  "Blocco note"

# --- 4. tutti aperti: nessuno, e non si finge -----------------------------
# Meglio non preparare niente che bruciare uno slot per settanta secondi.
verifica "tutti i candidati gia' aperti" \
  "Blocco note|Calcolatrice|Memo" \
  "Blocco note|Calcolatrice|Memo" \
  ""

# --- 5. il titolo con un documento dentro conta come "gia' aperta" --------
# Il primo tentativo asseriva il CONTRARIO - "il confronto e' sul nome intero" -
# e la realta' l'ha smentito il 26/08: il Blocco note con un file aperto si
# chiama "*wwwwww - Blocco note", il confronto esatto non lo trovava, e la
# scorta sceglieva proprio l'app gia' aperta. Risultato: due finestre "Blocco
# note" e nessuna pronta.
#
# I titoli di Windows sono "documento - Applicazione", quindi il nome dell'app
# ci finisce sempre dentro: basta che il titolo lo CONTENGA.
verifica "titolo con un documento dentro" \
  "*wwwwww - Blocco note|NVIDIA Overlay" \
  "Blocco note|Memo" \
  "Memo"

# --- 6. la regola e' davvero nel codice ------------------------------------
# Le regole sopra sono la copia di quella in cmd_ready: se qualcuno la toglie,
# questo file continuerebbe a passare senza accorgersene.
if grep -q "e' gia' aperta sull'host, non la uso per scaldare" bin/winfleet &&
   grep -q 'grep -qiF -- "\$c0"' bin/winfleet; then
  echo "  ok   winfleet contiene il filtro sulle finestre dell'host"
else
  echo "  NO   il filtro non e' piu' in bin/winfleet"
  fail=1
fi

exit "$fail"
