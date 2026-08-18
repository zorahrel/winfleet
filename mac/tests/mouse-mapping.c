// Il click deve cadere dove punti, anche dopo un ridimensionamento.
//
// Il guasto: Moonlight calcola il rettangolo del video dentro la finestra
// partendo dalla forma della SORGENTE, e ci mette le bande ai lati quando le due
// forme non coincidono. Con il ritaglio quel conto era sbagliato due volte -
// la sorgente giusta e' il ritaglio (non lo schermo remoto intero), e il video
// occupa tutta la finestra (bande non ce ne sono mai, perche' il ritaglio segue
// la finestra).
//
// Usando lo schermo intero come sorgente, su una finestra 1200x700 il conto dava
// un video di 1050x700: il click finiva 85 pixel piu' a destra di dove si era
// puntato. L'errore cresce con la differenza di forma fra finestra e schermo
// remoto, cioe' compare proprio ridimensionando - e sparisce se per caso le
// proporzioni tornano a coincidere, il che lo rende difficile da inchiodare.
//
// Qui si riproduce l'aritmetica dei due punti che contano (scaleSourceToDestination
// e la mappatura del click) e si verifica su misure diverse che il punto colpito
// sia quello visto. Il test e' capace di fallire: con la sorgente sbagliata i
// casi non quadrati saltano.

#include <stdio.h>
#include <stdlib.h>

// Copia FEDELE di StreamUtils::scaleSourceToDestinationSurface (streamutils.cpp):
// il video entra nella finestra mantenendo il rapporto della SORGENTE, centrato.
// Riscriverla "a senso" non basta - la prima versione di questo test usava un
// arrotondamento diverso e non distingueva piu' il codice giusto da quello
// sbagliato, cioe' non provava niente.
#include <math.h>
static void fit(int sw, int sh, int *dx, int *dy, int *dw, int *dh) {
    int dstH = (int)ceilf((float)(*dw) * sh / sw);
    int dstW = (int)ceilf((float)(*dh) * sw / sh);
    if (dstH > *dh) {
        *dx += (*dw - dstW) / 2;
        *dw = dstW;
    } else {
        *dy += (*dh - dstH) / 2;
        *dh = dstH;
    }
}

// Dove finisce sul PC un click a (px,py) nella finestra.
static void click_to_host(int px, int py, int cropX, int cropY, int cropW, int cropH,
                          int srcW, int srcH, int winW, int winH, int *hx, int *hy) {
    int dx = 0, dy = 0, dw = winW, dh = winH;
    fit(srcW, srcH, &dx, &dy, &dw, &dh);
    int x = px - dx; if (x < 0) x = 0; if (x > dw) x = dw;
    int y = py - dy; if (y < 0) y = 0; if (y > dh) y = dh;
    *hx = cropX + (int)((long long)x * cropW / dw);
    *hy = cropY + (int)((long long)y * cropH / dh);
}

// Il pixel che l'utente VEDE in (px,py): il ritaglio disegnato su tutta la
// finestra, senza bande.
static void visto(int px, int py, int cropX, int cropY, int cropW, int cropH,
                  int winW, int winH, int *vx, int *vy) {
    *vx = cropX + (int)((long long)px * cropW / winW);
    *vy = cropY + (int)((long long)py * cropH / winH);
}

int main(void) {
    struct { const char *nome; int cx, cy, cw, ch, ww, wh; } casi[] = {
        { "quadrata come lo schermo", 0, 0, 1800, 1200, 1800, 1200 },
        { "larga e bassa",            0, 0, 1600,  700, 1600,  700 },
        { "alta e stretta",           0, 0,  900, 1000,  900, 1000 },
        { "dopo un ingrandimento",    0, 0, 1589,  806, 1589,  806 },
        { "ritaglio spostato",      100, 50, 1200,  700, 1200,  700 },
    };
    const int SCHERMO_W = 1800, SCHERMO_H = 1200;

    int peggio_giusto = 0, peggio_sbagliato = 0;
    for (unsigned i = 0; i < sizeof casi / sizeof casi[0]; i++) {
        // I punti si prendono anche a UN QUARTO e a TRE QUARTI, non solo agli
        // angoli e al centro: l'errore di questa mappatura e' nullo al centro e
        // sui bordi, e massimo proprio in mezzo. Con i soli tre punti "ovvi" il
        // test passava anche col codice sbagliato - cioe' non provava niente.
        int punti[5][2] = {
            {0, 0},
            {casi[i].ww / 4, casi[i].wh / 4},
            {casi[i].ww / 2, casi[i].wh / 2},
            {casi[i].ww * 3 / 4, casi[i].wh * 3 / 4},
            {casi[i].ww - 1, casi[i].wh - 1},
        };
        for (int k = 0; k < 5; k++) {
            int px = punti[k][0], py = punti[k][1];
            int vx, vy; visto(px, py, casi[i].cx, casi[i].cy, casi[i].cw, casi[i].ch,
                              casi[i].ww, casi[i].wh, &vx, &vy);

            // GIUSTO: la sorgente e' il ritaglio
            int gx, gy;
            click_to_host(px, py, casi[i].cx, casi[i].cy, casi[i].cw, casi[i].ch,
                          casi[i].cw, casi[i].ch, casi[i].ww, casi[i].wh, &gx, &gy);
            int eg = abs(gx - vx) > abs(gy - vy) ? abs(gx - vx) : abs(gy - vy);
            if (eg > peggio_giusto) peggio_giusto = eg;

            // SBAGLIATO: la sorgente e' lo schermo remoto intero (il codice di prima)
            int sx, sy;
            click_to_host(px, py, casi[i].cx, casi[i].cy, casi[i].cw, casi[i].ch,
                          SCHERMO_W, SCHERMO_H, casi[i].ww, casi[i].wh, &sx, &sy);
            int es = abs(sx - vx) > abs(sy - vy) ? abs(sx - vx) : abs(sy - vy);
            if (es > peggio_sbagliato) peggio_sbagliato = es;

            if (eg > 1) {
                printf("  %-26s click (%4d,%4d): colpito (%d,%d), visto (%d,%d) -> %d px\n",
                       casi[i].nome, px, py, gx, gy, vx, vy, eg);
            }
        }
    }

    printf("ERRORE_CORRETTO: %d\n", peggio_giusto);
    printf("ERRORE_VECCHIO: %d\n", peggio_sbagliato);

    // Il test deve provare due cose: che la formula giusta non sbaglia, e che
    // quella di prima sbagliava - altrimenti non sta misurando niente.
    if (peggio_giusto > 1) { printf("ESITO: FAIL (la mappatura corretta sbaglia)\n"); return 1; }
    if (peggio_sbagliato < 10) { printf("ESITO: FAIL (il test non discrimina)\n"); return 1; }
    printf("ESITO: PASS\n");
    return 0;
}
