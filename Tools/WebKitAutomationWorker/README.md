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

## Fetch interception

The worker implements the standard Fetch domain through WebKit's Inspector
network agents, using an in-process automation transport. It requires the
matching WebKit frameworks from this fork, including intercepted-body buffering.
The controller forwards Fetch commands and events to the selected page session.

`Fetch.enable` accepts URL wildcard patterns, resource types, Request/Response
stages, and `handleAuthRequests`. Requests stay paused until continued, fulfilled,
or failed. `Fetch.disable` resumes outstanding interceptions. Re-enabling updates
patterns; new page-process targets are configured before their loads resume.

- `Fetch.continueRequest` supports URL, method, base64 upload, and header overrides,
  including per-request `interceptResponse`.
- `Fetch.fulfillRequest` accepts base64 bodies and textual or binary response
  headers. Omitting the body preserves it at the response stage and uses an empty
  body at the request stage.
- `Fetch.continueResponse` preserves the body while applying response overrides.
- `Fetch.failRequest` works at either stage. Request-stage reasons map to WebKit's
  error categories; response-stage failure cancels the load.
- `Fetch.continueWithAuth` handles HTTP Basic/Digest challenges with default
  handling, cancellation, or credentials.
- `Fetch.getResponseBody` returns the buffered response as base64.
- `Fetch.takeResponseBodyAsStream` returns a page-scoped handle for `IO.read` and
  `IO.close`. Reads are sequential; closing a stream cancels any pending read.
  After taking a stream, the request must be fulfilled with a body or failed.

Response bodies are buffered while delivery to the page remains paused, with a
32 MiB retrieval limit. Stream reads currently wait for the complete body; reads
return at most 1 MiB per chunk. Response header changes also wait for the original
body. Duplicate header names are not supported. Interception follows WebKit's
page network agents; service-worker-owned requests and intermediate redirect
responses/redirected request hops are not covered. Fetch IDs
are independent of native Network event IDs, so `requestPaused.networkId` is
omitted. Clients must keep handling events while a script or body read is pending.
Request priority is currently reported as `Medium`; resource types follow
WebKit's classification.

Run the native Fetch regressions from Brimp with the same worker environment as
above, using `crates/brimp/tests/test_webkit_fetch.py`.

The repository's `cdp.txt` retains only commands in the official CDP browser and
JavaScript schemas. Its third column describes this worker/controller's support;
`implemented` may cover only a documented subset of a command's parameters.

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
