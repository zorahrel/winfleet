// Toglie la barra del titolo di macOS e tiene la finestra della misura giusta.
//
// Due problemi, una sola causa: la finestra non e' nostra, e' una NSWindow del
// processo Moonlight.
//
// 1. L'app di Windows disegna gia' la sua barra dentro l'area client (Telegram, Edge
//    e chiunque abbia un frame proprio), e da lato Windows non si toglie: restavano
//    due barre, una sopra l'altra. Quella di troppo e' quella del Mac.
//
// 2. Moonlight ridimensiona la finestra da solo (Session::getWindowDimensions): se lo
//    stream non entra nei limiti dello schermo che SDL crede attivo, la rifa' all'80%
//    di quello schermo — anche molto dopo averla aperta della misura giusta, e anche
//    quando lo schermo giusto sarebbe un altro. Da fuori quella correzione e'
//    indistinguibile da un ridimensionamento dell'utente, e rincorrerla con
//    AppleScript significa o litigare con l'utente o subire Moonlight.
//
// Da dentro invece si distingue: un trascinamento dell'utente e' un *live resize*,
// una correzione di Moonlight no. Quindi la misura voluta la si tiene e la si
// ripristina solo quando a cambiarla non e' stato l'utente; quando invece e' stato
// lui, la nuova misura diventa quella voluta. Le proporzioni le fa rispettare Cocoa
// (setContentAspectRatio), che vincola il trascinamento senza combatterlo.
//
// Funziona perche' WinFleet lancia una PROPRIA copia di Moonlight, rifirmata ad-hoc:
// l'originale ha il runtime irrigidito e l'iniezione verrebbe (giustamente) rifiutata.
//
//   clang -dynamiclib -framework Cocoa -o wf-chrome.dylib wf-chrome.m
//
// Ambiente: WF_WIN=<larghezza>x<altezza> (misura voluta e proporzioni da tenere),
//           WF_CHROME=native per lasciare la barra dov'e'.

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

static const char *kSeen  = "wf_seen";
static const char *kWant  = "wf_want";

static NSSize gAsked = {0, 0};      // misura chiesta da WinFleet
static BOOL   gKeepChrome = NO;
static BOOL   gLocalCursor = YES;   // WF_CURSOR=remote per tenere solo quello di Windows
static const char *gSizeFile = NULL; // dove annotare la misura corrente
static const char *gCropFile = NULL; // rettangolo da mostrare, per il client

// Chi sta fuori deve sapere quanto e' grande la finestra per far seguire la
// risoluzione di Windows, e chiederlo con AppleScript costa decine di millisecondi
// a colpo — troppo, per una cosa da guardare dieci volte al secondo. Qui il dato
// c'e' gia': si scrive e basta.
static void publish(NSSize s) {
    int w = (int)lround(s.width), h = (int)lround(s.height);
    if (gSizeFile) {
        FILE *f = fopen(gSizeFile, "w");
        if (f) { fprintf(f, "%dx%d\n", w, h); fclose(f); }
    }
    // Il rettangolo che il client deve mostrare. L'app sta nell'angolo in alto a
    // sinistra dello schermo virtuale, quindi coincide con la finestra. Scriverlo qui
    // e non da fuori e' il motivo per cui segue il trascinamento senza ritardo: qui
    // l'evento arriva mentre trascini, fuori bisognerebbe andarlo a chiedere.
    if (gCropFile) {
        FILE *f = fopen(gCropFile, "w");
        if (f) { fprintf(f, "0 0 %d %d\n", w, h); fclose(f); }
    }
}

