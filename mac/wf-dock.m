// L'icona nel Dock di WinFleet: un click e c'e' tutto il PC, con la ricerca.
//
// Il pannello in barra dei menu (wf-panel.m) resta e fa la stessa cosa, ma vive in
// alto a destra fra venti altre icone: si trova se si sa gia' che c'e'. Il Dock e'
// dove si va a cercare un'app quando la si vuole aprire, quindi e' li' che ha senso
// mettere l'elenco delle app del PC.
//
// Le due differenze che contano rispetto al menu in barra:
//
// 1. C'e' un campo di ricerca vero. Nei menu di macOS si puo' digitare per saltare
//    a una voce, ma solo dall'inizio del nome: cercare "note" non trova "Blocco
//    note". Con settantadue app la differenza e' fra trovare e scorrere.
//
// 2. Si apre dove sta il mouse e si chiude appena si e' scelto. Una finestra che
//    resta aperta dopo aver aperto un'app e' una finestra che poi si deve chiudere.
//
// Un elenco di finestre e' vero solo nell'istante in cui lo si guarda, quindi si
// ricostruisce tutto a ogni apertura invece di tenere uno stato che invecchia.
//
//   clang -framework Cocoa -o WinFleetDock wf-dock.m

#import <Cocoa/Cocoa.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

static NSString *kCli;      // percorso del comando winfleet
static NSString *kConfig;   // ~/.config/winfleet

// ---------------------------------------------------------------------------
// Registro e comandi
// ---------------------------------------------------------------------------

// Ogni azione lascia una riga in dock.log. Senza, "ha aperto la cosa sbagliata"
// resta la parola dell'utente contro il codice e non si sistema niente.
static void logLine(NSString *what) {
    NSString *path = [kConfig stringByAppendingPathComponent:@"dock.log"];
    NSString *line = [NSString stringWithFormat:@"%@  %@\n",
                      [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterNoStyle
                                                     timeStyle:NSDateFormatterMediumStyle], what];
    [NSFileManager.defaultManager createDirectoryAtPath:kConfig
                            withIntermediateDirectories:YES attributes:nil error:nil];
    if (![NSFileManager.defaultManager fileExistsAtPath:path])
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) { [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil]; return; }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

// Staccato: aprire una finestra ci mette secondi e il pannello deve sparire subito,
// invece di restare li' bloccato a far sembrare che non abbia ricevuto il click.
// Il comando si lancia con argomenti veri, senza interporre una shell. Due motivi,
// entrambi trovati sul campo:
//
// 1. Passare da /bin/sh o /bin/bash consegna lo script alla bash 3.2 di sistema, che
//    e' del 2007 e rifiuta la sintassi di winfleet: errore di sintassi su un file
//    perfettamente valido, e solo quando lanciato dal pannello. Lo shebang dello
//    script sceglie da solo la bash giusta.
// 2. Senza shell di mezzo, i nomi con spazi, accenti e apostrofi ("Gestione
//    attivita'") non vanno protetti, e nessun nome di app puo' finire interpretato
//    come comando.
// Il comando gira staccato ma il suo esito NON si butta via: winfleet ha messaggi
// veri da dare ("tutte le finestre sono occupate", "app non trovata") e il pannello
// li stava scartando, quindi si premeva una voce e non succedeva niente — senza
// alcun modo di sapere se stava caricando, se aveva fallito o se il click era
// andato perso.
static void runArgs(NSArray<NSString *> *args, void (^done)(BOOL ok, NSString *msg)) {
    logLine([args componentsJoinedByString:@"  "]);
    NSTask *t = [NSTask new];
    t.launchPath = kCli;
    t.arguments = args;
    // Una app lanciata dal Finder ha un PATH minimo: winfleet chiama ssh, curl e
    // clang, e senza questo li cercherebbe dove non ci sono.
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"PATH"] = @"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    env[@"NO_COLOR"] = @"1";      // i codici colore in un avviso si vedono, e male
    t.environment = env;
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out; t.standardError = out;

    @try { [t launch]; }
    @catch (NSException *e) {
        logLine([@"ERRORE: " stringByAppendingString:e.reason]);
        if (done) done(NO, @"non riesco ad avviare winfleet");
        return;
    }
    if (!done) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *d = nil;
        @try { d = [out.fileHandleForReading readDataToEndOfFile]; } @catch (NSException *e) {}
        [t waitUntilExit];
        NSString *txt = d.length ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"";
        BOOL ok = (t.terminationStatus == 0);
        // L'ultima riga non vuota: winfleet stampa il risultato alla fine, e le
        // righe di avanzamento prima non servono a chi guarda un avviso.
        NSString *last = @"";
        for (NSString *l in [txt componentsSeparatedByString:@"\n"]) {
            NSString *c = [l stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (c.length) last = c;
        }
        logLine([NSString stringWithFormat:@"  -> %@ (%d)", last, t.terminationStatus]);
        dispatch_async(dispatch_get_main_queue(), ^{ done(ok, last); });
    });
}

