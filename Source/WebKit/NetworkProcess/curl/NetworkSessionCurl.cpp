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

#include "config.h"
#include "NetworkSessionCurl.h"

#include "AuthenticationManager.h"
#include "NetworkProcess.h"
#include "NetworkSessionCreationParameters.h"
#include "WebCookieManager.h"
#include "WebSocketTaskCurl.h"
#include <WebCore/CookieJarDB.h>
#include <WebCore/CurlContext.h>
#include <WebCore/NetworkStorageSession.h>
#if PLATFORM(GTK)
#include <WebCore/WebKitAutoconfigProxyResolver.h>
#endif

namespace WebKit {

using namespace WebCore;

NetworkSessionCurl::NetworkSessionCurl(NetworkProcess& networkProcess, const NetworkSessionCreationParameters& parameters)
    : NetworkSession(networkProcess, parameters)
{
#if PLATFORM(GTK)
    setIgnoreTLSErrors(parameters.ignoreTLSErrors);
    setProxySettings(parameters.proxySettings);
    if (!parameters.cookiePersistentStoragePath.isEmpty())
        setCookiePersistentStorage(parameters.cookiePersistentStoragePath, parameters.cookiePersistentStorageType);
    networkProcess.supplement<WebCookieManager>()->setHTTPCookieAcceptPolicy(sessionID(), parameters.cookieAcceptPolicy, [] { });
#else
    if (auto* storageSession = networkStorageSession()) {
        if (!parameters.cookiePersistentStorageFile.isEmpty())
            storageSession->setCookieDatabase(makeUniqueRef<CookieJarDB>(parameters.cookiePersistentStorageFile));
        storageSession->setProxySettings(parameters.proxySettings);
    }

#endif
    m_resourceLoadStatisticsDirectory = parameters.resourceLoadStatisticsParameters.directory;
    m_shouldIncludeLocalhostInResourceLoadStatistics = parameters.resourceLoadStatisticsParameters.shouldIncludeLocalhost ? ShouldIncludeLocalhost::Yes : ShouldIncludeLocalhost::No;
    m_enableResourceLoadStatisticsDebugMode = parameters.resourceLoadStatisticsParameters.enableDebugMode ? EnableResourceLoadStatisticsDebugMode::Yes : EnableResourceLoadStatisticsDebugMode::No;
    m_resourceLoadStatisticsManualPrevalentResource = parameters.resourceLoadStatisticsParameters.manualPrevalentResource;
    setTrackingPreventionEnabled(parameters.resourceLoadStatisticsParameters.enabled);
}

NetworkSessionCurl::~NetworkSessionCurl() = default;

void NetworkSessionCurl::clearAlternativeServices(WallTime)
{
    if (CheckedPtr storageSession = networkStorageSession())
        storageSession->clearAlternativeServices();
}

RefPtr<WebSocketTask> NetworkSessionCurl::createWebSocketTask(WebPageProxyIdentifier webPageProxyID, std::optional<FrameIdentifier>, std::optional<PageIdentifier>, NetworkSocketChannel& channel, WebCore::ResourceRequest&& request, const String& protocol, const WebCore::ClientOrigin& clientOrigin, bool, bool, OptionSet<WebCore::AdvancedPrivacyProtections>, StoredCredentialsPolicy, IsInitiatedByDedicatedWorker)
{
    return WebSocketTask::create(channel, webPageProxyID, request, protocol, clientOrigin);
}

void NetworkSessionCurl::didReceiveChallenge(WebSocketTask& webSocketTask, WebCore::AuthenticationChallenge&& challenge, CompletionHandler<void(WebKit::AuthenticationChallengeDisposition, const WebCore::Credential&)>&& challengeCompletionHandler)
{
    protect(networkProcess().authenticationManager())->didReceiveAuthenticationChallenge(sessionID(), webSocketTask.webPageProxyID(), !webSocketTask.topOrigin().isNull() ? &webSocketTask.topOrigin() : nullptr, challenge, NegotiatedLegacyTLS::No, WTF::move(challengeCompletionHandler));
}

#if PLATFORM(GTK)
void NetworkSessionCurl::setProxySettings(const SoupNetworkProxySettings& settings)
{
    if (settings.mode == SoupNetworkProxySettings::Mode::Default) {
        m_proxyResolver = g_proxy_resolver_get_default();
        return;
    }
    if (settings.mode == SoupNetworkProxySettings::Mode::NoProxy) {
        m_proxyResolver = adoptGRef(g_simple_proxy_resolver_new(nullptr, nullptr));
        return;
    }
    if (settings.mode == SoupNetworkProxySettings::Mode::Auto) {
        m_proxyResolver = webkitAutoconfigProxyResolverNew(settings.defaultProxyURL);
        return;
    }
    Vector<char*> ignoreHosts;
    for (auto& host : settings.ignoreHosts)
        ignoreHosts.append(const_cast<char*>(host.data()));
    ignoreHosts.append(nullptr);
    m_proxyResolver = adoptGRef(g_simple_proxy_resolver_new(settings.defaultProxyURL.data(), ignoreHosts.mutableSpan().data()));
    for (const auto& entry : settings.proxyMap)
        g_simple_proxy_resolver_set_uri_proxy(G_SIMPLE_PROXY_RESOLVER(m_proxyResolver.get()), entry.key.data(), entry.value.data());
}

void NetworkSessionCurl::setCookiePersistentStorage(const String& path, SoupCookiePersistentStorageType type)
{
    // The curl backend uses its native SQLite cookie store.
    if (type != SoupCookiePersistentStorageType::SQLite) {
        g_warning("The curl backend requires SQLite cookie persistence");
        return;
    }
    if (auto* storage = networkStorageSession()) {
        auto database = makeUniqueRef<CookieJarDB>(path);
        database->setAcceptPolicy(storage->cookieDatabase().acceptPolicy());
        storage->setCookieDatabase(WTF::move(database));
    }
}

void NetworkSessionCurl::allowSpecificHTTPSCertificateForHost(const CertificateInfo& info, const String& host)
{
    if (!info.certificateChain().isEmpty())
        m_allowedCertificates.set(host.convertToASCIILowercase(), info.certificateChain()[0]);
}

bool NetworkSessionCurl::isCertificateAllowed(const CertificateInfo& info, const String& host) const
{
    auto found = m_allowedCertificates.find(host.convertToASCIILowercase());
    return found != m_allowedCertificates.end() && !info.certificateChain().isEmpty() && found->value == info.certificateChain()[0];
}

void NetworkSessionCurl::setPersistentCredentialStorageEnabled(bool enabled)
{
    if (enabled)
        g_warning("The curl backend supports session credentials; persistent credential storage is unavailable");
}
#endif

} // namespace WebKit
