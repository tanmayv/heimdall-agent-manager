#!/usr/bin/env python3
"""Integration tests for Hub hardened proxy secret authentication."""
import json
import os
import socket
import subprocess
import tempfile
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
    hub_bin = Path("/tmp/ham-hub-test")
    odin = "/nix/store/lrzcmy4vglphhshdpsqmsgjpnf5z1yhi-odin-dev-2026-05/bin/odin"
    sqlite_lib = "/nix/store/whs07fdxlw22fi8b3jzd2z871dh41qx6-sqlite-3.51.2/lib"
    build_cmd = [odin, "build", "src/hub", f"-out:{hub_bin}", "-collection:odin_test=src"]
    if os.path.exists(sqlite_lib):
        build_cmd.append(f"-extra-linker-flags:-L{sqlite_lib}")
    subprocess.check_call(build_cmd, cwd=ROOT)

    with tempfile.TemporaryDirectory() as tmp:
        db_path = Path(tmp) / "hub.db"
        secret_file = Path(tmp) / "proxy_secret"
        secret_file.write_text("secure_shared_secret_456\n")
        os.chmod(secret_file, 0o600)

        hub_port = free_port()
        hub_proc = subprocess.Popen(
            [
                str(hub_bin),
                "--listen", f"127.0.0.1:{hub_port}",
                "--db", str(db_path),
                "--proxy-secret-file", str(secret_file),
                "--require-proxy-secret",
            ],
            cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        try:
            wait_for_port(hub_port, hub_proc)

            # 1. Health check should be unauthenticated and 200
            req = urllib.request.Request(f"http://127.0.0.1:{hub_port}/api/v1/health")
            with urllib.request.urlopen(req) as resp:
                assert resp.status == 200

            # 2. Request with trusted proxy header but missing X-Heimdall-Proxy-Secret -> 401
            req = urllib.request.Request(
                f"http://127.0.0.1:{hub_port}/api/v1/me",
                headers={"X-authentik-username": "alice"},
            )
            try:
                urllib.request.urlopen(req)
                assert False, "expected 401 Unauthenticated for missing proxy secret"
            except urllib.error.HTTPError as e:
                assert e.code == 401
                body = e.read().decode()
                assert "invalid or missing proxy secret" in body, f"unexpected body: {body}"
            print("PASS: Hub rejects trusted proxy headers when proxy secret is missing")

            # 3. Request with wrong X-Heimdall-Proxy-Secret -> 401
            req = urllib.request.Request(
                f"http://127.0.0.1:{hub_port}/api/v1/me",
                headers={
                    "X-authentik-username": "alice",
                    "X-Heimdall-Proxy-Secret": "wrong_secret",
                },
            )
            try:
                urllib.request.urlopen(req)
                assert False, "expected 401 Unauthenticated for wrong proxy secret"
            except urllib.error.HTTPError as e:
                assert e.code == 401
                body = e.read().decode()
                assert "invalid or missing proxy secret" in body, f"unexpected body: {body}"
            print("PASS: Hub rejects trusted proxy headers when proxy secret is incorrect")

            # 4. Request with valid X-Heimdall-Proxy-Secret -> 200
            req = urllib.request.Request(
                f"http://127.0.0.1:{hub_port}/api/v1/me",
                headers={
                    "X-authentik-username": "alice",
                    "X-authentik-name": "Alice User",
                    "X-authentik-email": "alice@example.com",
                    "X-Heimdall-Proxy-Secret": "secure_shared_secret_456",
                },
            )
            with urllib.request.urlopen(req) as resp:
                assert resp.status == 200
                data = json.loads(resp.read().decode())
                assert data["data"]["user_id"] == "alice"
            print("PASS: Hub accepts trusted proxy headers with verified X-Heimdall-Proxy-Secret")

        finally:
            hub_proc.terminate()
            hub_proc.wait()

    print("ALL HUB PROXY SECRET CHECKS PASSED")

if __name__ == "__main__":
    main()