// Sincrono, per leggere elenchi. Con un limite di tempo: se il PC e' spento o la
// rete e' lenta, senza timeout il pannello resterebbe congelato sotto il mouse.
static NSString *runRead(NSString *cmd, NSTimeInterval limit) {
    NSTask *t = [NSTask new];
    t.launchPath = @"/bin/bash";
    t.arguments = @[@"-lc", cmd];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p; t.standardError = [NSPipe pipe];
    @try { [t launch]; } @catch (NSException *e) { return @""; }

    // Il dato si legge nel thread che aspetta, non in uno parallelo: passandolo
    // fuori da un blocco asincrono si finisce per leggerlo mentre l'altro thread
    // lo sta ancora scrivendo, e il processo muore dentro CoreFoundation con un
    // messaggio che non nomina nessuna riga di questo file.
    __block NSData *out = nil;
    __block BOOL finished = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *d = nil;
        @try { d = [p.fileHandleForReading readDataToEndOfFile]; } @catch (NSException *e) { d = nil; }
        @synchronized (p) { out = d; finished = YES; }
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC)))) {
        @try { [t terminate]; } @catch (NSException *e) {}
        return @"";
    }
    NSData *safe = nil;
    @synchronized (p) { if (finished) safe = out; }
    if (!safe.length) return @"";
    NSString *str = [[NSString alloc] initWithData:safe encoding:NSUTF8StringEncoding];
    return str ?: @"";
}


// ---------------------------------------------------------------------------
// Dati
// ---------------------------------------------------------------------------

// Le app le legge dal file del catalogo invece di chiamare winfleet: il pannello si
// apre sotto il mouse e deve essere gia' pieno, non riempirsi mezzo secondo dopo.
static NSArray<NSString *> *hostApps(void) {
    NSString *tsv = [NSString stringWithContentsOfFile:[kConfig stringByAppendingPathComponent:@"host-apps.tsv"]
                                              encoding:NSUTF8StringEncoding error:nil];
    if (!tsv.length) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *line in [tsv componentsSeparatedByString:@"\n"]) {
        NSArray *f = [line componentsSeparatedByString:@"\t"];
        if (f.count >= 2 && [f[0] length]) [out addObject:f[0]];
    }
    [out sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return out;
}

// Lo stato del PC: acceso, sospeso, o acceso ma bloccato (che e' il caso in cui
// tutto sembra a posto e le finestre sono nere). Si misura con una connessione TCP
// alla porta di Sunshine invece che con un ping: risponde solo se il servizio c'e'
// davvero, ed e' esattamente cio' che serve sapere.
typedef enum { WFDown, WFUp, WFLocked } WFState;

static WFState gState = WFDown;

