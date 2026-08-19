// Cmd+W dentro una finestra di stream VERA, senza permessi di sistema.
//
// La prova col tasto premuto davvero non si puo' fare da un agente: serve il
// permesso Accessibilita' (AXIsProcessTrusted e' falso) e senza quello
// CGEventPost riesce ma l'evento viene scartato in silenzio - verificato su
// Arc, con la finestra a fuoco confermato, sei tentativi e zero eventi
// arrivati.
//
// Ma dall'INTERNO del processo il permesso non serve: un evento costruito qui e
// passato a performKeyEquivalent: della barra dei menu percorre esattamente la
// strada che AppKit usa quando l'utente preme i tasti. E' il pezzo che stava in
// mezzo fra "la voce esiste" e "la finestra si chiude".
//
// Questa libreria si inietta accanto a wf-chrome.dylib in un Moonlight vero:
// aspetta che la finestra di stream esista, poi manda Cmd+W come lo manderebbe
// il sistema e riporta se la finestra si e' chiusa.
#import <Cocoa/Cocoa.h>

static NSWindow *streamWindow(void) {
    for (NSWindow *w in [NSApp windows]) {
        if (!(w.styleMask & NSWindowStyleMaskTitled) || !w.isVisible) continue;
        NSString *cls = NSStringFromClass([w class]);
        if ([cls hasPrefix:@"QNS"] || [cls containsString:@"Qt"]) continue;
        return w;
    }
    return nil;
}

static void prova(void) {
    NSWindow *w = streamWindow();
    if (!w) { NSLog(@"[wf-cmdw] nessuna finestra di stream: non provo"); return; }

    NSMenu *win = NSApp.windowsMenu;
    if (!win) { NSLog(@"[wf-cmdw] ESITO=FAIL nessun menu Finestra"); return; }

    [w makeKeyAndOrderFront:nil];

    NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                  location:NSZeroPoint
                             modifierFlags:NSEventModifierFlagCommand
                                 timestamp:0
                              windowNumber:w.windowNumber
                                   context:nil
                                characters:@"w"
               charactersIgnoringModifiers:@"w"
                                 isARepeat:NO
                                   keyCode:13];

    NSDate *t0 = [NSDate date];
    BOOL preso = [win performKeyEquivalent:e];
    NSLog(@"[wf-cmdw] CRONO inizio");
    // Quanto ci mette la finestra a sparire, misurato DENTRO il processo.
    __block int giri2 = 0;
    __block NSTimer *tt = nil;
    tt = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *tm) {
        giri2++;
        if (!streamWindow()) {
            [tm invalidate];
            NSLog(@"[wf-cmdw] CRONO finestra sparita dopo %.2fs", -[t0 timeIntervalSinceNow]);
        } else if (giri2 > 200) {
            [tm invalidate];
            NSLog(@"[wf-cmdw] CRONO finestra ancora li' dopo 10s");
        }
    }];
    (void)tt;
    NSLog(@"[wf-cmdw] il menu ha preso Cmd+W: %@", preso ? @"si" : @"NO");
    // Diagnosi: chi rifiuta la chiusura?
    id del = w.delegate;
    NSLog(@"[wf-cmdw] classe=%@ delegate=%@ closable=%d risponde-a-shouldClose=%d",
          NSStringFromClass([w class]),
          del ? NSStringFromClass([del class]) : @"(nessuno)",
          (w.styleMask & NSWindowStyleMaskClosable) ? 1 : 0,
          (del && [del respondsToSelector:@selector(windowShouldClose:)]) ? 1 : 0);
    if (del && [del respondsToSelector:@selector(windowShouldClose:)]) {
        BOOL ok = [(id<NSWindowDelegate>)del windowShouldClose:w];
        NSLog(@"[wf-cmdw] il delegate dice di poter chiudere: %@", ok ? @"si" : @"NO");
    }
    // Il pulsante rosso usa lo stesso performClose:, quindi dovrebbe fallire
    // uguale. Si prova: se anche quello non chiude, il difetto e' generale e non
    // riguarda solo la scorciatoia.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSWindow *w2 = streamWindow();
        if (!w2) { NSLog(@"[wf-cmdw] rosso: finestra gia' chiusa"); return; }
        [w2 performClose:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSLog(@"[wf-cmdw] PULSANTE-ROSSO: finestra %@",
                  streamWindow() ? @"ANCORA APERTA (rotto anche quello)" : @"chiusa");
        });
    });

    // performClose: chiude in modo asincrono: si lascia girare il run loop.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL viva = NO;
        for (NSWindow *x in [NSApp windows]) {
            if (x == w && x.isVisible) { viva = YES; break; }
        }
        NSLog(@"[wf-cmdw] ESITO=%@ (finestra %@ dopo Cmd+W)",
              (preso && !viva) ? @"PASS" : @"FAIL",
              viva ? @"ancora aperta" : @"chiusa");
    });
}

__attribute__((constructor))
static void wf_cmdw_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // La finestra di stream nasce qualche secondo dopo l'avvio: si aspetta
        // che ci sia, invece di provare a vuoto.
        __block int giri = 0;
        __block NSTimer *t = nil;
        t = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            giri++;
            if (streamWindow()) { [timer invalidate]; prova(); }
            else if (giri > 60) { [timer invalidate]; NSLog(@"[wf-cmdw] ESITO=SKIP finestra mai comparsa"); }
        }];
        (void)t;
    });
}
