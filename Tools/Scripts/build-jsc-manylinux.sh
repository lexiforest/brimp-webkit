#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 BUILD_DIR" >&2
    exit 2
fi

readonly build_dir=$1
readonly workspace=$(pwd -P)
readonly dependency_root=WebKitBuild/Dependencies
readonly icu_prefix="$dependency_root/icu"
readonly icu_archive="$dependency_root/icu4c-77_1-src.tgz"
readonly icu_source="$dependency_root/icu-source"
readonly icu_sha256=588e431f77327c39031ffbb8843c0e3bc122c211374485fa87dc5f3faff24061
readonly icu_url=https://github.com/unicode-org/icu/releases/download/release-77-1/icu4c-77_1-src.tgz

if [[ $(getconf GNU_LIBC_VERSION) != "glibc 2.28" ]]; then
    echo "build-jsc-manylinux.sh must run in a glibc 2.28 container" >&2
    exit 1
fi

dnf install -y \
    cmake \
    ninja-build \
    perl \
    python3 \
    ruby

mkdir -p "$dependency_root"
curl --fail --location --retry 3 --output "$icu_archive" "$icu_url"
echo "$icu_sha256  $icu_archive" | sha256sum --check --strict
rm -rf "$icu_source" "$icu_prefix"
tar -C "$dependency_root" -xzf "$icu_archive"
mv "$dependency_root/icu" "$icu_source"

pushd "$icu_source/source"
CC=gcc CXX=g++ CFLAGS='-O2 -fPIC' CXXFLAGS='-O2 -fPIC' \
    ./configure \
        --prefix="$workspace/$icu_prefix" \
        --libdir="$workspace/$icu_prefix/lib" \
        --disable-samples \
        --disable-tests \
        --disable-static \
        --enable-shared
make --jobs="$(nproc)"
make install
popd

mkdir -p "$icu_prefix/share/licenses/icu"
cp "$icu_source/LICENSE" "$icu_prefix/share/licenses/icu/LICENSE"

export CC=gcc
export CXX=g++
cmake -S . -B "$build_dir" \
    -G Ninja \
    -DPORT=JSCOnly \
    -DCMAKE_BUILD_TYPE=Release \
    -DDEVELOPER_MODE=ON \
    -DDEVELOPER_MODE_FATAL_WARNINGS=OFF \
    -DENABLE_API_TESTS=OFF \
    '-DCMAKE_BUILD_RPATH=$ORIGIN/../lib' \
    -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
    -DCMAKE_PREFIX_PATH="$icu_prefix"
cmake --build "$build_dir" --target jsc --parallel
