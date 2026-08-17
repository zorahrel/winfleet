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
// Il puntatore: uno solo, e deve essere quello del Mac.
//
// Sunshine disegna il cursore di Windows DENTRO il video, quindi quello arriva
// sempre un viaggio di rete dopo la mano. Moonlight normalmente nasconde quello
// locale e resti con la freccia in ritardo; se invece quello locale ricompare, se
// ne vedono DUE che si rincorrono, ed e' peggio: l'occhio non sa quale seguire.
//
// La via d'uscita e' quella che usano i client desktop fatti bene (Discord fa
// cosi'): il cursore che vedi lo disegna il SISTEMA, istantaneo perche' non passa
// dalla rete, e quello remoto sparisce. Quello remoto non si puo' spegnere da
// Sunshine - questa build non ha capture_cursor, controllato nel binario - ma si
// puo' coprire: sotto il puntatore del Mac ci sta esattamente, e finche' i due
// sono sovrapposti l'occhio ne vede uno solo, quello che risponde subito.
//
// Quindi: cursore locale ACCESO di default dentro l'area del video.
// WF_CURSOR=remote per tornare al comportamento di prima (una freccia sola, in
// ritardo) se su qualche app la sovrapposizione desse fastidio.
static BOOL   gLocalCursor = YES;
static const char *gSizeFile = NULL; // dove annotare la misura corrente
static const char *gCropFile = NULL; // rettangolo da mostrare, per il client
// La misura piu' grande che Windows ha CONFERMATO di aver applicato. La scrive il
// ciclo esterno dopo la risposta dell'agente; qui serve a non allargare il
// ritaglio prima che ci sia davvero qualcosa da mostrare.
static const char *gAckFile  = NULL;
static const char *gAgent    = NULL; // "host:porta" dell'agente su Windows
static int    gSlot = -1;            // quale schermo virtuale e' il nostro
// Alzata quando un click sulla barra viene trattato come trascinamento del Mac.
// Serve solo all'autoverifica (WF_SELFTEST): e' la differenza fra "l'evento l'ho
// preso io" e "e' passato a SDL", cioe' fra la finestra del Mac e quella di Windows.
static BOOL   gLastTitlebarDrag = NO;

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

    // Il rettangolo che il client deve mostrare.
    //
    // Rimpicciolire e' sempre sicuro: si mostra MENO di quello che gia' c'e', e
    // farlo subito e' il motivo per cui il ritaglio segue il trascinamento senza
    // ritardo. Allargare no: finche' la finestra su Windows non e' cresciuta
    // davvero, oltre il suo bordo c'e' il desktop, e mostrarlo prima significa
    // vedere lo sfondo spuntare durante il resize. Era esattamente il sintomo.
    //
    // Chi sa QUANDO la finestra e' cresciuta e' il ciclo esterno, che lo chiede
    // all'agente e ne aspetta la conferma: l'allargamento del ritaglio lo scrive
    // lui. Qui ci si ferma alla misura piu' grande gia' confermata, che il ciclo
    // esterno pubblica in WF_ACK.
    if (gCropFile) {
        int cw = w, ch = h;
        if (gAckFile) {
            FILE *a = fopen(gAckFile, "r");
            if (a) {
                int aw = 0, ah = 0;
                if (fscanf(a, "%dx%d", &aw, &ah) == 2 && aw > 0 && ah > 0) {
                    if (cw > aw) cw = aw;
                    if (ch > ah) ch = ah;
                    // E si tiene il RAPPORTO della finestra, ritagliando di piu'
                    // dal lato che avanza. Senza, nell'istante in cui la finestra
                    // e' gia' cresciuta e Windows no, il rettangolo ha una forma
                    // diversa dalla finestra: il renderer centra l'immagine e
                    // riempie il resto di nero - sono le bande sui lati. Meglio
                    // mostrare qualche pixel in meno dell'app, che nessuno nota,
                    // di due strisce nere, che si notano subito.
                    if (w > 0 && h > 0) {
                        if ((long long)cw * h > (long long)ch * w) cw = (int)((long long)ch * w / h);
                        else                                       ch = (int)((long long)cw * h / w);
                    }
                    if (cw < 1) cw = 1;
                    if (ch < 1) ch = 1;
                }
                fclose(a);
            }
        }
        FILE *f = fopen(gCropFile, "w");
        if (f) { fprintf(f, "0 0 %d %d\n", cw, ch); fclose(f); }
        if (getenv("WF_DEBUG") && (cw != w || ch != h)) {
            NSLog(@"[wf] crop trattenuto: finestra %dx%d -> mostro %dx%d (Windows non ha ancora seguito)", w, h, cw, ch);
        }
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

// Quanto e' alta la barra del titolo di QUESTA finestra.
//
// La differenza frame/contentRect sembra il modo onesto di misurarla e invece con
// NSWindowStyleMaskFullSizeContentView vale ZERO: e' proprio il senso di quello
// stile, il contenuto occupa tutto il frame. Misurato: 32 punti prima di
// applicarlo, 0 dopo. Usarla per decidere dove finisce la barra spegneva il
// trascinamento senza un errore, perche' la striscia da guardare era alta zero.
//
// Si chiede quindi a Cocoa quanto vale la barra per uno stile titolato puro, che e'
// il valore che il pulsante di chiusura conferma (il semaforo sta a ~27 punti dal
// bordo alto, dentro i 32). Con WF_CHROME=native la finestra tiene la sua barra
// vera e la differenza frame/contentRect torna valida: si preferisce quella.
static CGFloat titlebarHeight(NSWindow *w) {
    NSRect f = w.frame;
    CGFloat real = f.size.height - [w contentRectForFrameRect:f].size.height;
    if (real > 1) return real;
    static CGFloat canonical = 0;
    if (canonical <= 0) {
        NSRect probe = [NSWindow frameRectForContentRect:NSMakeRect(0, 0, 100, 100)
                                               styleMask:NSWindowStyleMaskTitled];
        canonical = probe.size.height - 100;
        if (canonical <= 0) canonical = 28;   // non resta mai a zero
    }
    return canonical;
}

static void adopt(NSWindow *w) {
    if (!isStreamWindow(w)) return;
    if (objc_getAssociatedObject(w, kSeen)) return;
    objc_setAssociatedObject(w, kSeen, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Con WF_DEBUG=1 si scrive quello che serve a sapere se il trascinamento puo'
    // funzionare su QUESTA finestra: se la barra misurasse zero, la striscia da
    // guardare sarebbe alta zero e il click finirebbe dentro Windows senza che
    // nessun errore lo dica. E' successo, quindi la misura si controlla sulla
    // finestra vera e non solo su una di prova.
    if (getenv("WF_DEBUG")) {
        NSLog(@"[wf] finestra %@ frame=%.0fx%.0f barra=%.0f agente=%s slot=%d",
              NSStringFromClass([w class]), w.frame.size.width, w.frame.size.height,
              titlebarHeight(w), gAgent ? gAgent : "(nessuno)", gSlot);
        NSLog(@"[wf] stile: resizable=%d min=%.0fx%.0f max=%.0fx%.0f aspect=%.2fx%.2f",
              (w.styleMask & NSWindowStyleMaskResizable) ? 1 : 0,
              w.minSize.width, w.minSize.height, w.maxSize.width, w.maxSize.height,
              w.contentAspectRatio.width, w.contentAspectRatio.height);
    }

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
// Il puntatore del Mac dentro l'area del video.
//
// Moonlight nasconde il cursore quando entra nello stream, e non lo fa una volta
// sola: lo rifà a ogni movimento, a ogni rientro nella finestra, a ogni cambio di
// stato. Contro-annullare l'hide UNA volta - com'era prima, con un flag statico -
// funziona per un istante e poi vince SDL: il risultato e' che dentro la finestra
// non si vede nessun puntatore, ne' il nostro ne' quello remoto (che ora e'
// spento su Windows), e la freccia riappare solo uscendo dai bordi. Misurato.
//
// hide/unhide di NSCursor sono CONTATI: ogni hide va bilanciato, e chiamarli a
// caso lascia il contatore in uno stato che nessuno sa piu' risolvere. Quindi non
// si conta: si usa setHiddenUntilMouseMoves:NO, che azzera la richiesta di
// nascondere senza toccare il contatore, e lo si rifa' a ogni giro finche' il
// puntatore e' dentro il video. E' economico: un campo booleano, non un disegno.
static void showLocalCursor(void) {
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
    if (!inside) return;

    // Tre leve, perche' le prime due non bastano: provate, il puntatore restava
    // invisibile dentro il video.
    //
    // 1) setHiddenUntilMouseMoves: idempotente, si puo' rimettere a ogni giro.
    [NSCursor setHiddenUntilMouseMoves:NO];

    // 2) il contatore di [NSCursor hide], che SDL incrementa di continuo. Un solo
    //    unhide pareggia il primo e perde tutti quelli dopo, quindi si pareggia a
    //    ogni giro (un unhide di troppo non fa danno: non scende sotto zero).
    [NSCursor unhide];

    // 3) e soprattutto: si RIDISEGNA il cursore. hide/unhide agiscono su un
    //    contatore che SDL manovra a modo suo e possiamo solo inseguire; `set`
    //    invece impone qui e ora quale cursore mostrare, e non passa da nessun
    //    contatore. E' la leva che vince davvero, e costa una assegnazione.
    [[NSCursor arrowCursor] set];

    // 4) l'ultima parola ce l'ha CoreGraphics. NSCursor vive dentro
    //    l'applicazione, e se SDL ha nascosto il cursore a livello di sistema
    //    (CGDisplayHideCursor, che e' quello che fa quando cattura il mouse)
    //    nessuna chiamata AppKit lo riporta indietro. CGDisplayShowCursor annulla
    //    proprio quella, ed e' anch'essa contata: si chiama a ogni giro come
    //    l'unhide, per pareggiare quante volte serve.
    CGDisplayShowCursor(kCGDirectMainDisplay);

    // Con WF_DEBUG si dice, una volta ogni due secondi, che il giro sta girando e
    // se il sistema considera il cursore visibile: senza, l'unico modo di sapere
    // perche' non si vede e' indovinare.
    if (getenv("WF_DEBUG")) {
        static int n = 0;
        if (++n % 20 == 0) NSLog(@"[wf] cursore: giro attivo");
    }
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
// Il mouse si e' MOSSO (trascinamento) o e' rimasto fermo (click)?
//
// Sta in una funzione sua perche' e' l'unico pezzo che un test non puo'
// esercitare: sintetizzare un NSEvent si puo', muovere il mouse fisico no. Con
// WF_FORCE_DRAG=1 la si forza a rispondere "mosso", e cosi' la suite puo'
// verificare tutto il resto della catena.
static BOOL (*gDragProbe)(void) = NULL;

static BOOL waitForDragOrClick(void) {
    if (gDragProbe) return gDragProbe();
    NSPoint start = NSEvent.mouseLocation;
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.25];
    while ([until timeIntervalSinceNow] > 0) {
        if (!(NSEvent.pressedMouseButtons & 1)) return NO;   // rilasciato: era un click
        NSPoint now = NSEvent.mouseLocation;
        if (fabs(now.x - start.x) > 3 || fabs(now.y - start.y) > 3) return YES;
        [NSThread sleepForTimeInterval:0.008];
    }
    return NO;
}

static BOOL alwaysDrag(void) { return YES; }

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
            // La striscia in cima e' del Mac, ma non a scapito dell'app.
            //
            // Prendersi ogni click su quei 32 punti costava caro: in Arc lassu'
            // c'e' la barra degli indirizzi, e diventava impossibile cliccarla -
            // il click spariva dentro un trascinamento che non avevi chiesto.
            //
            // Si decide invece dal MOVIMENTO: si guarda se il mouse si sposta
            // davvero entro un quarto di secondo. Se si muove e' un
            // trascinamento e lo prende Cocoa; se resta fermo era un click, e lo
            // si lascia proseguire verso l'app come qualsiasi altro.
            if (p.y > w.frame.size.height - titlebarHeight(w)) {
                if (waitForDragOrClick()) {
                    gLastTitlebarDrag = YES;   // per l'autoverifica: chi ha preso l'evento
                    [w performWindowDragWithEvent:e];
                    return nil;
                }
                // Fermo: era un click dell'utente sull'app. Passa.
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
    gAckFile  = getenv("WF_ACK");
    gAgent    = getenv("WF_AGENT");
    const char *slot = getenv("WF_SLOT");
    if (slot) gSlot = atoi(slot);
    const char *keep = getenv("WF_CHROME");
    gKeepChrome = (keep && strcmp(keep, "native") == 0);
    // WF_CURSOR=remote torna alla freccia sola (quella di Windows, in ritardo).
    if (getenv("WF_FORCE_DRAG")) gDragProbe = alwaysDrag;
    const char *cur = getenv("WF_CURSOR");
    if (cur && strcmp(cur, "remote") == 0) gLocalCursor = NO;

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

        // Autoverifica sulla finestra VERA, non su una di prova.
        //
        // Un test esterno non puo' arrivare fin qui: sintetizzare un click sulla
        // finestra di Moonlight richiede il permesso di Accessibilita', che sulla
        // macchina di sviluppo non c'e'. Da dentro il processo invece si puo':
        // si fabbrica un mouseDown alle coordinate della barra e lo si manda
        // all'applicazione, esattamente come farebbe una mano. Se il monitor
        // installato sopra lo consuma, il trascinamento e' della finestra del Mac;
        // se lo lascia passare, finirebbe dentro Windows.
        //
        // Vale solo con WF_SELFTEST=1: a stream avviato costerebbe un click finto
        // che l'utente non ha chiesto.
        if (getenv("WF_SELFTEST")) {
            // Si ASPETTA la finestra invece di sperare che sia gia' nata: lo
            // stream ci mette qualche secondo e un timer a tempo fisso arrivava
            // prima, riportando "nessuna finestra" come se fosse un esito.
            __block int tries = 0;
            [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
                NSWindow *win = nil;
                for (NSWindow *w in [NSApp windows]) if (isAdopted(w)) { win = w; break; }
                if (!win) {
                    if (++tries > 30) { NSLog(@"[wf-selftest] nessuna finestra adottata"); [t invalidate]; }
                    return;
                }
                [t invalidate];

                CGFloat bar = titlebarHeight(win);
                NSPoint inBar = NSMakePoint(win.frame.size.width / 2,
                                            win.frame.size.height - bar / 2);
                NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                location:inBar modifierFlags:0 timestamp:0
                                            windowNumber:win.windowNumber context:nil
                                             eventNumber:9001 clickCount:1 pressure:1];
                // I monitor locali vedono l'evento prima di chiunque altro: se il
                // nostro lo consuma, sendEvent non lo consegna alla vista di SDL.
                gLastTitlebarDrag = NO;
                [NSApp sendEvent:e];
                NSLog(@"[wf-selftest] barra=%.0f click_y=%.0f esito=%@", bar, inBar.y,
                      gLastTitlebarDrag ? @"PASS (trascina il Mac)" : @"FAIL (finirebbe in Windows)");

                // Controprova: un click al centro del video NON deve essere preso
                // per trascinamento, altrimenti avremmo rubato l'input all'app.
                gLastTitlebarDrag = NO;
                NSEvent *v = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                location:NSMakePoint(win.frame.size.width / 2, 40)
                                          modifierFlags:0 timestamp:0
                                            windowNumber:win.windowNumber context:nil
                                             eventNumber:9002 clickCount:1 pressure:1];
                [NSApp sendEvent:v];
                NSLog(@"[wf-selftest] video esito=%@",
                      gLastTitlebarDrag ? @"FAIL (rubato all'app)" : @"PASS (va a Windows)");
            }];
        }
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            sweep();
        }];
        // Il cursore ha bisogno di un ritmo suo: SDL lo rinasconde a ogni
        // movimento, quindi rimetterlo due volte al secondo lo fa lampeggiare.
        // A 60 Hz il contrasto e' invisibile e resta sempre visibile.
        if (gLocalCursor) {
            // Non un NSTimer: quando SDL prende in mano il run loop per lo stream,
            // i timer di AppKit smettono di scattare - misurato, il giro del
            // cursore non partiva nemmeno una volta e nessuna delle leve poteva
            // funzionare. Un timer GCD ha una coda sua e continua a girare
            // qualunque cosa faccia il run loop; le chiamate a NSCursor le si
            // rimanda al thread principale, che e' dove devono avvenire.
            //
            // 10 volte al secondo, non 60: da quando il fork non nasconde piu' il
            // cursore dentro il video (fork/crop.patch), questo giro non deve piu'
            // vincere una gara - fa solo da rete se qualcosa lo nasconde
            // comunque. A 60 Hz la gara si vedeva, ed era il flicker.
            static dispatch_source_t tick;
            tick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                          dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
            dispatch_source_set_timer(tick, dispatch_time(DISPATCH_TIME_NOW, 0),
                                      (uint64_t)(NSEC_PER_SEC / 10), NSEC_PER_SEC / 20);
            dispatch_source_set_event_handler(tick, ^{
                dispatch_async(dispatch_get_main_queue(), ^{ showLocalCursor(); });
            });
            dispatch_resume(tick);
        }
    });
}
