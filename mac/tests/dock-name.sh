#!/opt/homebrew/bin/bash
# Un'app aperta su una finestra CALDA mostra il proprio nome nel Dock.
#
# Il difetto, visto dal vivo: si apre "Armoury Crate" e nel Dock compare
# "Finestra WinFleet". Una finestra di scorta nasce dal bundle dell'app usata
# per scaldarla, e quel bundle decide il nome che LaunchServices registra al
# lancio. Il file slot<N>.name era gia' corretto, il titolo della finestra pure:
# era il nome sotto l'icona - il primo che si legge - a restare quello sbagliato.
#
# Nel codice c'era scritto che non si poteva cambiare a processo avviato. E' vero
# per CFBundleName, che il Dock ha gia' letto, ma il nome mostrato non viene da
# li': viene dalla scheda che LaunchServices tiene per ogni processo vivo, e
# quella si corregge con _LSSetApplicationInformationItem.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
fail=0

# --- 1. la libreria fa la chiamata, e la fa sul nome giusto -----------------
# Si cerca la CHIAMATA, non la parola: i commenti qui sopra nominano entrambe le
# funzioni, quindi un grep semplice restava verde anche cancellando il codice.
# Provato commentando la chiamata: passava.
if grep -qE '^ +_LSSetApplicationInformationItem\(' mac/wf-chrome.m &&
   grep -qE '^ +_kLSDisplayNameKey,' mac/wf-chrome.m; then
  echo "  ok   Dock: la libreria corregge il nome registrato, non solo il titolo"
else
  echo "  NO   Dock: nessuna correzione del nome -> le finestre riusate restano intestate alla scorta"
  fail=1
fi

# --- 2. e NON lo fa per le finestre di scorta -------------------------------
# Una scorta deve restare invisibile: se le si desse un nome vero comparirebbe
# nel Dock come un'app che l'utente non ha aperto.
# Si conta l'INDENTAZIONE, non si delimita un blocco: dentro "if (!scorta)" la
# chiamata sta a dodici spazi, fuori a otto. Un primo tentativo con awk prendeva
# da "if (!scorta)" fino alla chiusura del dispatch_async, cioe' un pezzo che
# comprende ANCHE il fuori: spostando la chiamata fuori dall'if il test restava
# verde. Provato rimettendo il guasto.
if grep -qE '^            _LSSetApplicationInformationItem' mac/wf-chrome.m &&
   ! grep -qE '^        _LSSetApplicationInformationItem' mac/wf-chrome.m; then
  echo "  ok   Dock: la scorta resta senza nome, la correzione vale solo per le app vere"
else
  echo "  NO   Dock: il nome verrebbe messo anche alle finestre di scorta"
  fail=1
fi

# --- 3. la libreria compila e si CARICA -------------------------------------
# Il controllo che conta davvero. Aggiungendo questa modifica avevo copiato la
# libreria senza firmarla: dyld la rifiutava con "Code Signature Invalid",
# winfleet ripiegava sulla versione senza libreria - dove il nome e' giusto per
# un altro motivo - e la prova sembrava riuscita mentre il codice nuovo non era
# mai stato eseguito. Qui si compila come fa build_chrome, FIRMANDO, e si guarda
# che un Moonlight con la libreria dentro arrivi a stampare la sua versione.
if ! command -v clang >/dev/null 2>&1; then
  echo "  SKIP Dock: niente clang"
else
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  if clang -dynamiclib -framework Cocoa -o "$tmp/wf.dylib" mac/wf-chrome.m 2>"$tmp/err"; then
    codesign --force -s - "$tmp/wf.dylib" >/dev/null 2>&1 || true
    run="$(ls -d "$HOME"/.config/winfleet/runners/*.app 2>/dev/null | head -1)"
    if [ -n "$run" ] && [ -x "$run/Contents/MacOS/Moonlight" ]; then
      if DYLD_INSERT_LIBRARIES="$tmp/wf.dylib" "$run/Contents/MacOS/Moonlight" --version 2>&1 | grep -q Moonlight; then
        echo "  ok   Dock: la libreria si carica davvero dentro Moonlight"
      else
        echo "  NO   Dock: Moonlight non parte con la libreria -> ogni finestra ripiega senza"
        fail=1
      fi
    else
      echo "  SKIP Dock: nessun runner installato da provare"
    fi
  else
    echo "  NO   Dock: la libreria non compila -> $(head -1 "$tmp/err" | cut -c1-70)"
    fail=1
  fi
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