static WFState probeHost(void) {
    NSString *cfg = [NSString stringWithContentsOfFile:[kConfig stringByAppendingPathComponent:@"config.env"]
                                              encoding:NSUTF8StringEncoding error:nil];
    NSString *host = nil;
    for (NSString *line in [cfg componentsSeparatedByString:@"\n"])
        if ([line hasPrefix:@"HOST_TS="])
            host = [[line substringFromIndex:8] stringByTrimmingCharactersInSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"\"' "]];
    if (!host.length) return WFDown;

    // Un socket vero con timeout breve, aperto qui invece che con nc in una shell:
    // il pannello non deve mai restare fermo ad aspettare un PC spento, e far
    // partire una shell per una domanda di due secondi e' sproporzionato.
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return WFDown;
    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(47990);
    a.sin_addr.s_addr = inet_addr(host.UTF8String);
    BOOL up = (a.sin_addr.s_addr != INADDR_NONE) && connect(fd, (struct sockaddr *)&a, sizeof a) == 0;
    close(fd);
    return up ? WFUp : WFDown;
}

// Quali finestre sono aperte adesso, lette dai file di stato degli slot: costa
// nulla e non richiede che il PC risponda.
typedef struct { int slot; BOOL busy; } WFSlot;

static NSArray<NSDictionary *> *openWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < 8; i++) {
        NSString *f = [kConfig stringByAppendingPathComponent:[NSString stringWithFormat:@"slot%d.state", i]];
        NSString *s = [NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil];
        if (!s.length) continue;
        NSString *app = nil, *sup = nil;
        for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"app="]) app = [line substringFromIndex:4];
            if ([line hasPrefix:@"sup="]) sup = [line substringFromIndex:4];
        }
        if (!app.length || !sup.length) continue;
        // Uno stato vecchio non vuol dire finestra viva: si controlla il supervisore.
        if (kill((pid_t)sup.intValue, 0) != 0) continue;
        [out addObject:@{@"slot": @(i), @"app": app}];
    }
    return out;
}

// ---------------------------------------------------------------------------
// Riga dell'elenco
// ---------------------------------------------------------------------------

// Un NSPanel senza barra del titolo rifiuta di diventare finestra chiave, e senza
// quello il campo di ricerca non prende la tastiera: si aprirebbe un pannello in cui
// non si puo' scrivere, cioe' l'unica cosa per cui esiste.
@interface WFPanel : NSPanel
@end
@implementation WFPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface WFRow : NSTableCellView
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, strong) NSImageView *icon;
@end

@implementation WFRow
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _icon = [[NSImageView alloc] initWithFrame:NSMakeRect(8, 4, 18, 18)];
        _label = [[NSTextField alloc] initWithFrame:NSMakeRect(34, 3, f.size.width - 42, 18)];
        _label.bezeled = NO; _label.editable = NO; _label.drawsBackground = NO;
        _label.font = [NSFont systemFontOfSize:13];
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _label.autoresizingMask = NSViewWidthSizable;
        [self addSubview:_icon]; [self addSubview:_label];
    }
    return self;
}
@end

// ---------------------------------------------------------------------------
// Il pannello
// ---------------------------------------------------------------------------

@interface WFDock : NSObject <NSApplicationDelegate, NSTableViewDataSource,
                              NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate>
@property (nonatomic, strong) WFPanel      *panel;
@property (nonatomic, strong) NSSearchField *search;
@property (nonatomic, strong) NSTextField  *status;
@property (nonatomic, strong) NSTextField  *notice;
@property (nonatomic, strong) NSProgressIndicator *spin;
@property (nonatomic, strong) NSButton     *power;
@property (nonatomic, strong) NSTableView  *table;
@property (nonatomic, strong) NSArray      *rows;      // righe mostrate ora
@property (nonatomic, strong) NSArray      *apps;      // catalogo completo
@property (nonatomic, strong) NSArray      *windows;   // finestre aperte
@end

@implementation WFDock

// Il click sull'icona nel Dock quando non ci sono finestre aperte: e' il gesto
// naturale per "fammi vedere cosa c'e'", ed e' l'unico modo di aprire il pannello.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)vis {
    [self toggle];
    return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [self build];
    [self toggle];      // il primo avvio e' gia' una richiesta di vederlo
}

