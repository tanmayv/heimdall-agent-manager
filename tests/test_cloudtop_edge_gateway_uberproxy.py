#!/usr/bin/env python3
"""Automated integration tests for CT-7: Cloudtop Edge Gateway on Port 8989 & Owner LOAS Verification.

Verifies:
1. Port 8989 / 0.0.0.0 gateway ingress routing API requests to Hub and UI requests to Vite.
2. Owner LOAS/Identity Gate via ÜberProxy headers (X-Goog-Authenticated-User-Email, X-Forwarded-User, X-Remote-User).
3. Rejection with 403 Forbidden ("Access Denied: Caller identity does not match Cloudtop owner") for non-owners.
4. Non-loopback requests without ÜberProxy headers rejected with 403 Forbidden.
5. Localhost/loopback requests without ÜberProxy headers allowed with 200 OK (preserving developer workflow).
6. Expired LOAS / gcert returns 401 Unauthorized.
7. Dynamic identity translation to Hub (authentic user, display_name, email).
8. Fallback gateway HTML when Vite dev server is offline, and successful proxying when Vite is online.
"""
from __future__ import annotations

import base64
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

def make_uptick_bytes(email: str, tier: int = 30) -> bytes:
    # Field 1: tier (varint, tag = 1<<3|0 = 8)
    # Field 2: email (length delimited string, tag = 2<<3|2 = 18)
    b = bytearray()
    b.extend([0x08, tier])
    email_bytes = email.encode("utf-8")
    b.extend([0x12, len(email_bytes)])
    b.extend(email_bytes)
    return bytes(b)

