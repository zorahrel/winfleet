#!/usr/bin/env bash
# Costruisce il Moonlight di WinFleet: l'originale piu' il ritaglio.
#
# Perche' un fork. WinFleet mostra UNA finestra di Windows come finestra del Mac.
# Farla seguire cambiando la risoluzione dello schermo virtuale costa circa un
# secondo a colpo — il mode set di Windows piu' la ricostruzione dell'encoder di
# Sunshine, misurabile nel suo log — ed e' quello che rende il ridimensionamento a
# scatti invece che dal vivo.
#
# Ritagliando, quel costo sparisce: lo schermo resta fisso, su Windows si
# ridimensiona la finestra dell'app (immediato) e il client mostra solo il rettangolo
# che occupa. Forma libera, nessuna banda nera, nessun riscalo.
#
# La modifica e' in fork/crop.patch: una funzione che legge il rettangolo da un file
# (WF_CROP) e due punti nei renderer che lo usano come regione sorgente. Il resto e'
# Moonlight originale, preso al volo — qui non si tiene una copia del suo codice.
set -euo pipefail

SRC="${WINFLEET_FORK_SRC:-$HOME/.cache/winfleet/moonlight-qt}"
DEST="${WINFLEET_FORK_APP:-$HOME/.local/share/winfleet/Moonlight.app}"
PATCH="$(cd "$(dirname "$0")" && pwd)/crop.patch"

command -v git >/dev/null || { echo "Serve git."; exit 1; }
QMAKE="$(command -v qmake6 || echo /opt/homebrew/opt/qt/bin/qmake)"
[ -x "$QMAKE" ] || { echo "Serve Qt 6:  brew install qt"; exit 1; }
# Homebrew non e' sempre nel PATH di chi lancia questo script (launchd, un altro
# shell, una sessione non interattiva): aggiungerlo qui evita un "serve
# pkg-config" con pkg-config gia' installato - misurato.
case ":$PATH:" in *:/opt/homebrew/bin:*) ;; *) PATH="/opt/homebrew/bin:$PATH";; esac
export PATH
command -v pkg-config >/dev/null || { echo "Serve pkg-config:  brew install pkgconf"; exit 1; }

echo "==> sorgenti in $SRC"
if [ -d "$SRC/.git" ]; then
  # Si ripuliscono TUTTI i file toccati dalla patch, non solo app/streaming: da
  # quando la patch tocca anche app/gui e app/main.cpp, lasciarli modificati
  # faceva fallire il secondo build con "la patch non si applica piu'", e il
  # messaggio mandava a cercare un cambiamento a monte che non c'era.
  git -C "$SRC" checkout -- app 2>/dev/null || true
  git -C "$SRC" pull --ff-only >/dev/null 2>&1 || true
else
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 --recursive https://github.com/moonlight-stream/moonlight-qt.git "$SRC"
fi

echo "==> dipendenze precompilate di Moonlight"
# Su macOS Moonlight non usa le librerie di sistema ma un pacchetto suo: senza
# questo il build muore su openssl senza spiegare perche'.
[ -d "$SRC/libs/mac" ] || (cd "$SRC" && python3 setup-deps.py)

echo "==> applico il ritaglio"
git -C "$SRC" apply --check "$PATCH" 2>/dev/null || {
  echo "La patch non si applica piu' su questo Moonlight: e' cambiato il codice a monte."
  echo "Guarda fork/crop.patch — sono due punti soli, plvk.cpp e vt_metal.mm."
  exit 1
}
git -C "$SRC" apply "$PATCH"

echo "==> compilo"
cd "$SRC"
export PKG_CONFIG_PATH="/opt/homebrew/opt/openssl@3/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
"$QMAKE" moonlight-qt.pro >/dev/null
# Il make di primo livello avanza un sottoprogetto per volta: si insiste finche' non
# esce l'applicazione, o finche' non e' evidente che si e' fermato.
for _ in 1 2 3 4 5 6; do
  make -j"$(sysctl -n hw.ncpu)" >/dev/null 2>&1 || true
  [ -x app/Moonlight.app/Contents/MacOS/Moonlight ] && break
done
[ -x app/Moonlight.app/Contents/MacOS/Moonlight ] || { echo "Build fallito."; exit 1; }

echo "==> installo in $DEST"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -Rc app/Moonlight.app "$DEST" 2>/dev/null || cp -R app/Moonlight.app "$DEST"
codesign --force --deep --sign - "$DEST" >/dev/null 2>&1 || true

echo
echo "Fatto.  Per usarlo:"
echo "  winfleet dock <app>      (i lanciatori si rifanno su questo Moonlight)"
