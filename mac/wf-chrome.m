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

static NSSize wantOf(NSWindow *w) {
    NSValue *v = objc_getAssociatedObject(w, kWant);
    return v ? [v sizeValue] : NSZeroSize;
}
static void setWant(NSWindow *w, NSSize s) {
    objc_setAssociatedObject(w, kWant, [NSValue valueWithSize:s], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Solo le finestre vere dello stream: Qt ne tiene altre, nascoste, che non vanno
// toccate (e che non hanno una barra da togliere).
static BOOL isStreamWindow(NSWindow *w) {
    return w && (w.styleMask & NSWindowStyleMaskTitled) && w.isVisible;
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
        // Il rapporto resta quello dello stream. Non e' una preferenza estetica: la
        // sessione e' negoziata a una forma sola, e se lo schermo di Windows ne
        // prende un'altra Sunshine ci mette le bande nere per farcela stare. Cocoa
        // vincola il trascinamento mentre avviene, quindi non c'e' niente da
        // correggere dopo e la finestra non "scatta".
        [w setContentAspectRatio:gAsked];
        NSRect f = w.frame;
        if (fabs(f.size.width - want.width) > 1 || fabs(f.size.height - want.height) > 1) {
            f.origin.y += f.size.height - want.height;   // l'angolo in alto resta fermo
            f.size = want;
            [w setFrame:f display:YES];
        }
    }
}

static void onResize(NSNotification *n) {
    NSWindow *w = n.object;
    if (!isStreamWindow(w)) return;
    NSSize want = wantOf(w);
    if (want.width <= 0) return;

    if (w.inLiveResize) {
        setWant(w, w.frame.size);       // sta trascinando l'utente: comanda lui
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

__attribute__((constructor))
static void wf_chrome_init(void) {
    const char *env = getenv("WF_WIN");
    if (env) {
        int a = 0, b = 0;
        if (sscanf(env, "%dx%d", &a, &b) == 2 && a > 0 && b > 0) gAsked = NSMakeSize(a, b);
    }
    const char *keep = getenv("WF_CHROME");
    gKeepChrome = (keep && strcmp(keep, "native") == 0);

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
            if (isStreamWindow(w)) setWant(w, w.frame.size);
        }];
        // SDL ricrea la finestra piu' di una volta (cambio di schermo, di renderer):
        // conviene ripassare invece di fidarsi di un solo giro all'avvio.
        sweep();
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { sweep(); }];
    });
}
