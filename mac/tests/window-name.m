// La finestra deve chiamarsi come l'app che ci sta dentro, anche quando e' nata
// per un'altra.
//
// Il guasto vero: una finestra tenuta calda parte dal bundle dell'app usata per
// scaldarla (il Blocco note). Quando ci si mette sopra Arc, il nome nel Dock e in
// Cmd-Tab resta "Blocco note" - e con tre finestre calde si finisce con tre voci
// "Blocco note" che sono tre app diverse. Da fuori sembra che si siano aperte da
// sole delle app a caso.
//
// Il bundle non si puo' cambiare a processo avviato, ma il nome si': la libreria
// e' gia' dentro il processo e rilegge un file due volte al secondo.
//
// Qui si verifica proprio quello: si scrive un nome nel file, si aspetta, e si
// guarda se il titolo della finestra dello stream lo ha preso. Senza la libreria
// il titolo resta quello di partenza, quindi il test discrimina.

#import <Cocoa/Cocoa.h>

@interface Fake : NSView @end
@implementation Fake
- (void)mouseDown:(NSEvent *)e { (void)e; }   // come SDL: ingoia tutto
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        // Si parte come app NORMALE: cosi' "fuori dal Dock" alla fine e' un fatto
        // che solo la libreria puo' aver prodotto - altrimenti il controllo
        // passerebbe da solo e non proverebbe niente.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSRect r = NSMakeRect(0, 0, 600, 400);
        NSWindow *w = [[NSWindow alloc]
            initWithContentRect:r
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        // La libreria prende qualunque finestra con barra del titolo e visibile,
        // tranne quelle di Qt (che sono l'interfaccia di Moonlight e non vanno
        // toccate): una NSWindow normale va bene come finestra di stream finta.
        w.title = @"Blocco note";
        w.contentView = [[Fake alloc] initWithFrame:r];
        [w makeKeyAndOrderFront:nil];

        // Si lascia lavorare la libreria: il suo giro e' mezzo secondo.
        NSDate *fine = [NSDate dateWithTimeIntervalSinceNow:2.5];
        while ([fine timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }

        const char *atteso = getenv("WF_EXPECT") ?: "Arc";
        NSString *want = [NSString stringWithUTF8String:atteso];
        BOOL ok = [w.title isEqualToString:want];
        printf("ESITO_NOME: %s (titolo=\"%s\", atteso=\"%s\")\n",
               ok ? "PASS" : "FAIL", w.title.UTF8String, atteso);
        // E la seconda proprieta', quella che l'utente vede per prima: una
        // finestra di SCORTA non deve comparire nel Dock. Si scrive il marchio
        // nel file, si lascia lavorare la libreria, e si guarda la politica di
        // attivazione: accessory = fuori dal Dock, regular = app normale.
        const char *nf = getenv("WF_NAME");
        if (nf) {
            FILE *g = fopen(nf, "w");
            if (g) { fputs("::pronto::\n", g); fclose(g); }
            NSDate *f2 = [NSDate dateWithTimeIntervalSinceNow:1.5];
            while ([f2 timeIntervalSinceNow] > 0) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            BOOL fuori = ([NSApp activationPolicy] == NSApplicationActivationPolicyAccessory);
            printf("ESITO_SCORTA: %s (fuori dal Dock=%d)\n", fuori ? "PASS" : "FAIL", fuori);
        }
        return ok ? 0 : 1;
    }
}
