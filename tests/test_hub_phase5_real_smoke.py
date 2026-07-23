#!/usr/bin/env python3
"""Phase 5 real-binary smoke for Bridge enrollment, owner scope, and bearer auth."""
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


def request(method: str, url: str, body: dict | None = None, headers: dict[str, str] | None = None) -> tuple[int, dict]:
    data = None if body is None else json.dumps(body).encode()
    req_headers = {"Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode())


def main() -> None:
    hub_bin = Path(os.environ.get("HAM_HUB_BIN", "/tmp/ham-hub-phase5"))
    if not hub_bin.exists():
        raise SystemExit(f"missing HAM_HUB_BIN: {hub_bin}")
    port = free_port()
    alice = {"X-authentik-username": "alice", "X-authentik-name": "Alice"}
    bob = {"X-authentik-username": "bob", "X-authentik-name": "Bob"}
    with tempfile.TemporaryDirectory(prefix="ham-hub-p5-") as tmp:
        db_path = Path(tmp) / "hub.db"
        hub = subprocess.Popen(
            [str(hub_bin), "--listen", f"127.0.0.1:{port}", "--db", str(db_path), "--logout-url", "/_dev/logout"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        base = f"http://127.0.0.1:{port}/api/v1"
        try:
            wait_get(f"{base}/health")
            status, created = request("POST", f"{base}/bridge-enrollments", {"label": "Alice Mac", "expires_in_seconds": 900}, alice)
            assert status == 201 and created["data"]["enrollment_token"].startswith("hbe_"), created
            assert created["data"]["expires_at"] != "9999-12-31T23:59:59Z" and created["data"]["expires_at"].startswith("20"), created
            token = created["data"]["enrollment_token"]
            status, unlabeled = request("POST", f"{base}/bridge-enrollments", {"expires_in_seconds": 900}, alice)
            assert status == 201 and unlabeled["data"]["enrollment_token"].startswith("hbe_"), unlabeled
            unlabeled_token = unlabeled["data"]["enrollment_token"]
            status, expires_at_bypass = request("POST", f"{base}/bridge-enrollments", {"expires_at": "9999-12-31T23:59:59Z"}, alice)
            assert status == 400 and expires_at_bypass["error"]["code"] == "validation_failed", expires_at_bypass
            status, short_lived = request("POST", f"{base}/bridge-enrollments", {"expires_in_seconds": 1}, alice)
            assert status == 201, short_lived
            short_token = short_lived["data"]["enrollment_token"]
            time.sleep(2)
            status, expired_enroll = request("POST", f"{base}/bridges/enroll", {"machine": {"hostname": "expired"}}, {"Authorization": f"Bearer {short_token}"})
            assert status == 409 and expired_enroll["error"]["code"] == "conflict", expired_enroll
            status, listed_enrollments = request("GET", f"{base}/bridge-enrollments", headers=alice)
            assert status == 200 and token not in json.dumps(listed_enrollments) and unlabeled_token not in json.dumps(listed_enrollments), listed_enrollments
            status, revocable = request("POST", f"{base}/bridge-enrollments", {"label": "Revocable"}, alice)
            revocable_id = revocable["data"]["enrollment_id"]
            status, revoked_enrollment = request("DELETE", f"{base}/bridge-enrollments/{revocable_id}", headers=alice)
            assert status == 200 and revoked_enrollment["data"]["status"] == "revoked", revoked_enrollment
            tunnel_hub = f"http://localhost:{port}"
            status, enrolled = request(
                "POST",
                f"{base}/bridges/enroll",
                {"hub_url": tunnel_hub, "machine": {"hostname": "alice-host", "os": "macos", "arch": "arm64"}},
                {"Authorization": f"Bearer {token}"},
            )
            assert status == 201 and enrolled["data"]["bridge_token"].startswith("hbr_") and enrolled["data"]["hub_url"] == tunnel_hub, enrolled
            bridge_id = enrolled["data"]["bridge_id"]
            bridge_token = enrolled["data"]["bridge_token"]
            bridge_auth = {"Authorization": f"Bearer {bridge_token}"}
            status, default_labeled = request(
                "POST",
                f"{base}/bridges/enroll",
                {"machine": {"hostname": "default-host", "os": "linux", "arch": "amd64"}},
                {"Authorization": f"Bearer {unlabeled_token}"},
            )
            assert status == 201 and default_labeled["data"]["bridge_id"].startswith("brg_"), default_labeled
            default_bridge_id = default_labeled["data"]["bridge_id"]
            status, default_bridge_detail = request("GET", f"{base}/bridges/{default_bridge_id}", headers=alice)
            assert status == 200 and default_bridge_detail["data"]["label"] == "default-host" and default_bridge_detail["data"]["label_is_user_customized"] is False, default_bridge_detail
            status, bridge_detail_hub = request("GET", f"{base}/bridges/{bridge_id}", headers=alice)
            assert status == 200 and bridge_detail_hub["data"]["hub_url"] == tunnel_hub, bridge_detail_hub
            status, https_enr = request("POST", f"{base}/bridge-enrollments", {"label": "HTTPS direct"}, alice)
            assert status == 201, https_enr
            https_hub = f"https://127.0.0.1:{port}"
            status, https_enrolled = request("POST", f"{base}/bridges/enroll", {"hub_url": https_hub, "machine": {"hostname": "https-ok"}}, {"Authorization": f"Bearer {https_enr['data']['enrollment_token']}"})
            assert status == 201 and https_enrolled["data"]["hub_url"] == https_hub, https_enrolled
            status, reject_wss_enr = request("POST", f"{base}/bridge-enrollments", {"label": "Reject WSS"}, alice)
            assert status == 201, reject_wss_enr
            status, reject_wss = request("POST", f"{base}/bridges/enroll", {"hub_url": f"wss://127.0.0.1:{port}", "machine": {"hostname": "wss-bad"}}, {"Authorization": f"Bearer {reject_wss_enr['data']['enrollment_token']}"})
            assert status == 400 and reject_wss["error"]["code"] == "validation_failed", reject_wss
            bridge_bin = Path(os.environ.get("HAM_BRIDGE_BIN", ""))
            if bridge_bin.exists():
                status, cli_enr = request("POST", f"{base}/bridge-enrollments", {"label": "CLI tunnel"}, alice)
                assert status == 201, cli_enr
                cli_hub = f"http://127.0.0.1:{port}"
                cfg = Path(tmp) / "bridge-cli.toml"
                out = subprocess.run([str(bridge_bin), "enroll", "--config", str(cfg), "--hub", cli_hub, "--enrollment-token", cli_enr["data"]["enrollment_token"]], cwd=ROOT, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
                assert cli_hub in cfg.read_text() and "bridge enrolled" in out, out
                bad_cfg = Path(tmp) / "bridge-cli-wss.toml"
                bad = subprocess.run([str(bridge_bin), "enroll", "--config", str(bad_cfg), "--hub", f"wss://127.0.0.1:{port}", "--enrollment-token", "hbe_fake"], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                assert bad.returncode != 0 and "http:// or https://" in bad.stdout and not bad_cfg.exists(), bad.stdout
            status, reuse = request("POST", f"{base}/bridges/enroll", {"machine": {"hostname": "reuse"}}, {"Authorization": f"Bearer {token}"})
            assert status == 409, reuse
            status, query_token = request("POST", f"{base}/bridges/enroll?token={token}", {"machine": {"hostname": "bad"}})
            assert status == 401, query_token
            status, body_token = request("POST", f"{base}/bridges/enroll", {"token": token, "machine": {"hostname": "bad-body"}})
            assert status == 401, body_token
            status, bridges = request("GET", f"{base}/bridges", headers=alice)
            assert status == 200 and any(b["bridge_id"] == bridge_id for b in bridges["data"]), bridges
            status, bob_bridges = request("GET", f"{base}/bridges", headers=bob)
            assert status == 200 and not any(b["bridge_id"] == bridge_id for b in bob_bridges["data"]), bob_bridges
            status, bob_detail = request("GET", f"{base}/bridges/{bridge_id}", headers=bob)
            assert status == 404, bob_detail
            status, token_detail = request("GET", f"{base}/bridges/{bridge_id}", headers=bridge_auth)
            assert status == 200 and token_detail["data"]["bridge_id"] == bridge_id, token_detail
            status, token_wrong_detail = request("GET", f"{base}/bridges/brg_wrong", headers=bridge_auth)
            assert status == 404, token_wrong_detail
            status, token_list = request("GET", f"{base}/bridges", headers=bridge_auth)
            assert status == 403, token_list
            status, token_me = request("GET", f"{base}/me", headers=bridge_auth)
            assert status == 403, token_me
            status, body_bridge_token = request("POST", f"{base}/bridges/{bridge_id}/revoke", {"token": bridge_token})
            assert status == 401, body_bridge_token
            status, renamed = request("PATCH", f"{base}/bridges/{bridge_id}", {"label": "Work Mac"}, alice)
            assert status == 200 and renamed["data"]["label_is_user_customized"] is True, renamed
            status, revoked = request("POST", f"{base}/bridges/{bridge_id}/revoke", headers=alice)
            assert status == 200 and revoked["data"]["status"] == "revoked", revoked
            status, revoked_token_detail = request("GET", f"{base}/bridges/{bridge_id}", headers=bridge_auth)
            assert status == 403, revoked_token_detail
        finally:
            hub.terminate()
            try:
                hub.wait(timeout=3)
            except subprocess.TimeoutExpired:
                hub.kill()
    print("PASS: hub phase5 real smoke")


if __name__ == "__main__":
    main()
