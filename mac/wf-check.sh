#!/usr/bin/env bash
# Verifica che una finestra di winfleet mostri immagine vera e non un rettangolo nero.
#
# Serve a poter dire "funziona" con una misura invece che con un'occhiata: lo stream
# puo' connettersi, decodificare e restare nero — crop che punta a un'area vuota,
# app fuori dal rettangolo, o perdita UDP che rende ogni frame irrecuperabile (il
# firewall di Windows che marca la scheda come "Pubblica" fa esattamente questo).
# Misurare l'immagine distingue i due casi senza guardare lo schermo, e cattura solo
# la finestra: il desktop intero contiene quasi sempre roba che non c'entra.
#
# La misura: si riduce la finestra a 8x8 e si leggono i pixel veri. Media bassa =
# nero; media alta ma variazione nulla = tinta piatta, che e' comunque un guasto.
# Contare i byte del file non funziona — un PNG e' compresso e un TIFF ha header e
# padding, quindi anche un'immagine tutta nera restituisce byte "chiari": provato,
# dava 92% di "pixel accesi" su un rettangolo interamente nero.
set -euo pipefail
soglia="${1:-6}"    # luminosita' media minima (0-255)

geom=$(osascript -e 'tell application "System Events" to tell process "Moonlight" to get {position, size} of window 1' 2>/dev/null | tr -d ' ') || {
  echo "nessuna finestra di stream aperta"; exit 2; }
IFS=, read -r x y w h <<<"$geom"
[ -n "${h:-}" ] || { echo "geometria illeggibile: $geom"; exit 2; }

work=$(mktemp -d -t wfcheck)
trap 'rm -rf "$work"' EXIT
screencapture -x -o -R"$x,$y,$w,$h" "$work/win.png"

read -r avg dev <<<"$(python3 - "$work" <<'PY'
import subprocess, struct, sys
w = sys.argv[1]
subprocess.run(['sips','-z','8','8','-s','format','png',f'{w}/win.png','--out',f'{w}/s.png'],
               capture_output=True, check=True)
subprocess.run(['sips','-s','format','bmp',f'{w}/s.png','--out',f'{w}/s.bmp'],
               capture_output=True, check=True)          # sips non scrive su stdout
d   = open(f'{w}/s.bmp','rb').read()
off = struct.unpack('<I', d[10:14])[0]
step = struct.unpack('<H', d[28:30])[0] // 8
px  = d[off:]
vals = [px[i] for i in range(0, len(px)-step, step)] or [0]
m    = sum(vals)/len(vals)
print('%.1f %.1f' % (m, (sum((v-m)**2 for v in vals)/len(vals))**0.5))
PY
)"

printf 'finestra %sx%s  luminosita media %s  variazione %s  ' "$w" "$h" "$avg" "$dev"
# Due criteri, non uno. La luminosita' da sola boccia le finestre legittimamente
# scure: un terminale e' nero con qualche riga di testo, e faceva media 16 —
# "schermo nero" secondo il controllo, ma sullo schermo si legge benissimo.
# Quello che distingue una finestra vuota da una scura ma piena e' la VARIAZIONE fra
# le celle: un rettangolo nero e' uniforme, un terminale no.
awk -v a="$avg" -v d="$dev" -v s="$soglia" 'BEGIN{
  if (d+0 >= 8)             { print "✓ immagine presente"; exit 0 }   # contenuto vero
  if (a+0 >= s+0 && d+0 >=3){ print "✓ immagine presente"; exit 0 }   # chiara e non piatta
  if (a+0 <  s+0)           { print "✗ schermo nero"; exit 1 }
  print "✗ tinta piatta, nessun contenuto"; exit 1 }'
