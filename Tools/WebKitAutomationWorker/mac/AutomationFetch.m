#if __has_include("config.h")
#import "config.h"
#endif
#import "AutomationFetch.h"
#import <Cocoa/Cocoa.h>
#import <WebKit/_WKAutomationSession.h>
#import <WebKit/WKWebView.h>

static NSUInteger nextInspectorIdentifier;
static NSString *jsonString(id value)
{
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingWithoutEscapingSlashes error:nil] encoding:NSUTF8StringEncoding];
}

@interface AutomationFetch ()
- (void)send:(NSString *)method params:(NSDictionary *)params target:(NSString *)target reply:(AutomationFetchReply)reply;
@end

@implementation AutomationFetch {
    _WKAutomationSession *_session;
    __weak WKWebView *_webView;
    void (^_eventHandler)(NSString *, NSDictionary *);
    NSMutableDictionary<NSNumber *, AutomationFetchReply> *_callbacks;
    NSMutableDictionary<NSNumber *, NSNumber *> *_transportRequests;
    NSMutableDictionary<NSNumber *, NSString *> *_callbackTargets;
    NSMutableSet<NSString *> *_targets;
    NSMutableSet<NSString *> *_readyTargets;
    NSMutableSet<NSString *> *_configuringTargets;
    NSMutableDictionary<NSString *, NSDictionary *> *_requests;
    NSMutableDictionary<NSString *, NSNumber *> *_responseOverrides;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_paused;
    NSMutableDictionary<NSString *, NSData *> *_streams;
    NSMutableDictionary<NSString *, NSNumber *> *_streamOffsets;
    NSMutableSet<NSString *> *_loadingStreams;
    NSMutableDictionary<NSString *, NSString *> *_streamErrors;
    NSMutableDictionary<NSString *, NSDictionary *> *_streamReads;
    NSMutableArray<AutomationFetchReply> *_enableReplies;
    NSArray<NSDictionary *> *_patterns;
    BOOL _connected;
    BOOL _enabled;
    BOOL _handleAuth;
    BOOL _closed;
    NSString *_mainFrame;
    NSMutableDictionary<NSString *, void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *)> *_authChallenges;
}

- (instancetype)initWithSession:(_WKAutomationSession *)session webView:(WKWebView *)webView eventHandler:(void (^)(NSString *, NSDictionary *))eventHandler
{
    if (!(self = [super init]))
        return nil;
    _session = session;
    _webView = webView;
    _browsingContextHandle = [session registerWebView:webView];
    _eventHandler = [eventHandler copy];
    _callbacks = [NSMutableDictionary dictionary];
    _transportRequests = [NSMutableDictionary dictionary];
    _callbackTargets = [NSMutableDictionary dictionary];
    _targets = [NSMutableSet set];
    _readyTargets = [NSMutableSet set];
    _configuringTargets = [NSMutableSet set];
    _requests = [NSMutableDictionary dictionary];
    _responseOverrides = [NSMutableDictionary dictionary];
    _paused = [NSMutableDictionary dictionary];
    _streams = [NSMutableDictionary dictionary];
    _streamOffsets = [NSMutableDictionary dictionary];
    _loadingStreams = [NSMutableSet set];
    _streamErrors = [NSMutableDictionary dictionary];
    _streamReads = [NSMutableDictionary dictionary];
    _enableReplies = [NSMutableArray array];
    _authChallenges = [NSMutableDictionary dictionary];
    return self;
}

- (void)dispatchInspector:(NSDictionary *)message logicalIdentifier:(NSNumber *)identifier
{
    NSNumber *transportID = @(++nextInspectorIdentifier);
    _transportRequests[transportID] = identifier;
    [_session dispatchLocalMessage:jsonString(@{ @"id": transportID, @"method": @"Automation.sendInspectorMessage", @"params": @{ @"browsingContextHandle": _browsingContextHandle, @"message": jsonString(message) } })];
}

- (void)send:(NSString *)method params:(NSDictionary *)params target:(NSString *)target reply:(AutomationFetchReply)reply
{
    if (_closed) {
        reply(nil, @"Page closed");
        return;
    }
    NSNumber *identifier = @(++nextInspectorIdentifier);
    _callbacks[identifier] = [reply copy];
    NSDictionary *message = @{ @"id": identifier, @"method": method, @"params": params ?: @{ } };
    if (target) {
        _callbackTargets[identifier] = target;
        NSNumber *wrapper = @(++nextInspectorIdentifier);
        _callbackTargets[wrapper] = target;
        __weak AutomationFetch *weakSelf = self;
        _callbacks[wrapper] = ^(NSDictionary *result, NSString *error) {
            if (error)
                [weakSelf finish:identifier result:nil error:error];
        };
        message = @{ @"id": wrapper, @"method": @"Target.sendMessageToTarget", @"params": @{ @"targetId": target, @"message": jsonString(message) } };
    }
    [self dispatchInspector:message logicalIdentifier:identifier];
}

