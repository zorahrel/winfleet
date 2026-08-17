#!/usr/bin/env python3
"""Mette un distintivo di Windows sull'icona di un'app WinFleet.

Perche': nel Dock queste finestre sono indistinguibili dalle app native del Mac.
Hanno il nome dell'app, la sua icona, si ridimensionano e si minimizzano come le
altre - ed e' il punto del progetto - ma quando qualcosa va storto (il PC e'
spento, la rete cade) la differenza conta, e non c'e' niente che la mostri.

Il distintivo sta in basso a destra, dove macOS mette i badge, e occupa poco piu'
di un quarto del lato: abbastanza da leggersi a 32 punti nel Dock, abbastanza
poco da non coprire l'icona dell'app.

Uso:  wf-badge.py <sorgente.png> <destinazione.png>
"""

import sys
from PIL import Image, ImageDraw


def windows_logo(size):
    """Il quadrato a quattro riquadri, disegnato invece che caricato.

    Un PNG andrebbe versionato, tenuto allineato alle dimensioni e potrebbe
    mancare; qui la forma e' quattro rettangoli e si ridisegna a qualunque
    misura senza perdere nitidezza.
    """
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Cerchio di sfondo: separa il logo dall'icona sotto, che puo' essere di
    # qualsiasi colore. Bordo bianco per staccare anche su sfondi scuri.
    d.ellipse([0, 0, size - 1, size - 1], fill=(255, 255, 255, 255))
    pad = max(1, size // 12)
    d.ellipse([pad, pad, size - 1 - pad, size - 1 - pad], fill=(0, 120, 212, 255))

    # I quattro riquadri, con il taglio al centro.
    m = size * 0.28          # margine interno
    gap = max(1.0, size * 0.055)
    x0, y0 = m, m
    x1, y1 = size - m, size - m
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    w = (255, 255, 255, 255)
    d.rectangle([x0, y0, cx - gap / 2, cy - gap / 2], fill=w)
    d.rectangle([cx + gap / 2, y0, x1, cy - gap / 2], fill=w)
    d.rectangle([x0, cy + gap / 2, cx - gap / 2, y1], fill=w)
    d.rectangle([cx + gap / 2, cy + gap / 2, x1, y1], fill=w)
    return img


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    src = Image.open(sys.argv[1]).convert("RGBA")
    side = min(src.size)

    # Si lavora a una misura fissa e grande: l'icona sorgente puo' arrivare a
    # 32px da un exe vecchio, e ingrandire dopo aver composto il badge lo
    # sgranerebbe. Qui si ingrandisce prima, e il badge si disegna alla fine.
    target = 512
    if side != target:
        src = src.resize((target, target), Image.LANCZOS)

    badge_size = int(target * 0.42)
    badge = windows_logo(badge_size)

    off = target - badge_size - int(target * 0.02)
    src.alpha_composite(badge, (off, off))
    src.save(sys.argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main())
