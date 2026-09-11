/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "ResourceLoader.h"
#include "ResourceRequest.h"
#include "ResourceResponse.h"
#include "SharedBuffer.h"
#include <JavaScriptCore/ContentSearchUtilities.h>
#include <JavaScriptCore/RegularExpression.h>
#include <wtf/CompletionHandler.h>
#include <wtf/text/Base64.h>
#include <wtf/TZoneMalloc.h>

namespace Inspector {

enum class NetworkStage { Request, Response };

struct Intercept {
    String url;
    bool caseSensitive { true };
    bool isRegex { false };
    NetworkStage networkStage { NetworkStage::Response };

    inline bool operator==(const Intercept& other) const
    {
        return url == other.url
            && caseSensitive == other.caseSensitive
            && isRegex == other.isRegex
            && networkStage == other.networkStage;
    }

    bool matches(const String& url, NetworkStage);

private:
    std::optional<Inspector::ContentSearchUtilities::Searcher> m_urlSearcher;

    // Avoid having to (re)match the searcher each time a URL is requested.
    HashSet<String> m_knownMatchingURLs;
};

class PendingInterceptRequest {
    WTF_MAKE_TZONE_ALLOCATED(PendingInterceptRequest);
    WTF_MAKE_NONCOPYABLE(PendingInterceptRequest);
public:
    PendingInterceptRequest(RefPtr<WebCore::ResourceLoader> loader, Function<void(const WebCore::ResourceRequest&)>&& callback)
        : m_loader(loader)
        , m_completionCallback(WTF::move(callback))
    { }

    void continueWithOriginalRequest()
    {
        if (!m_loader->reachedTerminalState())
            m_completionCallback(m_loader->request());
    }

    void continueWithRequest(const WebCore::ResourceRequest& request)
    {
        m_completionCallback(request);
    }

    PendingInterceptRequest() = default;
    RefPtr<WebCore::ResourceLoader> m_loader;
    Function<void(const WebCore::ResourceRequest&)> m_completionCallback;
};

class PendingInterceptResponse {
    WTF_MAKE_TZONE_ALLOCATED(PendingInterceptResponse);
    WTF_MAKE_NONCOPYABLE(PendingInterceptResponse);
public:
    PendingInterceptResponse(const WebCore::ResourceResponse& originalResponse, CompletionHandler<void(const WebCore::ResourceResponse&, RefPtr<WebCore::FragmentedSharedBuffer>)>&& completionHandler, Function<void()>&& failHandler)
        : m_originalResponse(originalResponse)
        , m_completionHandler(WTF::move(completionHandler))
        , m_failHandler(WTF::move(failHandler))
    { }

    ~PendingInterceptResponse()
    {
        ASSERT(m_responded);
        for (auto& callback : m_bodyCallbacks)
            callback({ }, "Intercepted response is no longer available"_s);
    }

    void receiveBody(const WebCore::FragmentedSharedBuffer* data, bool finished, bool failed)
    {
        if (data && m_bodyError.isEmpty()) {
            if (m_body.size() + data->size() > 32 * 1024 * 1024) {
                m_bodyError = "Intercepted response exceeds the 32 MiB body limit"_s;
                m_body.clear();
            } else
                m_body.appendVector(data->copyData());
        }
        if (failed)
            m_bodyError = "Intercepted response failed while reading its body"_s;
        m_bodyComplete |= finished || failed || !m_bodyError.isEmpty();
        if (m_bodyComplete) {
            auto callbacks = std::exchange(m_bodyCallbacks, { });
            auto body = base64EncodeToString(m_body.span());
            for (auto& callback : callbacks)
                callback(body, m_bodyError);
        }
    }

    void getBody(Function<void(const String&, const String&)>&& callback)
    {
        if (m_bodyComplete)
            callback(base64EncodeToString(m_body.span()), m_bodyError);
        else
            m_bodyCallbacks.append(WTF::move(callback));
    }

    void fail()
    {
        m_failHandler();
        respondWithOriginalResponse();
    }

    WebCore::ResourceResponse originalResponse() { return m_originalResponse; }

    void respondWithOriginalResponse()
    {
        respond(m_originalResponse, nullptr);
    }

    void respond(const WebCore::ResourceResponse& response, RefPtr<WebCore::FragmentedSharedBuffer> data)
    {
        ASSERT(!m_responded);
        if (m_responded)
            return;

        m_responded = true;

        m_completionHandler(response, data);
    }

private:
    WebCore::ResourceResponse m_originalResponse;
    CompletionHandler<void(const WebCore::ResourceResponse&, RefPtr<WebCore::FragmentedSharedBuffer>)> m_completionHandler;
    Function<void()> m_failHandler;
    bool m_responded { false };
    bool m_bodyComplete { false };
    Vector<uint8_t> m_body;
    String m_bodyError;
    Vector<Function<void(const String&, const String&)>> m_bodyCallbacks;
};

} // namespace Inspector