static NSSize wantOf(NSWindow *w) {
    NSValue *v = objc_getAssociatedObject(w, kWant);
    return v ? [v sizeValue] : NSZeroSize;
}
static void setWant(NSWindow *w, NSSize s) {
    objc_setAssociatedObject(w, kWant, [NSValue valueWithSize:s], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Solo la finestra dello stream. Moonlight e' un programma Qt che apre una finestra
// sua (la QML) prima di quella del video: toccarla — ridimensionarla, cambiarle lo
// stile — blocca l avvio, e da fuori le due si assomigliano perche' sono entrambe
// intitolate e visibili. Si distinguono dalla classe: quelle di Qt sono QNSWindow,
// quella del video la crea SDL.
static BOOL isStreamWindow(NSWindow *w) {
    if (!w || !(w.styleMask & NSWindowStyleMaskTitled) || !w.isVisible) return NO;
    NSString *cls = NSStringFromClass([w class]);
    if ([cls hasPrefix:@"QNS"] || [cls containsString:@"Qt"]) return NO;
    return YES;
}

static void adopt(NSWindow *w) {
    if (!isStreamWindow(w)) return;
    if (objc_getAssociatedObject(w, kSeen)) return;
    objc_setAssociatedObject(w, kSeen, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!gKeepChrome) {
        // La barra resta (serve per trascinare e per i tre pulsanti) ma diventa
        // trasparente e il contenuto le passa sotto: il video occupa tutta la
        // finestra e di barre ne resta una sola, quella dell'app.
        w.titlebarAppearsTransparent = YES;
        w.titleVisibility = NSWindowTitleHidden;
        w.styleMask |= NSWindowStyleMaskFullSizeContentView;
    }

    NSSize want = (gAsked.width > 0) ? gAsked : w.frame.size;
    setWant(w, want);
    if (gAsked.width > 0) {
        // Nessun vincolo di proporzioni: con il ritaglio la finestra puo' prendere
        // qualsiasi forma, perche' quello che si vede e' esattamente la finestra
        // dell'app su Windows e non un'immagine da far entrare in una cornice.
        NSRect f = w.frame;
        if (fabs(f.size.width - want.width) > 1 || fabs(f.size.height - want.height) > 1) {
            f.origin.y += f.size.height - want.height;   // l'angolo in alto resta fermo
            f.size = want;
            [w setFrame:f display:YES];
        }
        publish(want);
    }
}

static void onResize(NSNotification *n) {
    NSWindow *w = n.object;
    if (!isStreamWindow(w)) return;
    NSSize want = wantOf(w);
    if (want.width <= 0) return;

    if (w.inLiveResize) {
        setWant(w, w.frame.size);       // sta trascinando l'utente: comanda lui
        publish(w.frame.size);
        return;
    }
    NSSize now = w.frame.size;
    if (fabs(now.width - want.width) < 1 && fabs(now.height - want.height) < 1) return;

    // Non e' stato l'utente: e' Moonlight che si e' rifatto i conti. Si rimette.
    NSRect f = w.frame;
    f.origin.y += f.size.height - want.height;
    f.size = want;
    [w setFrame:f display:YES];
}

static void sweep(void) {
    for (NSWindow *w in [NSApp windows]) adopt(w);
}

// Il puntatore del Mac dentro la finestra.
//
// Sunshine disegna il cursore di Windows dentro il video, e Moonlight nasconde
// quello locale: si finisce per guardare una freccia che e' un'immagine, quindi
// arriva sempre in ritardo di un viaggio di rete. Su una finestra che si usa per
// lavorare (non per giocare) il ritardo si sente su ogni click.
//
// La versione di Sunshine installata non ha capture_cursor — controllato nelle
// stringhe del binario: c'e' solo nel fork di AlkaidLab — quindi il cursore remoto
// non si puo' spegnere dall'host. Ma il puntatore locale si puo' rimettere: e'
// istantaneo perche' lo disegna macOS, e da' la sensazione giusta anche se sotto ne
// resta uno finto che lo insegue.
//
// Si mostra solo dentro l'area del video, e solo se il puntatore e' davvero li':
// forzarlo sempre visibile lo farebbe comparire anche sopra altre finestre.
static void showLocalCursor(void) {
    static BOOL shown = NO;
    NSWindow *w = nil;
    for (NSWindow *x in [NSApp windows]) if (isStreamWindow(x) && x.isKeyWindow) { w = x; break; }
    if (!w) { if (shown) { [NSCursor unhide]; shown = NO; } return; }
    if (!shown) { [NSCursor unhide]; shown = YES; }
}

// I tre pulsanti si vedono ma non rispondono al mouse: con il contenuto a tutta
// finestra la vista di SDL li copre, e SDL prende gli eventi a livello di finestra —
// sopra AppKit, quindi non e' questione di ordine delle viste. Il risultato e'
// peggio che non averli: si prova a chiudere e invece si clicca dentro Windows.
//
// Provato e scartato: rimettere i pulsanti in cima al theme frame (l'ordine si
// ristabilisce al primo ridisegno) e restringere la vista del video sotto la barra
// (il click continua ad arrivare a SDL).
//
// Quello che regge e' guardare gli eventi prima che li veda chiunque altro: un
// monitor locale gira all'inizio della catena, dentro questo processo. Se il click
// cade su uno dei pulsanti lo si esegue e si toglie l'evento di mezzo (ritornando
// nil), cosi' SDL non lo vede nemmeno; tutto il resto passa intatto e lo stream
// continua a ricevere il mouse come prima.
static void watchTitlebarClicks(void) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                          handler:^NSEvent *(NSEvent *e) {
        NSWindow *w = e.window;
        if (!isStreamWindow(w)) return e;

        // Coordinate della finestra: i pulsanti stanno nel theme frame, che ha
        // l'origine in basso a sinistra come tutto in Cocoa.
        NSPoint p = e.locationInWindow;
        NSButton *hit = nil;
        for (NSNumber *k in @[@(NSWindowCloseButton),
                              @(NSWindowMiniaturizeButton),
                              @(NSWindowZoomButton)]) {
            NSButton *b = [w standardWindowButton:(NSWindowButton)k.unsignedIntegerValue];
            if (!b || b.isHidden) continue;
            NSRect r = [b convertRect:b.bounds toView:nil];
            // Un margine di 4 punti: i semafori sono 16 punti e la mira non e'
            // chirurgica, mentre qui intorno non c'e' nient'altro da colpire.
            if (NSPointInRect(p, NSInsetRect(r, -4, -4))) { hit = b; break; }
        }
        if (!hit) return e;

        if      (hit == [w standardWindowButton:NSWindowCloseButton])       [w performClose:nil];
        else if (hit == [w standardWindowButton:NSWindowMiniaturizeButton]) [w miniaturize:nil];
        else                                                                [w zoom:nil];
        return nil;   // consumato: SDL non deve vederlo
    }];
}

__attribute__((constructor))
static void wf_chrome_init(void) {
    const char *env = getenv("WF_WIN");
    if (env) {
        int a = 0, b = 0;
        if (sscanf(env, "%dx%d", &a, &b) == 2 && a > 0 && b > 0) gAsked = NSMakeSize(a, b);
    }
    gSizeFile = getenv("WF_SIZE");
    gCropFile = getenv("WF_CROP");
    const char *keep = getenv("WF_CHROME");
    gKeepChrome = (keep && strcmp(keep, "native") == 0);
    const char *cur = getenv("WF_CURSOR");
    gLocalCursor = !(cur && strcmp(cur, "remote") == 0);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResizeNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *n) { onResize(n); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidEndLiveResizeNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *n) {
            NSWindow *w = n.object;
            if (isStreamWindow(w)) { setWant(w, w.frame.size); publish(w.frame.size); }
        }];
        // SDL ricrea la finestra piu' di una volta (cambio di schermo, di renderer):
        // conviene ripassare invece di fidarsi di un solo giro all'avvio.
        sweep();
        watchTitlebarClicks();
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            sweep();
            if (gLocalCursor) showLocalCursor();
        }];
    });
}
