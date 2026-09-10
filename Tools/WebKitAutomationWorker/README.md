# WebKitAutomationWorker

This target is the WebKit-side native host for external browser controllers.
It owns a Cocoa event loop, ephemeral `WKWebsiteDataStore` contexts, offscreen
or visible `WKWebView` pages, private WebKit automation APIs, and native page
events. It implements the worker-side CDP subset but not worker pooling, HTTP,
or WebSocket serving. Platform implementations live under MiniBrowser-style port
directories; the current implementation is in `mac/`, with `gtk/`, `wpe/`, and
`win/` reserved for future Linux and Windows targets.

The controller passes a connected local socket as
`--controller-socket-fd=N`. Messages use CDP request, response, and event JSON
envelopes prefixed by a four-byte network-byte-order length. The first request
must be `Browser.getVersion`; this worker currently reports CDP version 1.3.

Build the application with:

```sh
xcodebuild \
    -project Tools/WebKitAutomationWorker/WebKitAutomationWorker.xcodeproj \
    -scheme WebKitAutomationWorker -configuration Release \
    SYMROOT="$PWD/WebKitBuild" OBJROOT="$PWD/WebKitBuild" \
    CODE_SIGNING_ALLOWED=NO build
```

The resulting application is
`WebKitBuild/Release/WebKitAutomationWorker.app`. It is not intended to be
launched directly; a controller must supply the connected socket descriptor.

## Cookies, dialogs, and document scripts

The worker implements `Network.getCookies`, `getAllCookies`, `setCookie`,
`setCookies`, `deleteCookies`, and `clearBrowserCookies`, plus `Storage.getCookies`,
`setCookies`, `deleteCookies`, and `clearCookies`. Cookies belong to the worker's
single ephemeral context. Brimp routes browser-level Storage commands to the
selected context's worker, allocating it if needed before a page exists.

Cookie writes support `name`, `value`, `url`, `domain`, `path`, `secure`,
`httpOnly`, `sameSite`, and `expires`. Unsupported attributes, including partition
keys, are rejected. A batch is validated before any cookies are written.
`Network.getCookies` filters by `urls`, or by the current frame tree when omitted;
an empty URL array returns no cookies. Deletion requires a name and URL or domain,
with an optional path. Clearing affects only this context.

`Page.addScriptToEvaluateOnNewDocument` installs a page-world script at document
start in every frame, before document scripts. Registrations belong to the page,
persist across navigation/reload, and can be removed individually with
`Page.removeScriptToEvaluateOnNewDocument`. Named worlds, command-line API
injection, and immediate execution are unsupported and rejected when requested.

Enable Page events before triggering a JavaScript dialog. Alerts, confirms, and
prompts remain pending until `Page.handleJavaScriptDialog` supplies `accept` and
optional `promptText`. Closing a page dismisses its pending dialog. Brimp allows
script evaluation to remain pending while delivering dialog events and accepting
the answer; clients must also process events while awaiting evaluation results.

Run native regressions from the sibling Brimp checkout after building both:

```sh
BRIMP_TEST_WEBKIT_WORKER=/absolute/path/to/WebKitBuild/Release/WebKitAutomationWorker.app \
  uv run --with pytest python -m pytest crates/brimp/tests/test_webkit_automation.py -q
```

## Proxies

On macOS 14 and later, `Target.createBrowserContext` accepts `proxyServer`:

```json
{"id":2,"method":"Target.createBrowserContext","params":{"proxyServer":"http://127.0.0.1:8080"}}
```

Supported URLs are `http://host:port` (HTTP CONNECT) and `socks5://host:port`,
including optional percent-encoded username/password credentials. An explicit
port is required. The proxy applies to all pages using the context's data store;
proxy failure does not enable direct-connection fallback. Bypass lists and
other proxy schemes are unsupported.

Change the proxy after startup with the worker extension `Brimp.setProxy`:

```json
{"id":3,"method":"Brimp.setProxy","params":{"browserContextId":"CONTEXT_ID","proxyServer":"socks5://127.0.0.1:1080"}}
{"id":4,"method":"Brimp.setProxy","params":{"browserContextId":"CONTEXT_ID","proxyServer":""}}
```

An empty string clears the context's proxy override. Invalid settings leave the
previous configuration intact. Set the proxy before loading pages where possible:
WebKit may interrupt ongoing network operations when it changes. Disposing the
context discards its proxy configuration. `Browser.getVersion` advertises
`brimpProxy: true` for controllers that support these settings.

Brimp forwards `fetch --proxy URL` to context creation for this worker and
supports the same context and update commands through its public CDP server.
Context creation in Brimp is lazy: native proxy validation happens when the
context first acquires a worker.
