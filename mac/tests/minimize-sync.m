// Verifica che la dylib reagisca alla minimizzazione: carica wf-chrome nello
// stesso modo in cui lo fa Moonlight, apre una finestra finta che passa per
// "stream window", la minimizza e guarda se parte la chiamata all'agente.
#import <Cocoa/Cocoa.h>
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,400,300)
                                                  styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskClosable
                                                    backing:NSBackingStoreBuffered defer:NO];
        [w setTitle:@"wf-test"];
        [w makeKeyAndOrderFront:nil];
        // Lascia girare il constructor della dylib e il suo timer.
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
        NSLog(@"MINIMIZZO");
        [w miniaturize:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.0]];
        NSLog(@"RIPRISTINO");
        [w deminiaturize:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.0]];
    }
    return 0;
}
