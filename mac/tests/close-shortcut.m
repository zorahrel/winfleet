// Cmd+W chiude la finestra del MAC, e il resto della tastiera resta all'app.
//
// Senza questo, Cmd+W finiva dentro Windows come qualsiasi altro tasto (SDL
// prende la tastiera a livello di finestra) e chiudeva la scheda del browser
// remoto invece della finestra. Ma la cura non deve essere peggiore del male:
// se si intercettasse ogni Cmd, dentro l'app remota non funzionerebbero piu'
// copia, incolla, nuova scheda - cioe' il lavoro vero.
//
// Il test verifica le due cose insieme:
//   Cmd+W       -> chiude la finestra del Mac (performClose)
//   Cmd+T       -> passa all'app, nessuna chiusura
//   Cmd+Shift+W -> passa all'app: in un browser e' "chiudi finestra", non si indovina
#import <Cocoa/Cocoa.h>

static BOOL gClosed = NO;
static BOOL gSwallowed = NO;

@interface SDLLikeView : NSView @end
@implementation SDLLikeView
- (void)keyDown:(NSEvent *)e { gSwallowed = YES; }
- (BOOL)acceptsFirstResponder { return YES; }
@end

@interface ProbeWindow : NSWindow @end
@implementation ProbeWindow
- (void)performClose:(id)sender { gClosed = YES; }   // non si chiude davvero: si annota
@end

static void sendKey(ProbeWindow *w, NSString *ch, NSEventModifierFlags mods) {
    gClosed = gSwallowed = NO;
    NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                  location:NSZeroPoint
                             modifierFlags:mods
                                 timestamp:0
                              windowNumber:w.windowNumber
                                   context:nil
                                characters:ch
               charactersIgnoringModifiers:ch
                                 isARepeat:NO
                                   keyCode:0];
    [NSApp sendEvent:e];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
}

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    ProbeWindow *w = [[ProbeWindow alloc] initWithContentRect:NSMakeRect(100,100,600,400)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
          backing:NSBackingStoreBuffered defer:NO];
    [w setTitle:@"wf-key-test"];
    w.titlebarAppearsTransparent = YES;
    w.titleVisibility = NSWindowTitleHidden;
    w.styleMask |= NSWindowStyleMaskFullSizeContentView;
    SDLLikeView *v = [[SDLLikeView alloc] initWithFrame:NSMakeRect(0,0,600,400)];
    v.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    [w setContentView:v];
    [w makeKeyAndOrderFront:nil];
    [w makeFirstResponder:v];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];

    int fail = 0;

    sendKey(w, @"w", NSEventModifierFlagCommand);
    NSLog(@"ESITO_CMDW: %@", gClosed ? @"PASS" : @"FAIL");
    if (!gClosed) fail++;

    sendKey(w, @"t", NSEventModifierFlagCommand);
    NSLog(@"ESITO_CMDT: %@", (!gClosed) ? @"PASS" : @"FAIL");
    if (gClosed) fail++;

    sendKey(w, @"w", NSEventModifierFlagCommand | NSEventModifierFlagShift);
    NSLog(@"ESITO_CMDSHIFTW: %@", (!gClosed) ? @"PASS" : @"FAIL");
    if (gClosed) fail++;

    return fail;
} }
