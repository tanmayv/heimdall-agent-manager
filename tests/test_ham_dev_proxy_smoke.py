#!/usr/bin/env python3
"""Smoke test for runnable ham-dev-proxy (HBR-6)."""
from __future__ import annotations

import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class HubHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({
            "path": self.path,
            "headers": {k: v for k, v in self.headers.items()},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def wait_for_proxy(proc: subprocess.Popen, port: int) -> None:
    deadline = time.time() + 10
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"proxy exited early: {proc.poll()}\n{proc.stdout.read() if proc.stdout else ''}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("proxy did not start")


def main() -> None:
    proxy_bin = Path(os.environ.get("HAM_DEV_PROXY_BIN", "/tmp/ham-dev-proxy"))
    if not proxy_bin.exists():
        raise SystemExit(f"missing HAM_DEV_PROXY_BIN: {proxy_bin}")

    hub_port = free_port()
    proxy_port = free_port()
    hub = http.server.ThreadingHTTPServer(("127.0.0.1", hub_port), HubHandler)
    hub_thread = threading.Thread(target=hub.serve_forever, daemon=True)
    hub_thread.start()

    proc = subprocess.Popen(
        [str(proxy_bin), "--listen", f"127.0.0.1:{proxy_port}", "--hub-url", f"http://127.0.0.1:{hub_port}"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        wait_for_proxy(proc, proxy_port)
        req = urllib.request.Request(
            f"http://127.0.0.1:{proxy_port}/api/v1/me?x=1",
            headers={
                "X-authentik-username": "spoofed",
                "X-authentik-name": "Spoofed User",
                "X-Dev-User": "reviewer",
                "Authorization": "Bearer keep-me",
            },
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            payload = json.loads(resp.read().decode())
        headers = {k.lower(): v for k, v in payload["headers"].items()}
        assert payload["path"] == "/api/v1/me?x=1", payload
        assert headers.get("x-authentik-username") == "reviewer", headers
        assert headers.get("x-authentik-name") == "Reviewer User", headers
        assert headers.get("x-authentik-email") == "reviewer@example.com", headers
        assert headers.get("authorization") == "Bearer keep-me", headers

        login = urllib.request.urlopen(f"http://127.0.0.1:{proxy_port}/_dev/login?user=tanmay", timeout=5)
        assert login.status == 204
        assert "ham_dev_user=tanmay" in login.headers.get("Set-Cookie", "")
        logout = urllib.request.urlopen(f"http://127.0.0.1:{proxy_port}/_dev/logout", timeout=5)
        assert logout.status == 204
        assert "Max-Age=0" in logout.headers.get("Set-Cookie", "")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
        hub.shutdown()
        hub.server_close()

    print("PASS: ham-dev-proxy smoke")


if __name__ == "__main__":
    main()
