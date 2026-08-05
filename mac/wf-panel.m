// Il pannello di WinFleet: una tendina da cui si vede e si comanda il PC.
//
// Sta nella barra dei menu e non nel Dock perche' e' un pannello, non un'app da
// aprire e chiudere: serve mentre stai facendo altro. Il menu si ricostruisce ogni
// volta che lo apri — un elenco di finestre e' vero solo nell'istante in cui lo
// guardi, e mostrarne uno vecchio e' peggio che non mostrarlo.
//
// Le app si cercano digitando: i menu di macOS saltano alla voce mentre scrivi, e per
// settantasei app e' piu' veloce di qualsiasi campo di ricerca da costruire.
//
//   clang -framework Cocoa -o WinFleet wf-panel.m

#import <Cocoa/Cocoa.h>

static NSString *kCli;      // percorso del comando winfleet
static NSString *kConfig;   // ~/.config/winfleet

// Comandi lanciati staccati: aprire una finestra ci mette secondi, e il menu deve
// chiudersi subito invece di restare li' bloccato.
static void runDetached(NSString *cmd) {
    NSTask *t = [NSTask new];
    t.launchPath = @"/bin/sh";
    t.arguments = @[@"-c", cmd];
    @try { [t launch]; } @catch (NSException *e) { NSLog(@"winfleet: %@", e); }
}

static NSString *runCapture(NSString *cmd) {
    NSTask *t = [NSTask new];
    NSPipe *p = [NSPipe pipe];
    t.launchPath = @"/bin/sh";
    t.arguments = @[@"-c", cmd];
    t.standardOutput = p;
    t.standardError = [NSPipe pipe];
    @try { [t launch]; } @catch (NSException *e) { return @""; }
    NSData *d = [p.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *shellQuote(NSString *s) {
    return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

@interface Panel : NSObject <NSMenuDelegate>
@property (strong) NSStatusItem *item;
@property (strong) NSString *agent;     // indirizzo dell'agente, risolto una volta
@end

@implementation Panel

- (NSString *)agentAddr {
    if (_agent) return _agent;
    // Stesse regole del comando: l'indirizzo numerico, non il nome mDNS, che a ogni
    // richiesta costerebbe due decimi di secondo.
    NSString *cfg = [NSString stringWithContentsOfFile:[kConfig stringByAppendingPathComponent:@"config.env"]
                                              encoding:NSUTF8StringEncoding error:nil] ?: @"";
    for (NSString *line in [cfg componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"HOST_LAN="]) {
            NSString *v = [[line substringFromIndex:9] stringByTrimmingCharactersInSet:
                           [NSCharacterSet characterSetWithCharactersInString:@"\" "]];
            if (v.length) { _agent = v; break; }
        }
    }
    if (!_agent) _agent = @"";
    return _agent;
}

// --- voci del menu ---------------------------------------------------------------

- (void)openApp:(NSMenuItem *)sender {
    NSArray *pair = sender.representedObject;   // @[nome, exe]
    NSString *cmd = [NSString stringWithFormat:@"PICKED_EXE=%@ %@ open %@ >/dev/null 2>&1",
                     shellQuote(pair[1]), shellQuote(kCli), shellQuote(pair[0])];
    runDetached(cmd);
}

- (void)focusWindow:(NSMenuItem *)sender {
    pid_t pid = (pid_t)[sender.representedObject intValue];
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    [app activateWithOptions:NSApplicationActivateAllWindows];
}

- (void)raiseRemote:(NSMenuItem *)sender {
    NSString *cmd = [NSString stringWithFormat:@"curl -s --max-time 2 'http://%@:48088/raise?hwnd=%@' >/dev/null",
                     [self agentAddr], sender.representedObject];
    runDetached(cmd);
}

- (void)closeAll:(id)sender { runDetached([NSString stringWithFormat:@"%@ stop >/dev/null 2>&1", shellQuote(kCli)]); }
- (void)rescan:(id)sender   { runDetached([NSString stringWithFormat:@"%@ scan >/dev/null 2>&1", shellQuote(kCli)]); }
- (void)quit:(id)sender     { [NSApp terminate:nil]; }

// --- costruzione del menu --------------------------------------------------------

- (void)addHeader:(NSString *)title to:(NSMenu *)menu {
    NSMenuItem *h = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    h.enabled = NO;
    [menu addItem:h];
}

// Le finestre aperte adesso sul Mac, lette dallo stato che il comando tiene per ogni
// slot. Cliccarne una la porta davanti.
- (BOOL)addMacWindows:(NSMenu *)menu {
    BOOL any = NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *files = [[fm contentsOfDirectoryAtPath:kConfig error:nil]
                      sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *f in files) {
        if (![f hasPrefix:@"slot"] || ![f hasSuffix:@".state"]) continue;
        NSString *txt = [NSString stringWithContentsOfFile:[kConfig stringByAppendingPathComponent:f]
                                                  encoding:NSUTF8StringEncoding error:nil];
        if (!txt) continue;
        NSString *app = nil, *pid = nil, *mode = nil;
        for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"app="])  app  = [line substringFromIndex:4];
            if ([line hasPrefix:@"pid="])  pid  = [line substringFromIndex:4];
            if ([line hasPrefix:@"mode="]) mode = [line substringFromIndex:5];
        }
        if (!app.length || !pid.length) continue;
        if (kill((pid_t)pid.intValue, 0) != 0) continue;    // finestra gia' chiusa
        if (!any) { [self addHeader:@"Aperte sul Mac" to:menu]; any = YES; }
        NSMenuItem *mi = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"  %@  (%@)", app, mode ?: @""]
                   action:@selector(focusWindow:) keyEquivalent:@""];
        mi.target = self;
        mi.representedObject = pid;
        [menu addItem:mi];
    }
    return any;
}

