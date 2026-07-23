#!/usr/bin/env python3
"""M1 smoke against real ham-hub + ham-dev-proxy binaries (HBR-5/6/7/18)."""
from __future__ import annotations

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
    port = s.getsockname()[1]
    s.close()
    return port


def wait_get(url: str, timeout: float = 10.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=0.5):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"timed out waiting for {url}")


def get_json(url: str, headers: dict[str, str] | None = None) -> tuple[int, dict]:
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode())


def main() -> None:
    hub_bin = Path(os.environ.get("HAM_HUB_BIN", "/tmp/ham-hub-phase2"))
    proxy_bin = Path(os.environ.get("HAM_DEV_PROXY_BIN", "/tmp/ham-dev-proxy"))
    if not hub_bin.exists():
        raise SystemExit(f"missing HAM_HUB_BIN: {hub_bin}")
    if not proxy_bin.exists():
        raise SystemExit(f"missing HAM_DEV_PROXY_BIN: {proxy_bin}")

    hub_port = free_port()
    proxy_port = free_port()
    with tempfile.TemporaryDirectory(prefix="ham-hub-m1-") as tmp:
        db_path = Path(tmp) / "hub.db"
        hub = subprocess.Popen(
            [str(hub_bin), "--listen", f"127.0.0.1:{hub_port}", "--db", str(db_path), "--logout-url", "/_dev/logout"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        proxy = subprocess.Popen(
            [str(proxy_bin), "--listen", f"127.0.0.1:{proxy_port}", "--hub-url", f"http://127.0.0.1:{hub_port}"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            wait_get(f"http://127.0.0.1:{hub_port}/api/v1/health")
            wait_get(f"http://127.0.0.1:{proxy_port}/api/v1/health")

            status, health = get_json(f"http://127.0.0.1:{hub_port}/api/v1/health")
            assert status == 200 and health["data"]["ok"] is True, health
            assert hub.poll() is None, "hub exited after health"

            status, noid = get_json(f"http://127.0.0.1:{hub_port}/api/v1/me")
            assert status == 401 and noid["error"]["code"] == "unauthenticated", noid

            status, me = get_json(
                f"http://127.0.0.1:{hub_port}/api/v1/me",
                {
                    "X-authentik-username": "tanmay",
                    "X-authentik-name": "Tanmay Vijay",
                    "X-authentik-email": "tanmay@example.com",
                },
            )
            assert status == 200 and me["data"]["user_id"] == "tanmay", me

            status, query_token = get_json(
                f"http://127.0.0.1:{hub_port}/api/v1/me?token=bad",
                {"X-authentik-username": "tanmay"},
            )
            assert status == 401 and query_token["error"]["message"] == "bearer tokens must use the Authorization header", query_token

            status, proxied = get_json(
                f"http://127.0.0.1:{proxy_port}/api/v1/me",
                {
                    "X-authentik-username": "spoofed",
                    "X-authentik-name": "Spoofed User",
                    "X-Dev-User": "reviewer",
                },
            )
            assert status == 200 and proxied["data"]["user_id"] == "reviewer", proxied
            assert proxied["data"]["display_name"] == "Reviewer User", proxied

            req = urllib.request.Request(f"http://127.0.0.1:{proxy_port}/_dev/login?user=tanmay")
            with urllib.request.urlopen(req, timeout=5) as resp:
                assert resp.status == 204
                assert "ham_dev_user=tanmay" in resp.headers.get("Set-Cookie", "")
            with urllib.request.urlopen(f"http://127.0.0.1:{proxy_port}/_dev/logout", timeout=5) as resp:
                assert resp.status == 204
                assert "Max-Age=0" in resp.headers.get("Set-Cookie", "")
        finally:
            for proc in (proxy, hub):
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()

    print("PASS: hub M1 real smoke")


if __name__ == "__main__":
    main()