- (void)finish:(NSNumber *)identifier result:(NSDictionary *)result error:(NSString *)error
{
    AutomationFetchReply callback = _callbacks[identifier];
    [_callbacks removeObjectForKey:identifier];
    [_callbackTargets removeObjectForKey:identifier];
    if (callback)
        callback(result ?: @{ }, error);
}

- (void)receiveTransportResponse:(NSDictionary *)message
{
    NSNumber *identifier = _transportRequests[message[@"id"]];
    [_transportRequests removeObjectForKey:message[@"id"]];
    if (identifier && message[@"error"])
        [self finish:identifier result:nil error:message[@"error"][@"message"]];
}

- (void)configureTarget:(NSString *)target paused:(BOOL)paused
{
    [_configuringTargets addObject:target];
    NSMutableArray *commands = [@[
        @[ @"Network.enable", @{ } ],
        @[ @"Network.addInterception", @{ @"url": @"", @"stage": @"request" } ],
        @[ @"Network.addInterception", @{ @"url": @"", @"stage": @"response" } ],
    ] mutableCopy];
    if (_enabled)
        [commands addObject:@[ @"Network.setInterceptionEnabled", @{ @"enabled": @YES } ]];
    [self send:@"Page.getResourceTree" params:@{ } target:target reply:^(NSDictionary *result, NSString *error) {
        if (result[@"frameTree"][@"frame"][@"id"])
            _mainFrame = result[@"frameTree"][@"frame"][@"id"];
        [self configureCommands:commands index:0 target:target reply:^(NSDictionary *result, NSString *error) {
            [_configuringTargets removeObject:target];
            if (!error && [_targets containsObject:target])
                [_readyTargets addObject:target];
            if (paused)
                [self send:@"Target.resume" params:@{ @"targetId": target } target:nil reply:^(NSDictionary *result, NSString *resumeError) { [self finishEnable:error ?: resumeError]; }];
            else
                [self finishEnable:error];
        }];
    }];
}

- (void)configureCommands:(NSArray *)commands index:(NSUInteger)index target:(NSString *)target reply:(AutomationFetchReply)reply
{
    if (index == commands.count) { reply(@{ }, nil); return; }
    NSArray *command = commands[index];
    [self send:command[0] params:command[1] target:target reply:^(NSDictionary *result, NSString *error) {
        if (error) reply(nil, error);
        else [self configureCommands:commands index:index + 1 target:target reply:reply];
    }];
}

- (void)finishEnable:(NSString *)error
{
    if (!error && (_configuringTargets.count || !_readyTargets.count || _readyTargets.count != _targets.count))
        return;
    NSArray *replies = _enableReplies.copy;
    [_enableReplies removeAllObjects];
    for (AutomationFetchReply reply in replies)
        reply(@{ }, error);
}

- (void)receiveMessage:(NSDictionary *)message
{
    [self receiveInspector:message target:nil];
}

- (void)receiveInspector:(NSDictionary *)message target:(NSString *)target
{
    if (_closed)
        return;
    if (message[@"id"]) {
        [self finish:message[@"id"] result:message[@"result"] error:message[@"error"][@"message"]];
        return;
    }
    NSString *method = message[@"method"];
    NSDictionary *params = message[@"params"];
    if ([method isEqualToString:@"Target.dispatchMessageFromTarget"]) {
        NSData *data = [params[@"message"] dataUsingEncoding:NSUTF8StringEncoding];
        [self receiveInspector:[NSJSONSerialization JSONObjectWithData:data options:0 error:nil] target:params[@"targetId"]];
    } else if ([method isEqualToString:@"Target.targetCreated"]) {
        NSDictionary *info = params[@"targetInfo"];
        NSString *identifier = info[@"targetId"];
        if (![info[@"type"] isEqualToString:@"page"]) {
            if ([info[@"isPaused"] boolValue])
                [self send:@"Target.resume" params:@{ @"targetId": identifier } target:nil reply:^(NSDictionary *result, NSString *error) { }];
            return;
        }
        if ([_targets containsObject:identifier]) return;
        [_targets addObject:identifier];
        [self configureTarget:identifier paused:[info[@"isPaused"] boolValue]];
    } else if ([method isEqualToString:@"Target.targetDestroyed"]) {
        NSString *identifier = params[@"targetId"];
        [_targets removeObject:identifier];
        [_readyTargets removeObject:identifier];
        [_configuringTargets removeObject:identifier];
        for (NSNumber *callback in _callbackTargets.allKeys.copy) {
            if ([_callbackTargets[callback] isEqual:identifier])
                [self finish:callback result:nil error:@"Inspector target was destroyed"];
        }
        for (NSString *key in _paused.allKeys.copy) {
            if ([_paused[key][@"target"] isEqual:identifier])
                [_paused removeObjectForKey:key];
        }
        [self finishEnable:nil];
    } else if ([method isEqualToString:@"Network.requestWillBeSent"]) {
        NSString *key = [NSString stringWithFormat:@"%@/%@", target, params[@"requestId"]];
        _requests[key] = params;
        [_responseOverrides removeObjectForKey:key];
        if ([params[@"type"] isEqualToString:@"Document"] && !_mainFrame)
            _mainFrame = params[@"frameId"];
    } else if ([method isEqualToString:@"Network.requestIntercepted"] || [method isEqualToString:@"Network.responseIntercepted"])
        [self intercepted:params target:target response:[method isEqualToString:@"Network.responseIntercepted"]];
    else if ([method isEqualToString:@"Network.loadingFinished"] || [method isEqualToString:@"Network.loadingFailed"]) {
        NSString *key = [NSString stringWithFormat:@"%@/%@", target, params[@"requestId"]];
        [_requests removeObjectForKey:key];
        [_responseOverrides removeObjectForKey:key];
        for (NSString *identifier in _paused.allKeys.copy) {
            NSDictionary *pending = _paused[identifier];
            if ([pending[@"target"] isEqual:target] && [pending[@"networkId"] isEqual:params[@"requestId"]])
                [_paused removeObjectForKey:identifier];
        }
    }
}

