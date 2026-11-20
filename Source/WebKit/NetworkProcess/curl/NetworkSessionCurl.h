/*
 * Copyright (C) 2018 Sony Interactive Entertainment Inc.
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

#pragma once

#include "AuthenticationChallengeDisposition.h"
#include "NetworkSession.h"

#if PLATFORM(GTK)
#include "SoupCookiePersistentStorageType.h"
#include <WebCore/SoupNetworkProxySettings.h>
#include <WebCore/CertificateInfo.h>
#include <gio/gio.h>
#include <wtf/glib/GRefPtr.h>
#include <wtf/text/StringHash.h>
#endif

namespace WebKit {

struct NetworkSessionCreationParameters;
class WebSocketTask;

class NetworkSessionCurl final : public NetworkSession {
public:
    static std::unique_ptr<NetworkSession> create(NetworkProcess& networkProcess, const NetworkSessionCreationParameters& parameters)
    {
        return makeUnique<NetworkSessionCurl>(networkProcess, parameters);
    }
    NetworkSessionCurl(NetworkProcess&, const NetworkSessionCreationParameters&);
    ~NetworkSessionCurl();

    void clearAlternativeServices(WallTime) override;
#if PLATFORM(GTK)
    void setIgnoreTLSErrors(bool value) { m_ignoreTLSErrors = value; }
    bool ignoreTLSErrors() const { return m_ignoreTLSErrors; }
    void setProxySettings(const WebCore::SoupNetworkProxySettings&);
    GProxyResolver* proxyResolver() const { return m_proxyResolver.get(); }
    void setCookiePersistentStorage(const String&, SoupCookiePersistentStorageType);
    void allowSpecificHTTPSCertificateForHost(const WebCore::CertificateInfo&, const String&);
    bool isCertificateAllowed(const WebCore::CertificateInfo&, const String&) const;
    void setPersistentCredentialStorageEnabled(bool);
#endif

    void didReceiveChallenge(WebSocketTask&, WebCore::AuthenticationChallenge&&, CompletionHandler<void(WebKit::AuthenticationChallengeDisposition, const WebCore::Credential&)>&&);

private:
#if PLATFORM(GTK)
    bool m_ignoreTLSErrors { false };
    GRefPtr<GProxyResolver> m_proxyResolver;
    HashMap<String, WebCore::CertificateInfo::Certificate> m_allowedCertificates;
#endif
    RefPtr<WebSocketTask> createWebSocketTask(WebPageProxyIdentifier, std::optional<WebCore::FrameIdentifier>, std::optional<WebCore::PageIdentifier>, NetworkSocketChannel&, WebCore::ResourceRequest&&, const String& protocol, const WebCore::ClientOrigin&, bool, bool, OptionSet<WebCore::AdvancedPrivacyProtections>, WebCore::StoredCredentialsPolicy, WebCore::IsInitiatedByDedicatedWorker) final;
};

} // namespace WebKit
