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
