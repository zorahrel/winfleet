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
install -m 755 bin/winfleet "$BIN_DIR/winfleet"

echo
echo "Fatto."
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "  ! Aggiungi al PATH:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
echo
echo "Prossimi passi:"
echo "  1) Sul Mac:                 winfleet setup   (indirizzi, nome mDNS, SSH)"
echo "  2)                          winfleet push    (script → C:\\winfleet sul PC)"
echo "  3) Sul PC Windows (admin):  setup.ps1 -WebPass '<password>'"
echo "                              setup-vdd.ps1 -Slots 2"
echo "                              wf-instance.ps1 -Slot 0   (e -Slot 1)"
echo "  4) Accoppia ogni finestra dalla GUI di Moonlight, poi:  winfleet scan"
echo "  5)                          winfleet search telegram"
