"""Exercise a real WebKitGTK browser against local network fixtures.

Run under dbus-run-session and xvfb-run. Set WEBKIT_SMOKE_BINARY to the
browser-smoke consumer compiled against the build being verified.
"""

import hashlib
import json
import os
import socket
import ssl
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import BaseRequestHandler, ThreadingTCPServer
from urllib.parse import urlsplit

import pytest

pytestmark = pytest.mark.skipif(
    not os.environ.get("WEBKIT_SMOKE_BINARY"),
    reason="Run tools/webkit/linux/test.sh with the installed WebKit SDK",
)


@pytest.fixture
def server():
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlsplit(self.path).path
            if self.path.startswith("http://webkit-auth-proxy.invalid"):
                if self.headers.get("Proxy-Authorization") != "Basic dXNlcjpwYXNz":
                    self.send_response(407)
                    self.send_header("Proxy-Authenticate", 'Basic realm="proxy-test"')
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                assert "Authorization" not in self.headers
            if (
                path == "/auth"
                and self.headers.get("Authorization") != "Basic dXNlcjpwYXNz"
            ):
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="origin-test"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if path == "/slow":
                time.sleep(2)
            if path == "/redirect":
                self.send_response(302)
                self.send_header("Location", "/echo")
                self.end_headers()
                return
            if path == "/cookie":
                self.send_response(200)
                self.send_header("Set-Cookie", "server_cookie=one; Path=/; HttpOnly")
                self.end_headers()
                return
            if path == "/echo":
                body = json.dumps(dict(self.headers)).encode()
                content_type = "application/json"
            elif path == "/bytes":
                body = bytes([0, 128, 255, 65])
                content_type = "application/octet-stream"
            else:
                body = b"<title>Linux WebKit</title><script>window.answer = 42</script>"
                content_type = "text/html"
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except BrokenPipeError:
                pass  # Expected when the browser cancels /slow.

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as instance:
        thread = threading.Thread(target=instance.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{instance.server_port}"
        finally:
            instance.shutdown()
            thread.join()


@pytest.fixture
def browser(tmp_path):
    binary = Path(os.environ["WEBKIT_SMOKE_BINARY"]).resolve(strict=True)

    def run(url, script, *, expected_failure=None, **environment):
        source = tmp_path / "script.js"
        source.write_text(script)
        completed = subprocess.run(
            [str(binary), url, str(source)],
            env={**os.environ, **environment},
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        if expected_failure:
            assert completed.returncode != 0
            assert expected_failure in completed.stderr, completed.stderr
            return None
        assert completed.returncode == 0, completed.stdout + completed.stderr
        result = next(
            line.removeprefix("RESULT ")
            for line in completed.stdout.splitlines()
            if line.startswith("RESULT ")
        )
        return json.loads(result)

    return run


def test_navigation_javascript_and_binary_fetch(browser, server):
    result = browser(
        server,
        """
        const bytes = new Uint8Array(await (await fetch('/bytes')).arrayBuffer());
        const post = await fetch('/echo', {method: 'POST', body: bytes});
        const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
        return {title: document.title, answer: window.answer,
            bytes: [...bytes], post: [...new Uint8Array(await post.arrayBuffer())],
            digest: [...digest]};
    """,
    )
    assert result == {
        "title": "Linux WebKit",
        "answer": 42,
        "bytes": [0, 128, 255, 65],
        "post": [0, 128, 255, 65],
        "digest": list(hashlib.sha256(bytes([0, 128, 255, 65])).digest()),
    }


def test_redirects_and_cookie_ownership(browser, server):
    result = browser(
        server,
        """
        await fetch('/cookie');
        document.cookie = 'script_cookie=two; Path=/';
        const response = await fetch('/redirect', {headers: {'X-Brimp': 'browser-owned'}});
        return {redirected: response.redirected, url: response.url,
            headers: await response.json(), visible: document.cookie, userAgent: navigator.userAgent};
    """,
    )
    assert result["redirected"]
    assert result["url"] == server + "/echo"
    headers = {name.lower(): value for name, value in result["headers"].items()}
    assert "server_cookie=one" in headers["cookie"]
    assert "script_cookie=two" in headers["cookie"]
    assert headers["user-agent"] == result["userAgent"]
    assert headers["x-brimp"] == "browser-owned"
    assert "server_cookie" not in result["visible"]
    assert "script_cookie=two" in result["visible"]


def test_ephemeral_sessions_do_not_share_cookies(browser, server):
    browser(server, "await fetch('/cookie'); return true;")
    headers = browser(server, "return await (await fetch('/echo')).json();")
    assert "cookie" not in {name.lower() for name in headers}


def test_sqlite_cookie_persistence_is_scoped_to_its_store(browser, server, tmp_path):
    storage = str(tmp_path / "profile-one")
    assert (
        browser(
            server,
            "document.cookie = 'saved=one; Path=/; Max-Age=3600'; return document.cookie;",
            BRIMP_TEST_STORAGE_DIR=storage,
        )
        == "saved=one"
    )
    assert (
        browser(server, "return document.cookie;", BRIMP_TEST_STORAGE_DIR=storage)
        == "saved=one"
    )
    assert (
        browser(
            server,
            "return document.cookie;",
            BRIMP_TEST_STORAGE_DIR=str(tmp_path / "profile-two"),
        )
        == ""
    )


def test_session_proxy_is_used(browser, server):
    # The fixture serves the proxy's absolute request URI. This hostname cannot
    # resolve directly, so success proves the per-session proxy was selected.
    assert (
        browser(
            "http://webkit-proxy-test.invalid/",
            "return document.title;",
            BRIMP_TEST_PROXY=server,
        )
        == "Linux WebKit"
    )


def test_http_basic_authentication(browser, server):
    assert (
        browser(
            server + "/auth",
            "return document.title;",
            BRIMP_TEST_AUTH_USER="user",
            BRIMP_TEST_AUTH_PASSWORD="pass",
            BRIMP_TEST_AUTH_HOST="127.0.0.1",
        )
        == "Linux WebKit"
    )


def test_proxy_authentication_uses_proxy_credentials(browser, server):
    assert (
        browser(
            "http://webkit-auth-proxy.invalid/",
            "return document.title;",
            BRIMP_TEST_PROXY=server,
            BRIMP_TEST_AUTH_USER="user",
            BRIMP_TEST_AUTH_PASSWORD="pass",
            BRIMP_TEST_AUTH_HOST="127.0.0.1",
        )
        == "Linux WebKit"
    )


def test_fetch_cancellation_does_not_break_later_requests(browser, server):
    result = browser(
        server,
        """
        const controller = new AbortController();
        setTimeout(() => controller.abort(), 50);
        let error;
        try { await fetch('/slow', {signal: controller.signal}); }
        catch (e) { error = e.name; }
        const response = await fetch('/bytes');
        return {error, bytes: [...new Uint8Array(await response.arrayBuffer())]};
    """,
    )
    assert result == {"error": "AbortError", "bytes": [0, 128, 255, 65]}


def test_websocket_round_trip(browser, server):
    from websockets.sync.server import serve

    def echo(connection):
        connection.send(connection.recv())

    with serve(echo, "127.0.0.1", 0) as websocket:
        worker = threading.Thread(target=websocket.serve_forever, daemon=True)
        worker.start()
        try:
            port = websocket.socket.getsockname()[1]
            assert (
                browser(
                    server,
                    f"""
                return await new Promise((resolve, reject) => {{
                    const socket = new WebSocket('ws://127.0.0.1:{port}');
                    socket.onopen = () => socket.send('WebKit curl websocket');
                    socket.onmessage = event => {{ socket.close(); resolve(event.data); }};
                    socket.onerror = () => reject(new Error('WebSocket failed'));
                }});
            """,
                )
                == "WebKit curl websocket"
            )
        finally:
            websocket.shutdown()
            worker.join()


@pytest.fixture
def tls_certificate(tmp_path):
    certificate = tmp_path / "certificate.pem"
    key = tmp_path / "key.pem"
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            str(key),
            "-out",
            str(certificate),
            "-days",
            "1",
            "-subj",
            "/CN=localhost",
            "-addext",
            "subjectAltName=IP:127.0.0.1",
        ],
        check=True,
        capture_output=True,
    )
    return certificate, key


