#!/usr/bin/env python3
"""Compile and run a browser consumer against an extracted WebKit SDK."""

import argparse
import importlib.util
import os
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path)
    args = parser.parse_args()
    sdk = args.sdk.resolve()
    spec = importlib.util.spec_from_file_location(
        "packaging", Path(__file__).with_name("package-webkit-sdk.py")
    )
    packaging = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packaging)
    packaging.verify_package(sdk)
    root = Path(__file__).resolve().parents[2]
    libraries = sdk / "lib"

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body = b"<title>WebKit SDK</title><script>window.result = 6 * 7</script>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    with tempfile.TemporaryDirectory(prefix="webkit-sdk-smoke-") as directory:
        binary = Path(directory) / "webkit-sdk-smoke"
        subprocess.run(
            [
                "xcrun",
                "clang++",
                "-std=c++20",
                "-fobjc-arc",
                "-Wno-deprecated-declarations",
                "-F",
                str(libraries),
                "-iframework",
                str(libraries),
                "-framework",
                "AppKit",
                "-framework",
                "WebKit",
                str(root / ".github/webkit-sdk-smoke/main.mm"),
                "-o",
                str(binary),
            ],
            check=True,
        )
        environment = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("DYLD_", "__XPC_DYLD_"))
        }
        environment["DYLD_FRAMEWORK_PATH"] = str(libraries)
        environment["DYLD_LIBRARY_PATH"] = str(libraries)
        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                subprocess.run(
                    [
                        str(binary),
                        str(libraries),
                        f"http://127.0.0.1:{server.server_port}/",
                    ],
                    env=environment,
                    check=True,
                    timeout=45,
                )
            finally:
                server.shutdown()
                worker.join()


if __name__ == "__main__":
    main()
