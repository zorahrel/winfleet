#!/usr/bin/env bash
# WinFleet — installer lato Mac.
# Installa il client Moonlight (se manca) e il comando `winfleet`.
set -euo pipefail
cd "$(dirname "$0")"

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

echo "==> Moonlight (client di streaming)"
if [ -d "/Applications/Moonlight.app" ]; then
  echo "  già installato"
else
  if command -v brew >/dev/null 2>&1; then
    brew install --cask moonlight
  else
    echo "  Homebrew assente: installa Moonlight da https://moonlight-stream.org"
  fi
fi

echo "==> CLI winfleet → $BIN_DIR/winfleet"
mkdir -p "$BIN_DIR"
# Un collegamento, non una copia: una copia resta indietro appena si tocca il
# sorgente, e ci si ritrova a provare per ore una versione che non e' quella che si
# sta scrivendo. Il comando risolve il link da solo per ritrovare host/ e mac/.
ln -sfn "$(pwd)/bin/winfleet" "$BIN_DIR/winfleet"

echo
echo "Fatto."
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "  ! Aggiungi al PATH:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
# L'agente che tiene una finestra sempre calda. Senza, la prima app di ogni
# sessione paga i quindici secondi di negoziazione dello stream; con, ne paga
# due. Sta qui e non nelle istruzioni perche' e' parte del prodotto: una cosa
# che va ricordata a mano, prima o poi non viene fatta.
if [ -f mac/com.winfleet.ready.plist ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  AGENT="$HOME/Library/LaunchAgents/com.winfleet.ready.plist"
  # Il plist nel repo porta i percorsi di chi l'ha scritto: qui si riscrivono
  # con quelli di questa macchina, altrimenti l'agente punta a una cartella che
  # non esiste e fallisce in silenzio a ogni giro.
  sed -e "s|<string>/Users/[^<]*/bin/winfleet</string>|<string>$BIN_DIR/winfleet</string>|" \
      -e "s|/Users/[^/]*/.config/winfleet|$HOME/.config/winfleet|g" \
      mac/com.winfleet.ready.plist > "$AGENT.tmp" && mv "$AGENT.tmp" "$AGENT"
  launchctl unload "$AGENT" 2>/dev/null || true
  if launchctl load "$AGENT" 2>/dev/null; then
    echo "  ✓ finestra sempre pronta (le app si aprono in ~2s invece di 15)"
  fi
fi

echo
echo "Prossimi passi:"
echo "  1) Sul Mac:                 winfleet setup   (indirizzi, nome mDNS, SSH)"
echo "  2)                          winfleet push    (script → C:\\winfleet sul PC)"
echo "  3) Sul PC Windows (admin):  setup.ps1 -WebPass '<password>'"
echo "                              setup-vdd.ps1 -Slots 2"
echo "                              wf-instance.ps1 -Slot 0   (e -Slot 1)"
echo "  4) Accoppia ogni finestra dalla GUI di Moonlight, poi:  winfleet scan"
echo "  5)                          winfleet search telegram"
