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
static void runArgs(NSArray<NSString *> *args) {
    logLine([args componentsJoinedByString:@"  "]);
    NSTask *t = [NSTask new];
    t.launchPath = kCli;
    t.arguments = args;
    // Una app lanciata dal Finder ha un PATH minimo: winfleet chiama ssh, curl e
    // clang, e senza questo li cercherebbe dove non ci sono.
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"PATH"] = @"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    t.environment = env;
    @try { [t launch]; }
    @catch (NSException *e) { logLine([@"ERRORE: " stringByAppendingString:e.reason]); }
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

    __block NSData *out = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        out = [p.fileHandleForReading readDataToEndOfFile];
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC)))) {
        [t terminate];
        return @"";
    }
    return [[NSString alloc] initWithData:out ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
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

    self.search = [[NSSearchField alloc] initWithFrame:NSMakeRect(12, frame.size.height - 44, 316, 24)];
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

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 8, 324, frame.size.height - 60)];
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
    self.search.stringValue = @"";
    [self filter:@""];

    // Sopra il Dock, non sotto il mouse. La posizione del mouse sembra la scelta
    // ovvia ma e' sbagliata due volte: quando il pannello si apre con un click
    // sull'icona il mouse e' gia' li' (e allora tanto vale calcolarlo dal Dock), e
    // quando si apre in altro modo il puntatore puo' essere su un altro schermo —
    // il pannello compariva sull'ultrawide mentre il Dock era sul portatile.
    //
    // Lo schermo giusto e' quello che ha il Dock, cioe' quello con la barra dei menu:
    // NSScreen.screens[0], che non cambia con il puntatore.
    NSScreen *scr = NSScreen.screens.firstObject ?: NSScreen.mainScreen;
    NSRect full = scr.frame, vis = scr.visibleFrame, f = self.panel.frame;

    // visibleFrame toglie Dock e barra dei menu: la differenza fra i due rettangoli
    // dice dov'e' il Dock e quanto e' spesso, senza doverlo chiedere a nessuno.
    CGFloat dockBottom = NSMinY(vis) - NSMinY(full);   // Dock in basso
    CGFloat dockLeft   = NSMinX(vis) - NSMinX(full);
    CGFloat dockRight  = NSMaxX(full) - NSMaxX(vis);
    CGFloat x, y;
    NSPoint m = NSEvent.mouseLocation;
    BOOL mouseHere = NSPointInRect(m, full);

    if (dockLeft > 8) {                       // Dock a sinistra
        x = NSMinX(vis) + 8;
        y = mouseHere ? m.y - f.size.height / 2 : NSMidY(vis) - f.size.height / 2;
    } else if (dockRight > 8) {               // Dock a destra
        x = NSMaxX(vis) - f.size.width - 8;
        y = mouseHere ? m.y - f.size.height / 2 : NSMidY(vis) - f.size.height / 2;
    } else {                                  // Dock in basso (o nascosto)
        x = mouseHere ? m.x - f.size.width / 2 : NSMidX(vis) - f.size.width / 2;
        y = NSMinY(full) + MAX(dockBottom, 8) + 8;   // sopra il Dock, mai sotto
    }
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
        [rows addObject:@{@"kind": @"head", @"title": q.length ? @"App trovate" : @"App sul PC"}];
        [rows addObjectsFromArray:found];
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

    [self.panel orderOut:nil];      // si e' scelto: via

    if ([kind isEqual:@"app"]) {
        runArgs(@[@"open", title]);
    } else if ([kind isEqual:@"win"]) {
        // La finestra c'e' gia': si porta davanti invece di riaprirla.
        logLine([@"attiva finestra " stringByAppendingString:title]);
        for (NSRunningApplication *a in NSWorkspace.sharedWorkspace.runningApplications)
            if ([a.localizedName isEqual:title] || [a.localizedName containsString:@"Moonlight"])
                [a activateWithOptions:0];
    } else if ([kind isEqual:@"cmd"]) {
        NSString *c = r[@"cmd"];
        if ([c isEqual:@"stop"])          runArgs(@[@"stop"]);
        else if ([c isEqual:@"explorer"]) runArgs(@[@"open", @"Esplora file"]);
        else                              runArgs(@[@"open", @"Gestione attività"]);
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
