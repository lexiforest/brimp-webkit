#if __has_include("config.h")
#import "config.h"
#endif
#import "AutomationPage.h"

#import <WebKit/WKFrameInfo.h>
#import <WebKit/WKNavigationAction.h>
#import <WebKit/WKNavigationDelegate.h>
#import <WebKit/WKOpenPanelParameters.h>
#import <WebKit/WKPreferences.h>
#import <WebKit/WKPreferencesPrivate.h>
#import <WebKit/WKProcessPool.h>
#import <WebKit/WKUIDelegate.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>
#import <WebKit/WKWebViewPrivate.h>
#import <WebKit/WKWebpagePreferences.h>
#import <WebKit/WKWebpagePreferencesPrivate.h>
#import <WebKit/WKWebsiteDataStore.h>
#import <WebKit/WKWindowFeatures.h>
#import <WebKit/_WKResourceLoadDelegate.h>
#import <WebKit/_WKResourceLoadInfo.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface AutomationPage () <WKNavigationDelegate, WKUIDelegate, _WKResourceLoadDelegate>
@end

@implementation AutomationPage {
    AutomationPageEventHandler _eventHandler;
    NSWindow *_window;
    WKWebView *_webView;
}

- (instancetype)initWithDataStore:(WKWebsiteDataStore *)dataStore processPool:(WKProcessPool *)processPool size:(NSSize)size headless:(BOOL)headless eventHandler:(AutomationPageEventHandler)eventHandler
{
    if (!(self = [super init]))
        return nil;

    _eventHandler = [eventHandler copy];
    NSRect frame = NSMakeRect(0, 0, size.width, size.height);
    _window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    _window.tabbingMode = NSWindowTabbingModeDisallowed;
    _window.collectionBehavior = NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = dataStore;
    configuration.processPool = processPool;
    configuration.preferences.elementFullscreenEnabled = YES;
    configuration.preferences._developerExtrasEnabled = YES;

    _webView = [[WKWebView alloc] initWithFrame:frame configuration:configuration];
    _webView.inspectable = YES;
    _webView.navigationDelegate = self;
    _webView.UIDelegate = self;
    _webView._resourceLoadDelegate = self;
    _window.contentView = _webView;
    [_window makeFirstResponder:_webView];

    if (headless) {
        _window.ignoresMouseEvents = YES;
        [_window setFrameOrigin:NSMakePoint(-size.width - 100, -size.height - 100)];
        _webView._windowOcclusionDetectionEnabled = NO;
        [_window orderBack:nil];
    } else
        [_window makeKeyAndOrderFront:nil];
    return self;
}

- (WKWebView *)webView
{
    return _webView;
}

- (NSWindow *)window
{
    return _window;
}