- (void)build {
    NSRect frame = NSMakeRect(0, 0, 340, 420);
    self.panel = [[WFPanel alloc] initWithContentRect:frame
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView
                                              backing:NSBackingStoreBuffered defer:NO];
    self.panel.titlebarAppearsTransparent = YES;
    self.panel.titleVisibility = NSWindowTitleHidden;
    self.panel.movableByWindowBackground = YES;
    self.panel.hidesOnDeactivate = YES;   // si e' scelto: sparisce
    self.panel.delegate = self;
    self.panel.level = NSFloatingWindowLevel;

    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:frame];
    bg.material = NSVisualEffectMaterialPopover;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bg.state = NSVisualEffectStateActive;
    bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.panel.contentView = bg;

    // La riga di stato in cima: dice se il PC c'e', e da li' lo si accende o si
    // sospende. Senza, l'unica risposta a "perche' non si apre niente" e' provare.
    self.status = [[NSTextField alloc] initWithFrame:NSMakeRect(14, frame.size.height - 26, 200, 16)];
    self.status.bezeled = NO; self.status.editable = NO; self.status.drawsBackground = NO;
    self.status.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.status.autoresizingMask = NSViewMinYMargin;
    [bg addSubview:self.status];

    self.power = [[NSButton alloc] initWithFrame:NSMakeRect(frame.size.width - 96, frame.size.height - 30, 84, 20)];
    self.power.bezelStyle = NSBezelStyleInline;
    self.power.font = [NSFont systemFontOfSize:11];
    self.power.target = self;
    self.power.action = @selector(togglePower:);
    self.power.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;
    [bg addSubview:self.power];

    self.search = [[NSSearchField alloc] initWithFrame:NSMakeRect(12, frame.size.height - 70, 316, 24)];
    self.search.placeholderString = @"Cerca un'app sul PC";
    self.search.delegate = self;
    // NSSearchField manda l'azione al bersaglio invece di passare Invio al delegato
    // (sendsAction... di serie invia a fine ricerca, non alla pressione): senza
    // questo si digita, si vede la voce giusta selezionata, si preme Invio e non
    // succede niente.
    self.search.target = self;
    self.search.action = @selector(activateRow:);
    self.search.sendsWholeSearchString = YES;
    self.search.sendsSearchStringImmediately = NO;
    self.search.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.search.focusRingType = NSFocusRingTypeNone;
    [bg addSubview:self.search];

    self.spin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(14, frame.size.height - 92, 14, 14)];
    self.spin.style = NSProgressIndicatorStyleSpinning;
    self.spin.controlSize = NSControlSizeSmall;
    self.spin.hidden = YES;
    self.spin.autoresizingMask = NSViewMinYMargin;
    [bg addSubview:self.spin];

    self.notice = [[NSTextField alloc] initWithFrame:NSMakeRect(34, frame.size.height - 94, 292, 16)];
    self.notice.bezeled = NO; self.notice.editable = NO; self.notice.drawsBackground = NO;
    self.notice.font = [NSFont systemFontOfSize:11];
    self.notice.lineBreakMode = NSLineBreakByTruncatingTail;
    self.notice.hidden = YES;
    self.notice.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [bg addSubview:self.notice];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 8, 324, frame.size.height - 86)];
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    self.table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"c"];
    col.width = 300;
    [self.table addTableColumn:col];
    self.table.headerView = nil;
    self.table.rowHeight = 26;
    self.table.backgroundColor = NSColor.clearColor;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.target = self;
    self.table.doubleAction = @selector(activateRow:);
    self.table.action = @selector(activateRow:);      // un click basta: e' un menu
    self.table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    scroll.documentView = self.table;
    [bg addSubview:scroll];
}

