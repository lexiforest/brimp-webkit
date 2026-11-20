#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <WebKit/WKProcessPoolPrivate.h>
#import <WebKit/WKWebViewConfigurationPrivate.h>
#import <WebKit/WKWebViewPrivate.h>
#import <WebKit/_WKAutomationSession.h>
#import <WebKit/_WKAutomationSessionLocalConnection.h>

static void fail(NSString *message)
{
    fprintf(stderr, "%s\n", message.UTF8String);
    exit(1);
}

@interface Consumer : NSObject <WKNavigationDelegate>
@property(nonatomic, strong) WKWebView *view;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) _WKAutomationSession *automation;
@property(nonatomic, copy) NSString *handle;
@property(nonatomic) BOOL automationReady;
@property(nonatomic) BOOL documentReady;
@end

@implementation Consumer
- (void)finishIfReady
{
    if (!_automationReady || !_documentReady)
        return;
    [_view _close];
    [_automation _setMessageToFrontendHandler:nil];
    [_automation terminate];
    puts("WebKit SDK: packaged framework, local Automation, HTTP navigation and JavaScript passed");
    exit(0);
}

- (void)start:(NSURL *)url
{
    WKProcessPool *pool = [WKProcessPool new];
    _automation = [_WKAutomationSession new];
    _automation.sessionIdentifier = NSUUID.UUID.UUIDString;
    [pool _setAutomationSession:_automation];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.processPool = pool;
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    configuration._controlledByAutomation = YES;
    _view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) configuration:configuration];
    _view.navigationDelegate = self;
    _window = [[NSWindow alloc] initWithContentRect:_view.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    _window.contentView = _view;
    _handle = [_automation _registerWebView:_view];
    __weak Consumer *weakSelf = self;
    [_automation _setMessageToFrontendHandler:^(NSString *serialized) {
        Consumer *consumer = weakSelf;
        NSDictionary *message = [NSJSONSerialization JSONObjectWithData:[serialized dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![message[@"id"] isEqual:@1])
            return;
        if (message[@"error"])
            fail([message description]);
        for (NSDictionary *context in message[@"result"][@"contexts"]) {
            if ([context[@"handle"] isEqual:consumer.handle])
                consumer.automationReady = YES;
        }
        if (!consumer.automationReady)
            fail(@"Local Automation did not return the registered page");
        [consumer finishIfReady];
    }];
    [_automation _dispatchMessageFromRemote:@"{\"id\":1,\"method\":\"Automation.getBrowsingContexts\",\"params\":{}}"];
    [_view loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)navigation
{
    [view evaluateJavaScript:@"document.title + ':' + window.result" completionHandler:^(id value, NSError *error) {
        if (error || ![value isEqual:@"WebKit SDK:42"])
            fail(error.description ?: [value description]);
        self.documentReady = YES;
        [self finishIfReady];
    }];
}

- (void)webView:(WKWebView *)view didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    fail(error.description);
}

- (void)webView:(WKWebView *)view didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    fail(error.description);
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)view
{
    fail(@"WebKit content process terminated");
}
@end

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 3)
            fail(@"usage: webkit-sdk-smoke SDK_LIB_DIRECTORY URL");
        NSString *expected = [[[NSString stringWithUTF8String:argv[1]] stringByAppendingPathComponent:@"WebKit.framework"] stringByResolvingSymlinksInPath];
        NSString *loaded = [[NSBundle bundleForClass:WKWebView.class].bundlePath stringByResolvingSymlinksInPath];
        if (![loaded isEqual:expected])
            fail([@"Loaded unexpected WebKit: " stringByAppendingString:loaded]);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        Consumer *consumer = [Consumer new];
        [consumer start:[NSURL URLWithString:[NSString stringWithUTF8String:argv[2]]]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            fail(@"Timed out waiting for packaged WebKit");
        });
        [NSApp run];
    }
    return 0;
}
