#if __has_include("config.h")
#import "config.h"
#endif
#import "AutomationWorker.h"

#import "AutomationPage.h"
#import <Carbon/Carbon.h>
#import <WebKit/WKFrameInfoPrivate.h>
#import <WebKit/WKJSHandle.h>
#import <WebKit/WKProcessPoolPrivate.h>
#import <WebKit/WKSnapshotConfiguration.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewPrivate.h>
#import <WebKit/WKWebsiteDataStore.h>
#import <WebKit/_WKAutomationSession.h>
#import <WebKit/_WKAutomationSessionConfiguration.h>
#import <WebKit/_WKFrameHandle.h>
#import <WebKit/_WKFrameTreeNode.h>
#include <arpa/inet.h>
#include <fcntl.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface NSEvent (AutomationWorkerPrivate)
- (NSEvent *)_eventRelativeToWindow:(NSWindow *)window;
@end

@interface AutomationWorker ()
{
    NSMutableData *_inputBuffer;
    NSFileHandle *_controlSocket;
    _WKAutomationSession *_automationSession;
    WKProcessPool *_processPool;
    WKWebsiteDataStore *_websiteDataStore;
    NSMutableDictionary<NSString *, AutomationPage *> *_pages;
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, WKJSHandle *> *> *_handlesByTarget;
}
- (void)captureScreenshot:(NSDictionary *)parameters webView:(WKWebView *)webView contentSize:(NSSize)contentSize identifier:(id)identifier;
- (void)captureFullPageScreenshot:(NSDictionary *)parameters webView:(WKWebView *)webView contentSize:(NSSize)contentSize identifier:(id)identifier;
- (void)replyTo:(id)identifier withScreenshotImage:(NSImage *)image parameters:(NSDictionary *)parameters;
- (NSDictionary *)remoteObjectForValue:(id)value handles:(NSMutableDictionary<NSString *, WKJSHandle *> *)handles;
@end

@implementation AutomationWorker

static NSDictionary *frameObjectForNode(_WKFrameTreeNode *node)
{
    WKFrameInfo *info = node.info;
    NSURL *url = info.request.URL;
    WKSecurityOrigin *origin = info.securityOrigin;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSString *frameID = info.mainFrame ? @"main" : [NSString stringWithFormat:@"frame-%llu", info._handle.frameID];
#pragma clang diagnostic pop
    NSString *securityOrigin = @"";
    if (origin.protocol.length && origin.host.length)
        securityOrigin = [NSString stringWithFormat:@"%@://%@%@", origin.protocol, origin.host, origin.port ? [NSString stringWithFormat:@":%ld", (long)origin.port] : @""];
    return @{
        @"id": frameID, @"loaderId": frameID, @"url": url.absoluteString ?: @"about:blank",
        @"domainAndRegistry": url.host ?: @"", @"securityOrigin": securityOrigin,
        @"mimeType": @"text/html",
    };
}

static NSDictionary *frameTreeForNode(_WKFrameTreeNode *node)
{
    NSMutableDictionary *tree = [@{ @"frame": frameObjectForNode(node) } mutableCopy];
    if (node.childFrames.count) {
        NSMutableArray *children = [NSMutableArray arrayWithCapacity:node.childFrames.count];
        for (_WKFrameTreeNode *child in node.childFrames)
            [children addObject:frameTreeForNode(child)];
        tree[@"childFrames"] = children;
    }
    return tree;
}

- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    _inputBuffer = [NSMutableData data];
    NSString *socketArgument = [NSProcessInfo.processInfo.arguments filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *argument, NSDictionary *bindings) {
        return [argument hasPrefix:@"--controller-socket-fd="];
    }]].firstObject;
    int descriptor = [[socketArgument substringFromIndex:[@"--controller-socket-fd=" length]] intValue];
    if (!socketArgument || descriptor < 0)
        return nil;
    fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    _controlSocket = [[NSFileHandle alloc] initWithFileDescriptor:descriptor closeOnDealloc:YES];
    _pages = [NSMutableDictionary dictionary];
    _handlesByTarget = [NSMutableDictionary dictionary];
    return self;
}

- (void)start
{
    __weak AutomationWorker *weakSelf = self;
    _controlSocket.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) {
            [NSOperationQueue.mainQueue addOperationWithBlock:^{
                [NSApp terminate:nil];
            }];
            return;
        }
        [NSOperationQueue.mainQueue addOperationWithBlock:^{
            [weakSelf consumeData:data];
        }];
    };
}

