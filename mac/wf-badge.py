#!/usr/bin/env python3
"""Mette un distintivo di Windows sull'icona di un'app WinFleet.

Perche': nel Dock queste finestre sono indistinguibili dalle app native del Mac.
Hanno il nome dell'app, la sua icona, si ridimensionano e si minimizzano come le
altre - ed e' il punto del progetto - ma quando qualcosa va storto (il PC e'
spento, la rete cade) la differenza conta, e non c'e' niente che la mostri.

Due cose che questo file fa e che sembrano dettagli:

1. Il badge si RIDISEGNA a ogni misura, invece di essere disegnato grande e
   rimpicciolito. Un logo a quattro riquadri ridotto da 512 a 32 px diventa una
   macchia grigia: i riquadri finiscono sotto il pixel e si fondono fra loro.
   Ridisegnandolo, a 32 px si sceglie una forma piu' semplice che a quella
   misura si legge ancora.

2. Sotto una certa soglia il dettaglio si TOGLIE, non si rimpicciolisce. E' la
   stessa scelta che fa macOS con le sue icone di sistema: a 16 px non c'e' un
   disegno in miniatura, c'e' un disegno diverso.

Uso:
    wf-badge.py <sorgente.png> <destinazione.png> [misura]

Senza misura si lavora a 512, che e' il caso di chi compone una volta sola.
Con la misura si ottiene direttamente l'icona di quel lato, gia' composta - ed
e' cosi' che va usato per generare un .icns: una chiamata per ogni misura.
"""

import sys

from PIL import Image, ImageDraw


# Il blu di Windows. Non un blu qualsiasi: e' quello del logo, e su un'icona
# accanto alle app di sistema la differenza si nota.
BLU = (0, 120, 212, 255)
BIANCO = (255, 255, 255, 255)


def windows_logo(size):
    """Il distintivo, disegnato alla misura richiesta.

    Non si carica un PNG: andrebbe versionato, tenuto allineato alle misure e
    potrebbe mancare. Qui la forma e' geometria pura e si ridisegna a qualunque
    lato senza perdere nitidezza.
    """
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    if size < 12:
        # Sotto i 12 px non c'e' spazio per un disco CON dentro un disegno: il
        # bordo bianco prende due pixel, l'antialiasing del cerchio ne prende
        # altri, e quello che resta e' una macchia bianca - misurato, il 72% del
        # badge finiva bianco e il blu spariva.
        #
        # A questa misura si tiene solo il colore: un quadrato blu con l'angolo
        # smussato, che nel Dock si legge come "c'e' un segno, ed e' blu". Nessun
        # dettaglio, perche' nessun dettaglio sopravviverebbe.
        d.rounded_rectangle([0, 0, size - 1, size - 1],
                            radius=max(1, size // 4), fill=BLU, outline=BIANCO, width=1)
        return img

    # Il disco: separa il logo dall'icona sotto, che puo' essere di qualsiasi
    # colore. L'anello bianco lo stacca anche su sfondi chiari - senza, su
    # un'icona bianca il badge sparisce.
    #
    # L'anello e' spesso almeno un pixel a QUALUNQUE misura: a 12 px un bordo
    # calcolato in proporzione verrebbe zero e il disco si confonderebbe con
    # l'icona.
    bordo = max(1, round(size * 0.08))
    d.ellipse([0, 0, size - 1, size - 1], fill=BIANCO)
    d.ellipse([bordo, bordo, size - 1 - bordo, size - 1 - bordo], fill=BLU)

    # Lo spazio utile per il disegno DENTRO il disco, non dentro il quadrato che
    # lo contiene: il cerchio all'altezza degli angoli e' piu' stretto, e un
    # margine calcolato sul quadrato lascia il disegno a filo dell'anello. A 22 px
    # i riquadri toccavano il bordo bianco e il badge sembrava una macchia.
    m = size * 0.32
    x0, y0 = m, m
    x1, y1 = size - m, size - m
    largh = x1 - x0

    if largh < 6:
        # Troppo piccolo per quattro riquadri separati: a questa misura ogni
        # riquadro sarebbe sotto il pixel e i quattro si fonderebbero in una
        # macchia chiara, che e' peggio di niente. Si tiene la silhouette - un
        # quadrato pieno - che a 10 px si legge ancora come "una finestra".
        d.rectangle([x0, y0, x1, y1], fill=BIANCO)
        return img

    # I quattro riquadri, con il taglio a croce. Il taglio e' almeno un pixel:
    # sotto, i riquadri si toccano e il logo diventa un quadrato pieno per
    # arrotondamento invece che per scelta.
    gap = max(1.0, size * 0.06)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    d.rectangle([x0, y0, cx - gap / 2, cy - gap / 2], fill=BIANCO)
    d.rectangle([cx + gap / 2, y0, x1, cy - gap / 2], fill=BIANCO)
    d.rectangle([x0, cy + gap / 2, cx - gap / 2, y1], fill=BIANCO)
    d.rectangle([cx + gap / 2, cy + gap / 2, x1, y1], fill=BIANCO)
    return img


def componi(src, lato):
    """L'icona dell'app con il distintivo, al lato richiesto."""
    # Il lato lungo va alla misura piena e l'altro segue in proporzione, poi si
    # centra. Forzare entrambi i lati stira: un'icona 200x120 diventava un logo
    # schiacciato accanto a icone sane, ed e' un difetto che si nota subito
    # perche' capita solo ad alcune app.
    w, h = src.size
    if (w, h) != (lato, lato):
        scala = lato / max(w, h)
        nw, nh = max(1, round(w * scala)), max(1, round(h * scala))
        ridotta = src.resize((nw, nh), Image.LANCZOS)
        base = Image.new("RGBA", (lato, lato), (0, 0, 0, 0))
        base.alpha_composite(ridotta, ((lato - nw) // 2, (lato - nh) // 2))
    else:
        base = src.copy()

    # Un terzo del lato, non il 42% di prima: il badge copriva un quarto dei
    # pixel visibili dell'icona - misurato - e a quel punto non e' piu' un
    # distintivo, e' un'altra icona sopra la prima. Per confronto, il badge
    # degli alias di macOS sta al 16%, ma quello e' una freccia: qui serve piu'
    # spazio perche' il disegno ha quattro parti.
    badge = max(8, round(lato * 0.34))

    # Staccato dal bordo di un soffio, come i badge di sistema. A misure piccole
    # il margine sparisce: un pixel di stacco a 16 px e' il 6% del lato, cioe'
    # tanto quanto il disegno stesso.
    margine = round(lato * 0.02) if lato >= 64 else 0

    logo = windows_logo(badge)
    base.alpha_composite(logo, (lato - badge - margine, lato - badge - margine))
    return base


def main():
    if len(sys.argv) not in (3, 4):
        print(__doc__.strip(), file=sys.stderr)
        return 2

    lato = 512
    if len(sys.argv) == 4:
        try:
            lato = int(sys.argv[3])
        except ValueError:
            print("La misura dev'essere un numero.", file=sys.stderr)
            return 2
        if lato < 8 or lato > 2048:
            print("Misura fuori scala (8-2048).", file=sys.stderr)
            return 2

    src = Image.open(sys.argv[1]).convert("RGBA")
    componi(src, lato).save(sys.argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main())
