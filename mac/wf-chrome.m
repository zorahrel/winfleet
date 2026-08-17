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
// Il puntatore locale e' spento di default. Rimetterlo sembrava un miglioramento —
// e' istantaneo perche' lo disegna macOS — ma se ne vedono DUE: il proprio, che
// segue la mano, e quello di Windows disegnato dentro il video, che arriva un
// viaggio di rete dopo. Due frecce che si rincorrono si leggono come lag, e sono
// peggio di una sola freccia in ritardo, perche' l'occhio non sa piu' quale
// guardare. WF_CURSOR=local per riaccenderlo.
static BOOL   gLocalCursor = NO;
static const char *gSizeFile = NULL; // dove annotare la misura corrente
static const char *gCropFile = NULL; // rettangolo da mostrare, per il client
static const char *gAgent    = NULL; // "host:porta" dell'agente su Windows
static int    gSlot = -1;            // quale schermo virtuale e' il nostro

// Dice all'app su Windows di ridursi a icona, o di tornare.
//
// Sul Mac la finestra la minimizza Cocoa e si vede subito; su Windows l'app
// resterebbe in primo piano sul suo schermo virtuale, e al ripristino si
// tornerebbe a vedere cio' che nel frattempo le e' finito sopra. Le due cose vanno
// dette insieme.
//
// In coda separata e senza aspettare la risposta: parte da un handler di eventi, e
// un giro di rete dentro il thread principale si sente come uno scatto sul click.
static void tellWindows(BOOL minimize) {
    if (!gAgent || gSlot < 0) return;
    NSString *url = [NSString stringWithFormat:@"http://%s/show?slot=%d&how=%s",
                     gAgent, gSlot, minimize ? "min" : "restore"];
    NSURLRequest *r = [NSURLRequest requestWithURL:[NSURL URLWithString:url]
                                      cachePolicy:NSURLRequestReloadIgnoringCacheData
                                  timeoutInterval:2.0];
    [[NSURLSession.sharedSession dataTaskWithRequest:r] resume];
}


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

// Una finestra che abbiamo gia' preso in carico, riconosciuta dal marchio che le
// abbiamo messo addosso e non dal suo stato.
//
// Serve perche' isStreamWindow chiede isVisible, e una finestra RIDOTTA A ICONA non
// e' visibile: usarla per decidere se reagire alla minimizzazione scartava proprio
// l'evento che ci interessava. Trovato dal test, non a mente: la chiamata di
// ripristino partiva e quella di minimizzazione no.
static BOOL isAdopted(NSWindow *w) {
    return w && objc_getAssociatedObject(w, kSeen) != nil;
}

// Quanto e' alta la barra del titolo di QUESTA finestra. Con
// NSWindowStyleMaskFullSizeContentView il contenuto ci passa sotto, quindi la
// differenza frame/contentRect resta il modo onesto di misurarla: non si assume
// un valore fisso, che cambia con lo stile e con il display.
static CGFloat titlebarHeight(NSWindow *w) {
    NSRect f = w.frame;
    return f.size.height - [w contentRectForFrameRect:f].size.height;
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
// Il puntatore si rimette solo mentre e' davvero dentro la finestra dello stream.
//
// La prima versione lo mostrava quando la finestra era attiva, e sbagliava il caso
// piu' comune: uscendo dalla finestra il puntatore restava nascosto: si perdeva la
// freccia sul resto dello schermo e bisognava cliccare da qualche parte per
// riaverla. Moonlight nasconde il cursore quando entra nell'area del video, quindi
// va rimesso e ritolto seguendo la posizione, non il fuoco.
//
// unhide/hide di NSCursor sono contati: chiamarli sbilanciati lascia il cursore in
// uno stato che nessun altro sa risolvere, quindi si tiene traccia di cosa si e'
// fatto e si fa esattamente una chiamata per cambio di stato.
static void showLocalCursor(void) {
    static BOOL unhidden = NO;
    NSPoint m = NSEvent.mouseLocation;
    BOOL inside = NO;

    for (NSWindow *w in [NSApp windows]) {
        if (!isStreamWindow(w) || !w.isVisible) continue;
        // Solo l'area del video, senza la barra del titolo: li' il cursore lo
        // gestisce macOS e non serve interferire.
        NSRect f = w.frame;
        f.size.height -= titlebarHeight(w);
        if (NSPointInRect(m, f)) { inside = YES; break; }
    }

    // Solo unhide, mai hide. Nascondere il cursore quando esce dalla finestra
    // sembra la simmetria giusta ed e' la trappola: NSCursor vale per tutta
    // l'applicazione, non per una finestra, quindi lo si nasconderebbe anche sopra
    // la barra del titolo e sopra il pannello. Contro-annullare l'hide di Moonlight
    // e lasciarlo cosi' e' sufficiente: quando il puntatore esce dalla finestra
    // dello stream, comanda comunque l'app che sta sotto.
    if (inside && !unhidden) { [NSCursor unhide]; unhidden = YES; }
    (void)unhidden;
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

        if (!hit) {
            // Trascinare la finestra sul Mac deve muovere la finestra sul MAC.
            //
            // Con il contenuto a tutta finestra il video arriva fin sotto la barra,
            // e SDL prende gli eventi a livello di finestra: premere sulla barra
            // finiva dentro Windows. Siccome quasi tutte le app ci disegnano la
            // PROPRIA barra, quel premi-e-trascina afferrava la finestra dell'app su
            // Windows e la spostava sul suo schermo virtuale - mentre la finestra
            // sul Mac restava ferma. Due finestre che si scollano: l'app usciva dal
            // rettangolo ritagliato e si vedeva il desktop di Windows intorno.
            //
            // La striscia in cima e' del Mac, punto. Qui il drag lo fa Cocoa
            // (performWindowDragWithEvent: segue il mouse a 120 Hz e conosce snap,
            // Spaces e schermi) e l'evento non arriva a SDL.
            if (p.y > w.frame.size.height - titlebarHeight(w)) {
                [w performWindowDragWithEvent:e];
                return nil;
            }
            return e;
        }

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
    gAgent    = getenv("WF_AGENT");
    const char *slot = getenv("WF_SLOT");
    if (slot) gSlot = atoi(slot);
    const char *keep = getenv("WF_CHROME");
    gKeepChrome = (keep && strcmp(keep, "native") == 0);
    const char *cur = getenv("WF_CURSOR");
    gLocalCursor = (cur && strcmp(cur, "local") == 0);

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
        // Riduci a icona e ripristino vanno detti anche a Windows. Si ascoltano le
        // notifiche invece di agire solo nel click sul semaforo, cosi' vale anche
        // per Cmd+M, per il menu Finestra e per il click sull'icona nel Dock.
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidMiniaturizeNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *n) {
            if (isAdopted(n.object)) tellWindows(YES);
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidDeminiaturizeNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *n) {
            if (isAdopted(n.object)) tellWindows(NO);
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