- (void)consumeData:(NSData *)data
{
    [_inputBuffer appendData:data];
    while (true) {
        if (_inputBuffer.length < sizeof(uint32_t))
            return;
        uint32_t networkLength = 0;
        [_inputBuffer getBytes:&networkLength length:sizeof(networkLength)];
        NSUInteger length = ntohl(networkLength);
        if (length > 64 * 1024 * 1024) {
            [NSApp terminate:nil];
            return;
        }
        if (_inputBuffer.length < sizeof(uint32_t) + length)
            return;
        NSData *payload = [_inputBuffer subdataWithRange:NSMakeRange(sizeof(uint32_t), length)];
        [_inputBuffer replaceBytesInRange:NSMakeRange(0, sizeof(uint32_t) + length) withBytes:NULL length:0];
        NSError *error = nil;
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:payload options:0 error:&error];
        if (error || ![request isKindOfClass:[NSDictionary class]]) {
            [self send:@{ @"error": @{ @"code": @(-32700), @"message": @"Invalid worker JSON" } }];
            continue;
        }
        [self handleRequest:request];
    }
}

- (void)send:(NSDictionary *)message
{
    if (![NSJSONSerialization isValidJSONObject:message])
        return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    uint32_t networkLength = htonl(data.length);
    NSMutableData *frame = [NSMutableData dataWithBytes:&networkLength length:sizeof(networkLength)];
    [frame appendData:data];
    [_controlSocket writeData:frame];
}

- (void)replyTo:(id)identifier result:(NSDictionary *)result
{
    [self send:@{ @"id": identifier ?: [NSNull null], @"result": result ?: @{ } }];
}

- (void)replyTo:(id)identifier error:(NSString *)message
{
    [self send:@{ @"id": identifier ?: [NSNull null], @"error": @{ @"code": @(-32000), @"message": message ?: @"Worker operation failed" } }];
}

