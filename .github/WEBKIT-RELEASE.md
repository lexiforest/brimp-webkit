# WebKit binary releases

The `webkit-release.yml` workflow builds JavaScriptCore and full WebKit when a
`webkit-v-*` tag is pushed to this repository. Commit the workflow and its
supporting scripts before creating a release tag. The old `jsc-v*` trigger has
been removed.

For example, after committing and pushing the release changes:

```sh
git tag webkit-v-27.2.1
git push origin webkit-v-27.2.1
```

The workflow also accepts an existing tag through **Run workflow**. Both entry
points resolve the tag once and check out that exact commit for every build.
BUILD-INFO metadata records the tagged commit, including manual runs. Use a new
tag for each release; publication intentionally fails if the release exists.

## Assets

For tag `webkit-v-27.2.1`, the GitHub release contains:

| Archive | Target |
| --- | --- |
| `JavaScriptCore-webkit-v-27.2.1-linux-x64.tar.gz` | Linux x64, glibc 2.28 baseline |
| `JavaScriptCore-webkit-v-27.2.1-linux-arm64.tar.gz` | Linux arm64, glibc 2.28 baseline |
| `JavaScriptCore-webkit-v-27.2.1-windows-x64.tar.gz` | Windows x64 |
| `JavaScriptCore-webkit-v-27.2.1-windows-x64-symbols.tar.gz` | Windows debugging symbols |
| `JavaScriptCore-webkit-v-27.2.1-macos-arm64.tar.gz` | macOS arm64 JSC SDK |
| `WebKit-webkit-v-27.2.1-macos-arm64.tar.gz` | Full WebKit SDK, macOS 27.0+ arm64 |
| `WebKit-webkit-v-27.2.1-linux-x64-ubuntu-26.04.tar.gz` | WebKitGTK SDK, Ubuntu 26.04 x64, curl-impersonate |

`SHA256SUMS` covers all seven archives. Publication waits for every build and
smoke test, including the Linux network suite. Full WebKit targets macOS arm64
and Linux x64; Windows remains JSC only.

The macOS WebKit SDK includes frameworks, public/private headers, resources, runtime
libraries, browser XPC subprocesses, license files and a hashed file manifest.
Keep its `lib/` layout intact. Its README explains compilation and per-process
framework selection. This is an SDK with development signatures, not a
notarized application or an installable Brimp Python/Node package. Packaging the
Brimp host and bindings remains a downstream release step.

## Linux WebKitGTK SDK

The Linux job uses GitHub's `ubuntu-26.04` x64 runner, four compiler jobs and a
six-hour timeout. It builds pinned curl-impersonate v2.3.2 with BoringSSL, then
WebKitGTK with the `safari270` transport profile. All scripts and tests live in
`Tools/Scripts/linux-webkit/` in the tagged checkout; no Brimp checkout or SSH
credentials are needed. Logs are uploaded on success or failure.

This SDK has a fixed installation prefix, `/opt/brimp/sdk/webkit-curl`. Extract
the archive and install its contents at that path. System libraries are not
bundled: the archive README lists Ubuntu dependency packages and the environment
settings for compiling and launching a consumer. It is not a manylinux artifact
and is not a Brimp host or pip/npm engine bundle. Media, speech and gamepads are
disabled; the networking README lists remaining API limitations.

The archive includes headers, libraries, subprocesses, licenses for WebKit and
its statically linked curl dependencies, revision metadata and a hashed manifest.
CI hides the original install and build products, extracts the archive back to
its installation prefix and runs all 15 browser tests as the unprivileged runner
user with sandboxing enabled. These exercise HTTP/HTTPS, proxies/authentication,
cookies, cancellation and WebSockets, and compare TLS/HTTP2 fingerprints against
the pinned curl CLI. This validates archive completeness at the required prefix,
not arbitrary relocation or compatibility with older Ubuntu versions.

## Build and verification

The macOS jobs select Xcode 27.2 on GitHub's `xcode-27` arm64 image. Full WebKit
uses a sparse checkout, two compiler jobs, no debug symbols and the
`Everything up to WebKit` scheme. The job allows six hours and uploads its build
log on failure. Runner time, memory and disk capacity must be confirmed by the
first complete GitHub run.

JSC builds execute the shell and compile a C API consumer against each SDK.
The WebKit job extracts its archive, hides the original build products, then
compiles and runs a consumer against the extracted SDK. That consumer verifies
the loaded framework path, local Automation, HTTP navigation and JavaScript
execution. Package validation rejects broken or escaping symlinks, missing
browser processes and manifest mismatches.

Local checks:

```sh
actionlint .github/workflows/webkit-release.yml
python3 -m pytest Tools/Scripts/test_package_webkit_sdk.py -q
python3 Tools/Scripts/test-webkit-sdk.py /path/to/extracted/WebKit-sdk
```

Packaging scripts require Python 3.11+. The workflow installs it explicitly.
The browser consumer requires macOS, Xcode and a compatible built SDK. A local
packaging smoke test using older engine binaries does not validate a fresh
Safari 27.2 build; that still requires the complete build and runtime checks.