// Si ricarica tutto a ogni apertura: le finestre aperte cambiano senza che il
// pannello ne sappia niente, e mostrarne un elenco vecchio e' peggio che non
// mostrarlo.
- (void)toggle {
    if (self.panel.isVisible) { [self.panel orderOut:nil]; return; }
    self.apps = hostApps();
    self.windows = openWindows();
    [self refreshState];
    self.search.stringValue = @"";
    [self done:nil];
    [self filter:@""];

    // Centrato sullo schermo che si sta guardando. Le due alternative provate erano
    // peggio: sotto il puntatore lo faceva comparire su un altro schermo quando il
    // mouse era altrove, e ancorato al Dock lo incollava a un bordo, dove per
    // leggerlo bisogna comunque spostare lo sguardo. Un pannello che si apre al
    // centro si trova sempre, ed e' dove l'occhio e' gia'.
    //
    // "Lo schermo che si sta guardando" e' quello con la finestra attiva, non quello
    // con il puntatore: si puo' aver lasciato il mouse su un monitor e stare
    // lavorando su un altro.
    NSScreen *scr = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSPoint m = NSEvent.mouseLocation;
    for (NSScreen *s in NSScreen.screens) if (NSPointInRect(m, s.frame)) { scr = s; break; }

    NSRect vis = scr.visibleFrame, f = self.panel.frame;
    // Leggermente sopra il centro: un pannello centrato esatto sembra basso, perche'
    // si legge dall'alto e il peso visivo sta nelle prime righe.
    CGFloat x = NSMidX(vis) - f.size.width / 2;
    CGFloat y = NSMidY(vis) - f.size.height / 2 + f.size.height * 0.08;
    x = MAX(NSMinX(vis) + 8, MIN(x, NSMaxX(vis) - f.size.width - 8));
    y = MAX(NSMinY(vis) + 8, MIN(y, NSMaxY(vis) - f.size.height - 8));
    [self.panel setFrameOrigin:NSMakePoint(x, y)];

    [NSApp activateIgnoringOtherApps:YES];
    [self.panel makeKeyAndOrderFront:nil];
    // Il fuoco va dato dopo che il pannello e' davvero davanti: farlo nello stesso
    // giro di eventi lo assegna a una finestra che non e' ancora quella chiave, e il
    // campo resta li' con il cursore che lampeggia senza ricevere niente — si scrive
    // e non compare nulla, che e' il modo peggiore di rompersi.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.panel makeFirstResponder:self.search];
        [self.search selectText:nil];
    });
}

