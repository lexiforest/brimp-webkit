#include "config.h"
#include "CurlSSLHandle.h"
#include <cstdlib>

namespace WebCore {

void CurlSSLHandle::platformInitialize()
{
    // curl-impersonate owns the profile's ciphers, groups and signature algorithms.
    // Certificate trust uses the SDK's CA bundle unless the embedding process
    // explicitly selects a different trust store before starting WebKit.
    if (const char* path = std::getenv("WEBKIT_CURL_CA_BUNDLE"))
        setCACertPath(String::fromUTF8(path));
}

} // namespace WebCore
