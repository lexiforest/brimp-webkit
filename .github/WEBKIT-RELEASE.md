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

`SHA256SUMS` covers all six archives. Publication waits for all builds and smoke
tests to pass. The full WebKit build currently targets macOS arm64, matching the
implemented Brimp browser host. Linux and Windows builds are JSC only.

The WebKit SDK includes frameworks, public/private headers, resources, runtime
libraries, browser XPC subprocesses, license files and a hashed file manifest.
Keep its `lib/` layout intact. Its README explains compilation and per-process
framework selection. This is an SDK with development signatures, not a
notarized application or an installable Brimp Python/Node package. Packaging the
Brimp host and bindings remains a downstream release step.

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