// La ricerca guarda dentro il nome, non solo l'inizio: e' l'unico motivo per cui
// questo pannello esiste invece del menu in barra, dove "note" non trova
// "Blocco note".
- (void)filter:(NSString *)q {
    NSMutableArray *rows = [NSMutableArray array];

    for (NSDictionary *w in self.windows) {
        NSString *app = w[@"app"];
        if (q.length && [app rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        [rows addObject:@{@"kind": @"win", @"title": app, @"slot": w[@"slot"]}];
    }
    if (rows.count) [rows insertObject:@{@"kind": @"head", @"title": @"Finestre aperte"} atIndex:0];

    NSMutableArray *found = [NSMutableArray array];
    for (NSString *a in self.apps) {
        if (q.length && [a rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        [found addObject:@{@"kind": @"app", @"title": a}];
    }
    if (found.count) {
        if (q.length) {
            // Mentre si cerca i gruppi sono d'intralcio: si vuole la lista corta,
            // ordinata per quanto somiglia a quello che si e' scritto.
            [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                BOOL pa = [a[@"title"] rangeOfString:q options:NSCaseInsensitiveSearch|NSAnchoredSearch].location != NSNotFound;
                BOOL pb = [b[@"title"] rangeOfString:q options:NSCaseInsensitiveSearch|NSAnchoredSearch].location != NSNotFound;
                if (pa != pb) return pa ? NSOrderedAscending : NSOrderedDescending;
                return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
            }];
            [rows addObject:@{@"kind": @"head", @"title": @"App trovate"}];
            [rows addObjectsFromArray:found];
        } else {
            // Settantadue voci di fila non sono un elenco, sono un muro. Si
            // raggruppano per iniziale, che e' l'unico criterio che non richiede di
            // sapere cos'e' ogni app e che regge quando ne installi una nuova.
            NSString *cur = nil;
            for (NSDictionary *a in found) {
                NSString *ini = [[a[@"title"] substringToIndex:1] uppercaseString];
                if (![ini isEqual:cur]) { cur = ini; [rows addObject:@{@"kind": @"head", @"title": ini}]; }
                [rows addObject:a];
            }
        }
    }

    if (!q.length) {
        [rows addObject:@{@"kind": @"head", @"title": @"Strumenti"}];
        [rows addObject:@{@"kind": @"cmd", @"title": @"Esplora file",     @"cmd": @"explorer"}];
        [rows addObject:@{@"kind": @"cmd", @"title": @"Gestione attività", @"cmd": @"taskmgr"}];
        [rows addObject:@{@"kind": @"cmd", @"title": @"Chiudi tutte le finestre", @"cmd": @"stop"}];
    }

    self.rows = rows;
    [self.table reloadData];
    // Si preseleziona la prima voce vera: cosi' si cerca e si preme Invio senza
    // toccare le frecce.
    for (NSUInteger i = 0; i < rows.count; i++) {
        if (![rows[i][@"kind"] isEqual:@"head"]) {
            [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
            break;
        }
    }
}

// Il riscontro: una riga sotto la ricerca che dice cosa sta succedendo. Serve a
// coprire i venti secondi fra il click e la finestra, che senza niente sullo schermo
// sono venti secondi in cui il programma sembra rotto.
- (void)busy:(NSString *)what {
    self.notice.stringValue = what ?: @"";
    self.notice.textColor = NSColor.secondaryLabelColor;
    [self showNotice:YES];
    [self.spin startAnimation:nil];
    self.spin.hidden = NO;
}

- (void)done:(NSString *)err {
    [self.spin stopAnimation:nil];
    self.spin.hidden = YES;
    if (!err) { [self showNotice:NO]; return; }
    self.notice.stringValue = err;
    self.notice.textColor = NSColor.systemRedColor;
    [self showNotice:YES];
}

// La riga di avviso non lascia il suo spazio quando non c'e': una fascia vuota fra
// la ricerca e l'elenco si nota, e sembra un difetto di allineamento invece che
// posto riservato a un messaggio che compare di rado.
- (void)showNotice:(BOOL)on {
    if (self.notice.hidden == !on) return;
    self.notice.hidden = !on;
    NSView *scroll = self.table.enclosingScrollView.superview ?: self.table.enclosingScrollView;
    NSScrollView *sv = self.table.enclosingScrollView;
    NSRect f = sv.frame;
    CGFloat gap = 24;
    if (on) { f.size.height -= gap; }
    else    { f.size.height += gap; }
    sv.frame = f;
    (void)scroll;
}

// Lo stato si chiede in secondo piano: interrogare la rete mentre si apre il
// pannello lo farebbe comparire mezzo secondo dopo il click, e mezzo secondo su un
// menu si nota.
- (void)refreshState {
    [self paint:gState];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        WFState st = probeHost();
        dispatch_async(dispatch_get_main_queue(), ^{ gState = st; [self paint:st]; });
    });
}

- (void)paint:(WFState)st {
    switch (st) {
        case WFUp:
            self.status.stringValue = @"● PC acceso";
            self.status.textColor = [NSColor systemGreenColor];
            self.power.title = @"Sospendi";
            break;
        case WFLocked:
            self.status.stringValue = @"● PC bloccato";
            self.status.textColor = [NSColor systemOrangeColor];
            self.power.title = @"Sospendi";
            break;
        default:
            self.status.stringValue = @"○ PC spento";
            self.status.textColor = [NSColor secondaryLabelColor];
            self.power.title = @"Accendi";
            break;
    }
}

static void runPc(NSString *arg) {
    NSTask *t = [NSTask new];
    t.launchPath = [NSHomeDirectory() stringByAppendingPathComponent:@"bin/pc"];
    t.arguments = @[arg];
    @try { [t launch]; } @catch (NSException *e) { logLine([@"pc non disponibile: " stringByAppendingString:arg]); }
}

// Accendere e' un click solo: e' gratis e reversibile. Spegnere no, quindi passa da
// un menu con due voci distinte — sospendere e spegnere non sono la stessa cosa e
// confonderle costa caro: da spento il PC si riaccende solo con il Wake-on-LAN, che
// richiede una voce del BIOS non ancora attiva. Il menu lo dice invece di lasciarlo
// scoprire a PC spento.
- (void)togglePower:(id)sender {
    if (gState == WFDown) {
        logLine(@"accendo il PC");
        [self busy:@"accendo il PC…"];
        runPc(@"wake");
        // Ricontrollo da solo: accendere ci mette una ventina di secondi e nessuno
        // vuole riaprire il pannello per sapere se e' andata.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ [self done:nil]; [self refreshState]; });
        return;
    }

    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *sl = [m addItemWithTitle:@"Sospendi  (si riaccende dal Mac)"
                                  action:@selector(doSleep:) keyEquivalent:@""];
    sl.target = self;
    NSMenuItem *off = [m addItemWithTitle:@"Spegni  (poi va acceso a mano)"
                                   action:@selector(doShutdown:) keyEquivalent:@""];
    off.target = self;
    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem *rb = [m addItemWithTitle:@"Riavvia" action:@selector(doReboot:) keyEquivalent:@""];
    rb.target = self;
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, -4) inView:self.power];
}