- (void)handleRequest:(NSDictionary *)request
{
    id identifier = request[@"id"];
    NSString *operation = request[@"operation"];
    NSDictionary *parameters = request[@"params"];
    if (![operation isKindOfClass:[NSString class]] || ![parameters isKindOfClass:[NSDictionary class]]) {
        [self replyTo:identifier error:@"Invalid worker request"];
        return;
    }
    if ([operation isEqualToString:@"ping"]) {
        [self replyTo:identifier result:@{ @"protocolVersion": @1 }];
        return;
    }
    if ([operation isEqualToString:@"context.create"]) {
        if (_websiteDataStore || _pages.count) {
            [self replyTo:identifier error:@"Worker already owns a browser context"];
            return;
        }
        _websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
        _processPool = [WKProcessPool new];
        _WKAutomationSessionConfiguration *configuration = [_WKAutomationSessionConfiguration new];
        configuration.controlledByExternalAgent = YES;
        configuration.navigatorWebDriverEnabled = NO;
        _automationSession = [[_WKAutomationSession alloc] initWithConfiguration:configuration];
        _automationSession.sessionIdentifier = [NSUUID UUID].UUIDString;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [_processPool _setAutomationSession:_automationSession];
#pragma clang diagnostic pop
        [self replyTo:identifier result:@{ }];
        return;
    }
    if ([operation isEqualToString:@"context.dispose"]) {
        for (AutomationPage *page in _pages.allValues.copy)
            [page close];
        [_pages removeAllObjects];
        [_handlesByTarget removeAllObjects];
        _automationSession = nil;
        _processPool = nil;
        _websiteDataStore = nil;
        [self replyTo:identifier result:@{ }];
        return;
    }
    if ([operation isEqualToString:@"page.create"]) {
        NSString *url = [parameters[@"url"] isKindOfClass:[NSString class]] ? parameters[@"url"] : @"about:blank";
        NSString *targetIdentifier = [parameters[@"targetId"] isKindOfClass:[NSString class]] ? parameters[@"targetId"] : nil;
        if (!targetIdentifier.length || !_websiteDataStore || _pages[targetIdentifier]) {
            [self replyTo:identifier error:@"Invalid page creation request"];
            return;
        }
        NSSize pageSize = NSMakeSize(1280, 720);
        BOOL headless = [NSProcessInfo.processInfo.arguments containsObject:@"--headless"];
        for (NSString *argument in NSProcessInfo.processInfo.arguments) {
            if (![argument hasPrefix:@"--window-size="])
                continue;
            NSArray<NSString *> *components = [[argument substringFromIndex:[@"--window-size=" length]] componentsSeparatedByString:@","];
            if (components.count == 2 && components[0].integerValue > 0 && components[1].integerValue > 0)
                pageSize = NSMakeSize(components[0].integerValue, components[1].integerValue);
        }
        __weak AutomationWorker *weakSelf = self;
        AutomationPage *page = [[AutomationPage alloc] initWithDataStore:_websiteDataStore processPool:_processPool size:pageSize headless:headless eventHandler:^(NSString *event, NSDictionary *eventParameters) {
            [weakSelf emitEvent:event parameters:eventParameters targetIdentifier:targetIdentifier];
        }];
        _pages[targetIdentifier] = page;
        _handlesByTarget[targetIdentifier] = [NSMutableDictionary dictionary];
        [page loadURLString:url];
        [self replyTo:identifier result:@{ }];
        return;
    }
    if ([operation isEqualToString:@"page.close"]) {
        NSString *targetIdentifier = parameters[@"targetId"];
        AutomationPage *page = _pages[targetIdentifier];
        if (!page) {
            [self replyTo:identifier error:@"Unknown targetId"];
            return;
        }
        [_handlesByTarget removeObjectForKey:targetIdentifier];
        [_pages removeObjectForKey:targetIdentifier];
        [page close];
        [self replyTo:identifier result:@{ }];
        return;
    }

    NSString *targetIdentifier = parameters[@"targetId"];
    AutomationPage *page = _pages[targetIdentifier];
    NSMutableDictionary<NSString *, WKJSHandle *> *handles = _handlesByTarget[targetIdentifier];
    WKWebView *webView = page.webView;
    if (!webView) {
        [self replyTo:identifier error:@"No active page"];
        return;
    }
    if ([operation hasSuffix:@".enable"] || [operation hasSuffix:@".disable"]) {
        [self replyTo:identifier result:@{ }];
        return;
    }
    if ([operation isEqualToString:@"page.navigate"]) {
        NSString *urlString = parameters[@"url"];
        NSURL *url = [urlString isKindOfClass:[NSString class]] ? [NSURL URLWithString:urlString] : nil;
        if (!url) {
            [self replyTo:identifier error:@"Invalid URL"];
            return;
        }
        [handles removeAllObjects];
        WKNavigation *navigation = [webView loadRequest:[NSURLRequest requestWithURL:url]];
        [self replyTo:identifier result:@{ @"frameId": @"main", @"navigationId": [NSString stringWithFormat:@"%p", navigation] }];
        return;
    }
    if ([operation isEqualToString:@"page.reload"]) {
        [handles removeAllObjects];
        WKNavigation *navigation = [webView reload];
        [self replyTo:identifier result:@{ @"navigationId": [NSString stringWithFormat:@"%p", navigation] }];
        return;
    }
    if ([operation isEqualToString:@"emulation.setDeviceMetricsOverride"]) {
        NSInteger width = [parameters[@"width"] integerValue];
        NSInteger height = [parameters[@"height"] integerValue];
        if (width <= 0 || height <= 0 || width > 32767 || height > 32767) {
            [self replyTo:identifier error:@"Invalid viewport dimensions"];
            return;
        }
        CGFloat viewportInset = NSHeight(page.window.contentView.frame) - NSHeight(page.window.contentLayoutRect);
        [page.window setContentSize:NSMakeSize(width, height + viewportInset)];
        [self replyTo:identifier result:@{ }];
        return;
    }
    if ([operation isEqualToString:@"page.getFrameTree"]) {
        [webView _frames:^(_WKFrameTreeNode *root) {
            if (!root) {
                [self replyTo:identifier error:@"Could not retrieve frame tree"];
                return;
            }
            [self replyTo:identifier result:@{ @"frameTree": frameTreeForNode(root) }];
        }];
        return;
    }
    if ([operation isEqualToString:@"runtime.evaluate"]) {
        NSString *expression = parameters[@"expression"];
        if (![expression isKindOfClass:[NSString class]]) {
            [self replyTo:identifier error:@"Runtime.evaluate requires expression"];
            return;
        }
        BOOL returnByValue = [parameters[@"returnByValue"] boolValue];
        NSString *script = returnByValue ? expression : [NSString stringWithFormat:@"(() => { const value = (%@); return value !== null && (typeof value === 'object' || typeof value === 'function') ? window.webkit.createJSHandle(value) : value; })()", expression];
        [webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
            if (error) {
                [self replyTo:identifier result:@{
                    @"result": @{ @"type": @"undefined" },
                    @"exceptionDetails": @{ @"text": error.localizedDescription ?: @"JavaScript evaluation failed", @"lineNumber": @0, @"columnNumber": @0 }
                }];
                return;
            }
            [self replyTo:identifier result:@{ @"result": [self remoteObjectForValue:value handles:handles] }];
        }];
        return;
    }
    if ([operation isEqualToString:@"runtime.callFunctionOn"]) {
        WKJSHandle *handle = handles[parameters[@"objectId"]];
        NSString *function = parameters[@"functionDeclaration"];
        if (![function isKindOfClass:[NSString class]]) {
            [self replyTo:identifier error:@"Runtime.callFunctionOn requires functionDeclaration"];
            return;
        }
        if (parameters[@"objectId"] && !handle) {
            [self replyTo:identifier error:@"Runtime.callFunctionOn received an unknown objectId"];
            return;
        }
        NSMutableArray *arguments = [NSMutableArray array];
        NSArray *providedArguments = parameters[@"arguments"];
        if (![providedArguments isKindOfClass:NSArray.class])
            providedArguments = @[ ];
        for (NSDictionary *argument in providedArguments) {
            if (argument[@"objectId"]) {
                WKJSHandle *argumentHandle = handles[argument[@"objectId"]];
                if (!argumentHandle) {
                    [self replyTo:identifier error:@"Unknown argument objectId"];
                    return;
                }
                [arguments addObject:argumentHandle];
            } else
                [arguments addObject:argument[@"value"] ?: [NSNull null]];
        }
        BOOL returnByValue = [parameters[@"returnByValue"] boolValue];
        NSString *receiver = handle ? @"object" : @"globalThis";
        NSString *body = returnByValue
            ? [NSString stringWithFormat:@"return await (%@).apply(%@, callArguments);", function, receiver]
            : [NSString stringWithFormat:@"const value = await (%@).apply(%@, callArguments); return value !== null && (typeof value === 'object' || typeof value === 'function') ? window.webkit.createJSHandle(value) : value;", function, receiver];
        NSMutableDictionary *scriptArguments = [@{ @"callArguments": arguments } mutableCopy];
        if (handle)
            scriptArguments[@"object"] = handle;
        [webView callAsyncJavaScript:body arguments:scriptArguments inFrame:handle.sourceFrame inContentWorld:(handle ? handle.contentWorld : WKContentWorld.pageWorld) completionHandler:^(id value, NSError *error) {
            if (error) {
                [self replyTo:identifier result:@{ @"result": @{ @"type": @"undefined" }, @"exceptionDetails": @{ @"text": error.localizedDescription ?: @"Function call failed", @"lineNumber": @0, @"columnNumber": @0 } }];
                return;
            }
            [self replyTo:identifier result:@{ @"result": [self remoteObjectForValue:value handles:handles] }];
        }];
        return;
    }
    if ([operation isEqualToString:@"runtime.releaseObject"]) {
        if (![handles objectForKey:parameters[@"objectId"]]) {
            [self replyTo:identifier error:@"Unknown objectId"];
            return;
        }
        [handles removeObjectForKey:parameters[@"objectId"]];
        [self replyTo:identifier result:@{ }];
        return;
    }
    if ([operation isEqualToString:@"page.captureScreenshot"]) {
        if (![parameters[@"captureBeyondViewport"] boolValue]) {
            [self captureScreenshot:parameters webView:webView contentSize:NSZeroSize identifier:identifier];
            return;
        }
        NSString *sizeScript = @"({width:Math.max(document.documentElement.scrollWidth,document.body.scrollWidth),height:Math.max(document.documentElement.scrollHeight,document.body.scrollHeight),scrollX,scrollY})";
        [webView evaluateJavaScript:sizeScript completionHandler:^(NSDictionary *size, NSError *error) {
            if (error || ![size isKindOfClass:[NSDictionary class]]) {
                [self replyTo:identifier error:error.localizedDescription ?: @"Could not measure document for snapshot"];
                return;
            }
            NSSize contentSize = NSMakeSize([size[@"width"] doubleValue], [size[@"height"] doubleValue]);
            NSMutableDictionary *fullPageParameters = [parameters mutableCopy];
            fullPageParameters[@"_originalScrollX"] = size[@"scrollX"] ?: @0;
            fullPageParameters[@"_originalScrollY"] = size[@"scrollY"] ?: @0;
            [self captureScreenshot:fullPageParameters webView:webView contentSize:contentSize identifier:identifier];
        }];
        return;
    }
    if ([operation isEqualToString:@"input.dispatchMouseEvent"]) {
        [self dispatchMouseEvent:parameters webView:webView identifier:identifier];
        return;
    }
    if ([operation isEqualToString:@"input.dispatchKeyEvent"]) {
        [self dispatchKeyEvent:parameters webView:webView identifier:identifier];
        return;
    }
    [self replyTo:identifier error:[NSString stringWithFormat:@"Unsupported native operation: %@", operation]];
}

