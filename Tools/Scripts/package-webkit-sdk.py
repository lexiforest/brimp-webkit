#!/usr/bin/env python3
"""Package the macOS WebKit frameworks, subprocesses, resources and headers."""

import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

FRAMEWORKS = (
    "JavaScriptCore",
    "WebCore",
    "WebKit",
    "WebKitLegacy",
    "WebInspectorUI",
    "WebGPU",
    "_WebKit_SwiftUI",
)
REQUIRED_FRAMEWORKS = FRAMEWORKS[:5]
REQUIRED_SERVICES = (
    "com.apple.WebKit.WebContent.xpc",
    "com.apple.WebKit.Networking.xpc",
    "com.apple.WebKit.GPU.xpc",
)
LIBRARIES = ("libANGLE-shared.dylib", "libwebrtc.dylib", "libWebKitSwift.dylib")


def validate_links(directory):
    root = directory.resolve()
    for path in directory.rglob("*"):
        if not path.is_symlink():
            continue
        link = path.readlink()
        if link.is_absolute() or not path.resolve().is_relative_to(root):
            raise RuntimeError(f"Nonportable SDK symlink: {path} -> {link}")
        if not path.exists():
            raise RuntimeError(f"Dangling SDK symlink: {path} -> {link}")


def copy_products(build, destination):
    for name in REQUIRED_FRAMEWORKS:
        binary = build / f"{name}.framework" / name
        if not binary.is_file():
            raise RuntimeError(f"Missing framework binary: {binary}")
    for name in REQUIRED_SERVICES:
        bundle = build / name
        if not (bundle / "Contents/Info.plist").is_file():
            raise RuntimeError(f"Missing browser subprocess: {bundle}")
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        if not (bundle / "Contents/MacOS" / info["CFBundleExecutable"]).is_file():
            raise RuntimeError(f"Missing browser subprocess executable: {bundle}")
    destination.mkdir(parents=True)
    products = [build / f"{name}.framework" for name in FRAMEWORKS]
    products += list(build.glob("com.apple.WebKit.*.xpc"))
    products += [build / name for name in LIBRARIES]
    products += list(build.glob("*.metallib")) + list(build.glob("*.js"))
    for source in products:
        if source.is_dir():
            shutil.copytree(source, destination / source.name, symlinks=True)
        elif source.is_file():
            shutil.copy2(source, destination / source.name)
    # Xcode may leave the standard Frameworks link pointing to an empty,
    # uncreated directory when a framework has no embedded frameworks.
    for name in FRAMEWORKS:
        framework = destination / f"{name}.framework"
        link = framework / "Frameworks"
        if link.is_symlink() and str(link.readlink()) == "Versions/Current/Frameworks":
            (framework / "Versions/Current/Frameworks").mkdir(exist_ok=True)
    # Framework links to XPC services and libraries must resolve inside this SDK.
    validate_links(destination)


def copy_licenses(root, output):
    source = root / "Source"
    if not (source / "JavaScriptCore/COPYING.LIB").is_file():
        raise RuntimeError("Missing JavaScriptCore license")
    for path in source.rglob("*"):
        if path.is_file() and path.name.upper().startswith(("LICENSE", "COPYING")):
            target = output / "share/licenses" / path.relative_to(root)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)


def file_records(root):
    records = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if relative == "manifest.json":
            continue
        if path.is_symlink():
            records[relative] = {"symlink": str(path.readlink())}
        elif path.is_file():
            with path.open("rb") as source:
                records[relative] = {
                    "sha256": hashlib.file_digest(source, "sha256").hexdigest()
                }
    return records


def verify_package(root):
    validate_links(root)
    manifest = json.loads((root / "manifest.json").read_text())
    if manifest["files"] != file_records(root):
        raise RuntimeError("SDK contents do not match the package manifest")
    return manifest


def package(root, build, output, tag, commit, minimum_macos):
    output.mkdir(parents=True, exist_ok=False)
    copy_products(build, output / "lib")
    copy_licenses(root, output)
    (output / "BUILD-INFO.txt").write_text(
        f"tag={tag}\ncommit={commit}\ntarget=macos-arm64\nminimum_macos={minimum_macos}\n"
    )
    (output / "README.md").write_text("""# WebKit macOS arm64 SDK

`lib/` contains the built WebKit frameworks, public/private headers, resources,
shared libraries and browser XPC services. Keep this directory layout intact.
The required macOS version is recorded in BUILD-INFO.txt and manifest.json.

Compile an embedding host using `-F <sdk>/lib -iframework <sdk>/lib` and link
WebKit and AppKit. Launch the host with both DYLD_FRAMEWORK_PATH and
DYLD_LIBRARY_PATH set to the absolute path of `<sdk>/lib`. Restrict these
settings to that child process. The host must verify the loaded framework path.

This is a development SDK with ad-hoc signatures, not a notarized application
or a pip/npm package. It does not include the Brimp language bindings or host.
Downstream distributors must package and sign their final application bundle.

The corresponding source is the tagged lexiforest/WebKit repository revision
in BUILD-INFO.txt. License texts are under share/licenses/.
""")
    manifest = {
        "format": 1,
        "tag": tag,
        "commit": commit,
        "target": "macos-arm64",
        "minimum_macos": minimum_macos,
        "files": file_records(output),
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    verify_package(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Full WebKit SDK packaging currently supports macOS arm64")
    build = args.build_dir.resolve()
    binary = build / "WebKit.framework/WebKit"
    architectures = subprocess.check_output(
        ["xcrun", "lipo", "-archs", str(binary)], text=True
    ).strip()
    if architectures != "arm64":
        parser.error(f"Expected arm64 WebKit, got {architectures}")
    load_commands = subprocess.check_output(
        ["xcrun", "vtool", "-show-build", str(binary)], text=True
    )
    minimum = next(
        line.split()[1]
        for line in load_commands.splitlines()
        if line.strip().startswith("minos ")
    )
    package(
        Path(__file__).resolve().parents[2],
        build,
        args.output_dir.resolve(),
        args.tag,
        args.commit,
        minimum,
    )
    print(args.output_dir)


if __name__ == "__main__":
    main()