@pytest.fixture
def https_server(tls_certificate):
    certificate, key = tls_certificate

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body = b"<title>Trusted HTTPS</title>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"https://127.0.0.1:{server.server_port}"
        finally:
            server.shutdown()
            thread.join()


def test_https_with_explicit_trust_store(browser, https_server, tls_certificate):
    assert (
        browser(
            https_server,
            "return document.title;",
            WEBKIT_CURL_CA_BUNDLE=str(tls_certificate[0]),
        )
        == "Trusted HTTPS"
    )


def test_https_rejects_untrusted_certificate(browser, https_server):
    browser(
        https_server,
        "return document.title;",
        expected_failure="Navigation failed",
    )


def test_https_host_certificate_exception(browser, https_server):
    assert (
        browser(
            https_server,
            "return document.title;",
            BRIMP_TEST_ALLOW_CERTIFICATE="1",
        )
        == "Trusted HTTPS"
    )
    browser(https_server, "return true;", expected_failure="Navigation failed")


def test_secure_websocket_round_trip(browser, https_server, tls_certificate):
    from websockets.sync.server import serve

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(*tls_certificate)

    def echo(connection):
        connection.send(connection.recv())

    with serve(echo, "127.0.0.1", 0, ssl=context) as websocket:
        worker = threading.Thread(target=websocket.serve_forever, daemon=True)
        worker.start()
        try:
            port = websocket.socket.getsockname()[1]
            assert (
                browser(
                    https_server,
                    f"""
                return await new Promise((resolve, reject) => {{
                    const socket = new WebSocket('wss://127.0.0.1:{port}');
                    socket.onopen = () => socket.send('secure websocket');
                    socket.onmessage = event => {{ socket.close(); resolve(event.data); }};
                    socket.onerror = () => reject(new Error('Secure WebSocket failed'));
                }});
                """,
                    WEBKIT_CURL_CA_BUNDLE=str(tls_certificate[0]),
                )
                == "secure websocket"
            )
        finally:
            websocket.shutdown()
            worker.join()


