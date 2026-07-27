#!/usr/bin/env python3
"""Forwarding invariant and loopback boundary test for ham-dev-proxy (DP-6, DP-7)."""
from __future__ import annotations

import http.server
import json
import os
import socket
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
import threading

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


def wait_for_proxy(proc: subprocess.Popen, host: str, port: int) -> None:
    deadline = time.time() + 10
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"proxy exited early: {proc.poll()}\n{proc.stdout.read() if proc.stdout else ''}")
        try:
            with socket.create_connection((host, port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("proxy did not start")


def run_proxy_test(listen_host: str, expect_mgmt_disabled: bool) -> None:
    proxy_bin = Path(os.environ.get("HAM_DEV_PROXY_BIN", "/tmp/ham-dev-proxy"))
    if not proxy_bin.exists():
        raise SystemExit(f"missing HAM_DEV_PROXY_BIN: {proxy_bin}")

    hub_port = free_port()
    proxy_port = free_port()
    hub = http.server.ThreadingHTTPServer(("127.0.0.1", hub_port), HubHandler)
    hub_thread = threading.Thread(target=hub.serve_forever, daemon=True)
    hub_thread.start()

    proc = subprocess.Popen(
        [str(proxy_bin), "--listen", f"{listen_host}:{proxy_port}", "--hub-url", f"http://127.0.0.1:{hub_port}"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    
    # Wait for the proxy. If binding 0.0.0.0, connect via 127.0.0.1.
    connect_host = "127.0.0.1" if listen_host == "0.0.0.0" else listen_host

    try:
        wait_for_proxy(proc, connect_host, proxy_port)

        # Test forwarding invariants
        req = urllib.request.Request(
            f"http://{connect_host}:{proxy_port}/api/v1/test",
            headers={
                "X-authentik-username": "spoofed-user",
                "X-Dev-User": "tanmay",
                "Authorization": "Bearer hut_secret_token",
            },
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            payload = json.loads(resp.read().decode())
        headers = {k.lower(): v for k, v in payload["headers"].items()}

        assert headers.get("authorization") == "Bearer hut_secret_token", "Bearer should be passed through"
        assert headers.get("x-authentik-username") == "tanmay", "Dev User should be injected"
        assert headers.get("x-dev-user") is None, "X-Dev-User should be stripped"

        # Test management boundary
        try:
            resp = urllib.request.urlopen(f"http://{connect_host}:{proxy_port}/_dev/", timeout=5)
            status = resp.status
        except urllib.error.HTTPError as e:
            status = e.code

        if expect_mgmt_disabled:
            assert status == 404, "Management route should be 404 on non-loopback bind"
        else:
            assert status == 200, "Management route should be 200 on loopback bind"

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
        hub.shutdown()
        hub.server_close()


def main() -> None:
    # Test on loopback (management enabled)
    run_proxy_test("127.0.0.1", expect_mgmt_disabled=False)

    # Test on non-loopback (management disabled)
    run_proxy_test("0.0.0.0", expect_mgmt_disabled=True)

    print("PASS: ham-dev-proxy forwarding invariants")


if __name__ == "__main__":
    main()
