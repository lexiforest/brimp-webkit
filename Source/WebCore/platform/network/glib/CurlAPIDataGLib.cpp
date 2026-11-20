/*
 * Copyright (C) 2009 Gustavo Noronha Silva
 * Copyright (C) 2009 Collabora Ltd.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#include "config.h"
#include "ResourceRequest.h"
#include "ResourceResponse.h"
#include <WebCore/WebKitFormDataInputStream.h>

namespace WebCore {

GRefPtr<GInputStream> ResourceRequest::createBodyStream() const
{
    RefPtr formData = httpBody();
    if (!formData || formData->isEmpty())
        return nullptr;

    auto resolvedFormData = formData->resolveBlobReferences();
    for (auto& element : resolvedFormData->elements()) {
        if (element.lengthInBytes() > 0)
            return webkitFormDataInputStreamNew(WTF::move(resolvedFormData));
    }
    return nullptr;
}

void ResourceRequest::updateSoupMessageHeaders(SoupMessageHeaders* headers) const
{
    for (const auto& header : httpHeaderFields())
        soup_message_headers_append(headers, header.key.utf8().data(), header.value.utf8().data());
}

void ResourceRequest::updateFromSoupMessageHeaders(SoupMessageHeaders* headers)
{
    m_requestData.m_httpHeaderFields.clear();
    SoupMessageHeadersIter iterator;
    soup_message_headers_iter_init(&iterator, headers);
    const char* name;
    const char* value;
    while (soup_message_headers_iter_next(&iterator, &name, &value))
        m_requestData.m_httpHeaderFields.set(String::fromLatin1(name), String::fromLatin1(value));
}

void ResourceResponse::updateSoupMessageHeaders(SoupMessageHeaders* headers) const
{
    for (const auto& header : httpHeaderFields())
        soup_message_headers_append(headers, header.key.utf8().data(), header.value.utf8().data());
}

void ResourceResponse::updateFromSoupMessageHeaders(SoupMessageHeaders* soupHeaders)
{
    SoupMessageHeadersIter headersIter;
    const char* headerName;
    const char* headerValue;
    soup_message_headers_iter_init(&headersIter, soupHeaders);
    while (soup_message_headers_iter_next(&headersIter, &headerName, &headerValue))
        addHTTPHeaderField(String::fromLatin1(headerName), String::fromLatin1(headerValue));
}

} // namespace WebCore