def test_http2_settings_match_curl_impersonate(browser, tls_certificate):
    from h2.config import H2Configuration
    from h2.connection import H2Connection
    from h2.events import RemoteSettingsChanged, RequestReceived, WindowUpdated

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(*tls_certificate)
    context.set_alpn_protocols(["h2"])
    fingerprints = []
    errors = []

    class Handler(BaseRequestHandler):
        def handle(self):
            try:
                with context.wrap_socket(self.request, server_side=True) as connection:
                    connection.settimeout(10)
                    assert connection.selected_alpn_protocol() == "h2"
                    protocol = H2Connection(H2Configuration(client_side=False))
                    protocol.initiate_connection()
                    connection.sendall(protocol.data_to_send())
                    signature = {"settings": None, "window": None}
                    recorded = False
                    while data := connection.recv(65536):
                        for event in protocol.receive_data(data):
                            if isinstance(event, RemoteSettingsChanged):
                                if signature["settings"] is None:
                                    signature["settings"] = [
                                        (int(key), change.new_value)
                                        for key, change in event.changed_settings.items()
                                    ]
                            elif (
                                isinstance(event, WindowUpdated)
                                and event.stream_id == 0
                            ):
                                if signature["window"] is None:
                                    signature["window"] = event.delta
                            elif isinstance(event, RequestReceived):
                                if not recorded:
                                    fingerprints.append(signature.copy())
                                    recorded = True
                                body = b"<title>HTTP/2 WebKit</title>"
                                protocol.send_headers(
                                    event.stream_id,
                                    [
                                        (":status", "200"),
                                        ("content-type", "text/html"),
                                        ("content-length", str(len(body))),
                                    ],
                                )
                                protocol.send_data(
                                    event.stream_id, body, end_stream=True
                                )
                        connection.sendall(protocol.data_to_send())
            except (ConnectionResetError, BrokenPipeError):
                pass  # Closing the browser may reset its idle connection.
            except Exception as error:  # noqa: BLE001 - Report server-thread failures in the test.
                errors.append(error)

    class Server(ThreadingTCPServer):
        daemon_threads = True

    with Server(("127.0.0.1", 0), Handler) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        url = f"https://127.0.0.1:{server.server_address[1]}/"
        try:
            subprocess.run(
                [
                    os.environ["CURL_IMPERSONATE_BINARY"],
                    "--impersonate",
                    "safari270",
                    "--cacert",
                    str(tls_certificate[0]),
                    "--max-time",
                    "10",
                    url,
                ],
                check=True,
                capture_output=True,
                timeout=15,
            )
            assert len(fingerprints) == 1
            expected = fingerprints[0]
            result = browser(
                url,
                "return {title: document.title, protocol: performance.getEntriesByType('navigation')[0].nextHopProtocol};",
                WEBKIT_CURL_CA_BUNDLE=str(tls_certificate[0]),
            )
            assert result == {"title": "HTTP/2 WebKit", "protocol": "h2"}
            assert len(fingerprints) >= 2
            assert all(value == expected for value in fingerprints[1:])
            assert not errors, errors
        finally:
            server.shutdown()
            worker.join()


