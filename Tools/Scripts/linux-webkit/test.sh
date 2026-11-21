#!/usr/bin/env bash
set -euo pipefail

sdk=$(realpath "${1:?usage: test.sh WEBKIT_INSTALL_PREFIX CURL_INSTALL_PREFIX}")
curl_sdk=$(realpath "${2:?usage: test.sh WEBKIT_INSTALL_PREFIX CURL_INSTALL_PREFIX}")
tests=$(cd -- "$(dirname -- "$0")" && pwd)
# Report host sandbox restrictions once, before compiling or running browser tests.
if ! bwrap --unshare-user --unshare-pid --ro-bind / / --proc /proc true; then
    echo "Bubblewrap cannot create a sandbox; check the host's user-namespace/AppArmor policy (see README.md)." >&2
    exit 1
fi
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
mkdir -m 700 "$temporary/runtime"
export XDG_RUNTIME_DIR="$temporary/runtime"
export GTK_A11Y=none

pc=$(find "$sdk" -name webkitgtk-6.0.pc -print -quit)
[[ -n "$pc" ]]
PKG_CONFIG_PATH="$(dirname "$pc")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PKG_CONFIG_PATH
libraries=$(pkg-config --variable=libdir webkitgtk-6.0)
export LD_LIBRARY_PATH="$libraries${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export WEBKIT_EXPECTED_LIBRARY_DIR="$libraries/"
export WEBKIT_RUNTIME_ROOT="$sdk"
export WEBKIT_EXEC_PATH="$sdk/libexec/webkitgtk-6.0"
export WEBKIT_INJECTED_BUNDLE_PATH="$sdk/lib/webkitgtk-6.0/injected-bundle"
export WEBKIT_SMOKE_BINARY="$temporary/browser-smoke"
export CURL_IMPERSONATE_BINARY="$curl_sdk/bin/curl-impersonate"
export LIBGL_ALWAYS_SOFTWARE=1

# pkg-config emits compiler arguments, intentionally split into an array.
read -r -a flags <<< "$(pkg-config --cflags --libs webkitgtk-6.0)"
cc "$tests/browser-smoke.c" -o "$WEBKIT_SMOKE_BINARY" "${flags[@]}" -ldl
dbus-run-session -- xvfb-run -a python3 -m pytest "$tests/test_network.py" \
    -o "cache_dir=$temporary/pytest-cache" -v "${@:3}"
