#import "AutomationWorker.h"

#import <Cocoa/Cocoa.h>
#import <WebKit/WKProcessPoolPrivate.h>

@interface AutomationWorkerAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AutomationWorkerAppDelegate {
    AutomationWorker *_worker;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    _worker = [AutomationWorker new];
    if (!_worker) {
        NSLog(@"WebKitAutomationWorker requires --controller-socket-fd=N");
        [NSApp terminate:nil];
        return;
    }
    [_worker start];
}

@end

int main(int argc, char *argv[])
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [WKProcessPool _setLinkedOnOrAfterEverythingForTesting];
#pragma clang diagnostic pop

    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        AutomationWorkerAppDelegate *delegate = [AutomationWorkerAppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
