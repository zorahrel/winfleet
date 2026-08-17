// Test DISCRIMINANTE del fix sul trascinamento.
//
// Il primo test passava anche senza la dylib, quindi non provava niente: in una
// NSWindow normale il drag della barra lo fa Cocoa da solo. La situazione vera e'
// un'altra: il video copre tutta la finestra e SDL si prende gli eventi prima che
// Cocoa possa trattarli come trascinamento.
//
// Qui quella condizione si riproduce con una vista che copre tutto e ingoia i
// mouseDown, come fa SDL. Senza il fix il click sulla barra finisce alla vista
// (cioe' "dentro Windows"); con il fix il monitor locale della dylib lo prende
// prima e lo gira a Cocoa.
#import <Cocoa/Cocoa.h>

static BOOL gDragCalled = NO;
static BOOL gSwallowed  = NO;

@interface SDLLikeView : NSView @end
@implementation SDLLikeView
- (void)mouseDown:(NSEvent *)e { gSwallowed = YES; NSLog(@"INGOIATO_DA_SDL"); }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
@end

@interface ProbeWindow : NSWindow @end
@implementation ProbeWindow
- (void)performWindowDragWithEvent:(NSEvent *)event { gDragCalled = YES; NSLog(@"DRAG_COCOA"); }
@end

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    ProbeWindow *w = [[ProbeWindow alloc] initWithContentRect:NSMakeRect(100,100,600,400)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
          backing:NSBackingStoreBuffered defer:NO];
    [w setTitle:@"wf-drag-test"];
    w.titlebarAppearsTransparent = YES;
    w.titleVisibility = NSWindowTitleHidden;
    w.styleMask |= NSWindowStyleMaskFullSizeContentView;
    // Il "video": copre tutto, barra compresa.
    SDLLikeView *v = [[SDLLikeView alloc] initWithFrame:NSMakeRect(0,0,600,400)];
    v.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    [w setContentView:v];
    [w makeKeyAndOrderFront:nil];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];

    CGFloat H = w.frame.size.height;
    CGFloat bar = H - [w contentRectForFrameRect:w.frame].size.height;
    if (bar < 1) bar = [NSWindow frameRectForContentRect:NSMakeRect(0,0,100,100)
                                              styleMask:NSWindowStyleMaskTitled].size.height - 100;
    NSLog(@"barra=%.0f", bar);

    gDragCalled = gSwallowed = NO;
    [NSApp sendEvent:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
        location:NSMakePoint(300, H - bar/2) modifierFlags:0 timestamp:0
        windowNumber:w.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1]];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
    NSLog(@"ESITO_BARRA: %@", gDragCalled ? @"PASS (il Mac trascina)"
                                          : (gSwallowed ? @"FAIL (finito dentro Windows)" : @"FAIL (perso)"));

    gDragCalled = gSwallowed = NO;
    [NSApp sendEvent:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
        location:NSMakePoint(300, 80) modifierFlags:0 timestamp:0
        windowNumber:w.windowNumber context:nil eventNumber:2 clickCount:1 pressure:1]];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
    NSLog(@"ESITO_VIDEO: %@", gSwallowed ? @"PASS (il click va a Windows)"
                                         : (gDragCalled ? @"FAIL (rubato il click)" : @"FAIL (perso)"));
    return 0;
} }
