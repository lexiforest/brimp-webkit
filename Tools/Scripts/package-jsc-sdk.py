#!/usr/bin/env python3

import argparse
import shutil
from pathlib import Path


PUBLIC_HEADERS = (
    "JSBase.h",
    "JSContextRef.h",
    "JSObjectRef.h",
    "JSStringRef.h",
    "JSTypedArray.h",
    "JSValueRef.h",
    "JavaScript.h",
    "WebKitAvailability.h",
)

WINDOWS_RUNTIME_PATTERNS = (
    "icudt*.dll",
    "icuin*.dll",
    "icuuc*.dll",
)

WINDOWS_SYMBOLS = (
    "JavaScriptCore.pdb",
    "jsc.pdb",
)

LINUX_RUNTIME_PATTERNS = (
    "libicudata.so*",
    "libicui18n.so*",
    "libicuuc.so*",
)


def copy_tree(source, destination):
    if not source.is_dir():
        raise RuntimeError(f"Missing build output directory: {source}")
    shutil.copytree(source, destination, symlinks=True)


def copy_file(source, destination):
    if not source.is_file():
        raise RuntimeError(f"Missing build output file: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def copy_outputs(build_dir, output_dir, platform):
    if platform == "windows":
        copy_file(
            build_dir / "bin" / "jsc.exe",
            output_dir / "bin" / "jsc.exe",
        )
        copy_file(
            build_dir / "bin" / "JavaScriptCore.dll",
            output_dir / "bin" / "JavaScriptCore.dll",
        )
        copy_file(
            build_dir / "lib" / "JavaScriptCore.lib",
            output_dir / "lib" / "JavaScriptCore.lib",
        )
        return

    if platform != "macos":
        copy_tree(build_dir / "bin", output_dir / "bin")
        copy_tree(build_dir / "lib", output_dir / "lib")
        return

    if (build_dir / "bin").is_dir():
        copy_tree(build_dir / "bin", output_dir / "bin")
    else:
        shell = build_dir / "jsc"
        if not shell.is_file():
            raise RuntimeError(f"Missing JavaScriptCore shell: {shell}")
        (output_dir / "bin").mkdir(parents=True)
        shutil.copy2(shell, output_dir / "bin" / "jsc")

    if (build_dir / "lib").is_dir():
        copy_tree(build_dir / "lib", output_dir / "lib")
    else:
        framework = build_dir / "JavaScriptCore.framework"
        (output_dir / "lib").mkdir(parents=True)
        copy_tree(
            framework,
            output_dir / "lib" / "JavaScriptCore.framework",
        )


def copy_headers(build_dir, output_dir, platform):
    if platform == "macos":
        source = build_dir / "JavaScriptCore.framework" / "Headers"
    else:
        source = build_dir / "JavaScriptCore" / "Headers" / "JavaScriptCore"

    destination = output_dir / "include" / "JavaScriptCore"
    destination.mkdir(parents=True)
    for name in PUBLIC_HEADERS:
        header = source / name
        if not header.is_file():
            raise RuntimeError(f"Missing public header: {header}")
        shutil.copy2(header, destination / name, follow_symlinks=True)


def copy_vcpkg_licenses(build_dir, output_dir):
    installed = build_dir / "vcpkg_installed"
    if not installed.is_dir():
        return

    for copyright_file in installed.glob("*/share/*/copyright"):
        package = copyright_file.parent.name
        destination = output_dir / "share" / "licenses" / package
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copy2(copyright_file, destination / "copyright")


def copy_vcpkg_runtime(build_dir, output_dir, platform):
    if platform != "windows":
        return

    installed = build_dir / "vcpkg_installed"
    for pattern in WINDOWS_RUNTIME_PATTERNS:
        for runtime in installed.glob(f"*/bin/{pattern}"):
            shutil.copy2(runtime, output_dir / "bin" / runtime.name)


def copy_linux_runtime(runtime_lib_dir, output_dir):
    if not runtime_lib_dir or not runtime_lib_dir.is_dir():
        raise RuntimeError(
            "Linux packages require --runtime-lib-dir with the ICU libraries"
        )

    destination = output_dir / "lib"
    destination.mkdir(parents=True, exist_ok=True)
    for pattern in LINUX_RUNTIME_PATTERNS:
        libraries = list(runtime_lib_dir.glob(pattern))
        if not libraries:
            raise RuntimeError(
                f"Missing Linux runtime library {pattern} in {runtime_lib_dir}"
            )
        for library in libraries:
            target = destination / library.name
            if library.is_symlink():
                target.symlink_to(library.readlink())
            else:
                shutil.copy2(library, target)

    license_file = runtime_lib_dir.parent / "share" / "licenses" / "icu" / "LICENSE"
    copy_file(
        license_file,
        output_dir / "share" / "licenses" / "icu" / "LICENSE",
    )


def copy_windows_symbols(build_dir, output_dir):
    copied = False
    for directory in ("bin", "lib"):
        for name in WINDOWS_SYMBOLS:
            source = build_dir / directory / name
            if source.is_file():
                copy_file(source, output_dir / directory / name)
                copied = True

    if not copied:
        raise RuntimeError("No Windows PDB files were found")


def cmake_config(platform):
    properties = {
        "linux": (
            'IMPORTED_LOCATION "${_JSC_PREFIX}/lib/libJavaScriptCore.so"\n'
            '    INTERFACE_INCLUDE_DIRECTORIES "${_JSC_PREFIX}/include"\n'
            '    INTERFACE_LINK_OPTIONS "-Wl,-rpath,${_JSC_PREFIX}/lib"'
        ),
        "macos": (
            "IMPORTED_LOCATION\n"
            '        "${_JSC_PREFIX}/lib/'
            'JavaScriptCore.framework/JavaScriptCore"\n'
            '    INTERFACE_INCLUDE_DIRECTORIES "${_JSC_PREFIX}/include"\n'
            '    INTERFACE_LINK_OPTIONS "-Wl,-rpath,${_JSC_PREFIX}/lib"'
        ),
        "windows": (
            'IMPORTED_IMPLIB "${_JSC_PREFIX}/lib/JavaScriptCore.lib"\n'
            '    IMPORTED_LOCATION "${_JSC_PREFIX}/bin/'
            'JavaScriptCore.dll"\n'
            '    INTERFACE_INCLUDE_DIRECTORIES "${_JSC_PREFIX}/include"'
        ),
    }[platform]

    return f"""# Generated by package-jsc-sdk.py.
get_filename_component(
    _JSC_PREFIX "${{CMAKE_CURRENT_LIST_DIR}}/../../.." ABSOLUTE)

if(NOT TARGET JavaScriptCore::JavaScriptCore)
    add_library(JavaScriptCore::JavaScriptCore SHARED IMPORTED)
    set_target_properties(JavaScriptCore::JavaScriptCore PROPERTIES
        {properties})
endif()

unset(_JSC_PREFIX)
"""


def readme(platform, glibc_baseline=None):
    runtime = {
        "linux": (
            "The CMake target adds an RPATH for the packaged libraries. "
            f"This SDK requires glibc {glibc_baseline} or newer and bundles "
            "its ICU runtime."
        ),
        "macos": "The CMake target adds an RPATH for the packaged framework.",
        "windows": "Copy the DLLs from `<sdk>/bin` beside your executable.",
    }[platform]

    return f"""# JavaScriptCore SDK

This package contains the JavaScriptCore public C API, the `jsc` shell, and
the dynamic libraries needed to link an application.

Use the SDK from CMake:

```cmake
find_package(JavaScriptCore CONFIG REQUIRED)
target_link_libraries(my_app PRIVATE JavaScriptCore::JavaScriptCore)
```

Configure the downstream project with the extracted SDK as a prefix:

```text
-DCMAKE_PREFIX_PATH=<sdk>
```

Runtime setup: {runtime}

The supported public entry point is:

```c
#include <JavaScriptCore/JavaScript.h>
```
"""


def symbols_readme():
    return """# JavaScriptCore Windows symbols

This package contains the PDB files for `JavaScriptCore.dll` and `jsc.exe`.
It matches the Windows SDK with the same tag and target name.
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--platform", required=True, choices=("linux", "macos", "windows")
    )
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--symbols-output-dir", type=Path)
    parser.add_argument("--runtime-lib-dir", type=Path)
    parser.add_argument("--glibc-baseline")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    build_dir = args.build_dir.resolve()
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True)

    copy_outputs(build_dir, output_dir, args.platform)
    copy_headers(build_dir, output_dir, args.platform)
    copy_vcpkg_runtime(build_dir, output_dir, args.platform)
    copy_vcpkg_licenses(build_dir, output_dir)
    if args.platform == "linux":
        copy_linux_runtime(args.runtime_lib_dir, output_dir)
        if not args.glibc_baseline:
            raise RuntimeError("Linux packages require --glibc-baseline")
    elif args.runtime_lib_dir or args.glibc_baseline:
        raise RuntimeError(
            "--runtime-lib-dir and --glibc-baseline are only supported on Linux"
        )

    license_dir = output_dir / "share" / "licenses" / "JavaScriptCore"
    license_dir.mkdir(parents=True)
    shutil.copy2(
        root / "Source" / "JavaScriptCore" / "COPYING.LIB",
        license_dir / "COPYING.LIB",
    )

    config_dir = output_dir / "lib" / "cmake" / "JavaScriptCore"
    config_dir.mkdir(parents=True)
    (config_dir / "JavaScriptCoreConfig.cmake").write_text(
        cmake_config(args.platform), encoding="utf-8"
    )

    build_info = (
        f"tag={args.tag}\n"
        f"commit={args.commit}\n"
        f"target={args.target}\n"
    )
    if args.glibc_baseline:
        build_info += f"glibc={args.glibc_baseline}\n"
    (output_dir / "BUILD-INFO.txt").write_text(build_info, encoding="utf-8")
    (output_dir / "README.md").write_text(
        readme(args.platform, args.glibc_baseline), encoding="utf-8"
    )

    if args.symbols_output_dir:
        if args.platform != "windows":
            raise RuntimeError("Separate symbols are only supported on Windows")
        symbols_dir = args.symbols_output_dir.resolve()
        symbols_dir.mkdir(parents=True)
        copy_windows_symbols(build_dir, symbols_dir)
        (symbols_dir / "BUILD-INFO.txt").write_text(
            build_info, encoding="utf-8"
        )
        (symbols_dir / "README.md").write_text(
            symbols_readme(), encoding="utf-8"
        )
        symbols_license = (
            symbols_dir / "share" / "licenses" / "JavaScriptCore"
        )
        symbols_license.mkdir(parents=True)
        shutil.copy2(
            root / "Source" / "JavaScriptCore" / "COPYING.LIB",
            symbols_license / "COPYING.LIB",
        )


if __name__ == "__main__":
    main()
