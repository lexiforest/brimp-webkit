#!/usr/bin/env python3

import argparse
import re
import subprocess
from pathlib import Path


GLIBC_VERSION = re.compile(r"\bGLIBC_(\d+)\.(\d+)\b")


def elf_files(paths):
    seen = set()
    for path in paths:
        candidates = path.rglob("*") if path.is_dir() else (path,)
        for candidate in candidates:
            if not candidate.is_file():
                continue
            resolved = candidate.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            if resolved.read_bytes()[:4] == b"\x7fELF":
                yield resolved


def required_glibc(path):
    output = subprocess.run(
        ["objdump", "--dynamic-syms", path],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    versions = {
        (int(major), int(minor))
        for major, minor in GLIBC_VERSION.findall(output)
    }
    return max(versions, default=(0, 0))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--maximum", required=True)
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    maximum = tuple(int(part) for part in args.maximum.split("."))
    if len(maximum) != 2:
        parser.error("--maximum must be MAJOR.MINOR")

    checked = 0
    for path in elf_files(args.paths):
        checked += 1
        required = required_glibc(path)
        print(f"{path}: GLIBC_{required[0]}.{required[1]}")
        if required > maximum:
            raise SystemExit(
                f"{path} requires GLIBC_{required[0]}.{required[1]}, "
                f"which exceeds GLIBC_{maximum[0]}.{maximum[1]}"
            )
    if not checked:
        raise SystemExit("no ELF files were found")


if __name__ == "__main__":
    main()
