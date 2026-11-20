# Linux WebKit networking development

This directory contains the Linux build recipe and browser tests for the
WebKitGTK curl-impersonate port in this WebKit repository. The first
Linux transport implementation builds and passes all 15 browser tests on
Ubuntu 26.04 x64, running as an unprivileged user with sandboxing enabled.

The development machine uses Ubuntu 26.04 x64. Install the distribution's
`webkit2gtk` source build dependencies (enable matching `deb-src` repositories
first), then the tools used by this recipe:

```sh
sudo apt-get build-dep webkit2gtk
sudo apt-get install clang-21 lld-21 ccache cmake ninja-build unifdef nasm \
    xvfb xauth dbus-x11 python3-pytest python3-websockets python3-h2 curl pkg-config
bash Tools/Scripts/linux-webkit/build.sh /path/to/WebKit /path/to/build-workspace
```

The recipe pins curl-impersonate v2.3.2 at
`5b1c3542fc7fc0e9fe623a6c9a848d16f92fe99a`. It builds matching BoringSSL headers
and static libraries, then links those into WebKit with private symbols. It
does not substitute the system OpenSSL library at the SSL callback boundary.
The initial transport profile is `safari270`; WebKit retains ownership of HTTP
headers, cookies and redirects. GTK still exposes libsoup cookie/header data
types, and WebDriver uses Soup for its local command server. Browser HTTP
transport uses curl. WebCrypto retains GTK's GCrypt implementation.

The initial build disables media, speech, gamepads, documentation and
introspection to focus on browser networking. It preserves the normal browser
process architecture. `BRIMP_BUILD_JOBS` controls parallel compilation.

The port starts from the Brimp WebKit fork at `902c0df41fef`, based on
`safari-7625.2.8-branch`. Linux build fixes cover the built-in JavaScript
preprocessor, disabled-video bindings, scrolling-layer ownership, native
WebGPU guards and the WebSocket virtual interface. A separate Soup baseline
with those fixes builds and passes 11 browser checks on the development machine.

`browser-smoke.c` is an embedding consumer that loads a page and awaits an
asynchronous JavaScript function. `test_network.py` checks real browser
navigation, WebCrypto, binary responses and request bodies, redirects, cookie
isolation and SQLite persistence, HTTP/proxy authentication, cancellation,
WebSockets, TLS trust and certificate exceptions. It compares the TLS
ClientHello's stable fields and HTTP/2 settings/window against curl-impersonate.
It does not assert that every browser-visible property matches Safari.

Run as a normal user after installing the SDK:

```sh
python3 -m venv /tmp/webkit-tests
. /tmp/webkit-tests/bin/activate
python -m pip install 'pytest>=8,<10' 'websockets>=12,<17' 'h2>=4,<5'
bash Tools/Scripts/linux-webkit/test.sh /path/to/build-workspace/sdk/webkit-curl \
    /path/to/build-workspace/sdk/curl-impersonate-2.3.2
```

The test runner compiles the embedding consumer, verifies the loaded WebKit
library's location and starts pytest under D-Bus and Xvfb. Additional arguments
are passed to pytest. The browser sandbox is not disabled by the runner.

The validated SDK is installed at `/opt/brimp/sdk/webkit-curl` on the development
machine, with build and test logs under `/opt/brimp/logs`. The final browser run
passed all 15 tests in 15.20 seconds. Its TLS ClientHello and HTTP/2 settings
match the pinned curl-impersonate CLI's `safari270` profile. The installed WebKit
library has no dynamic dependency on libcurl, libssl or libcrypto, and does not
export the checked curl/BoringSSL entry points. The SDK requires Ubuntu system dependencies. Release builds now use Ubuntu 24.04
and Clang 18 so downstream packages can target manylinux 2.39. Runtime layout
version 1 supports relocation: set WEBKIT_EXEC_PATH and WEBKIT_INJECTED_BUNDLE_PATH
to the relocated subprocess/bundle directories and add the runtime root read-only
to the WebKit context sandbox. The release workflow hides the original SDK/build
products and runs all 15 tests from a different extracted location. The historical
Ubuntu 26.04 measurements above describe the earlier development build.

The Linux transport reads `WEBKIT_CURL_CA_BUNDLE` at startup when a custom
trust store is needed. TLS verification remains enabled by default.

Current API limits: the curl cookie store uses SQLite, so GTK's legacy text
cookie storage is rejected. Persistent OS credential storage and client
certificate authentication are not implemented. The existing curl backend also
has incomplete Cookie Store API, cookie change observation and deletion by
modification time. Its cookie privacy/SameSite behavior still needs a separate
parity audit. These limitations must not be represented as supported features
in downstream bindings. The SDK also exposes fork-local GTK APIs for Brimp: a
local Automation/Inspector channel, binary navigation requests, asynchronous
page closure and empty cookie-store replacement. The host and Python/Node
contracts live in the adjacent Brimp repository under `tools/webkit/` and
`bindings/*/tests` (Node uses `bindings/node/test`). Build the host with
`python3 tools/webkit/build.py --sdk /opt/brimp/sdk/webkit-curl` from that checkout.
The tagged workflow packages the engine SDK; pip/npm engine bundles remain
separate release work.
