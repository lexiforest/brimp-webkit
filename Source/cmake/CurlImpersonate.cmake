# Use the pinned curl-impersonate SDK and its matching BoringSSL. Static linkage
# gives WebKit one TLS implementation, including the SSL_CTX callback boundary.
set(CURL_IMPERSONATE_ROOT "" CACHE PATH "curl-impersonate SDK including matching BoringSSL headers")
if (NOT CURL_IMPERSONATE_ROOT)
    message(FATAL_ERROR "CURL_IMPERSONATE_ROOT must name the pinned curl-impersonate SDK")
endif ()
find_package(PkgConfig REQUIRED)
list(PREPEND CMAKE_PREFIX_PATH "${CURL_IMPERSONATE_ROOT}")
pkg_check_modules(CURL_IMPERSONATE REQUIRED libcurl-impersonate)
find_path(OPENSSL_INCLUDE_DIR openssl/ssl.h PATHS "${CURL_IMPERSONATE_ROOT}/include" NO_DEFAULT_PATH REQUIRED)
file(STRINGS "${OPENSSL_INCLUDE_DIR}/openssl/base.h" _boringssl_define REGEX "^#define OPENSSL_IS_BORINGSSL")
if (NOT _boringssl_define)
    message(FATAL_ERROR "curl-impersonate requires its matching BoringSSL headers")
endif ()
find_file(CURL_IMPERSONATE_LIBRARY libcurl-impersonate.a PATHS "${CURL_IMPERSONATE_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)
set(_curl_dependencies)
foreach (_library IN LISTS CURL_IMPERSONATE_STATIC_LIBRARIES)
    if (_library STREQUAL "curl-impersonate")
        continue()
    endif ()
    if (_library STREQUAL "dl" OR _library STREQUAL "pthread" OR _library STREQUAL "stdc++" OR _library STREQUAL "m")
        list(APPEND _curl_dependencies "${_library}")
    else ()
        unset(_dependency CACHE)
        find_file(_dependency "lib${_library}.a" PATHS "${CURL_IMPERSONATE_ROOT}/lib/curl-impersonate" NO_DEFAULT_PATH REQUIRED)
        list(APPEND _curl_dependencies "${_dependency}")
    endif ()
endforeach ()
add_library(CURL::libcurl STATIC IMPORTED GLOBAL)
set_target_properties(CURL::libcurl PROPERTIES
    IMPORTED_LOCATION "${CURL_IMPERSONATE_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${CURL_IMPERSONATE_ROOT}/include"
    INTERFACE_LINK_LIBRARIES "${_curl_dependencies}"
    INTERFACE_LINK_OPTIONS "-Wl,--exclude-libs,ALL"
)
add_library(OpenSSL::SSL INTERFACE IMPORTED GLOBAL)
set_target_properties(OpenSSL::SSL PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${OPENSSL_INCLUDE_DIR}"
    INTERFACE_LINK_LIBRARIES "${CURL_IMPERSONATE_ROOT}/lib/curl-impersonate/libssl.a;${CURL_IMPERSONATE_ROOT}/lib/curl-impersonate/libcrypto.a"
)
include(CheckCXXSourceCompiles)
cmake_push_check_state()
set(CMAKE_REQUIRED_LIBRARIES CURL::libcurl)
check_cxx_source_compiles("#include <curl/curl.h>
int main() { return curl_easy_impersonate(nullptr, \"safari270\", 0); }" HAVE_CURL_IMPERSONATE)
cmake_pop_check_state()
if (NOT HAVE_CURL_IMPERSONATE)
    message(FATAL_ERROR "The selected SDK does not provide curl_easy_impersonate")
endif ()
