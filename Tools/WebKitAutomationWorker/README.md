# WebKitAutomationWorker

This target is the WebKit-side native host for external browser controllers.
It owns a Cocoa event loop, ephemeral `WKWebsiteDataStore` contexts, offscreen
or visible `WKWebView` pages, private WebKit automation APIs, and native page
events. It deliberately does not implement CDP, worker pooling, or network
listening. Platform implementations live under MiniBrowser-style port
directories; the current implementation is in `mac/`, with `gtk/`, `wpe/`, and
`win/` reserved for future Linux and Windows targets.

The controller passes a connected local socket as
`--controller-socket-fd=N`. Messages are UTF-8 JSON prefixed by a four-byte
network-byte-order length. The first request must be `ping`; this worker
currently reports protocol version 1.

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