static NSEventModifierFlags modifierFlagsForCDP(NSUInteger modifiers)
{
    NSEventModifierFlags result = 0;
    if (modifiers & 1)
        result |= NSEventModifierFlagOption;
    if (modifiers & 2)
        result |= NSEventModifierFlagControl;
    if (modifiers & 4)
        result |= NSEventModifierFlagCommand;
    if (modifiers & 8)
        result |= NSEventModifierFlagShift;
    return result;
}

- (void)replyAfterInputEventInWebView:(WKWebView *)webView identifier:(id)identifier
{
    // Sending an NSEvent queues work in the WebContent process. Use a subsequent
    // script message as an ordering barrier before acknowledging the CDP command.
    [webView evaluateJavaScript:@"void 0" completionHandler:^(id value, NSError *error) {
        if (error)
            [self replyTo:identifier error:error.localizedDescription];
        else
            [self replyTo:identifier result:@{ }];
    }];
}

- (void)dispatchMouseEvent:(NSDictionary *)parameters webView:(WKWebView *)webView identifier:(id)identifier
{
    NSString *type = parameters[@"type"];
    if (![type isKindOfClass:[NSString class]]) {
        [self replyTo:identifier error:@"Input.dispatchMouseEvent requires type"];
        return;
    }
    CGFloat x = [parameters[@"x"] doubleValue];
    CGFloat y = [parameters[@"y"] doubleValue];
    if (x < 0 || y < 0 || x > NSWidth(webView.bounds) || y > NSHeight(webView.bounds)) {
        [self replyTo:identifier error:@"Mouse coordinates are outside the viewport"];
        return;
    }
    NSWindow *window = webView.window;
    // WKWebView's event bridge consumes the view-relative point using web-content
    // coordinates (origin at the top left), matching CDP.
    NSPoint location = [webView convertPoint:NSMakePoint(x, y) toView:nil];
    NSEventModifierFlags modifiers = modifierFlagsForCDP([parameters[@"modifiers"] unsignedIntegerValue]);
    if ([type isEqualToString:@"mouseWheel"]) {
        CGEventRef cgEvent = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, (int)-[parameters[@"deltaY"] doubleValue], (int)-[parameters[@"deltaX"] doubleValue]);
        NSPoint screenLocation = [window convertPointToScreen:location];
        screenLocation.y = NSScreen.screens.firstObject.frame.size.height - screenLocation.y;
        CGEventSetLocation(cgEvent, screenLocation);
        NSEvent *event = [[NSEvent eventWithCGEvent:cgEvent] _eventRelativeToWindow:window];
        CFRelease(cgEvent);
        [_automationSession markEventAsSynthesizedForAutomation:event];
        [window sendEvent:event];
        [self replyAfterInputEventInWebView:webView identifier:identifier];
        return;
    }

    NSString *button = parameters[@"button"];
    BOOL right = [button isEqualToString:@"right"];
    BOOL middle = [button isEqualToString:@"middle"];
    NSEventType eventType;
    if ([type isEqualToString:@"mouseMoved"])
        eventType = NSEventTypeMouseMoved;
    else if ([type isEqualToString:@"mousePressed"])
        eventType = right ? NSEventTypeRightMouseDown : middle ? NSEventTypeOtherMouseDown : NSEventTypeLeftMouseDown;
    else if ([type isEqualToString:@"mouseReleased"])
        eventType = right ? NSEventTypeRightMouseUp : middle ? NSEventTypeOtherMouseUp : NSEventTypeLeftMouseUp;
    else {
        [self replyTo:identifier error:[NSString stringWithFormat:@"Unsupported mouse event type: %@", type]];
        return;
    }
    NSEvent *event = [NSEvent mouseEventWithType:eventType location:location modifierFlags:modifiers timestamp:NSDate.timeIntervalSinceReferenceDate windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:MAX([parameters[@"clickCount"] integerValue], 1) pressure:[type isEqualToString:@"mousePressed"] ? 1 : 0];
    [_automationSession markEventAsSynthesizedForAutomation:event];
    [window makeFirstResponder:webView];
    [window sendEvent:event];
    if (eventType == NSEventTypeMouseMoved)
        [webView _simulateMouseMove:event];
    [self replyAfterInputEventInWebView:webView identifier:identifier];
}

