#include "config.h"
#include "CertificateInfo.h"
#include <openssl/x509_vfy.h>
#include <wtf/glib/GUniquePtr.h>
#include <wtf/text/CString.h>

namespace WebCore {

CertificateInfo::CertificateInfo(GTlsCertificate* certificate, GTlsCertificateFlags errors)
    : m_verificationError(errors ? X509_V_ERR_CERT_REJECTED : X509_V_OK)
{
    for (auto* current = certificate; current; current = g_tls_certificate_get_issuer(current)) {
        GUniqueOutPtr<char> pem;
        g_object_get(current, "certificate-pem", &pem.outPtr(), nullptr);
        if (pem)
            m_certificateChain.append(makeCertificate({ byteCast<uint8_t>(pem.get()), strlen(pem.get()) }));
    }
}

const GRefPtr<GTlsCertificate>& CertificateInfo::certificate() const
{
    if (m_glibCertificate || m_certificateChain.isEmpty())
        return m_glibCertificate;
    auto certificateType = g_tls_backend_get_certificate_type(g_tls_backend_get_default());
    for (size_t index = m_certificateChain.size(); index; --index) {
        auto& bytes = m_certificateChain[index - 1];
        CString pem(std::span<const char> { byteCast<char>(bytes.span().data()), bytes.size() });
        auto* certificate = G_TLS_CERTIFICATE(g_initable_new(certificateType, nullptr, nullptr,
            "certificate-pem", pem.data(), "issuer", m_glibCertificate.get(), nullptr));
        if (!certificate) {
            m_glibCertificate = nullptr;
            break;
        }
        m_glibCertificate = adoptGRef(certificate);
    }
    return m_glibCertificate;
}

GTlsCertificateFlags CertificateInfo::tlsErrors() const
{
    switch (m_verificationError) {
    case X509_V_OK:
        return static_cast<GTlsCertificateFlags>(0);
    case X509_V_ERR_CERT_HAS_EXPIRED:
        return G_TLS_CERTIFICATE_EXPIRED;
    case X509_V_ERR_CERT_NOT_YET_VALID:
        return G_TLS_CERTIFICATE_NOT_ACTIVATED;
    case X509_V_ERR_CERT_REVOKED:
        return G_TLS_CERTIFICATE_REVOKED;
    case X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT:
    case X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN:
    case X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY:
        return G_TLS_CERTIFICATE_UNKNOWN_CA;
    default:
        return G_TLS_CERTIFICATE_GENERIC_ERROR;
    }
}

} // namespace WebCore