// Le app installate sul PC, dal catalogo che "winfleet scan" tiene aggiornato.
// Digitando si salta alla voce: e' la ricerca, senza costruirne una.
- (void)addAppList:(NSMenu *)menu {
    NSString *tsv = [NSString stringWithContentsOfFile:[kConfig stringByAppendingPathComponent:@"host-apps.tsv"]
                                              encoding:NSUTF8StringEncoding error:nil];
    NSMenu *sub = [NSMenu new];
    int n = 0;
    for (NSString *line in [(tsv ?: @"") componentsSeparatedByString:@"\n"]) {
        NSArray *parts = [line componentsSeparatedByString:@"\t"];
        if (parts.count < 2 || [parts[0] length] == 0) continue;
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:parts[0]
                                                    action:@selector(openApp:) keyEquivalent:@""];
        mi.target = self;
        mi.representedObject = @[parts[0], parts[1]];
        [sub addItem:mi];
        n++;
    }
    if (n == 0) {
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:@"catalogo vuoto — rileggi le app"
                                                    action:@selector(rescan:) keyEquivalent:@""];
        mi.target = self;
        [sub addItem:mi];
    } else {
        [sub addItem:[NSMenuItem separatorItem]];
        NSMenuItem *r = [[NSMenuItem alloc] initWithTitle:@"Rileggi le app dal PC"
                                                   action:@selector(rescan:) keyEquivalent:@""];
        r.target = self;
        [sub addItem:r];
    }
    NSMenuItem *top = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"Apri un'app  (%d)", n] action:nil keyEquivalent:@""];
    top.submenu = sub;
    [menu addItem:top];
}

// Cosa e' aperto di la'. Serve a ritrovare una finestra che sta su uno schermo che
// non stai guardando: cliccandola la si porta in primo piano su Windows.
- (void)addRemoteWindows:(NSMenu *)menu {
    NSString *addr = [self agentAddr];
    NSMenu *sub = [NSMenu new];
    int n = 0;
    if (addr.length) {
        NSString *out = runCapture([NSString stringWithFormat:
            @"curl -s --max-time 2 'http://%@:48088/windows'", addr]);
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
            NSArray *parts = [line componentsSeparatedByString:@"\t"];
            if (parts.count < 2 || [parts[1] length] == 0) continue;
            NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:parts[1]
                                                        action:@selector(raiseRemote:) keyEquivalent:@""];
            mi.target = self;
            mi.representedObject = parts[0];
            [sub addItem:mi];
            n++;
        }
    }
    if (n == 0) {
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:@"nessuna, o agente non raggiungibile"
                                                    action:nil keyEquivalent:@""];
        mi.enabled = NO;
        [sub addItem:mi];
    }
    NSMenuItem *top = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"Finestre sul PC  (%d)", n] action:nil keyEquivalent:@""];
    top.submenu = sub;
    [menu addItem:top];
}

- (void)addTool:(NSString *)title exe:(NSString *)exe to:(NSMenu *)menu {
    NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:title action:@selector(openApp:) keyEquivalent:@""];
    mi.target = self;
    mi.representedObject = @[title, exe];
    [menu addItem:mi];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    if (getenv("WF_PANEL_DEBUG")) NSLog(@"WFPANEL costruisco la tendina");

    if ([self addMacWindows:menu]) [menu addItem:[NSMenuItem separatorItem]];

    [self addAppList:menu];
    [self addRemoteWindows:menu];
    [menu addItem:[NSMenuItem separatorItem]];

    [self addHeader:@"Windows" to:menu];
    [self addTool:@"Esplora file"      exe:@"C:\\Windows\\explorer.exe"           to:menu];
    [self addTool:@"Gestione attività" exe:@"C:\\Windows\\System32\\Taskmgr.exe"  to:menu];
    [self addTool:@"Pannello di controllo" exe:@"C:\\Windows\\System32\\control.exe" to:menu];
    [self addTool:@"Prompt dei comandi" exe:@"C:\\Windows\\System32\\cmd.exe"     to:menu];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *c = [[NSMenuItem alloc] initWithTitle:@"Chiudi tutte le finestre"
                                               action:@selector(closeAll:) keyEquivalent:@"w"];
    c.target = self;
    [menu addItem:c];
    NSMenuItem *q = [[NSMenuItem alloc] initWithTitle:@"Esci dal pannello"
                                               action:@selector(quit:) keyEquivalent:@"q"];
    q.target = self;
    [menu addItem:q];
    if (getenv("WF_PANEL_DEBUG")) NSLog(@"WFPANEL voci: %ld", (long)menu.numberOfItems);
}

- (void)start {
    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *img = [NSImage imageWithSystemSymbolName:@"macwindow.on.rectangle"
                             accessibilityDescription:@"WinFleet"];
    if (img) { img.template = YES; self.item.button.image = img; }
    else     { self.item.button.title = @"WF"; }

    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    self.item.menu = menu;
}
@end

int main(void) {
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        kConfig = [home stringByAppendingPathComponent:@".config/winfleet"];
        kCli = [home stringByAppendingPathComponent:@".local/bin/winfleet"];
        if (![NSFileManager.defaultManager isExecutableFileAtPath:kCli]) {
            kCli = [home stringByAppendingPathComponent:@"Projects/winfleet/bin/winfleet"];
        }

        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;   // barra dei menu, non Dock
        // Riferimento che dura: il menu tiene il delegato in modo debole, e se il
        // pannello venisse liberato la tendina si aprirebbe vuota senza un errore.
        static Panel *p;
        p = [Panel new];
        [p start];
        [NSApp run];
    }
    return 0;
}
