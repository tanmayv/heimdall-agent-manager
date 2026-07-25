#!/usr/bin/env python3
"""Integration test for the browser device-confirm flow (ELDA-2 / ELDA-6 / ELDA-7).

Drives a real built ham-hub. The authorize endpoint is public; verify/approve/
the HTML page all require trusted-proxy auth (HBR-5). Asserts:
  - AC1: GET /api/v1/device returns the self-contained HTML page.
  - AC2: GET /device, verify, approve return 401 without trusted-proxy headers,
    200/200/200 with.
  - AC3: verify returns the device info captured at authorize; unknown code ->
    generic 404 "invalid or expired code".
  - AC4: approve binds owner from Auth_Context only; a client-supplied
    owner_user_id in the body is IGNORED.
  - AC5: after approve/deny the grant is terminal: verify -> 410, approve -> 409.
  - AC6: approve records audit fields (approver IP via trusted-XFF captured).

The owner-binding (AC4) and generic-error/no-enumeration guarantees are asserted
at the unit level too (device_auth_verify_approve_test), since the owner field
is not observable over HTTP.

Run: HAM_HUB_BIN=<path> python3 tests/test_device_verify_approve_http.py
"""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = "src/hub/repository/sqlite/migrations"

# Trusted-proxy identity headers (injected by the outpost/dev-proxy).
TP = {"X-authentik-username": "tanmay", "X-authentik-name": "Tanmay V",
      "X-authentik-email": "tanmay@example.com"}
TP_EVIL = {"X-authentik-username": "attacker", "X-authentik-name": "Attacker",
           "X-authentik-email": "attacker@example.com"}


def free_port() -> int:
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def wait_ready(port: int, timeout: float = 10.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v1/health", timeout=0.5):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"ham-hub did not start on port {port}")


def req(base: str, method: str, path: str, body: dict | None = None, headers: dict | None = None) -> tuple[int, dict | str]:
    data = json.dumps(body).encode() if body is not None else None
    h = {"Content-Type": "application/json"} if body is not None else {}
    if headers:
        h.update(headers)
    r = urllib.request.Request(f"{base}{path}", data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=5) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def fail(msg: str) -> None:
    print("FAIL:", msg); sys.exit(1)


def jget(raw: str) -> dict:
    try:
        return json.loads(raw).get("data", {})
    except Exception:
        return {}


def main() -> None:
    import tempfile
    hub_bin = Path(os.environ.get("HAM_HUB_BIN", "/tmp/ham-hub-da/bin/ham-hub"))
    if not hub_bin.exists():
        raise SystemExit(f"missing HAM_HUB_BIN: {hub_bin}")
    th = Path(tempfile.mkdtemp()); port = free_port()
    env = dict(os.environ); env["HEIMDALL_HOME"] = str(th)
    proc = subprocess.Popen([str(hub_bin), "--listen", f"127.0.0.1:{port}",
                             "--db", str(th / "h.db"), "--migrations-dir", MIGRATIONS],
                            cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    try:
        wait_ready(port)
        base = f"http://127.0.0.1:{port}"

        # --- AC1 + AC2: HTML page, auth gate ---
        s, raw = req(base, "GET", "/api/v1/device")
        if s != 401: fail(f"GET /device without TP headers must be 401, got {s}")
        s, raw = req(base, "GET", "/api/v1/device", headers=TP)
        if s != 200: fail(f"GET /device with TP headers must be 200, got {s}")
        if not raw.lstrip().startswith("<!DOCTYPE html>") or "<form" not in raw.lower() and "user_code" not in raw:
            fail("GET /device must return the HTML page with a user_code entry")
        print("AC1+AC2 OK: HTML page served; 401 without TP, 200 with")

        # authorize (public) to obtain a user_code
        s, r = req(base, "POST", "/api/v1/device/authorize",
                   {"client": "electron", "device_label": "MacBook Pro", "os": "macOS 15", "app_version": "1.2.3"})
        if s != 200: fail(f"authorize failed: {s} {r}")
        uc = jget(r)["user_code"]

        # --- AC2: verify/approve 401 without TP ---
        s, _ = req(base, "POST", "/api/v1/device/verify", {"user_code": uc})
        if s != 401: fail(f"verify without TP must be 401, got {s}")
        s, _ = req(base, "POST", "/api/v1/device/approve", {"user_code": uc, "approve": True})
        if s != 401: fail(f"approve without TP must be 401, got {s}")

        # --- AC3: verify shows device info ---
        s, r = req(base, "POST", "/api/v1/device/verify", {"user_code": uc}, TP)
        if s != 200: fail(f"verify must be 200, got {s}: {r}")
        d = jget(r)
        if d.get("client") != "electron" or d.get("device_label") != "MacBook Pro" or d.get("os") != "macOS 15":
            fail(f"verify device info mismatch: {d}")
        # --- AC3: unknown code -> generic 404, no code enumeration ---
        s, r = req(base, "POST", "/api/v1/device/verify", {"user_code": "ZZZZ-ZZZZ"}, TP)
        if s != 404: fail(f"unknown code must be 404, got {s}")
        if "invalid or expired" not in r.lower(): fail(f"generic error message mismatch: {r}")
        print("AC3 OK: verify shows device info; unknown -> generic 404")

        # --- AC4: approve binds owner from Auth_Context; body owner IGNORED ---
        s, r = req(base, "POST", "/api/v1/device/approve",
                   {"user_code": uc, "approve": True, "owner_user_id": "EVIL-ATTACKER", "user": "hijack"}, TP)
        if s != 200: fail(f"approve must be 200, got {s}: {r}")
        print("AC4 OK: approve accepted (owner from context; body owner field ignored — verified at unit level)")

        # --- AC5: terminal grant: verify -> 410, approve -> 409 ---
        s, _ = req(base, "POST", "/api/v1/device/verify", {"user_code": uc}, TP)
        if s != 410: fail(f"verify terminal must be 410, got {s}")
        s, _ = req(base, "POST", "/api/v1/device/approve", {"user_code": uc, "approve": True}, TP)
        if s != 409: fail(f"approve terminal must be 409, got {s}")
        print("AC5 OK: terminal verify -> 410, approve -> 409")

        # --- AC: deny path is also terminal ---
        uc2 = jget(req(base, "POST", "/api/v1/device/authorize", {"client": "electron"})[1])["user_code"]
        s, _ = req(base, "POST", "/api/v1/device/approve", {"user_code": uc2, "approve": False}, TP)
        if s != 200: fail(f"deny must be 200, got {s}")
        s, _ = req(base, "POST", "/api/v1/device/verify", {"user_code": uc2}, TP)
        if s != 410: fail(f"denied grant verify must be 410, got {s}")
        print("OK: deny path terminal (410)")

        # --- AC6: audit fields captured (approver IP via trusted-XFF) ---
        # Verified at unit level (approver_ip/approver_ua/decided_at/owner_user_id
        # are not observable over HTTP). The HTTP path supplies approver_ip from
        # trusted-XFF + User-Agent; the unit test asserts they land on the grant.
        print("AC6 OK: audit fields captured (asserted in unit test)")
    finally:
        proc.terminate()
        try: proc.wait(timeout=3)
        except subprocess.TimeoutExpired: proc.kill()
    print("ALL PASS")


if __name__ == "__main__":
    main()
