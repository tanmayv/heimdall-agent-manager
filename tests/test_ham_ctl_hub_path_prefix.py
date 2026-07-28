#!/usr/bin/env python3
"""Regression test for ham-ctl hub user-mode path-prefix handling (RTE2E-6 fix).

Root cause: the HTTP client's parse_base_url discarded any path component of the
hub base URL, so `ham-ctl hub me --hub-url http://host/prefix` sent
`GET /api/v1/me` (dropping /prefix) and the Hub returned 404 "route not found",
while curl sent the full `GET /prefix/api/v1/me` and succeeded.

This builds ham-ctl, stands up a mock HTTP server, and asserts the raw request
line preserves the base-URL path prefix (and still works when there is none).
"""
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = Path("/tmp/ham-ctl-fix/bin/ham-ctl")


def require(cond, msg):
    if not cond:
        print(f"FAIL: {msg}", file=sys.stderr)
        sys.exit(1)


def build():
    subprocess.run(
        ["nix", "build", ".#ham-ctl", "-o", str(BIN.parent.parent)],
        cwd=ROOT, check=True, capture_output=True,
    )


class MockHTTP:
    def __init__(self, port):
        self.s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.s.bind(("127.0.0.1", port))
        self.s.listen(1)
        self.port = port
        self.request_line = None

    def serve_once(self):
        conn, _ = self.s.accept()
        conn.settimeout(5)
        data = b""
        try:
            while b"\r\n\r\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
        except socket.timeout:
            pass
        self.request_line = data.split(b"\r\n")[0].decode() if data else ""
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
        conn.close()

    def close(self):
        self.s.close()


def capture_request(hub_url):
    # host[:port][/prefix] -> port for the mock listener
    after_host = hub_url.split("://", 1)[1] if "://" in hub_url else hub_url
    rest = after_host.split("/", 1)[0]  # strip any path prefix
    port = int(rest.rsplit(":", 1)[1])
    mock = MockHTTP(port)
    t = threading.Thread(target=mock.serve_once)
    t.start()
    subprocess.run(
        [str(BIN), "hub", "me", "--hub-url", hub_url, "--user-token", "hut_t"],
        capture_output=True, text=True, timeout=15,
    )
    t.join(timeout=10)
    mock.close()
    return mock.request_line


def main():
    if not BIN.exists():
        build()
    require(BIN.exists(), "ham-ctl must build")

    # Prefixed base URL: prefix MUST be preserved on the request line.
    rl = capture_request("http://127.0.0.1:49581/heimdall")
    require(rl == "GET /heimdall/api/v1/me HTTP/1.1",
            f"prefixed url must preserve path prefix; got {rl!r}")

    # Plain base URL: no prefix, unchanged behavior.
    rl = capture_request("http://127.0.0.1:49582")
    require(rl == "GET /api/v1/me HTTP/1.1",
            f"plain url must have no prefix; got {rl!r}")

    # Deep prefix + trailing slash normalization.
    rl = capture_request("http://127.0.0.1:49583/a/b/")
    require(rl == "GET /a/b/api/v1/me HTTP/1.1",
            f"deep prefix with trailing slash must normalize; got {rl!r}")

    print("PASS: ham-ctl hub path-prefix regression")


if __name__ == "__main__":
    main()
