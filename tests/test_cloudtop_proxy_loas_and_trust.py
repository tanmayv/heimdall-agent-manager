#!/usr/bin/env python3
"""Integration tests for CT-3 / CT-4 hardened proxy-to-hub trust and dev-proxy LOAS check."""
from __future__ import annotations

import http.server
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p

class RecordingHub:
    def __init__(self) -> None:
        self.requests: list[dict] = []
        self.lock = threading.Lock()

    def handler_factory(self) -> type:
        hub = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def _record(self) -> None:
                body = json.dumps({"path": self.path, "headers": {k: v for k, v in self.headers.items()}}).encode()
                with hub.lock:
                    hub.requests.append({"method": self.command, "path": self.path, "headers": dict(self.headers)})
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None: self._record()
            def do_POST(self) -> None: self._record()
            def log_message(self, *_args) -> None: pass
        return Handler

def wait_for_port(port: int, proc: subprocess.Popen) -> None:
    deadline = time.time() + 10
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"process exited early with code {proc.poll()}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise TimeoutError(f"timed out waiting for port {port}")

def main() -> None:
    proxy_bin = Path("/tmp/ham-dev-proxy-test")
    odin = "/nix/store/lrzcmy4vglphhshdpsqmsgjpnf5z1yhi-odin-dev-2026-05/bin/odin"
    subprocess.check_call([odin, "build", "src/dev_proxy", f"-out:{proxy_bin}", "-collection:odin_test=src"], cwd=ROOT)

    hub = RecordingHub()
    hub_port = free_port()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", hub_port), hub.handler_factory())
    threading.Thread(target=server.serve_forever, daemon=True).start()

    with tempfile.TemporaryDirectory() as tmp:
        secret_file = Path(tmp) / "proxy_secret"
        secret_file.write_text("test_secret_xyz123\n")
        os.chmod(secret_file, 0o600)

        # 1. Test LOAS / gcert ingress rejection when expired
        proxy_port_loas = free_port()
        env_loas = dict(os.environ)
        env_loas["HEIMDALL_HOME"] = tmp
        env_loas["HEIMDALL_MOCK_GCERT_REMAINING_MINUTES"] = "0"
        env_loas["HAM_PROXY_SECRET_FILE"] = str(secret_file)

        proc_loas = subprocess.Popen(
            [str(proxy_bin), "--listen", f"127.0.0.1:{proxy_port_loas}", "--hub-url", f"http://127.0.0.1:{hub_port}"],
            cwd=ROOT, env=env_loas, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        try:
            wait_for_port(proxy_port_loas, proc_loas)
            # Proxied request should return 401 Unauthorized due to expired gcert
            req = urllib.request.Request(f"http://127.0.0.1:{proxy_port_loas}/api/v1/projects")
            try:
                urllib.request.urlopen(req)
                assert False, "expected 401 Unauthorized when gcert is expired"
            except urllib.error.HTTPError as e:
                assert e.code == 401, f"expected 401 got {e.code}"
                err_body = e.read().decode()
                assert "LOAS/gcert credential expired or missing" in err_body, f"unexpected body: {err_body}"
            print("PASS: dev-proxy LOAS ingress rejection when expired")
        finally:
            proc_loas.terminate()
            proc_loas.wait()

        # 2. Test Proxy-to-Hub Trust and Header Stripping when valid
        proxy_port = free_port()
        env = dict(os.environ)
        env["HEIMDALL_HOME"] = tmp
        env["HEIMDALL_MOCK_GCERT_REMAINING_MINUTES"] = "1200"
        env["HAM_PROXY_SECRET_FILE"] = str(secret_file)
        env["HEIMDALL_AUDIT_MODE"] = "1"

        proc = subprocess.Popen(
            [str(proxy_bin), "--listen", f"127.0.0.1:{proxy_port}", "--hub-url", f"http://127.0.0.1:{hub_port}", "--audit-mode"],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        try:
            wait_for_port(proxy_port, proc)

            # Send request with spoofed client headers:
            headers = {
                "X-Forwarded-For": "10.0.0.1",
                "X-Forwarded-Host": "evil.com",
                "Forwarded": "for=10.0.0.1",
                "X-Real-IP": "10.0.0.1",
                "X-authentik-role": "superadmin",
                "X-Heimdall-Proxy-Secret": "client_injected_secret",
            }
            req = urllib.request.Request(f"http://127.0.0.1:{proxy_port}/api/v1/projects", headers=headers)
            with urllib.request.urlopen(req, timeout=5) as resp:
                assert resp.status == 200

            with hub.lock:
                last_req = hub.requests[-1]
                rec_headers = {k.lower(): v for k, v in last_req["headers"].items()}

            # Verify client spoof headers were stripped
            assert "x-forwarded-for" not in rec_headers, "X-Forwarded-For must be stripped"
            assert "x-forwarded-host" not in rec_headers, "X-Forwarded-Host must be stripped"
            assert "forwarded" not in rec_headers, "Forwarded must be stripped"
            assert "x-real-ip" not in rec_headers, "X-Real-IP must be stripped"
            assert "x-authentik-role" not in rec_headers, "X-authentik-role must be stripped"

            # Verify dev-proxy injected verified secret and audit user (reviewer)
            assert rec_headers.get("x-heimdall-proxy-secret") == "test_secret_xyz123", (
                f"expected proxy secret test_secret_xyz123, got {rec_headers.get('x-heimdall-proxy-secret')}"
            )
            assert rec_headers.get("x-authentik-username") == "reviewer", (
                f"audit mode without cookie must default to reviewer, got {rec_headers.get('x-authentik-username')}"
            )
            print("PASS: dev-proxy header stripping, proxy secret injection, and audit mode user resolution")
        finally:
            proc.terminate()
            proc.wait()

    print("ALL CT-3 & CT-4 LOAS AND TRUST TESTS PASSED")

if __name__ == "__main__":
    main()
