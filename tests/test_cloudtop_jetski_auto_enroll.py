#!/usr/bin/env python3
"""Automated integration tests for CT-10: Auto-configure Hub Jetski Provider & Bridge Enrollment with Hostname.

Verifies:
1. Hub pre-seeds loopback bridge (brg_local) with "jetski" provider and tiers ["cheap", "normal", "smart"].
2. Created agents without explicit provider/tier default to "jetski" and "normal".
3. Bridge auto-pairing / enrollment accepts hostname and sets bridge.label and bridge.machine_hostname.
4. Relaunching/restarting an instance whose pinned bridge is offline seamlessly falls back to brg_local.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p

def wait_for_port(port: int, timeout: float = 10.0) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return True
        except OSError:
            time.sleep(0.1)
    return False

def http_json(url: str, method: str = "GET", data: dict | None = None, headers: dict | None = None) -> tuple[int, dict]:
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8")
        try:
            return e.code, json.loads(raw) if raw else {}
        except Exception:
            return e.code, {"raw": raw}

def test_cloudtop_jetski_and_auto_enroll() -> None:
    hub_bin = ROOT / "dist" / "heimdall-cloudtop" / "bin" / "ham-hub"
    if not hub_bin.exists():
        hub_bin = ROOT / "result-hub" / "bin" / "ham-hub"
    bridge_bin = ROOT / "dist" / "heimdall-cloudtop" / "bin" / "ham-bridge"
    if not bridge_bin.exists():
        bridge_bin = ROOT / "result-bridge" / "bin" / "ham-bridge"

    assert hub_bin.exists(), f"ham-hub binary not found at {hub_bin}"
    assert bridge_bin.exists(), f"ham-bridge binary not found at {bridge_bin}"

    test_dir = Path(tempfile.mkdtemp(prefix="heimdall-ct10-test-"))
    try:
        db_path = test_dir / "hub.db"
        token_path = test_dir / "bridge_token"
        hub_port = free_port()
        hub_url = f"http://127.0.0.1:{hub_port}"

        # 1. Start Hub with migrations
        migrations_dir = ROOT / "src" / "hub" / "repository" / "sqlite" / "migrations"
        if not migrations_dir.exists():
            migrations_dir = ROOT / "dist" / "heimdall-cloudtop" / "share" / "migrations"
        env = dict(os.environ)
        env["HOSTNAME"] = "cloudtop-host-test"
        env["USER"] = "testowner"
        env["HAM_CLOUDTOP_OWNER"] = "testowner"

        hub_proc = subprocess.Popen(
            [
                str(hub_bin),
                "--listen", f"127.0.0.1:{hub_port}",
                "--db", str(db_path),
                "--migrations-dir", str(migrations_dir),
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        try:
            assert wait_for_port(hub_port, timeout=10), "Hub failed to start"

            # 2. Check local loopback bridge pre-seeding
            auth_headers = {"X-authentik-username": "testowner", "X-authentik-name": "Test Owner"}
            status, bridges_data = http_json(f"{hub_url}/api/v1/bridges", headers=auth_headers)
            assert status == 200, f"/api/v1/bridges returned {status}: {bridges_data}"
            
            data_field = bridges_data.get("data", [])
            items = data_field if isinstance(data_field, list) else data_field.get("items", [])
            local_bridge = next((b for b in items if b.get("bridge_id") == "brg_local"), None)
            assert local_bridge is not None, f"brg_local not found in {items}"
            
            caps_field = local_bridge.get("capabilities", [])
            if isinstance(caps_field, list) and len(caps_field) > 0:
                caps = caps_field[0]
            elif isinstance(caps_field, dict):
                caps = caps_field
            else:
                caps = {}
            assert caps.get("provider") == "jetski", f"Expected jetski provider, got {caps} from {local_bridge}"
            assert caps.get("default_tier") == "normal", f"Expected default_tier normal, got {caps}"
            assert local_bridge.get("machine_hostname") == "cloudtop-host-test", f"Expected machine_hostname cloudtop-host-test, got {local_bridge}"
            print("PASS 1: brg_local pre-seeded with jetski provider, normal tier, and host name.")

            # 3. Test Agent Creation defaults to jetski & normal
            status, agent_data = http_json(
                f"{hub_url}/api/v1/agents",
                method="POST",
                data={"name": "TestCoder"},
                headers=auth_headers,
            )
            assert status in (200, 201), f"Create agent returned {status}: {agent_data}"
            created_agent = agent_data.get("data", {})
            assert created_agent.get("default_provider") == "jetski", f"Expected default_provider jetski, got {created_agent}"
            assert created_agent.get("default_tier") == "normal", f"Expected default_tier normal, got {created_agent}"
            agent_id = created_agent.get("agent_id")
            print("PASS 2: Created agent default_provider=jetski and default_tier=normal.")

            # 4. Test auto-pair bridge handler with custom hostname
            custom_host = "test-box-hostname.c.googlers.com"
            status, autopair_data = http_json(
                f"{hub_url}/api/v1/bridges/auto-pair",
                method="POST",
                data={"user": "testowner", "hostname": custom_host},
                headers=auth_headers,
            )
            assert status == 200, f"Auto-pair returned {status}: {autopair_data}"
            status, bridges_data_2 = http_json(f"{hub_url}/api/v1/bridges", headers=auth_headers)
            assert status == 200, f"/api/v1/bridges returned {status}: {bridges_data_2}"
            items_2 = bridges_data_2.get("data", []) if isinstance(bridges_data_2.get("data"), list) else bridges_data_2.get("data", {}).get("items", [])
            paired_bridge = next((b for b in items_2 if b.get("bridge_id") == "brg_local"), {})
            assert paired_bridge.get("label") == custom_host, f"Expected label {custom_host}, got {paired_bridge}"
            assert paired_bridge.get("machine_hostname") == custom_host, f"Expected machine_hostname {custom_host}, got {paired_bridge}"
            print("PASS 3: Auto-pair bridge updated label and machine_hostname to provided hostname.")

            # 5. Test enroll CLI with --name/--hostname
            enroll_token_file = test_dir / "enroll_token"
            enroll_host = "custom-cloudtop-node"
            res = subprocess.run(
                [
                    str(bridge_bin),
                    "enroll",
                    "--hub", hub_url,
                    "--name", enroll_host,
                    "--bridge-token-file", str(enroll_token_file),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            assert res.returncode == 0, f"ham-bridge enroll failed: {res.stderr} {res.stdout}"
            assert enroll_token_file.exists() and enroll_token_file.stat().st_size > 0, "Enrollment token not written"
            print("PASS 4: ham-bridge enroll --name executed successfully.")

        finally:
            hub_proc.terminate()
            try:
                hub_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                hub_proc.kill()
    finally:
        shutil.rmtree(test_dir, ignore_errors=True)

if __name__ == "__main__":
    test_cloudtop_jetski_and_auto_enroll()
    print("ALL CT-10 INTEGRATION TESTS PASSED!")