static unsigned short keyCodeForCDP(NSDictionary *parameters)
{
    if (parameters[@"nativeVirtualKeyCode"])
        return [parameters[@"nativeVirtualKeyCode"] unsignedShortValue];
    switch ([parameters[@"windowsVirtualKeyCode"] unsignedIntegerValue]) {
    case 'A': return kVK_ANSI_A;
    case 'B': return kVK_ANSI_B;
    case 'C': return kVK_ANSI_C;
    case 'D': return kVK_ANSI_D;
    case 'E': return kVK_ANSI_E;
    case 'F': return kVK_ANSI_F;
    case 'G': return kVK_ANSI_G;
    case 'H': return kVK_ANSI_H;
    case 'I': return kVK_ANSI_I;
    case 'J': return kVK_ANSI_J;
    case 'K': return kVK_ANSI_K;
    case 'L': return kVK_ANSI_L;
    case 'M': return kVK_ANSI_M;
    case 'N': return kVK_ANSI_N;
    case 'O': return kVK_ANSI_O;
    case 'P': return kVK_ANSI_P;
    case 'Q': return kVK_ANSI_Q;
    case 'R': return kVK_ANSI_R;
    case 'S': return kVK_ANSI_S;
    case 'T': return kVK_ANSI_T;
    case 'U': return kVK_ANSI_U;
    case 'V': return kVK_ANSI_V;
    case 'W': return kVK_ANSI_W;
    case 'X': return kVK_ANSI_X;
    case 'Y': return kVK_ANSI_Y;
    case 'Z': return kVK_ANSI_Z;
    case '0': return kVK_ANSI_0;
    case '1': return kVK_ANSI_1;
    case '2': return kVK_ANSI_2;
    case '3': return kVK_ANSI_3;
    case '4': return kVK_ANSI_4;
    case '5': return kVK_ANSI_5;
    case '6': return kVK_ANSI_6;
    case '7': return kVK_ANSI_7;
    case '8': return kVK_ANSI_8;
    case '9': return kVK_ANSI_9;
    case 8: return kVK_Delete;
    case 9: return kVK_Tab;
    case 13: return kVK_Return;
    case 27: return kVK_Escape;
    case 32: return kVK_Space;
    case 37: return kVK_LeftArrow;
    case 38: return kVK_UpArrow;
    case 39: return kVK_RightArrow;
    case 40: return kVK_DownArrow;
    default: return USHRT_MAX;
    }
}

