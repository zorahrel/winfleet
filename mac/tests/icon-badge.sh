#!/opt/homebrew/bin/bash
# Le icone che l'utente guarda devono avere il badge, ed essere quelle giuste.
#
# Due guasti veri, entrambi rimasti in giro per giorni perche' nessuno li
# controllava:
#
# 1. Un'icona senza badge di Windows. Il badge lo mette wf-badge.py, che puo'
#    fallire in silenzio: l'icona viene scritta lo stesso e da quel momento resta
#    cosi' per sempre, perche' il criterio normale e' "il file c'e', vado avanti".
#    Telegram aveva un badge grande UN SETTIMO di quello delle altre app.
#
# 2. Il RUNNER con un'icona vecchia. Il lanciatore e' l'icona su cui si clicca; il
#    runner e' il bundle da cui parte lo stream, cioe' quello che si vede nel Dock
#    mentre l'app e' aperta - per tutto il tempo in cui la si usa. Erano
#    disallineati tutti e otto.
#
# E una trappola che il secondo fix porta con se': cambiare un file dentro un
# bundle firmato ne rompe la firma, e su Apple Silicon quel bundle non parte piu'.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0
ICONS="$HOME/.config/winfleet/icons"
RUNNERS="$HOME/.config/winfleet/runners"
LAUNCHERS="$HOME/Applications/WinFleet"

# --- 1. la misura del badge sa distinguere ---------------------------------
# Si costruiscono due icone finte: una col badge, una senza. Se la funzione le
# giudica uguali non sta misurando niente.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp" <<'PY' 2>/dev/null || { echo "  SKIP: manca Pillow"; exit 0; }
import sys
from PIL import Image, ImageDraw
d = sys.argv[1]
# senza badge: un cerchio rosso e basta
a = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
ImageDraw.Draw(a).ellipse([20, 20, 490, 490], fill=(200, 30, 30, 255))
a.save(f"{d}/senza.png")
# col badge: lo stesso, piu' il quadrato bianco in basso a destra
b = a.copy()
ImageDraw.Draw(b).rectangle([300, 300, 500, 500], fill=(255, 255, 255, 255))
b.save(f"{d}/con.png")
PY

for v in senza con; do
  mkdir -p "$tmp/$v.iconset"
  for s in 16 32 128 256; do
    sips -z "$s" "$s" "$tmp/$v.png" --out "$tmp/$v.iconset/icon_${s}x${s}.png" >/dev/null 2>&1
  done
  iconutil -c icns "$tmp/$v.iconset" -o "$tmp/$v.icns" >/dev/null 2>&1
done

pct_con="$(/opt/homebrew/bin/bash -c 'source bin/winfleet 2>/dev/null; icns_badge_pct "'"$tmp"'/con.icns"' 2>/dev/null | tail -1)"
pct_senza="$(/opt/homebrew/bin/bash -c 'source bin/winfleet 2>/dev/null; icns_badge_pct "'"$tmp"'/senza.icns"' 2>/dev/null | tail -1)"

if [ "${pct_con:-0}" -ge 20 ] 2>/dev/null && [ "${pct_senza:-100}" -lt 20 ] 2>/dev/null; then
  echo "  ok   misura del badge: con=${pct_con}% senza=${pct_senza}% (soglia 20%)"
else
  echo "  NO   misura del badge non discrimina: con=${pct_con:-?}% senza=${pct_senza:-?}%"
  fail=1
fi

# --- 2. le icone vere hanno tutte il badge ---------------------------------
# Tutte le icone in un SOLO processo python: farne partire uno per icona, su
# settanta icone, costava sei minuti - e un test che si evita di lanciare non
# protegge niente. Cosi' sono pochi secondi.
esito="$(python3 mac/tests/icon-badge-scan.py "$ICONS" 2>/dev/null || echo 0)"
senza_badge="${esito%% *}"
nomi=""
[ "$senza_badge" != "$esito" ] && nomi=" ${esito#* }"
if [ "$senza_badge" = 0 ]; then
  echo "  ok   badge: tutte le icone del catalogo ce l'hanno"
else
  echo "  NO   badge: $senza_badge icone senza -$nomi"
  fail=1
fi

# --- 3. runner e lanciatori allineati al catalogo ---------------------------
diff_runner=0; diff_launch=0
for a in "$RUNNERS"/*.app; do
  [ -d "$a" ] || continue
  n="$(basename "$a" .app)"
  [ -f "$ICONS/$n.icns" ] || continue
  cmp -s "$ICONS/$n.icns" "$a/Contents/Resources/moonlight.icns" || diff_runner=$(( diff_runner + 1 ))
done
for a in "$LAUNCHERS"/*.app; do
  [ -d "$a" ] || continue
  n="$(basename "$a" .app)"
  [ -f "$ICONS/$n.icns" ] || continue
  cmp -s "$ICONS/$n.icns" "$a/Contents/Resources/icon.icns" || diff_launch=$(( diff_launch + 1 ))
done
if [ "$diff_runner" = 0 ] && [ "$diff_launch" = 0 ]; then
  echo "  ok   icone allineate: runner e lanciatori hanno quelle del catalogo"
else
  echo "  NO   icone vecchie: $diff_runner runner, $diff_launch lanciatori"
  fail=1
fi

# --- 4. i bundle sono firmati ----------------------------------------------
# Cambiare l'icona dentro un bundle ne rompe la firma, e su Apple Silicon quel
# bundle non parte piu': un'icona giusta su un'app che non si apre e' un pessimo
# affare.
rotte=0
for a in "$RUNNERS"/*.app; do
  [ -d "$a" ] || continue
  codesign -v "$a" >/dev/null 2>&1 || rotte=$(( rotte + 1 ))
done
if [ "$rotte" = 0 ]; then
  echo "  ok   firme: tutti i runner partono"
else
  echo "  NO   firme: $rotte runner con la firma rotta (non partirebbero)"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