def make_uptick_header(email: str, signed: bool = False) -> str:
    proto = make_uptick_bytes(email)
    b64 = base64.b64encode(proto).decode("ascii")
    if signed:
        return f"{b64}.AFhcHLEwRAIgLNWLWIWppnTlc8lxuRIMJqQUsKH0rLivdJv15zzXji8CIHRmXlREUo2TzGKp2Ww-7mrkpLqc4DcqFGt155qVtTqC"
    return b64


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
                with hub.lock:
                    hub.requests.append({"method": self.command, "path": self.path, "headers": dict(self.headers)})
                if self.path == "/api/v1/me":
                    uname = self.headers.get("X-authentik-username", "")
                    dname = self.headers.get("X-authentik-name", "")
                    email = self.headers.get("X-authentik-email", "")
                    body = json.dumps({"user_id": uname, "name": uname, "display_name": dname, "email": email}).encode()
                else:
                    body = json.dumps({"ok": True, "path": self.path}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None: self._record()
            def do_POST(self) -> None: self._record()
            def log_message(self, *_args) -> None: pass
        return Handler

class MockViteServer:
    def __init__(self) -> None:
        self.requests: list[dict] = []
        self.lock = threading.Lock()

    def handler_factory(self) -> type:
        vite = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                with vite.lock:
                    vite.requests.append({"method": self.command, "path": self.path, "headers": dict(self.headers)})
                body = b"<!DOCTYPE html><html><body><h1>Vite Dev UI Running</h1></body></html>"
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
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
    proxy_bin = Path("/tmp/ham-dev-proxy-ct7-test")
    odin = "/nix/store/lrzcmy4vglphhshdpsqmsgjpnf5z1yhi-odin-dev-2026-05/bin/odin"
    subprocess.check_call([odin, "build", "src/dev_proxy", f"-out:{proxy_bin}", "-collection:odin_test=src"], cwd=ROOT)

    # Start recording Hub mock
    hub = RecordingHub()
    hub_port = free_port()
    hub_server = http.server.ThreadingHTTPServer(("127.0.0.1", hub_port), hub.handler_factory())
    threading.Thread(target=hub_server.serve_forever, daemon=True).start()

    # Start mock Vite server
    vite = MockViteServer()
    vite_port = free_port()
    vite_server = http.server.ThreadingHTTPServer(("127.0.0.1", vite_port), vite.handler_factory())
    threading.Thread(target=vite_server.serve_forever, daemon=True).start()

    with tempfile.TemporaryDirectory() as tmp:
        secret_file = Path(tmp) / "proxy_secret"
        secret_file.write_text("ct7_secret_key_999\n")
        os.chmod(secret_file, 0o600)

        gateway_port = free_port()
        env = dict(os.environ)
        env["HEIMDALL_HOME"] = tmp
        env["HAM_PROXY_SECRET_FILE"] = str(secret_file)
        env["USER"] = "tanmayvijay"
        env["HEIMDALL_MOCK_GCERT_REMAINING_MINUTES"] = "1200"

        # Launch dev-proxy in Cloudtop gateway mode (listening on 0.0.0.0:<port>)
        proc = subprocess.Popen(
            [
                str(proxy_bin),
                "--listen", f"0.0.0.0:{gateway_port}",
                "--hub-url", f"http://127.0.0.1:{hub_port}",
                "--vite-url", f"http://127.0.0.1:{vite_port}",
                "--default-user", "tanmayvijay",
            ],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        try:
            wait_for_port(gateway_port, proc)

            # TEST 1: Matching Cloudtop Owner with ÜberProxy header (X-Goog-Authenticated-User-Email)
            # Host simulates corporate Cloudtop address (e.g. tanmayvijay.c.googlers.com)
            req = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/me",
                headers={
                    "Host": "tanmayvijay.c.googlers.com:8989",
                    "X-Goog-Authenticated-User-Email": "tanmayvijay@google.com",
                },
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                assert resp.status == 200
                data = json.loads(resp.read().decode())
                assert data["user_id"] == "tanmayvijay", f"expected user_id tanmayvijay, got {data}"
                assert data["email"] == "tanmayvijay@google.com", f"expected email tanmayvijay@google.com, got {data}"

            with hub.lock:
                last_hub_req = hub.requests[-1]
                rec_headers = {k.lower(): v for k, v in last_hub_req["headers"].items()}

            assert rec_headers.get("x-authentik-username") == "tanmayvijay"
            assert rec_headers.get("x-authentik-email") == "tanmayvijay@google.com"
            assert rec_headers.get("x-heimdall-proxy-secret") == "ct7_secret_key_999"
            assert "x-goog-authenticated-user-email" not in rec_headers, "ÜberProxy headers must be sanitized before Hub"
            print("PASS 1: Matching owner via X-Goog-Authenticated-User-Email resolved and forwarded to Hub")

            # TEST 2: Accounts prefix format (accounts.google.com:tanmayvijay@google.com)
            req = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/me",
                headers={
                    "Host": "tanmayvijay.c.googlers.com:8989",
                    "X-Goog-Authenticated-User-Email": "accounts.google.com:tanmayvijay@google.com",
                },
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                assert resp.status == 200
                data = json.loads(resp.read().decode())
                assert data["user_id"] == "tanmayvijay"
            print("PASS 2: Accounts prefix format (accounts.google.com:...) parsed correctly")

            # TEST 3a: Google internal ÜberProxy PEN headers (X-UberProxy-User)
            req_uber_user = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/me",
                headers={
                    "Host": "tanmayvijay.c.googlers.com:8989",
                    "X-UberProxy-User": "tanmayvijay",
                },
            )
            with urllib.request.urlopen(req_uber_user, timeout=5) as resp:
                assert resp.status == 200
                data = json.loads(resp.read().decode())
                assert data["user_id"] == "tanmayvijay"
                assert data["email"] == "tanmayvijay@google.com"
            print("PASS 3a: X-UberProxy-User alone resolved and normalized to tanmayvijay@google.com")

            # TEST 3b: Google internal ÜberProxy PEN headers (X-UberProxy-User-Email)
            req_uber_email = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/me",
                headers={
                    "Host": "tanmayvijay.c.googlers.com:8989",
                    "X-UberProxy-User-Email": "tanmayvijay@google.com",
                },
            )
            with urllib.request.urlopen(req_uber_email, timeout=5) as resp:
                assert resp.status == 200
                data = json.loads(resp.read().decode())
                assert data["user_id"] == "tanmayvijay"
                assert data["email"] == "tanmayvijay@google.com"
            print("PASS 3b: X-UberProxy-User-Email alone resolved and normalized to tanmayvijay@google.com")

            # TEST 3c: ÜberProxy PEN URL Host (*.proxy.googlers.com) with X-UberProxy-User
            req_pen_host = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/me",
                headers={
                    "Host": "f8a92b3c4d5e.proxy.googlers.com:8989",
                    "X-UberProxy-User": "tanmayvijay",
                    "X-UberProxy-User-Email": "tanmayvijay@google.com",
                },
            )
            with urllib.request.urlopen(req_pen_host, timeout=5) as resp:
                assert resp.status == 200
                data = json.loads(resp.read().decode())
                assert data["user_id"] == "tanmayvijay"
            print("PASS 3c: ÜberProxy PEN URL Host (*.proxy.googlers.com) allowed and authenticated")

            # TEST 3c2: ÜberProxy UpTick header (X-UberProxy-UpTick) with owner email
            req_uptick = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/me",
                headers={
                    "Host": "b2607f8b04800100000c005d2ac109a6e231d000000000000000001.proxy.googlers.com:8989",
                    "X-UberProxy-UpTick": make_uptick_header("tanmayvijay@google.com"),
                },
            )
            with urllib.request.urlopen(req_uptick, timeout=5) as resp:
                assert resp.status == 200
                data = json.loads(resp.read().decode())
                assert data["user_id"] == "tanmayvijay"
                assert data["email"] == "tanmayvijay@google.com"
            print("PASS 3c2: X-UberProxy-UpTick header decoded and admitted")

            # TEST 3c3: ÜberProxy Signed UpTick header (X-UberProxy-Signed-UpTick) with owner email
            req_signed_uptick = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/me",
                headers={
                    "Host": "b2607f8b04800100000c005d2ac109a6e231d000000000000000001.proxy.googlers.com:8989",
                    "X-UberProxy-Signed-UpTick": make_uptick_header("tanmayvijay@google.com", signed=True),
                },
            )
            with urllib.request.urlopen(req_signed_uptick, timeout=5) as resp:
                assert resp.status == 200
                data = json.loads(resp.read().decode())
                assert data["user_id"] == "tanmayvijay"
                assert data["email"] == "tanmayvijay@google.com"
            print("PASS 3c3: X-UberProxy-Signed-UpTick header decoded and admitted")

            # TEST 3d: Fallback Priority 3 (X-Forwarded-User) when matching owner
            req_fwd = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/me",
                headers={
                    "Host": "tanmayvijay.c.googlers.com:8989",
                    "X-Forwarded-User": "tanmayvijay",
                },
            )
            with urllib.request.urlopen(req_fwd, timeout=5) as resp:
                assert resp.status == 200
                data = json.loads(resp.read().decode())
                assert data["user_id"] == "tanmayvijay"
            print("PASS 3d: X-Forwarded-User fallback admitted when matching owner")

            # TEST 3e: Unrecognized/spoofable header (X-Remote-User) alone without valid auth MUST BE REJECTED
            req_remote = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/me",
                headers={
                    "Host": "tanmayvijay.c.googlers.com:8989",
                    "X-Remote-User": "tanmayvijay",
                },
            )
            try:
                urllib.request.urlopen(req_remote, timeout=5)
                assert False, "expected 403 Forbidden for X-Remote-User alone"
            except urllib.error.HTTPError as e:
                assert e.code == 403
                body = e.read().decode()
                assert "Access Denied: Caller identity does not match Cloudtop owner" in body
            print("PASS 3e: X-Remote-User alone is rejected (not an authoritative identity header)")

            # TEST 3f: Untrusted Host header strictly rejected even with valid ÜberProxy auth
            req_evil_host = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/me",
                headers={
                    "Host": "evil-attacker.com:8989",
                    "X-UberProxy-User": "tanmayvijay",
                },
            )
            try:
                urllib.request.urlopen(req_evil_host, timeout=5)
                assert False, "expected 403 Forbidden for untrusted Host header evil-attacker.com"
            except urllib.error.HTTPError as e:
                assert e.code == 403
                body = e.read().decode()
                assert "invalid host header" in body
            print("PASS 3f: Untrusted Host header rejected even with valid ÜberProxy authentication")

            # TEST 3g: Credential Masking in Denial Logs (Cookie & sensitive headers redacted)
            req_cookie_leak = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/me",
                headers={
                    "Host": "evil-attacker.com:8989",
                    "X-UberProxy-User": "tanmayvijay",
                    "Cookie": "super_secret_session_token=12345; user=tanmayvijay",
                    "X-Custom-Secret": "sensitive_key_val",
                },
            )
            try:
                urllib.request.urlopen(req_cookie_leak, timeout=5)
                assert False, "expected 403 Forbidden for evil-attacker.com"
            except urllib.error.HTTPError as e:
                assert e.code == 403
            print("PASS 3g: Request with sensitive Cookie/secret headers rejected")

            # TEST 4: Non-owner caller identity rejected with 403 Forbidden for all header types
            for bad_header, bad_val in [
                ("X-Goog-Authenticated-User-Email", "alice@google.com"),
                ("X-UberProxy-User", "alice"),
                ("X-UberProxy-User-Email", "alice@google.com"),
                ("X-Forwarded-User", "alice"),
                ("X-UberProxy-UpTick", make_uptick_header("alice@google.com")),
                ("X-UberProxy-Signed-UpTick", make_uptick_header("alice@google.com", signed=True)),
            ]:
                req_bad = urllib.request.Request(
                    f"http://127.0.0.1:{gateway_port}/api/v1/me",
                    headers={
                        "Host": "tanmayvijay.c.googlers.com:8989",
                        bad_header: bad_val,
                    },
                )
                initial_hub_req_count = len(hub.requests)
                try:
                    urllib.request.urlopen(req_bad, timeout=5)
                    assert False, f"expected 403 Forbidden for non-owner {bad_header}={bad_val}"
                except urllib.error.HTTPError as e:
                    assert e.code == 403, f"expected 403 got {e.code}"
                    err_body = e.read().decode()
                    assert "Access Denied: Caller identity does not match Cloudtop owner" in err_body
                assert len(hub.requests) == initial_hub_req_count, "Hub must not receive rejected requests"
            print("PASS 4: Non-owner caller identity rejected with 403 across all header types")

            # TEST 5: Non-loopback Host without ÜberProxy headers rejected with 403 Forbidden
            req = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/health",
                headers={"Host": "tanmayvijay.c.googlers.com:8989"},
            )
            try:
                urllib.request.urlopen(req, timeout=5)
                assert False, "expected 403 Forbidden for non-loopback host without ÜberProxy headers"
            except urllib.error.HTTPError as e:
                assert e.code == 403, f"expected 403 got {e.code}"
                err_body = e.read().decode()
                assert "Access Denied: Caller identity does not match Cloudtop owner" in err_body, (
                    f"unexpected body: {err_body}"
                )
            print("PASS 5: Non-loopback host without ÜberProxy headers rejected")

            # TEST 6: Localhost/loopback request without ÜberProxy headers allowed (dev workflow)
            req = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/health",
                headers={"Host": f"127.0.0.1:{gateway_port}"},
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                assert resp.status == 200
            print("PASS 6: Loopback connection without ÜberProxy headers permitted")

            # TEST 7: Proxying to Vite dev server on non-API routes
            req = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/",
                headers={
                    "Host": "tanmayvijay.c.googlers.com:8989",
                    "X-Goog-Authenticated-User-Email": "tanmayvijay@google.com",
                },
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                assert resp.status == 200
                body = resp.read().decode()
                assert "Vite Dev UI Running" in body, f"expected Vite UI, got: {body}"
            print("PASS 7: Non-API UI requests successfully proxied to Vite dev server")

        finally:
            proc.terminate()
            stdout_data, _ = proc.communicate()
            assert "super_secret_session_token" not in stdout_data, "Cookie secret must be redacted from denial logs!"
            assert "sensitive_key_val" not in stdout_data, "Custom secret must be redacted from denial logs!"
            assert "Cookie: [REDACTED]" in stdout_data, "Expected Cookie: [REDACTED] in logs"
            print("PASS 3h: Denial logs verified: Cookie and secret headers are strictly redacted")

        # TEST 8: Fallback Gateway HTML when Vite dev server is offline
        offline_vite_port = free_port()
        offline_gateway_port = free_port()
        proc_offline = subprocess.Popen(
            [
                str(proxy_bin),
                "--listen", f"127.0.0.1:{offline_gateway_port}",
                "--hub-url", f"http://127.0.0.1:{hub_port}",
                "--vite-url", f"http://127.0.0.1:{offline_vite_port}",
                "--default-user", "tanmayvijay",
            ],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        try:
            wait_for_port(offline_gateway_port, proc_offline)
            req = urllib.request.Request(f"http://127.0.0.1:{offline_gateway_port}/")
            with urllib.request.urlopen(req, timeout=5) as resp:
                assert resp.status == 200
                body = resp.read().decode()
                assert "Heimdall Cloudtop Gateway" in body
                assert "Port 8989 Active" in body
            print("PASS 8: Fallback gateway HTML returned when Vite dev server is offline")
        finally:
            proc_offline.terminate()
            proc_offline.wait()

        # TEST 9: Expired LOAS / gcert credential check returns 401 Unauthorized
        loas_gateway_port = free_port()
        env_expired = dict(env)
        env_expired["HEIMDALL_MOCK_GCERT_REMAINING_MINUTES"] = "0"
        proc_loas = subprocess.Popen(
            [
                str(proxy_bin),
                "--listen", f"0.0.0.0:{loas_gateway_port}",
                "--hub-url", f"http://127.0.0.1:{hub_port}",
                "--default-user", "tanmayvijay",
            ],
            cwd=ROOT, env=env_expired, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        try:
            wait_for_port(loas_gateway_port, proc_loas)
            req = urllib.request.Request(
                f"http://127.0.0.1:{loas_gateway_port}/api/v1/me",
                headers={
                    "Host": "tanmayvijay.c.googlers.com:8989",
                    "X-Goog-Authenticated-User-Email": "tanmayvijay@google.com",
                },
            )
            try:
                urllib.request.urlopen(req, timeout=5)
                assert False, "expected 401 Unauthorized when gcert is expired"
            except urllib.error.HTTPError as e:
                assert e.code == 401, f"expected 401 got {e.code}"
                err_body = e.read().decode()
                assert "LOAS/gcert credential expired or missing" in err_body
            print("PASS 9: Expired LOAS/gcert returns 401 Unauthorized")
        finally:
            proc_loas.terminate()
            proc_loas.wait()

    print("ALL CT-7 CLOUDTOP EDGE GATEWAY & OWNER LOAS TESTS PASSED!")

if __name__ == "__main__":
    main()