- (void)doSleep:(id)sender {
    logLine(@"sospendo il PC");
    runPc(@"sleep");
    [self.panel orderOut:nil];
}

// Spegnere e' l'unica azione qui che non si annulla da sola: da spento il magic
// packet non basta finche' il BIOS non e' configurato, quindi si chiede conferma.
// Non e' cerimonia: e' la differenza fra riaccenderlo dal divano e alzarsi.
- (void)doShutdown:(id)sender {
    NSAlert *a = [NSAlert new];
    a.messageText = @"Spegnere il PC?";
    a.informativeText = @"Da spento non si riaccende dal Mac: il Wake-on-LAN richiede "
                        @"una voce del BIOS non ancora attiva. Per riaccenderlo dovrai "
                        @"premere il pulsante.\n\nSe vuoi solo metterlo a riposo, usa Sospendi.";
    [a addButtonWithTitle:@"Spegni"];
    [a addButtonWithTitle:@"Annulla"];
    a.alertStyle = NSAlertStyleWarning;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    logLine(@"spengo il PC");
    runPc(@"off");
    [self.panel orderOut:nil];
}

- (void)doReboot:(id)sender {
    logLine(@"riavvio il PC");
    runPc(@"reboot");
    [self.panel orderOut:nil];
}

- (void)controlTextDidChange:(NSNotification *)n { [self filter:self.search.stringValue]; }

// Invio apre, Esc chiude, le frecce scorrono l'elenco pur restando nel campo: la
// tastiera deve bastare, o tanto vale usare il menu in barra.
- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)s {
    if (s == @selector(insertNewline:))   { [self activateRow:nil]; return YES; }
    if (s == @selector(cancelOperation:)) { [self.panel orderOut:nil]; return YES; }
    if (s == @selector(moveDown:) || s == @selector(moveUp:)) {
        NSInteger i = self.table.selectedRow;
        NSInteger step = (s == @selector(moveDown:)) ? 1 : -1;
        for (NSInteger k = i + step; k >= 0 && k < (NSInteger)self.rows.count; k += step) {
            if (![self.rows[k][@"kind"] isEqual:@"head"]) {
                [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:k] byExtendingSelection:NO];
                [self.table scrollRowToVisible:k];
                break;
            }
        }
        return YES;
    }
    return NO;
}

