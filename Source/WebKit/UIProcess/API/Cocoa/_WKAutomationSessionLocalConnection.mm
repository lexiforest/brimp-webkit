/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
#import "_WKAutomationSessionLocalConnection.h"

#if ENABLE(REMOTE_INSPECTOR)

#import "WKWebViewInternal.h"
#import "WebAutomationSession.h"
#import "WebPageProxy.h"
#import "_WKAutomationSessionInternal.h"
#import <JavaScriptCore/InspectorFrontendChannel.h>
#import <objc/runtime.h>
#import <wtf/BlockPtr.h>
#import <wtf/RetainPtr.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/WeakObjCPtr.h>

namespace WebKit {

// Local embedding transport. The wrapper disconnects before deallocation;
// the application owns framing and delivery of messages outside this process.
class LocalFrontendChannel final : public Inspector::FrontendChannel {
    WTF_MAKE_TZONE_ALLOCATED(LocalFrontendChannel);
public:
    explicit LocalFrontendChannel(void (^handler)(NSString *))
        : m_handler(makeBlockPtr(handler))
    {
    }

    ConnectionType connectionType() const final { return ConnectionType::Local; }

    void sendMessageToFrontend(const String& message) final
    {
        if (m_handler)
            m_handler(message.createNSString().get());
    }

private:
    BlockPtr<void(NSString *)> m_handler;
};

WTF_MAKE_TZONE_ALLOCATED_IMPL(LocalFrontendChannel);

} // namespace WebKit

@interface _WKAutomationSessionLocalChannel : NSObject {
@public
    std::unique_ptr<WebKit::LocalFrontendChannel> _channel;
    WeakObjCPtr<_WKAutomationSession> _session;
}
@end

@implementation _WKAutomationSessionLocalChannel
- (void)dealloc
{
    RetainPtr session = _session.get();
    if (_channel && session) {
        Ref automationSession = downcast<WebKit::WebAutomationSession>([session _apiObject]);
        automationSession->disconnect(*_channel);
    }
    [super dealloc];
}
@end

static void *kAutomationLocalChannelKey = &kAutomationLocalChannelKey;

@implementation _WKAutomationSession (LocalConnection)

- (NSString *)_registerWebView:(WKWebView *)webView
{
    RefPtr page = [webView _page].get();
    if (!page)
        return nil;
    Ref session = downcast<WebKit::WebAutomationSession>([self _apiObject]);
    return session->handleForWebPageProxy(*page).createNSString().autorelease();
}

- (void)_setMessageToFrontendHandler:(void (^)(NSString *))handler
{
    Ref session = downcast<WebKit::WebAutomationSession>([self _apiObject]);

    // Tear down any previously installed local channel first. The wrapper's
    // dealloc disconnects the channel from the session, so just dropping the
    // associated object would race; do the disconnect deterministically.
    RetainPtr existing = (_WKAutomationSessionLocalChannel *)objc_getAssociatedObject(self, kAutomationLocalChannelKey);
    if (existing) {
        if (existing->_channel)
            session->disconnect(*existing->_channel);
        existing->_channel = nullptr;
        existing->_session = nil;
        objc_setAssociatedObject(self, kAutomationLocalChannelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!handler)
        return;

    RetainPtr wrapper = adoptNS([[_WKAutomationSessionLocalChannel alloc] init]);
    wrapper->_channel = makeUnique<WebKit::LocalFrontendChannel>(handler);
    wrapper->_session = self;

    session->connect(*wrapper->_channel);

    objc_setAssociatedObject(self, kAutomationLocalChannelKey, wrapper.get(), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)_dispatchMessageFromRemote:(NSString *)message
{
    Ref session = downcast<WebKit::WebAutomationSession>([self _apiObject]);
    session->dispatchMessageFromRemote(String(message));
}

@end

#endif // ENABLE(REMOTE_INSPECTOR)
