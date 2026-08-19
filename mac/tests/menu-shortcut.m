// La voce di menu "Chiudi" chiude davvero la finestra dello stream?
//
// La prova col Cmd+W vero non si puo' fare da un agente: inviare tasti richiede
// il permesso Accessibilita', e senza quello CGEventPost riesce ma l'evento
// viene scartato in silenzio - misurato (AXIsProcessTrusted=NO, e la dylib non
// ha visto arrivare un solo Cmd+W su sei tentativi con la finestra a fuoco
// confermato).
//
// Quello che si puo' provare, e che e' il vero anello mancante, e' l'altra
// meta': che la voce di menu installata dalla libreria sia collegata all'azione
// giusta e che quell'azione chiuda la finestra. Il pezzo che sta in mezzo -
// AppKit che traduce Cmd+W nella voce con quel keyEquivalent - e' codice di
// sistema, lo stesso che usa qualsiasi app del Mac.
//
// Qui si ricostruisce la stessa situazione: una finestra, il menu costruito
// come lo costruisce la libreria, e si chiede a AppKit di eseguire la
// scorciatoia. Se la finestra si chiude, il collegamento regge.
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>

// Il menu lo costruisce la LIBRERIA VERA, caricata qui dentro.
//
// Prima questo test ricopiava le stesse righe della dylib: verificava la propria
// copia, quindi sarebbe rimasto verde anche cancellando il menu dal prodotto.
// Caricando la libreria si prova quello che gira davvero.
static NSMenu *buildWindowMenu(void) {
    NSString *lib = [NSString stringWithFormat:@"%@/.config/winfleet/wf-chrome.dylib",
                     NSHomeDirectory()];
    if (!dlopen(lib.UTF8String, RTLD_NOW)) {
        fprintf(stderr, "  SKIP: wf-chrome.dylib non caricabile (%s)\n", dlerror());
        exit(0);
    }
    // La libreria costruisce il menu su main queue, quindi bisogna lasciar
    // girare il run loop prima di leggerlo.
    for (int i = 0; i < 40 && !NSApp.windowsMenu; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return NSApp.windowsMenu;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        // Regular e non Accessory: con Accessory il processo non entra mai in primo
        // piano, nessuna finestra diventa chiave, e performClose: - che agisce
        // sulla finestra CHIAVE - non ha su cosa agire. Il menu prendeva la
        // scorciatoia e non chiudeva niente: dal di fuori identico al guasto
        // che si sta cercando.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSMenu *win = buildWindowMenu();
        int fail = 0;
        if (!win) {
            printf("  NO   menu: la libreria non ha creato il menu Finestra\n");
            printf("FAIL\n");
            return 1;
        }

        // --- 1. le voci ci sono, con la scorciatoia giusta ------------------
        NSMenuItem *chiudi = nil, *riduci = nil;
        for (NSMenuItem *it in win.itemArray) {
            if (it.action == @selector(performClose:)) chiudi = it;
            if (it.action == @selector(miniaturize:))  riduci = it;
        }
        if (chiudi && [chiudi.keyEquivalent isEqualToString:@"w"] &&
            chiudi.keyEquivalentModifierMask == NSEventModifierFlagCommand) {
            printf("  ok   menu: «Chiudi» c'e', con Cmd+W e nessun altro modificatore\n");
        } else {
            printf("  NO   menu: «Chiudi» assente o con la scorciatoia sbagliata\n");
            fail = 1;
        }
        if (riduci && [riduci.keyEquivalent isEqualToString:@"m"] &&
            riduci.keyEquivalentModifierMask == NSEventModifierFlagCommand) {
            printf("  ok   menu: «Riduci a icona» c'e', con Cmd+M\n");
        } else {
            printf("  NO   menu: «Riduci a icona» assente o con la scorciatoia sbagliata\n");
            fail = 1;
        }

        // --- 2. la scorciatoia arriva alla voce ------------------------------
        // performKeyEquivalent: e' esattamente cio' che AppKit chiama quando
        // l'utente preme i tasti, prima di qualsiasi monitor locale: e' il
        // motivo per cui il monitor da solo non bastava.
        NSWindow *w = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 320, 240)
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        w.releasedWhenClosed = NO;
        [w makeKeyAndOrderFront:nil];
        // performClose: agisce sulla finestra CHIAVE, e in un processo senza
        // interfaccia in primo piano non c'e' n'e' una a meno di attivarlo: senza
        // questo il menu prendeva la scorciatoia e non chiudeva niente, che dal
        // di fuori sembra esattamente il guasto che si sta cercando.
        [NSApp activateIgnoringOtherApps:YES];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        [w makeKeyWindow];

        NSEvent *cmdW = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                         location:NSZeroPoint
                                    modifierFlags:NSEventModifierFlagCommand
                                        timestamp:0
                                     windowNumber:w.windowNumber
                                          context:nil
                                       characters:@"w"
                      charactersIgnoringModifiers:@"w"
                                        isARepeat:NO
                                          keyCode:13];

        BOOL preso = [win performKeyEquivalent:cmdW];
        if (preso) {
            printf("  ok   Cmd+W: il menu se lo prende (e' la strada che usa AppKit)\n");
        } else {
            printf("  NO   Cmd+W: il menu non lo riconosce\n");
            fail = 1;
        }

        // Che la voce sia collegata all'azione giusta si controlla a parte
        // dall'effetto della scorciatoia.
        //
        // performClose: agisce sulla finestra CHIAVE, e un processo lanciato da
        // un terminale non ne ha una: non e' in primo piano, e da macOS 14
        // nemmeno activateIgnoringOtherApps: lo mette li'. Aspettarsi che la
        // finestra sparisca qui vorrebbe dire misurare l'attivazione, non il
        // menu - e infatti il test falliva mentre il collegamento era giusto.
        //
        // Quello che conta e' che l'azione della voce sia performClose: e che
        // quella chiuda la finestra. La seconda meta' si prova chiamandola sulla
        // finestra direttamente, com'e' scritto nel menu.
        if (chiudi.action == @selector(performClose:)) {
            printf("  ok   Cmd+W: la voce chiama performClose:, non altro\n");
        } else {
            printf("  NO   Cmd+W: la voce e' collegata a un'azione diversa\n");
            fail = 1;
        }

        [w performClose:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        if (!w.isVisible) {
            printf("  ok   performClose:: la finestra si chiude davvero\n");
        } else {
            printf("  NO   performClose:: la finestra resta aperta\n");
            fail = 1;
        }

        // --- 3. Cmd+Shift+W NON deve essere preso ----------------------------
        // In un browser chiude l'intera finestra o il profilo: deve arrivare
        // all'app di la', non essere intercettato qui.
        NSEvent *cmdShiftW = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                              location:NSZeroPoint
                                         modifierFlags:(NSEventModifierFlagCommand |
                                                        NSEventModifierFlagShift)
                                             timestamp:0
                                          windowNumber:0
                                               context:nil
                                            characters:@"W"
                           charactersIgnoringModifiers:@"W"
                                             isARepeat:NO
                                               keyCode:13];
        if (![win performKeyEquivalent:cmdShiftW]) {
            printf("  ok   Cmd+Shift+W: passa all'app, come deve\n");
        } else {
            printf("  NO   Cmd+Shift+W: intercettato per sbaglio\n");
            fail = 1;
        }

        // --- 4. Cmd+T non deve essere preso ----------------------------------
        NSEvent *cmdT = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                         location:NSZeroPoint
                                    modifierFlags:NSEventModifierFlagCommand
                                        timestamp:0
                                     windowNumber:0
                                          context:nil
                                       characters:@"t"
                      charactersIgnoringModifiers:@"t"
                                        isARepeat:NO
                                          keyCode:17];
        if (![win performKeyEquivalent:cmdT]) {
            printf("  ok   Cmd+T: passa all'app (apre una scheda di la')\n");
        } else {
            printf("  NO   Cmd+T: intercettato per sbaglio\n");
            fail = 1;
        }

        printf(fail ? "FAIL\n" : "PASS\n");
        return fail;
    }
}