- (void)dispatchKeyEvent:(NSDictionary *)parameters webView:(WKWebView *)webView identifier:(id)identifier
{
    NSString *type = parameters[@"type"];
    NSEventType eventType;
    if ([type isEqualToString:@"keyDown"] || [type isEqualToString:@"rawKeyDown"] || [type isEqualToString:@"char"])
        eventType = NSEventTypeKeyDown;
    else if ([type isEqualToString:@"keyUp"])
        eventType = NSEventTypeKeyUp;
    else {
        [self replyTo:identifier error:[NSString stringWithFormat:@"Unsupported key event type: %@", type ?: @"(null)"]];
        return;
    }
    NSString *characters = parameters[@"text"];
    if (![characters isKindOfClass:[NSString class]] || !characters.length)
        characters = [parameters[@"key"] isKindOfClass:[NSString class]] ? parameters[@"key"] : @"";
    NSWindow *window = webView.window;
    NSEvent *event = [NSEvent keyEventWithType:eventType location:NSZeroPoint modifierFlags:modifierFlagsForCDP([parameters[@"modifiers"] unsignedIntegerValue]) timestamp:NSDate.timeIntervalSinceReferenceDate windowNumber:window.windowNumber context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:[parameters[@"autoRepeat"] boolValue] keyCode:keyCodeForCDP(parameters)];
    [_automationSession markEventAsSynthesizedForAutomation:event];
    [window makeFirstResponder:webView];
    if (eventType == NSEventTypeKeyDown)
        [webView keyDown:event];
    else
        [webView keyUp:event];
    [self replyAfterInputEventInWebView:webView identifier:identifier];
}

