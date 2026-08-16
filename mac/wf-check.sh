#!/usr/bin/env bash
# Verifica che una finestra di winfleet mostri immagine vera e non un rettangolo nero.
#
# Serve a poter dire "funziona" con una misura invece che con un'occhiata: lo stream
# puo' connettersi, decodificare e restare nero — crop che punta a un'area vuota,
# app fuori dal rettangolo, perdita UDP che rende ogni frame irrecuperabile (il
# firewall di Windows che marca la scheda come "Pubblica" fa esattamente questo), o
# sessione di Windows bloccata. Misurare l'immagine distingue i casi senza guardare
# lo schermo, e cattura solo la finestra: il desktop intero contiene quasi sempre
# roba che non c'entra col programma.
#
# La misura: si riduce la finestra a 8x8 e si leggono i pixel veri. Media bassa e
# uniforme = nero; media alta senza variazione = tinta piatta, che e' comunque un
# guasto. Contare i byte del file non funziona — un PNG e' compresso e un TIFF ha
# header e padding, quindi anche un'immagine tutta nera restituisce byte "chiari":
# provato, dava 92% di "pixel accesi" su un rettangolo interamente nero.
#
# I due criteri sono separati perche' una finestra puo' essere legittimamente scura:
# un terminale e' nero con qualche riga di testo e fa media 16, che il solo criterio
# di luminosita' bocciava. Quello che distingue una finestra vuota da una scura ma
# piena e' la VARIAZIONE fra le celle.
set -uo pipefail
soglia="${1:-6}"    # luminosita' media minima (0-255)

work=$(mktemp -d -t wfcheck)
trap 'rm -rf "$work"' EXIT

# La geometria si chiede a CoreGraphics, non ad AppleScript: System Events richiede
# il permesso di Accessibilita', che macOS revoca ogni volta che il binario cambia
# firma — e Moonlight viene rifirmato a ogni build. Quando succede osascript non
# fallisce in modo visibile, risponde vuoto: il controllo diceva "nessuna finestra
# aperta" con la finestra davanti agli occhi.
cat > "$work/geom.py" <<'PYEOF'
import subprocess, sys
try:
    import Quartz
except ImportError:
    # Senza PyObjC si ripiega su AppleScript, che pero' puo' non avere il permesso.
    r = subprocess.run(['osascript', '-e',
        'tell application "System Events" to tell process "Moonlight" '
        'to get {position, size} of window 1'], capture_output=True, text=True)
    v = r.stdout.strip().replace(' ', '')
    print(v if v.count(',') == 3 else '')
    sys.exit(0)

best = None
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly,
                                           Quartz.kCGNullWindowID) or []:
    if 'Moonlight' not in str(w.get('kCGWindowOwnerName', '')):
        continue
    b = w.get('kCGWindowBounds') or {}
    area = b.get('Width', 0) * b.get('Height', 0)
    # Sopra i 40.000 punti quadrati: sotto ci sono solo pannelli e tooltip.
    if area > 40000 and (best is None or area > best[0]):
        best = (area, b)

if best:
    b = best[1]
    print('%d,%d,%d,%d' % (b['X'], b['Y'], b['Width'], b['Height']))
else:
    print('')
PYEOF

geom=$(python3 "$work/geom.py" 2>/dev/null)
if [ -z "$geom" ]; then
  # Distinguere "non c'e' nessuna finestra" da "non riesco a vederla" e' l'unica
  # cosa che conta qui: il primo e' un guasto di winfleet, il secondo un permesso
  # mancante di CHI ESEGUE questo controllo. Confonderli manda a cercare un difetto
  # dove non c'e'.
  if pgrep -f "winfleet/runners/" >/dev/null 2>&1; then
    echo "lo stream gira ma non riesco a leggerne la finestra"
    echo "  (serve Registrazione schermo per il terminale: Impostazioni → Privacy)"
    exit 3
  fi
  echo "nessuna finestra di stream aperta"; exit 2
fi
IFS=, read -r x y w h <<<"$geom"
[ -n "${h:-}" ] || { echo "geometria illeggibile: $geom"; exit 2; }

screencapture -x -o -R"$x,$y,$w,$h" "$work/win.png" 2>/dev/null
[ -s "$work/win.png" ] || { echo "non riesco a catturare la finestra"; exit 2; }

cat > "$work/measure.py" <<'PYEOF'
import subprocess, struct, sys
w = sys.argv[1]
subprocess.run(['sips', '-z', '8', '8', '-s', 'format', 'png',
                f'{w}/win.png', '--out', f'{w}/s.png'], capture_output=True, check=True)
# sips non scrive su stdout: serve un file vero.
subprocess.run(['sips', '-s', 'format', 'bmp',
                f'{w}/s.png', '--out', f'{w}/s.bmp'], capture_output=True, check=True)
d    = open(f'{w}/s.bmp', 'rb').read()
off  = struct.unpack('<I', d[10:14])[0]
step = struct.unpack('<H', d[28:30])[0] // 8
px   = d[off:]
vals = [px[i] for i in range(0, len(px) - step, step)] or [0]
m    = sum(vals) / len(vals)
print('%.1f %.1f' % (m, (sum((v - m) ** 2 for v in vals) / len(vals)) ** 0.5))
PYEOF

read -r avg dev <<<"$(python3 "$work/measure.py" "$work")"
[ -n "${dev:-}" ] || { echo "non riesco a misurare l'immagine"; exit 2; }

printf 'finestra %sx%s  luminosita media %s  variazione %s  ' "$w" "$h" "$avg" "$dev"
awk -v a="$avg" -v d="$dev" -v s="$soglia" 'BEGIN{
  if (d+0 >= 8)              { print "✓ immagine presente"; exit 0 }   # contenuto vero, anche scuro
  if (a+0 >= s+0 && d+0 >= 3){ print "✓ immagine presente"; exit 0 }   # chiara e non piatta
  if (a+0 <  s+0)            { print "✗ schermo nero"; exit 1 }
  print "✗ tinta piatta, nessun contenuto"; exit 1 }'
