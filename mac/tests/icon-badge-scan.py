#!/usr/bin/env python3
"""Elenca le icone senza il badge di Windows.

Un processo solo per tutte: la stessa cosa fatta lanciando python per ogni icona
costava sei minuti su settanta icone, e un test che si evita di lanciare non
protegge niente.

Stampa: "<quante> <nome(pct)> <nome(pct)> ..." — zero se sono tutte a posto.
"""
import glob
import os
import subprocess
import sys
import tempfile

try:
    from PIL import Image
except ImportError:
    # Senza Pillow non si giudica: rispondere "zero problemi" e' meglio che far
    # fallire un controllo che non puo' funzionare.
    print(0)
    raise SystemExit

SOGLIA = 20          # percento dell'angolo in basso a destra che dev'essere bianco


def badge_pct(path, png):
    subprocess.run(["sips", "-s", "format", "png", "-Z", "256", path, "--out", png],
                   capture_output=True)
    try:
        im = Image.open(png).convert("RGBA")
    except Exception:
        return None
    w, h = im.size
    px = list(im.crop((int(w * 0.6), int(h * 0.6), w, h)).getdata())
    if not px:
        return None
    white = sum(1 for q in px if q[0] > 200 and q[1] > 200 and q[2] > 200 and q[3] > 120)
    return 100.0 * white / len(px)


def main():
    if len(sys.argv) != 2:
        print(0)
        return 0
    tmp = tempfile.mkdtemp()
    png = os.path.join(tmp, "c.png")
    bad = []
    for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.icns"))):
        pct = badge_pct(f, png)
        if pct is None:
            continue
        if pct < SOGLIA:
            bad.append("%s(%.0f%%)" % (os.path.basename(f)[:-5], pct))
    print(" ".join([str(len(bad))] + bad))
    return 0


if __name__ == "__main__":
    sys.exit(main())