- (void)loadURLString:(NSString *)urlString
{
    NSURL *url = [NSURL URLWithString:urlString];
    if (url)
        [_webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)close
{
    _webView.navigationDelegate = nil;
    _webView.UIDelegate = nil;
    _webView._resourceLoadDelegate = nil;
    [_window close];
    _webView = nil;
    _window = nil;
    _eventHandler = nil;
}

- (void)emit:(NSString *)name parameters:(NSDictionary *)parameters
{
    if (_eventHandler)
        _eventHandler(name, parameters ?: @{ });
}

static NSString *navigationIdentifier(WKNavigation *navigation)
{
    return [NSString stringWithFormat:@"%p", navigation];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction preferences:(WKWebpagePreferences *)preferences decisionHandler:(void (^)(WKNavigationActionPolicy, WKWebpagePreferences *))decisionHandler
{
    preferences.allowsJSHandleCreationInPageWorld = YES;
    decisionHandler(WKNavigationActionPolicyAllow, preferences);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation
{
    [self emit:@"page.frameStartedLoading" parameters:@{ @"frameId": @"main", @"navigationId": navigationIdentifier(navigation) }];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    NSString *identifier = navigationIdentifier(navigation);
    [self emit:@"network.loadingFailed" parameters:@{ @"requestId": @"main", @"timestamp": @(NSProcessInfo.processInfo.systemUptime), @"type": @"Document", @"errorText": error.localizedDescription ?: @"Navigation failed", @"canceled": @(error.code == NSURLErrorCancelled), @"navigationId": identifier }];
    [self emit:@"page.frameStoppedLoading" parameters:@{ @"frameId": @"main", @"navigationId": identifier }];
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation
{
    NSString *url = webView.URL.absoluteString ?: @"about:blank";
    [self emit:@"page.frameNavigated" parameters:@{ @"frame": @{ @"id": @"main", @"loaderId": @"main", @"url": url, @"domainAndRegistry": webView.URL.host ?: @"", @"securityOrigin": @"", @"mimeType": @"text/html" }, @"type": @"Navigation", @"navigationId": navigationIdentifier(navigation) }];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    NSNumber *timestamp = @(NSProcessInfo.processInfo.systemUptime);
    NSString *identifier = navigationIdentifier(navigation);
    [self emit:@"page.domContentEventFired" parameters:@{ @"timestamp": timestamp, @"navigationId": identifier }];
    [self emit:@"page.loadEventFired" parameters:@{ @"timestamp": timestamp, @"navigationId": identifier }];
    [self emit:@"page.frameStoppedLoading" parameters:@{ @"frameId": @"main", @"navigationId": identifier }];
}

- (nullable WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures
{
    [self emit:@"page.windowOpen" parameters:@{ @"url": navigationAction.request.URL.absoluteString ?: @"", @"windowName": @"", @"windowFeatures": @[], @"userGesture": @NO }];
    return nil;
}

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler
{
    [self emit:@"page.javascriptDialogOpening" parameters:@{ @"url": frame.request.URL.absoluteString ?: @"", @"message": message, @"type": @"alert", @"hasBrowserHandler": @YES, @"defaultPrompt": @"" }];
    completionHandler();
    [self emit:@"page.javascriptDialogClosed" parameters:@{ @"result": @YES, @"userInput": @"" }];
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler
{
    [self emit:@"page.javascriptDialogOpening" parameters:@{ @"url": frame.request.URL.absoluteString ?: @"", @"message": message, @"type": @"confirm", @"hasBrowserHandler": @YES, @"defaultPrompt": @"" }];
    completionHandler(NO);
    [self emit:@"page.javascriptDialogClosed" parameters:@{ @"result": @NO, @"userInput": @"" }];
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *))completionHandler
{
    [self emit:@"page.javascriptDialogOpening" parameters:@{ @"url": frame.request.URL.absoluteString ?: @"", @"message": prompt, @"type": @"prompt", @"hasBrowserHandler": @YES, @"defaultPrompt": defaultText ?: @"" }];
    completionHandler(nil);
    [self emit:@"page.javascriptDialogClosed" parameters:@{ @"result": @NO, @"userInput": @"" }];
}

- (void)webView:(WKWebView *)webView runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSArray<NSURL *> *))completionHandler
{
    completionHandler(nil);
}

static NSString *resourceTypeForLoadInfo(_WKResourceLoadInfo *loadInfo)
{
    switch (loadInfo.resourceType) {
    case _WKResourceLoadInfoResourceTypeDocument: return @"Document";
    case _WKResourceLoadInfoResourceTypeStylesheet: return @"Stylesheet";
    case _WKResourceLoadInfoResourceTypeImage: return @"Image";
    case _WKResourceLoadInfoResourceTypeMedia: return @"Media";
    case _WKResourceLoadInfoResourceTypeFont: return @"Font";
    case _WKResourceLoadInfoResourceTypeScript: return @"Script";
    case _WKResourceLoadInfoResourceTypeXMLHTTPRequest: return @"XHR";
    case _WKResourceLoadInfoResourceTypeFetch: return @"Fetch";
    case _WKResourceLoadInfoResourceTypePing:
    case _WKResourceLoadInfoResourceTypeBeacon: return @"Ping";
    case _WKResourceLoadInfoResourceTypeCSPReport: return @"CSPViolationReport";
    case _WKResourceLoadInfoResourceTypeApplicationManifest: return @"Manifest";
    default: return @"Other";
    }
}

static NSString *requestIdentifier(_WKResourceLoadInfo *loadInfo)
{
    return [NSString stringWithFormat:@"%llu", loadInfo.resourceLoadID];
}

- (void)webView:(WKWebView *)webView resourceLoad:(_WKResourceLoadInfo *)loadInfo didSendRequest:(NSURLRequest *)request
{
    NSMutableDictionary *requestObject = [@{ @"url": request.URL.absoluteString ?: @"", @"method": request.HTTPMethod ?: @"GET", @"headers": request.allHTTPHeaderFields ?: @{ }, @"initialPriority": @"Medium", @"referrerPolicy": @"no-referrer-when-downgrade" } mutableCopy];
    if (request.HTTPBody.length) {
        NSString *postData = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
        if (postData)
            requestObject[@"postData"] = postData;
        requestObject[@"hasPostData"] = @YES;
    }
    [self emit:@"network.requestWillBeSent" parameters:@{ @"requestId": requestIdentifier(loadInfo), @"loaderId": @"main", @"documentURL": webView.URL.absoluteString ?: request.URL.absoluteString ?: @"", @"request": requestObject, @"timestamp": @(NSProcessInfo.processInfo.systemUptime), @"wallTime": @(NSDate.date.timeIntervalSince1970), @"initiator": @{ @"type": @"other" }, @"type": resourceTypeForLoadInfo(loadInfo), @"hasUserGesture": @NO }];
}

- (void)webView:(WKWebView *)webView resourceLoad:(_WKResourceLoadInfo *)loadInfo didReceiveResponse:(NSURLResponse *)response
{
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSInteger status = httpResponse ? httpResponse.statusCode : 200;
    [self emit:@"network.responseReceived" parameters:@{ @"requestId": requestIdentifier(loadInfo), @"loaderId": @"main", @"timestamp": @(NSProcessInfo.processInfo.systemUptime), @"type": resourceTypeForLoadInfo(loadInfo), @"response": @{ @"url": response.URL.absoluteString ?: @"", @"status": @(status), @"statusText": httpResponse ? [NSHTTPURLResponse localizedStringForStatusCode:status] : @"OK", @"headers": httpResponse.allHeaderFields ?: @{ }, @"mimeType": response.MIMEType ?: @"", @"charset": response.textEncodingName ?: @"", @"connectionReused": @NO, @"connectionId": @0, @"encodedDataLength": @(MAX(response.expectedContentLength, 0)), @"securityState": @"unknown" }, @"hasExtraInfo": @NO }];
}

- (void)webView:(WKWebView *)webView resourceLoad:(_WKResourceLoadInfo *)loadInfo didCompleteWithError:(NSError *)error response:(NSURLResponse *)response
{
    if (error) {
        [self emit:@"network.loadingFailed" parameters:@{ @"requestId": requestIdentifier(loadInfo), @"timestamp": @(NSProcessInfo.processInfo.systemUptime), @"type": resourceTypeForLoadInfo(loadInfo), @"errorText": error.localizedDescription ?: @"Resource load failed", @"canceled": @(error.code == NSURLErrorCancelled) }];
        return;
    }
    [self emit:@"network.loadingFinished" parameters:@{ @"requestId": requestIdentifier(loadInfo), @"timestamp": @(NSProcessInfo.processInfo.systemUptime), @"encodedDataLength": @(MAX(response.expectedContentLength, 0)) }];
}

@end
