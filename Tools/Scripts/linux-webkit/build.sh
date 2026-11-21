#!/usr/bin/env bash
set -euo pipefail

# Development build; system dependencies are described in the adjacent README.
webkit_source=$(realpath "${1:?usage: build.sh WEBKIT_SOURCE WORK_DIRECTORY}")
work=$(realpath -m "${2:?usage: build.sh WEBKIT_SOURCE WORK_DIRECTORY}")
curl_source="$work/src/curl-impersonate"
curl_sdk="$work/sdk/curl-impersonate-2.3.2"
curl_revision=5b1c3542fc7fc0e9fe623a6c9a848d16f92fe99a
jobs=${BRIMP_BUILD_JOBS:-16}

mkdir -p "$work/src" "$work/build" "$work/sdk"
if [[ ! -d "$curl_source/.git" ]]; then
    git clone --depth 1 --branch v2.3.2 \
        https://github.com/lexiforest/curl-impersonate.git "$curl_source"
fi
[[ "$(git -C "$curl_source" rev-parse HEAD)" == "$curl_revision" ]]
[[ -z "$(git -C "$curl_source" status --porcelain --untracked-files=no)" ]]

# WebKit already normalizes internationalized hostnames before invoking curl.
cmake -S "$curl_source" -B "$work/build/curl" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$curl_sdk" \
    -DCMAKE_INSTALL_LIBDIR=lib -DSUBJOBS="$jobs" -DUSE_LIBIDN2=OFF \
    -DCURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    -DCURL_CA_PATH=/etc/ssl/certs
cmake --build "$work/build/curl" --target install-all --parallel 4
# WebKit's SSL-context callback must use the exact TLS headers behind curl.
cp -a "$work/build/curl/deps/src/boringssl/include/openssl" "$curl_sdk/include/"

# Pin the production C++ implementation; host Swift auto-detection must not
# enable prototype features or add a Swift runtime dependency to the SDK.
cmake -S "$webkit_source" -B "$work/build/webkit-curl" -G Ninja \
    -DPORT=GTK -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang-18 -DCMAKE_CXX_COMPILER=clang++-18 \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DTRY_USE_LD_LLD=ON -DUSE_LD_LLD=ON -DCURL_IMPERSONATE_ROOT="$curl_sdk" \
    -DCMAKE_INSTALL_PREFIX="$work/sdk/webkit-curl" \
    -DENABLE_DOCUMENTATION=OFF -DENABLE_INTROSPECTION=OFF \
    -DENABLE_SWIFT_DEMO_URI_SCHEME=OFF -DENABLE_BACK_FORWARD_LIST_SWIFT=OFF \
    -DENABLE_API_TESTS=OFF -DENABLE_LAYOUT_TESTS=OFF -DENABLE_MINIBROWSER=ON \
    -DENABLE_VIDEO=OFF -DENABLE_WEB_AUDIO=OFF -DUSE_GSTREAMER=OFF \
    -DENABLE_SPEECH_SYNTHESIS=OFF -DENABLE_GAMEPAD=OFF \
    -DUSE_SYSPROF_CAPTURE=OFF -DUSE_SKIA_OPENTYPE_SVG=OFF \
    -DUSE_LIBBACKTRACE=OFF
cmake --build "$work/build/webkit-curl" --parallel "$jobs"
cmake --install "$work/build/webkit-curl"
