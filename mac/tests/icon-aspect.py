#!/usr/bin/env python3
"""L'icona non deve mai uscire deformata, e nemmeno perdere il badge.

Il difetto vero: wf-badge portava l'icona a 512x512 forzando ENTRAMBI i lati.
Una sorgente 200x120 veniva stirata, e nel Dock si vedeva un logo schiacciato in
mezzo a icone sane - "a volte mi escono storte", senza un criterio apparente,
perche' dipende dall'icona che l'app di Windows si porta dietro.

Qui si passano forme diverse e si misura la deformazione sul risultato: un
cerchio disegnato tondo deve restare tondo. Il test e' costruito per essere
capace di fallire: con la vecchia riga resize((512,512)) il caso largo esce a
rapporto 0.6 e questo file torna non-zero.
"""
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("SKIP: manca Pillow")
    sys.exit(0)

ROOT = Path(__file__).resolve().parents[2]
BADGE = ROOT / "mac" / "wf-badge.py"
TMP = Path(subprocess.run(["mktemp", "-d"], capture_output=True, text=True).stdout.strip())

# Un cerchio: qualunque stiramento lo rende un ovale, e si misura senza ambiguita'.
CASI = [(256, 256), (200, 120), (120, 200), (44, 44), (620, 300)]

def tondo(path):
    """Rapporto larghezza/altezza del cerchio rosso dentro l'immagine."""
    im = Image.open(path).convert("RGBA")
    px = im.load()
    xs, ys = [], []
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if a > 100 and r > 180 and g < 80 and b < 80:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    return (max(xs) - min(xs) + 1) / (max(ys) - min(ys) + 1)

def badge_presente(path):
    """Il quadrato bianco in basso a destra: quattro riquadri, il logo Windows."""
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    ang = im.crop((int(w * 0.62), int(h * 0.62), w, h)).getdata()
    return sum(1 for p in ang if p[0] > 200 and p[1] > 200 and p[2] > 200 and p[3] > 120)

def badge_leggibile(path, lato):
    """Il badge si distingue a questa misura?

    Non basta "c'e' del bianco": a 16 px il disegno a quattro riquadri diventava
    una macchia chiara - il 72% del badge bianco, il blu quasi sparito - e nel
    Dock si vedeva un puntino sbiadito invece del segno di Windows.

    Il criterio e' che si veda il COLORE: un badge riconoscibile ha una quota
    consistente di blu. Sotto quella, qualunque cosa ci sia disegnata non si
    legge.
    """
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    b = max(8, round(w * 0.34))
    px = list(im.crop((w - b, h - b, w, h)).getdata())
    if not px:
        return 0.0
    blu = sum(1 for q in px if q[2] > 150 and q[0] < 100 and q[3] > 120)
    return 100.0 * blu / len(px)


esito = 0

# --- il badge deve leggersi a TUTTE le misure del Dock ---------------------
# 16 px e' Cmd-Tab e il Dock piccolo, 32 px il Dock normale: sono le misure a
# cui l'icona si guarda davvero, e sono quelle a cui un disegno pensato per 512
# si sfalda.
sorgente = TMP / "src_badge.png"
im = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
ImageDraw.Draw(im).ellipse([10, 10, 500, 500], fill=(90, 90, 90, 255))
im.save(sorgente)

for lato in (16, 32, 64, 128, 256):
    out = TMP / f"badge_{lato}.png"
    r = subprocess.run([sys.executable, str(BADGE), str(sorgente), str(out), str(lato)],
                       capture_output=True, text=True)
    if r.returncode != 0 or not out.exists():
        print(f"NO  badge a {lato}px: non prodotto ({r.stderr.strip()[:60]})")
        esito = 1
        continue
    blu = badge_leggibile(out, lato)
    if blu < 25:
        print(f"NO  badge a {lato}px: solo {blu:.0f}% di blu, non si distingue")
        esito = 1
    else:
        print(f"ok  badge a {lato}px: {blu:.0f}% di blu, si legge")

for w, h in CASI:
    src = TMP / f"src_{w}x{h}.png"
    out = TMP / f"out_{w}x{h}.png"
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    lato = min(w, h) - 8
    d.ellipse([4, 4, 4 + lato, 4 + lato], fill=(255, 0, 0, 255))
    im.save(src)

    r = subprocess.run([sys.executable, str(BADGE), str(src), str(out)],
                       capture_output=True, text=True)
    if r.returncode != 0 or not out.exists():
        print(f"NO  {w}x{h}: wf-badge non ha prodotto nulla ({r.stderr.strip()[:80]})")
        esito = 1
        continue

    rap = tondo(out)
    if rap is None:
        print(f"NO  {w}x{h}: il disegno e' sparito dal risultato")
        esito = 1
        continue
    if abs(rap - 1.0) > 0.06:
        print(f"NO  {w}x{h}: icona deformata, rapporto {rap:.3f} (atteso ~1.000)")
        esito = 1
        continue

    bianchi = badge_presente(out)
    if bianchi < 150:
        print(f"NO  {w}x{h}: manca il badge di Windows ({bianchi} pixel chiari)")
        esito = 1
        continue

    print(f"ok  {w}x{h}: rapporto {rap:.3f}, badge presente")

sys.exit(esito)
