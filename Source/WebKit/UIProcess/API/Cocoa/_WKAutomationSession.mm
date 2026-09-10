/*
 * Copyright (C) 2016 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "_WKAutomationSessionInternal.h"

#import "AutomationSessionClient.h"
#import "WKAPICast.h"
#import "WKProcessPool.h"
#import "WKWebViewInternal.h"
#import "WebPageProxy.h"
#import <JavaScriptCore/InspectorFrontendChannel.h>
#import <wtf/BlockPtr.h>
#import <wtf/TZoneMallocInlines.h>
#import "WebAutomationSession.h"
#import "_WKAutomationSessionConfiguration.h"
#import "_WKAutomationSessionDelegate.h"
#import <WebCore/WebCoreObjCExtras.h>
#import <wtf/WeakObjCPtr.h>

#if ENABLE(REMOTE_INSPECTOR)
namespace WebKit {
class LocalAutomationFrontendChannel final : public Inspector::FrontendChannel {
    WTF_MAKE_TZONE_ALLOCATED(LocalAutomationFrontendChannel);
public:
    explicit LocalAutomationFrontendChannel(void (^handler)(NSString *))
        : m_handler(makeBlockPtr(handler)) { }
    ConnectionType connectionType() const final { return ConnectionType::Local; }
    void sendMessageToFrontend(const String& message) final { m_handler(message.createNSString().get()); }
private:
    BlockPtr<void(NSString *)> m_handler;
};
WTF_MAKE_TZONE_ALLOCATED_IMPL(LocalAutomationFrontendChannel);
}
#endif

@implementation _WKAutomationSession {
#if ENABLE(REMOTE_INSPECTOR)
    std::unique_ptr<WebKit::LocalAutomationFrontendChannel> _localChannel;
#endif
    RetainPtr<_WKAutomationSessionConfiguration> _configuration;
    WeakObjCPtr<id <_WKAutomationSessionDelegate>> _delegate;
}

- (void)setLocalMessageHandler:(void (^)(NSString *))handler
{
#if ENABLE(REMOTE_INSPECTOR)
    if (_localChannel) {
        protect(*_session)->disconnect(*_localChannel);
        _localChannel = nullptr;
    }
    if (handler) {
        _localChannel = makeUnique<WebKit::LocalAutomationFrontendChannel>(handler);
        protect(*_session)->connect(*_localChannel);
    }
#endif
}

- (void)dispatchLocalMessage:(NSString *)message
{
#if ENABLE(REMOTE_INSPECTOR)
    if (_localChannel)
        protect(*_session)->dispatchMessageFromRemote(String(message));
#endif
}

- (NSString *)registerWebView:(WKWebView *)webView
{
    RefPtr page = [webView _page].get();
    return page ? protect(*_session)->handleForWebPageProxy(*page).createNSString().autorelease() : nil;
}

- (instancetype)init
{
    return [self initWithConfiguration:adoptNS([[_WKAutomationSessionConfiguration alloc] init]).get()];
}

- (instancetype)initWithConfiguration:(_WKAutomationSessionConfiguration *)configuration
{
    if (!(self = [super init]))
        return nil;

    API::Object::constructInWrapper<WebKit::WebAutomationSession>(self, [configuration siteIsolationEnabled]);

    _configuration = adoptNS([configuration copy]);

    return self;
}

- (void)dealloc
{
    if (WebCoreObjCScheduleDeallocateOnMainRunLoop(_WKAutomationSession.class, self))
        return;

#if ENABLE(REMOTE_INSPECTOR)
    if (_localChannel) {
        protect(*_session)->disconnect(*_localChannel);
        _localChannel = nullptr;
    }
#endif
    protect(*_session)->setClient(nullptr);
    SUPPRESS_UNCOUNTED_ARG _session->~WebAutomationSession();

    [super dealloc];
}

- (id <_WKAutomationSessionDelegate>)delegate
{
    return _delegate.getAutoreleased();
}

- (void)setDelegate:(id <_WKAutomationSessionDelegate>)delegate
{
    _delegate = delegate;
    protect(*_session)->setClient(delegate ? makeUnique<WebKit::AutomationSessionClient>(delegate) : nullptr);
}

- (NSString *)sessionIdentifier
{
    return _session->sessionIdentifier().createNSString().autorelease();
}

- (void)setSessionIdentifier:(NSString *)sessionIdentifier
{
    protect(*_session)->setSessionIdentifier(sessionIdentifier);
}

- (_WKAutomationSessionConfiguration *)configuration
{
    return adoptNS([_configuration copy]).autorelease();
}

- (BOOL)isPaired
{
    return _session->isPaired();
}

- (BOOL)isPendingTermination
{
    return _session->isPendingTermination();
}

- (BOOL)isSimulatingUserInteraction
{
    return _session->isSimulatingUserInteraction();
}

- (void)terminate
{
    protect(*_session)->terminate();
}

#if PLATFORM(MAC)
- (BOOL)wasEventSynthesizedForAutomation:(NSEvent *)event
{
    return protect(*_session)->wasEventSynthesizedForAutomation(event);
}

- (void)markEventAsSynthesizedForAutomation:(NSEvent *)event
{
    protect(*_session)->markEventAsSynthesizedForAutomation(event);
}
#endif

#pragma mark WKObject protocol implementation

- (API::Object&)_apiObject
{
    return *_session;
}

@end
