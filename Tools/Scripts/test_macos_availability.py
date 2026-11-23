"""Compile availability-sensitive shims without building the browser first."""

import subprocess
import sys
from pathlib import Path

import pytest


@pytest.mark.skipif(sys.platform != "darwin", reason="requires the macOS SDK")
@pytest.mark.parametrize("minimum", ["26.0", "26.2"])
def test_credential_updater_compiles_for_supported_macos(tmp_path, minimum):
    root = Path(__file__).resolve().parents[2]
    shim = root / "Source/WebKit/WebKitSwift/CredentialUpdaterShim"
    # The header includes Platform.h but uses no definitions from it. Avoid
    # requiring generated WebKit configuration for this standalone compiler test.
    include = tmp_path / "include"
    (include / "wtf").mkdir(parents=True)
    (include / "wtf/Platform.h").write_text("// No platform macros needed here.\n")
    result = subprocess.run(
        [
            "xcrun",
            "swiftc",
            "-typecheck",
            "-module-cache-path",
            str(tmp_path / "module-cache"),
            "-target",
            f"arm64-apple-macosx{minimum}",
            "-D",
            "HAVE_CREDENTIAL_UPDATE_API",
            "-Xcc",
            f"-I{include}",
            "-import-objc-header",
            str(shim.with_suffix(".h")),
            str(shim.with_suffix(".swift")),
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=180,
    )
    assert result.returncode == 0, result.stdout + result.stderr