static NSString *resourceType(NSString *type)
{
    if ([type isEqualToString:@"StyleSheet"])
        return @"Stylesheet";
    if ([type isEqualToString:@"Beacon"])
        return @"Ping";
    return type ?: @"Other";
}

- (BOOL)matches:(NSDictionary *)request stage:(NSString *)stage type:(NSString *)type
{
    for (NSDictionary *pattern in _patterns) {
        if (![pattern[@"requestStage"] isEqual:stage] || (pattern[@"resourceType"] && ![pattern[@"resourceType"] isEqual:type]))
            continue;
        NSRegularExpression *regex = pattern[@"regex"];
        NSString *url = request[@"url"] ?: @"";
        if ([regex firstMatchInString:url options:0 range:NSMakeRange(0, url.length)])
            return YES;
    }
    return NO;
}

static NSDictionary *cdpRequest(NSDictionary *request)
{
    NSString *policy = request[@"referrerPolicy"];
    if (!policy || [policy isEqual:@"empty-string"])
        policy = @"strict-origin-when-cross-origin";
    NSMutableDictionary *result = [@{ @"url": request[@"url"] ?: @"", @"method": request[@"method"] ?: @"GET", @"headers": request[@"headers"] ?: @{ }, @"initialPriority": @"Medium", @"referrerPolicy": policy } mutableCopy];
    if (request[@"postData"]) {
        result[@"postData"] = request[@"postData"];
        result[@"hasPostData"] = @YES;
    }
    return result;
}

static NSArray *headerEntries(NSDictionary *headers)
{
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *name in headers)
        [entries addObject:@{ @"name": name, @"value": [headers[name] description] }];
    return entries;
}

- (void)intercepted:(NSDictionary *)params target:(NSString *)target response:(BOOL)response
{
    NSString *networkID = params[@"requestId"];
    NSString *key = [NSString stringWithFormat:@"%@/%@", target, networkID];
    NSDictionary *metadata = _requests[key];
    NSDictionary *request = response ? metadata[@"request"] : params[@"request"];
    if (!request)
        request = @{ @"url": params[@"response"][@"url"] ?: @"", @"method": @"GET", @"headers": @{ } };
    NSString *stage = response ? @"Response" : @"Request";
    NSString *type = resourceType(metadata[@"type"]);
    BOOL matches = response && _responseOverrides[key] ? [_responseOverrides[key] boolValue] : [self matches:request stage:stage type:type];
    if (response) [_responseOverrides removeObjectForKey:key];
    if (!_enabled || !matches) {
        [self send:@"Network.interceptContinue" params:@{ @"requestId": networkID, @"stage": stage.lowercaseString } target:target reply:^(NSDictionary *result, NSString *error) { }];
        return;
    }
    NSString *identifier = NSUUID.UUID.UUIDString;
    _paused[identifier] = [@{ @"target": target, @"networkId": networkID, @"stage": stage, @"request": request, @"response": params[@"response"] ?: @{ } } mutableCopy];
    NSString *frame = metadata[@"frameId"];
    NSMutableDictionary *event = [@{ @"requestId": identifier, @"request": cdpRequest(request), @"frameId": !frame || [frame isEqual:_mainFrame] ? @"main" : frame, @"resourceType": type } mutableCopy];
    // Inspector request IDs belong to a different namespace than the native
    // resource delegate; do not advertise an incorrect CDP Network linkage.
    if (response) {
        NSDictionary *value = params[@"response"];
        event[@"responseStatusCode"] = value[@"status"] ?: @0;
        event[@"responseStatusText"] = value[@"statusText"] ?: @"";
        event[@"responseHeaders"] = headerEntries(value[@"headers"] ?: @{ });
    }
    _eventHandler(@"Fetch.requestPaused", event);
}