- (void)captureScreenshot:(NSDictionary *)parameters webView:(WKWebView *)webView contentSize:(NSSize)contentSize identifier:(id)identifier
{
    NSString *format = [parameters[@"format"] isKindOfClass:[NSString class]] ? parameters[@"format"] : @"png";
    if (![format isEqualToString:@"png"] && ![format isEqualToString:@"jpeg"]) {
        [self replyTo:identifier error:[NSString stringWithFormat:@"Unsupported screenshot format: %@", format]];
        return;
    }
    if (!NSEqualSizes(contentSize, NSZeroSize)) {
        [self captureFullPageScreenshot:parameters webView:webView contentSize:contentSize identifier:identifier];
        return;
    }
    WKSnapshotConfiguration *configuration = [WKSnapshotConfiguration new];
    configuration.rect = webView.bounds;
    NSDictionary *clip = parameters[@"clip"];
    if ([clip isKindOfClass:[NSDictionary class]]) {
        configuration.rect = CGRectMake([clip[@"x"] doubleValue], [clip[@"y"] doubleValue], [clip[@"width"] doubleValue], [clip[@"height"] doubleValue]);
        if ([clip[@"scale"] doubleValue] > 0)
            configuration.snapshotWidth = @([clip[@"width"] doubleValue] * [clip[@"scale"] doubleValue]);
    }
    [webView takeSnapshotWithConfiguration:configuration completionHandler:^(NSImage *image, NSError *error) {
        if (error || !image) {
            [self replyTo:identifier error:error.localizedDescription ?: @"Snapshot failed"];
            return;
        }
        [self replyTo:identifier withScreenshotImage:image parameters:parameters];
    }];
}

- (void)captureFullPageScreenshot:(NSDictionary *)parameters webView:(WKWebView *)webView contentSize:(NSSize)contentSize identifier:(id)identifier
{
    CGFloat viewportWidth = NSWidth(webView.bounds);
    CGFloat viewportHeight = NSHeight(webView.bounds);
    if (contentSize.width <= 0 || contentSize.height <= 0 || viewportWidth <= 0 || viewportHeight <= 0) {
        [self replyTo:identifier error:@"Invalid document dimensions for full-page snapshot"];
        return;
    }
    if (contentSize.width > 32767 || contentSize.height > 32767 || contentSize.width * contentSize.height > 100000000) {
        [self replyTo:identifier error:@"Document is too large for full-page snapshot"];
        return;
    }
    NSString *restoreScrollScript = [NSString stringWithFormat:@"scrollTo(%.17g, %.17g)", [parameters[@"_originalScrollX"] doubleValue], [parameters[@"_originalScrollY"] doubleValue]];
    NSMutableArray<NSDictionary *> *offsets = [NSMutableArray array];
    for (CGFloat y = 0; y < contentSize.height; y += viewportHeight) {
        for (CGFloat x = 0; x < contentSize.width; x += viewportWidth) {
            [offsets addObject:@{
                @"x": @(MIN(x, MAX(0, contentSize.width - viewportWidth))),
                @"y": @(MIN(y, MAX(0, contentSize.height - viewportHeight))),
            }];
        }
    }
    NSMutableArray<NSImage *> *tiles = [NSMutableArray arrayWithCapacity:offsets.count];
    __block void (^captureTile)(NSUInteger);
    captureTile = ^(NSUInteger index) {
        if (index == offsets.count) {
            [webView evaluateJavaScript:restoreScrollScript completionHandler:^(id value, NSError *error) {
                if (error) {
                    [self replyTo:identifier error:error.localizedDescription];
                    captureTile = nil;
                    return;
                }
                NSBitmapImageRep *fullBitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:contentSize.width pixelsHigh:contentSize.height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                if (!fullBitmap) {
                    [self replyTo:identifier error:@"Could not allocate full-page snapshot bitmap"];
                    captureTile = nil;
                    return;
                }
                CGContextRef context = [NSGraphicsContext graphicsContextWithBitmapImageRep:fullBitmap].CGContext;
                CGContextSetRGBFillColor(context, 1, 1, 1, 1);
                CGContextFillRect(context, CGRectMake(0, 0, contentSize.width, contentSize.height));
                for (NSUInteger tileIndex = 0; tileIndex < tiles.count; ++tileIndex) {
                    NSImage *tile = tiles[tileIndex];
                    CGFloat x = [offsets[tileIndex][@"x"] doubleValue];
                    CGFloat y = [offsets[tileIndex][@"y"] doubleValue];
                    NSRect destination = NSMakeRect(x, contentSize.height - y - viewportHeight, viewportWidth, viewportHeight);
                    CGImageRef tileImage = [tile CGImageForProposedRect:NULL context:nil hints:nil];
                    CGContextDrawImage(context, destination, tileImage);
                }
                NSImage *fullImage = [[NSImage alloc] initWithSize:contentSize];
                [fullImage addRepresentation:fullBitmap];
                [webView _doAfterNextPresentationUpdate:^{
                    [self replyTo:identifier withScreenshotImage:fullImage parameters:parameters];
                    captureTile = nil;
                }];
            }];
            return;
        }
        NSString *scrollScript = [NSString stringWithFormat:@"scrollTo(%.17g, %.17g)", [offsets[index][@"x"] doubleValue], [offsets[index][@"y"] doubleValue]];
        [webView evaluateJavaScript:scrollScript completionHandler:^(id value, NSError *error) {
            if (error) {
                [webView evaluateJavaScript:restoreScrollScript completionHandler:nil];
                [self replyTo:identifier error:error.localizedDescription];
                captureTile = nil;
                return;
            }
            WKSnapshotConfiguration *configuration = [WKSnapshotConfiguration new];
            configuration.rect = webView.bounds;
            [webView takeSnapshotWithConfiguration:configuration completionHandler:^(NSImage *image, NSError *snapshotError) {
                if (snapshotError || !image) {
                    [webView evaluateJavaScript:restoreScrollScript completionHandler:nil];
                    [self replyTo:identifier error:snapshotError.localizedDescription ?: @"Full-page snapshot tile failed"];
                    captureTile = nil;
                    return;
                }
                [tiles addObject:image];
                captureTile(index + 1);
            }];
        }];
    };
    captureTile(0);
}