- (void)activateRow:(id)sender {
    NSInteger i = self.table.selectedRow;

    if (i < 0 || i >= (NSInteger)self.rows.count) return;
    NSDictionary *r = self.rows[i];
    NSString *kind = r[@"kind"], *title = r[@"title"];
    if ([kind isEqual:@"head"]) return;

    if ([kind isEqual:@"app"]) {
        // Il pannello resta e dice cosa sta facendo. Chiuderlo subito sembrava
        // pulito, ma aprire una finestra ci mette una ventina di secondi: sparire
        // senza lasciare traccia significa non sapere se il click e' arrivato, se
        // sta caricando o se e' fallito. Si chiude quando la finestra c'e'.
        [self busy:[NSString stringWithFormat:@"apro %@…", title]];
        runArgs(@[@"open", title], ^(BOOL ok, NSString *msg) {
            if (ok) { [self done:nil]; [self.panel orderOut:nil]; }
            else    { [self done:msg.length ? msg : @"non si e' aperta"]; }
        });
        return;
    }

    [self.panel orderOut:nil];      // le altre azioni sono immediate

    if ([kind isEqual:@"win"]) {
        // La finestra c'e' gia': si porta davanti invece di riaprirla.
        logLine([@"attiva finestra " stringByAppendingString:title]);
        for (NSRunningApplication *a in NSWorkspace.sharedWorkspace.runningApplications)
            if ([a.localizedName isEqual:title] || [a.localizedName containsString:@"Moonlight"])
                [a activateWithOptions:0];
    } else if ([kind isEqual:@"cmd"]) {
        NSString *c = r[@"cmd"];
        if ([c isEqual:@"stop"])          runArgs(@[@"stop"], nil);
        else if ([c isEqual:@"explorer"]) runArgs(@[@"open", @"Esplora file"], nil);
        else                              runArgs(@[@"open", @"Gestione attività"], nil);
    }
}

// ---- tabella ----
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return self.rows.count; }

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSDictionary *r = self.rows[row];
    WFRow *cell = [t makeViewWithIdentifier:@"r" owner:self];
    if (!cell) {
        cell = [[WFRow alloc] initWithFrame:NSMakeRect(0, 0, col.width, 26)];
        cell.identifier = @"r";
    }
    BOOL head = [r[@"kind"] isEqual:@"head"];
    cell.label.stringValue = r[@"title"];
    cell.label.font = head ? [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
                           : [NSFont systemFontOfSize:13];
    cell.label.textColor = head ? NSColor.secondaryLabelColor : NSColor.labelColor;
    cell.icon.image = nil;

    if ([r[@"kind"] isEqual:@"app"] || [r[@"kind"] isEqual:@"win"]) {
        // L'icona vera dell'app, quella gia' estratta dall'eseguibile di Windows per
        // i lanciatori: se non c'e' si resta senza, che e' meglio di un segnaposto
        // uguale per tutti.
        NSString *icns = [NSString stringWithFormat:@"%@/icons/%@.icns", kConfig, r[@"title"]];
        if ([NSFileManager.defaultManager fileExistsAtPath:icns])
            cell.icon.image = [[NSImage alloc] initWithContentsOfFile:icns];
    }
    if ([r[@"kind"] isEqual:@"win"])
        cell.label.stringValue = [NSString stringWithFormat:@"%@  ▸ aperta", r[@"title"]];
    return cell;
}

- (BOOL)tableView:(NSTableView *)t shouldSelectRow:(NSInteger)row {
    return ![self.rows[row][@"kind"] isEqual:@"head"];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        kConfig = [home stringByAppendingPathComponent:@".config/winfleet"];
        kCli = [home stringByAppendingPathComponent:@".local/bin/winfleet"];
        if (![NSFileManager.defaultManager isExecutableFileAtPath:kCli]) {
            for (NSString *p in @[@"/usr/local/bin/winfleet", @"/opt/homebrew/bin/winfleet"])
                if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) { kCli = p; break; }
        }
        NSApplication *app = NSApplication.sharedApplication;
        WFDock *d = [WFDock new];
        app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];   // nel Dock
        [app run];
    }
    return 0;
}