static NSArray *parsePatterns(id inputs, NSString **error)
{
    if (!inputs)
        inputs = @[ @{ } ];
    if (![inputs isKindOfClass:NSArray.class]) { *error = @"patterns must be an array"; return nil; }
    NSMutableArray *patterns = [NSMutableArray array];
    for (id input in inputs) {
        if (![input isKindOfClass:NSDictionary.class]) { *error = @"Each pattern must be an object"; return nil; }
        NSString *glob = input[@"urlPattern"] ?: @"*";
        NSString *stage = input[@"requestStage"] ?: @"Request";
        NSString *type = input[@"resourceType"];
        if (![glob isKindOfClass:NSString.class] || ![@[ @"Request", @"Response" ] containsObject:stage]
            || (type && ![@[ @"Document", @"Stylesheet", @"Image", @"Media", @"Font", @"Script", @"TextTrack", @"XHR", @"Fetch", @"Prefetch", @"EventSource", @"WebSocket", @"Manifest", @"SignedExchange", @"Ping", @"CSPViolationReport", @"Preflight", @"Other" ] containsObject:type])) {
            *error = @"Invalid Fetch request pattern"; return nil;
        }
        NSMutableString *regex = [NSMutableString stringWithString:@"^"];
        for (NSUInteger index = 0; index < glob.length; ++index) {
            unichar character = [glob characterAtIndex:index];
            if (character == '\\' && index + 1 < glob.length)
                [regex appendString:[NSRegularExpression escapedPatternForString:[glob substringWithRange:NSMakeRange(++index, 1)]]];
            else if (character == '*')
                [regex appendString:@".*"];
            else if (character == '?')
                [regex appendString:@"."];
            else
                [regex appendString:[NSRegularExpression escapedPatternForString:[glob substringWithRange:NSMakeRange(index, 1)]]];
        }
        [regex appendString:@"$"];
        NSMutableDictionary *pattern = [@{ @"requestStage": stage, @"regex": [NSRegularExpression regularExpressionWithPattern:regex options:NSRegularExpressionDotMatchesLineSeparators error:nil] } mutableCopy];
        if (type)
            pattern[@"resourceType"] = type;
        [patterns addObject:pattern];
    }
    return patterns;
}

static NSDictionary *parseHeaders(id value, NSString **error)
{
    if (![value isKindOfClass:NSArray.class]) { *error = @"headers must be an array"; return nil; }
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (id entry in value) {
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"name"] isKindOfClass:NSString.class] || ![entry[@"value"] isKindOfClass:NSString.class]) { *error = @"Invalid header entry"; return nil; }
        NSString *name = entry[@"name"], *content = entry[@"value"];
        if (!name.length || [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n:"]].location != NSNotFound || [content rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) { *error = @"Invalid header name or value"; return nil; }
        NSCharacterSet *invalidName = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"] invertedSet];
        if ([name rangeOfCharacterFromSet:invalidName].location != NSNotFound) { *error = @"Invalid header name"; return nil; }
        for (NSString *existing in headers) {
            if ([existing caseInsensitiveCompare:name] == NSOrderedSame) { *error = @"Duplicate header names are not supported"; return nil; }
        }
        headers[name] = content;
    }
    return headers;
}