def client_hello_signature(data):
    """Compare stable ClientHello fields, excluding randomness and GREASE."""
    assert data[0] == 1  # HandshakeType.client_hello
    offset = 4 + 2 + 32
    offset += 1 + data[offset]  # Legacy session ID
    length = int.from_bytes(data[offset : offset + 2], "big")
    ciphers = data[offset + 2 : offset + 2 + length]
    offset += 2 + length
    offset += 1 + data[offset]  # Compression methods
    length = int.from_bytes(data[offset : offset + 2], "big")
    offset += 2
    end = offset + length

    def words(value):
        return [
            int.from_bytes(value[i : i + 2], "big")
            for i in range(0, len(value), 2)
            if (int.from_bytes(value[i : i + 2], "big") & 0x0F0F) != 0x0A0A
        ]

    extensions = []
    values = {}
    while offset < end:
        kind = int.from_bytes(data[offset : offset + 2], "big")
        size = int.from_bytes(data[offset + 2 : offset + 4], "big")
        value = data[offset + 4 : offset + 4 + size]
        offset += 4 + size
        if (kind & 0x0F0F) == 0x0A0A:
            continue
        extensions.append(kind)
        if kind in (10, 13):  # Supported groups and signature algorithms
            values[kind] = words(value[2:])
        elif kind in (11, 16):  # Point formats and ALPN
            values[kind] = value.hex()
        elif kind == 43:  # Supported TLS versions
            values[kind] = words(value[1:])
    return {"ciphers": words(ciphers), "extensions": extensions, "values": values}


def capture_client_hello(action):
    captured = []
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(15)

        def capture():
            with listener.accept()[0] as connection:
                connection.settimeout(15)
                data = b""
                handshake = b""
                while True:
                    while len(data) < 5:
                        part = connection.recv(65536)
                        if not part:
                            raise AssertionError("TLS record ended early")
                        data += part
                    length = int.from_bytes(data[3:5], "big")
                    while len(data) < length + 5:
                        part = connection.recv(65536)
                        if not part:
                            raise AssertionError("TLS record ended early")
                        data += part
                    assert data[0] == 22  # TLS handshake record
                    handshake += data[5 : 5 + length]
                    data = data[5 + length :]
                    if len(handshake) >= 4 and len(handshake) >= 4 + int.from_bytes(
                        handshake[1:4], "big"
                    ):
                        captured.append(client_hello_signature(handshake))
                        return

        thread = threading.Thread(target=capture, daemon=True)
        thread.start()
        action(f"https://127.0.0.1:{listener.getsockname()[1]}/")
        thread.join(20)
    assert not thread.is_alive()
    assert len(captured) == 1
    return captured[0]


def curl_handshake_signature(target):
    curl = os.environ["CURL_IMPERSONATE_BINARY"]

    def curl_handshake(url):
        # The fixture closes after ClientHello; transfer failure is expected.
        subprocess.run(
            [curl, "--impersonate", target, "--max-time", "10", url],
            capture_output=True,
            timeout=15,
            check=False,
        )

    return capture_client_hello(curl_handshake)


def browser_handshake_signature(browser, server, target=None):
    environment = {"WEBKIT_CURL_IMPERSONATE": target} if target else {}

    def action(url):
        return browser(
            server,
            f"try {{ await fetch({json.dumps(url)}); }} catch (e) {{}} return true;",
            **environment,
        )

    return capture_client_hello(action)


def test_browser_tls_matches_curl_impersonate(browser, server):
    assert browser_handshake_signature(browser, server) == curl_handshake_signature(
        "safari270"
    )


def test_impersonation_environment_selects_the_transport_profile(browser, server):
    actual = browser_handshake_signature(browser, server, "chrome150")
    expected = curl_handshake_signature("chrome150")
    # Chrome shuffles the ClientHello extensions for each connection.
    for signature in (actual, expected):
        signature["extensions"].sort()
    assert actual == expected