- (void)replyTo:(id)identifier withScreenshotImage:(NSImage *)image parameters:(NSDictionary *)parameters
{
    NSString *format = [parameters[@"format"] isKindOfClass:[NSString class]] ? parameters[@"format"] : @"png";
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
    NSBitmapImageFileType bitmapType = [format isEqualToString:@"jpeg"] ? NSBitmapImageFileTypeJPEG : NSBitmapImageFileTypePNG;
    double compressionFactor = parameters[@"quality"] ? [parameters[@"quality"] doubleValue] / 100.0 : 0.8;
    NSDictionary *properties = bitmapType == NSBitmapImageFileTypeJPEG ? @{ NSImageCompressionFactor: @(compressionFactor) } : @{ };
    NSData *encoded = [bitmap representationUsingType:bitmapType properties:properties];
    [self replyTo:identifier result:@{ @"data": [encoded base64EncodedStringWithOptions:0] ?: @"" }];
}

- (NSDictionary *)remoteObjectForValue:(id)value handles:(NSMutableDictionary<NSString *, WKJSHandle *> *)handles
{
    if (!value)
        return @{ @"type": @"undefined" };
    if (value == [NSNull null])
        return @{ @"type": @"object", @"subtype": @"null", @"value": [NSNull null] };
    if ([value isKindOfClass:[WKJSHandle class]]) {
        NSString *objectId = [NSUUID UUID].UUIDString;
        handles[objectId] = value;
        return @{ @"type": @"object", @"objectId": objectId, @"description": @"Object" };
    }
    if ([value isKindOfClass:[NSString class]])
        return @{ @"type": @"string", @"value": value };
    if ([value isKindOfClass:[NSNumber class]]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
            return @{ @"type": @"boolean", @"value": value };
        return @{ @"type": @"number", @"value": value };
    }
    if ([NSJSONSerialization isValidJSONObject:@[ value ]])
        return @{ @"type": @"object", @"value": value, @"description": [value description] };
    return @{ @"type": @"string", @"value": [value description], @"description": [value description] };
}

- (void)emitEvent:(NSString *)event parameters:(NSDictionary *)parameters targetIdentifier:(NSString *)targetIdentifier
{
    if (!targetIdentifier.length || !_pages[targetIdentifier])
        return;
    [self send:@{ @"event": event, @"targetId": targetIdentifier, @"params": parameters ?: @{ } }];
}

@end