- (void)handleCommand:(NSString *)method parameters:(NSDictionary *)params reply:(AutomationFetchReply)reply
{
    if ([method isEqualToString:@"Fetch.enable"]) {
        NSString *error = nil;
        NSArray *patterns = parsePatterns(params[@"patterns"], &error);
        id auth = params[@"handleAuthRequests"];
        if (auth && (![auth isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)auth) != CFBooleanGetTypeID()))
            error = @"handleAuthRequests must be a boolean";
        if (error) { reply(nil, error); return; }
        BOOL wasEnabled = _enabled;
        _patterns = patterns;
        _enabled = YES;
        _handleAuth = [auth boolValue];
        if (wasEnabled && _readyTargets.count == _targets.count && _targets.count) { reply(@{ }, nil); return; }
        [_enableReplies addObject:[reply copy]];
        if (!_connected) {
            _connected = YES;
            [self send:@"Target.setPauseOnStart" params:@{ @"pauseOnStart": @YES } target:nil reply:^(NSDictionary *result, NSString *error) { [self finishEnable:error]; }];
        } else {
            for (NSString *target in _readyTargets)
                [self send:@"Network.setInterceptionEnabled" params:@{ @"enabled": @YES } target:target reply:^(NSDictionary *result, NSString *error) { [self finishEnable:error]; }];
        }
        return;
    }
    if ([method isEqualToString:@"Fetch.disable"]) {
        BOOL wasEnabled = _enabled;
        _enabled = NO;
        _handleAuth = NO;
        if (!wasEnabled) { reply(@{ }, nil); return; }
        for (void (^completion)(NSURLSessionAuthChallengeDisposition, NSURLCredential *) in _authChallenges.allValues.copy)
            completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        [_authChallenges removeAllObjects];
        [_paused removeAllObjects];
        dispatch_group_t group = dispatch_group_create();
        __block NSString *failure;
        for (NSString *target in _readyTargets) {
            dispatch_group_enter(group);
            [self send:@"Network.setInterceptionEnabled" params:@{ @"enabled": @NO } target:target reply:^(NSDictionary *result, NSString *error) { if (error) failure = error; dispatch_group_leave(group); }];
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{ reply(@{ }, failure); });
        return;
    }
    if ([method isEqualToString:@"Fetch.continueWithAuth"]) {
        [self continueAuthentication:params reply:reply];
        return;
    }
    if ([method hasPrefix:@"IO."]) {
        [self handleStream:method params:params reply:reply];
        return;
    }
    NSString *identifier = params[@"requestId"];
    NSMutableDictionary *pending = [identifier isKindOfClass:NSString.class] ? _paused[identifier] : nil;
    if (!pending) { reply(nil, @"Unknown or already resolved Fetch requestId"); return; }
    if ([pending[@"busy"] boolValue]) { reply(nil, @"Fetch request already has a pending command"); return; }
    NSString *stage = pending[@"stage"], *target = pending[@"target"], *networkID = pending[@"networkId"];
    if ([method isEqualToString:@"Fetch.getResponseBody"] || [method isEqualToString:@"Fetch.takeResponseBodyAsStream"]) {
        if (![stage isEqual:@"Response"] || [pending[@"streamTaken"] boolValue]) { reply(nil, @"Response body is unavailable at this stage"); return; }
        BOOL stream = [method isEqualToString:@"Fetch.takeResponseBodyAsStream"];
        if (stream && [pending[@"bodyRead"] boolValue]) { reply(nil, @"getResponseBody and takeResponseBodyAsStream are mutually exclusive"); return; }
        if (!stream) pending[@"bodyRead"] = @YES;
        NSString *handle = stream ? NSUUID.UUID.UUIDString : nil;
        if (stream) {
            _streams[handle] = [NSData data];
            _streamOffsets[handle] = @0;
            [_loadingStreams addObject:handle];
            pending[@"streamTaken"] = @YES;
        } else
            pending[@"busy"] = @YES;
        [self send:@"Network.getResponseBody" params:@{ @"requestId": networkID } target:target reply:^(NSDictionary *result, NSString *error) {
            [pending removeObjectForKey:@"busy"];
            if (!stream) { reply(result, error); return; }
            if (!_streams[handle]) return;
            [_loadingStreams removeObject:handle];
            if (error)
                _streamErrors[handle] = error;
            else {
                NSData *data = [result[@"base64Encoded"] boolValue] ? [[NSData alloc] initWithBase64EncodedString:result[@"body"] options:0] : [result[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
                _streams[handle] = data ?: [NSData data];
            }
            NSDictionary *read = _streamReads[handle];
            [_streamReads removeObjectForKey:handle];
            if (read)
                [self handleStream:@"IO.read" params:read[@"params"] reply:read[@"reply"]];
        }];
        if (stream)
            reply(@{ @"stream": handle }, nil);
        return;
    }
    NSString *error = nil;
    NSMutableDictionary *arguments = [@{ @"requestId": networkID } mutableCopy];
    NSString *backend;
    if ([method isEqualToString:@"Fetch.continueRequest"]) {
        if ([pending[@"streamTaken"] boolValue]) { reply(nil, @"A streamed response must be fulfilled or failed"); return; }
        id interceptResponse = params[@"interceptResponse"];
        if (interceptResponse && (![interceptResponse isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)interceptResponse) != CFBooleanGetTypeID())) { reply(nil, @"interceptResponse must be a boolean"); return; }
        if (interceptResponse && ![stage isEqual:@"Request"]) { reply(nil, @"interceptResponse requires the Request stage"); return; }
        if ([stage isEqual:@"Response"]) {
            if (params[@"url"] || params[@"method"] || params[@"postData"] || params[@"headers"]) { reply(nil, @"Request overrides require the Request stage"); return; }
            backend = @"Network.interceptContinue";
            arguments[@"stage"] = stage.lowercaseString;
        } else {
            backend = @"Network.interceptWithRequest";
            for (NSString *key in @[ @"url", @"method", @"postData" ]) {
                if (params[key]) {
                    if (![params[key] isKindOfClass:NSString.class]) { reply(nil, @"Request overrides must be strings"); return; }
                    arguments[key] = params[key];
                }
            }
            if (params[@"url"]) {
                NSURL *url = [NSURL URLWithString:params[@"url"]];
                if (!url.host.length || ![@[ @"http", @"https" ] containsObject:url.scheme.lowercaseString]) { reply(nil, @"url must be an absolute HTTP(S) URL"); return; }
            }
            if (params[@"method"] && (![params[@"method"] length] || [params[@"method"] rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"] invertedSet]].location != NSNotFound)) { reply(nil, @"Invalid HTTP method"); return; }
            if (params[@"postData"] && ![[NSData alloc] initWithBase64EncodedString:params[@"postData"] options:0]) { reply(nil, @"postData must be base64"); return; }
            if (params[@"headers"])
                arguments[@"headers"] = parseHeaders(params[@"headers"], &error);
        }
    } else if ([method isEqualToString:@"Fetch.failRequest"]) {
        NSDictionary *reasons = @{ @"Failed": @"General", @"Aborted": @"Cancellation", @"TimedOut": @"Timeout", @"AccessDenied": @"AccessControl", @"ConnectionClosed": @"General", @"ConnectionReset": @"General", @"ConnectionRefused": @"General", @"ConnectionAborted": @"General", @"ConnectionFailed": @"General", @"NameNotResolved": @"General", @"InternetDisconnected": @"General", @"AddressUnreachable": @"General", @"BlockedByClient": @"General", @"BlockedByResponse": @"AccessControl" };
        NSString *reason = [params[@"errorReason"] isKindOfClass:NSString.class] ? reasons[params[@"errorReason"]] : nil;
        if (!reason) { reply(nil, @"Invalid errorReason"); return; }
        backend = @"Network.interceptRequestWithError";
        arguments[@"errorType"] = reason;
    } else if ([method isEqualToString:@"Fetch.fulfillRequest"] || [method isEqualToString:@"Fetch.continueResponse"]) {
        [self fulfill:method params:params identifier:identifier pending:pending reply:reply];
        return;
    } else { reply(nil, @"Unsupported Fetch method"); return; }
    if (error) { reply(nil, error); return; }
    if ([method isEqual:@"Fetch.continueRequest"] && params[@"interceptResponse"])
        _responseOverrides[[NSString stringWithFormat:@"%@/%@", target, networkID]] = params[@"interceptResponse"];
    pending[@"busy"] = @YES;
    [self send:backend params:arguments target:target reply:^(NSDictionary *result, NSString *error) {
        [pending removeObjectForKey:@"busy"];
        if (!error) [_paused removeObjectForKey:identifier];
        reply(result, error);
    }];
}

- (void)fulfill:(NSString *)method params:(NSDictionary *)params identifier:(NSString *)identifier pending:(NSMutableDictionary *)pending reply:(AutomationFetchReply)reply
{
    BOOL responseStage = [pending[@"stage"] isEqual:@"Response"];
    BOOL continuing = [method isEqualToString:@"Fetch.continueResponse"];
    if (continuing && (!responseStage || [pending[@"streamTaken"] boolValue])) { reply(nil, @"Response cannot be continued at this stage"); return; }
    if (params[@"binaryResponseHeaders"]) {
        if (params[@"responseHeaders"] || ![params[@"binaryResponseHeaders"] isKindOfClass:NSString.class]) { reply(nil, @"Specify either responseHeaders or binaryResponseHeaders"); return; }
        NSData *data = [[NSData alloc] initWithBase64EncodedString:params[@"binaryResponseHeaders"] options:0];
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] : nil;
        if (!text) { reply(nil, @"binaryResponseHeaders must be base64"); return; }
        NSMutableArray *entries = [NSMutableArray array];
        for (NSString *line in [text componentsSeparatedByString:[NSString stringWithFormat:@"%C", (unichar)0]]) {
            if (!line.length) continue;
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound) { reply(nil, @"Invalid binary header entry"); return; }
            [entries addObject:@{ @"name": [line substringToIndex:colon.location], @"value": [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] }];
        }
        NSMutableDictionary *decoded = params.mutableCopy;
        [decoded removeObjectForKey:@"binaryResponseHeaders"];
        decoded[@"responseHeaders"] = entries;
        [self fulfill:method params:decoded identifier:identifier pending:pending reply:reply];
        return;
    }
    if (continuing && params[@"body"]) { reply(nil, @"continueResponse does not accept a body"); return; }
    if (continuing && ((params[@"responseCode"] != nil) != (params[@"responseHeaders"] != nil))) { reply(nil, @"responseCode and responseHeaders must be supplied together"); return; }
    NSDictionary *original = pending[@"response"];
    id status = params[@"responseCode"] ?: (continuing ? original[@"status"] : nil);
    if (![status isKindOfClass:NSNumber.class] || [status doubleValue] != [status integerValue] || [status integerValue] < 100 || [status integerValue] > 599) { reply(nil, @"responseCode must be an HTTP status code"); return; }
    NSString *error = nil;
    NSDictionary *headers = params[@"responseHeaders"] ? parseHeaders(params[@"responseHeaders"], &error) : (responseStage ? original[@"headers"] : @{ });
    if (error) { reply(nil, error); return; }
    NSString *phrase = params[@"responsePhrase"] ?: (continuing ? original[@"statusText"] : [NSHTTPURLResponse localizedStringForStatusCode:[status integerValue]]);
    if (![phrase isKindOfClass:NSString.class] || [phrase rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) { reply(nil, @"Invalid responsePhrase"); return; }
    NSString *body = params[@"body"];
    if (body && (![body isKindOfClass:NSString.class] || ![[NSData alloc] initWithBase64EncodedString:body options:0])) { reply(nil, @"body must be base64" ); return; }
    if ([pending[@"streamTaken"] boolValue] && !body) { reply(nil, @"A streamed response requires an explicit body" ); return; }
    if (continuing && !params[@"responseCode"] && !params[@"responseHeaders"] && !params[@"responsePhrase"]) {
        pending[@"busy"] = @YES;
        [self send:@"Network.interceptContinue" params:@{ @"requestId": pending[@"networkId"], @"stage": @"response" } target:pending[@"target"] reply:^(NSDictionary *result, NSString *error) {
            [pending removeObjectForKey:@"busy"];
            if (!error) [_paused removeObjectForKey:identifier];
            reply(result, error);
        }];
        return;
    }
    NSString *mime = original[@"mimeType"] ?: @"application/octet-stream";
    for (NSString *name in headers) {
        if ([name caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame)
            mime = [headers[name] componentsSeparatedByString:@";"].firstObject;
    }
    pending[@"busy"] = @YES;
    void (^complete)(NSString *, NSString *) = ^(NSString *content, NSString *bodyError) {
        if (bodyError) { [pending removeObjectForKey:@"busy"]; reply(nil, bodyError); return; }
        NSDictionary *arguments = @{ @"requestId": pending[@"networkId"], @"content": content, @"base64Encoded": @YES, @"mimeType": mime, @"status": status, @"statusText": phrase ?: @"", @"headers": headers ?: @{ } };
        [self send:responseStage ? @"Network.interceptWithResponse" : @"Network.interceptRequestWithResponse" params:arguments target:pending[@"target"] reply:^(NSDictionary *result, NSString *error) {
            [pending removeObjectForKey:@"busy"];
            if (!error) [_paused removeObjectForKey:identifier];
            reply(result, error);
        }];
    };
    if (!body && responseStage) {
        [self send:@"Network.getResponseBody" params:@{ @"requestId": pending[@"networkId"] } target:pending[@"target"] reply:^(NSDictionary *result, NSString *error) {
            NSString *content = [result[@"base64Encoded"] boolValue] ? result[@"body"] : [[result[@"body"] dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
            complete(content ?: @"", error);
        }];
    } else
        complete(body ?: @"", nil);
}

- (BOOL)handleAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion
{
    if (!_enabled || !_handleAuth)
        return NO;
    NSURLProtectionSpace *space = challenge.protectionSpace;
    NSString *scheme;
    if ([space.authenticationMethod isEqual:NSURLAuthenticationMethodHTTPBasic]) scheme = @"basic";
    else if ([space.authenticationMethod isEqual:NSURLAuthenticationMethodHTTPDigest]) scheme = @"digest";
    else return NO;
    NSString *identifier = NSUUID.UUID.UUIDString;
    _authChallenges[identifier] = [completion copy];
    NSString *origin = [NSString stringWithFormat:@"%@://%@:%ld", space.protocol ?: @"http", space.host, (long)space.port];
    NSDictionary *request = @{ @"url": challenge.failureResponse.URL.absoluteString ?: origin };
    NSDictionary *metadata;
    for (NSDictionary *candidate in _requests.allValues) {
        if ([candidate[@"request"][@"url"] isEqual:challenge.failureResponse.URL.absoluteString]) {
            metadata = candidate;
            request = candidate[@"request"];
            break;
        }
    }
    NSString *frame = metadata[@"frameId"];
    _eventHandler(@"Fetch.authRequired", @{ @"requestId": identifier, @"request": cdpRequest(request), @"frameId": !frame || [frame isEqual:_mainFrame] ? @"main" : frame, @"resourceType": resourceType(metadata[@"type"]), @"authChallenge": @{ @"source": space.isProxy ? @"Proxy" : @"Server", @"origin": origin, @"scheme": scheme, @"realm": space.realm ?: @"" } });
    return YES;
}

- (void)continueAuthentication:(NSDictionary *)params reply:(AutomationFetchReply)reply
{
    NSString *identifier = params[@"requestId"];
    id response = params[@"authChallengeResponse"];
    void (^completion)(NSURLSessionAuthChallengeDisposition, NSURLCredential *) = [identifier isKindOfClass:NSString.class] ? _authChallenges[identifier] : nil;
    if (!completion) { reply(nil, @"Unknown authentication requestId"); return; }
    if (![response isKindOfClass:NSDictionary.class]) { reply(nil, @"authChallengeResponse must be an object"); return; }
    NSString *action = response[@"response"];
    NSURLCredential *credential = nil;
    NSURLSessionAuthChallengeDisposition disposition;
    if ([action isEqual:@"Default"]) disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    else if ([action isEqual:@"CancelAuth"]) disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
    else if ([action isEqual:@"ProvideCredentials"]) {
        if ((response[@"username"] && ![response[@"username"] isKindOfClass:NSString.class]) || (response[@"password"] && ![response[@"password"] isKindOfClass:NSString.class])) { reply(nil, @"username and password must be strings"); return; }
        disposition = NSURLSessionAuthChallengeUseCredential;
        credential = [NSURLCredential credentialWithUser:response[@"username"] ?: @"" password:response[@"password"] ?: @"" persistence:NSURLCredentialPersistenceNone];
    } else { reply(nil, @"Invalid authentication response"); return; }
    [_authChallenges removeObjectForKey:identifier];
    completion(disposition, credential);
    reply(@{ }, nil);
}

- (void)handleStream:(NSString *)method params:(NSDictionary *)params reply:(AutomationFetchReply)reply
{
    NSString *handle = params[@"handle"];
    NSData *data = [handle isKindOfClass:NSString.class] ? _streams[handle] : nil;
    if (!data) { reply(nil, @"Unknown stream handle"); return; }
    if ([method isEqual:@"IO.close"]) {
        NSDictionary *read = _streamReads[handle];
        [_streamReads removeObjectForKey:handle];
        [_loadingStreams removeObject:handle];
        [_streamErrors removeObjectForKey:handle];
        [_streams removeObjectForKey:handle];
        [_streamOffsets removeObjectForKey:handle];
        if (read) { AutomationFetchReply waiting = read[@"reply"]; waiting(nil, @"Stream closed"); }
        reply(@{ }, nil); return;
    }
    if (![method isEqual:@"IO.read"]) { reply(nil, @"Unsupported IO method"); return; }
    if (params[@"offset"]) { reply(nil, @"Fetch streams support sequential reads only"); return; }
    id size = params[@"size"] ?: @(65536);
    if (![size isKindOfClass:NSNumber.class] || [size doubleValue] != [size integerValue] || [size integerValue] <= 0) { reply(nil, @"size must be a positive integer"); return; }
    if (_streamErrors[handle]) { reply(nil, _streamErrors[handle]); return; }
    if ([_loadingStreams containsObject:handle]) {
        if (_streamReads[handle]) { reply(nil, @"A stream read is already pending"); return; }
        _streamReads[handle] = @{ @"params": params, @"reply": [reply copy] };
        return;
    }
    NSUInteger offset = [_streamOffsets[handle] unsignedIntegerValue];
    NSUInteger count = MIN(MIN([size unsignedIntegerValue], 1024 * 1024), data.length - offset);
    NSString *body = [[data subdataWithRange:NSMakeRange(offset, count)] base64EncodedStringWithOptions:0];
    _streamOffsets[handle] = @(offset + count);
    reply(@{ @"data": body, @"base64Encoded": @YES, @"eof": @(offset + count == data.length) }, nil);
}

- (void)close
{
    if (_closed)
        return;
    _enabled = NO;
    for (void (^completion)(NSURLSessionAuthChallengeDisposition, NSURLCredential *) in _authChallenges.allValues.copy)
        completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    [_authChallenges removeAllObjects];
    _closed = YES;
    NSArray *callbacks = _callbacks.allValues.copy;
    [_callbacks removeAllObjects];
    [_callbackTargets removeAllObjects];
    [_transportRequests removeAllObjects];
    for (AutomationFetchReply reply in callbacks)
        reply(nil, @"Page closed");
    [self finishEnable:@"Page closed"];
    for (NSDictionary *read in _streamReads.allValues.copy) {
        AutomationFetchReply waiting = read[@"reply"];
        waiting(nil, @"Page closed");
    }
    [_streamReads removeAllObjects];
    [_loadingStreams removeAllObjects];
    [_streamErrors removeAllObjects];
    [_streams removeAllObjects];
    [_streamOffsets removeAllObjects];
    [_paused removeAllObjects];
    [_requests removeAllObjects];
    _eventHandler = nil;
}
@end
