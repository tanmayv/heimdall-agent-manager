#!/usr/bin/env python3
"""Integration test suite for REQ-TCC-7: Agent task chain creation and pub/sub subscriptions.

Covers 6 scenarios:
1. Agent mode `ham-ctl task-chain create` creates a `team_work` chain, sets title/description,
   and launches coordinator on the specified bridge.
2. Agent mode `ham-ctl task-chain subscribe` registers subscription for `chain_status` and `task_status`.
3. Agent mode `ham-ctl task subscribe` registers subscription for a specific task.
4. Triggering a task status change dispatches `notify_task_nudge` to subscriber instances.
5. Triggering chain completion dispatches `notify_task_nudge` to chain subscribers.
6. `ham-ctl task-chain unsubscribe` and `ham-ctl task unsubscribe` cleanly deregister subscriptions.
"""

import hashlib
import json
import os
import pathlib
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
HUB_BIN = ROOT / "bin" / "ham-hub"
BRIDGE_BIN = ROOT / "bin" / "ham-bridge"
CTL_BIN = ROOT / "bin" / "ham-ctl"
MIGRATIONS = ROOT / "src" / "hub" / "repository" / "sqlite" / "migrations"


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def wait_for_port(port: int, timeout: float = 12.0) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def http_req(url: str, method: str = "GET", data=None, headers=None):
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            try:
                return resp.status, json.loads(raw.decode("utf-8"))
            except Exception:
                return resp.status, raw.decode("utf-8")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw.decode("utf-8"))
        except Exception:
            return e.code, raw.decode("utf-8")


def sha1_token(tok: str) -> str:
    return "sha1:" + hashlib.sha1(tok.encode("utf-8")).hexdigest()


def main() -> int:
    assert HUB_BIN.exists(), f"ham-hub not found at {HUB_BIN}"
    assert BRIDGE_BIN.exists(), f"ham-bridge not found at {BRIDGE_BIN}"
    assert CTL_BIN.exists(), f"ham-ctl not found at {CTL_BIN}"
    assert MIGRATIONS.exists(), f"migrations dir not found at {MIGRATIONS}"

    test_dir = pathlib.Path(tempfile.mkdtemp(prefix="ham-test-agent-tcc7-"))
    print(f"[*] Starting REQ-TCC-7 integration test in {test_dir}")

    hub_proc = None
    bridge_proc = None
    hub_log = None
    bridge_log = None

    try:
        db_path = test_dir / "hub.db"
        hub_port = free_port()
        hub_url = f"http://127.0.0.1:{hub_port}"
        bridge_port = free_port()
        bridge_endpoint_port = free_port()
        bridge_token_file = test_dir / "bridge_token"
        bridge_run_dir = test_dir / "bridge_run"
        bridge_run_dir.mkdir(parents=True, exist_ok=True)
        home_dir = test_dir / "home"
        home_dir.mkdir(parents=True, exist_ok=True)

        env = dict(os.environ)
        env["HOME"] = str(home_dir)
        env["USER"] = "testowner"
        env["HAM_CLOUDTOP_OWNER"] = "testowner"
        env["PATH"] = f"{ROOT / 'bin'}:{env.get('PATH', '')}"
        env["HEIMDALL_MOCK_GCERT_REMAINING_MINUTES"] = "1200"
        env.pop("HEIMDALL_VAULT_KEY", None)

        hub_log_path = test_dir / "hub.log"
        bridge_log_path = test_dir / "bridge.log"
        hub_log = open(hub_log_path, "w")
        bridge_log = open(bridge_log_path, "w")

        print(f"[*] Starting Hub on 127.0.0.1:{hub_port}...")
        hub_proc = subprocess.Popen(
            [
                "stdbuf", "-oL", "-eL",
                str(HUB_BIN),
                "--listen", f"127.0.0.1:{hub_port}",
                "--db", str(db_path),
                "--migrations-dir", str(MIGRATIONS),
                "--trusted-proxy-cidr", "127.0.0.1/32",
            ],
            env=env,
            stdout=hub_log,
            stderr=subprocess.STDOUT,
        )

        assert wait_for_port(hub_port), "Hub did not bind port within timeout"
        print("[*] Hub is ready!")

        auth_headers = {
            "X-authentik-username": "testowner",
            "X-authentik-name": "Test Owner",
        }

        # Provision user in DB
        now_iso = "2026-09-28T10:00:00Z"
        with sqlite3.connect(db_path) as conn:
            conn.execute(
                "INSERT OR IGNORE INTO users (user_id, name, display_name, email, status, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                ("testowner", "testowner", "Test Owner", "test@example.com", "active", now_iso, now_iso),
            )

        # Enroll bridge
        # ===== BROWSER-APPROVED DEVICE FLOW (REQ-ENROLL-9) =====
        #
        # Replaces the deleted pair: POST /api/v1/bridge-enrollments for a one-time
        # token, then POST /api/v1/bridges/enroll to exchange it. Both 404 now.
        #
        # Hard refusals: bridge_public_key must be a 130-char lowercase-hex
        # uncompressed P-256 point; bridge_key_fingerprint must NOT be sent (the Hub
        # derives it and refuses a disagreeing one); PKCE is mandatory and S256-only.
        # The authorize and token calls are ANONYMOUS -- the bridge makes them. Only
        # the approval is authenticated, and that is what binds the owner.
        st_az, az_data = http_req(
            f"{hub_url}/api/v1/device/authorize",
            method="POST",
            data={"client": "ham-bridge", "device_label": "test-bridge", "os": "linux",
                  "os_user": "tester", "bridge_public_key": "040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40",
                  "code_challenge": "J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI", "code_challenge_method": "S256"},
        )
        assert st_az == 200, f"device authorize failed: {st_az} {az_data}"
        user_code = az_data["data"]["user_code"]
        device_code = az_data["data"]["device_code"]
        st_ap, ap_data = http_req(
            f"{hub_url}/api/v1/device/approve",
            method="POST",
            data={"user_code": user_code, "approve": True},
            headers=auth_headers,
        )
        assert st_ap == 200, f"device approve failed: {st_ap} {ap_data}"
        st_tk, tk_data = http_req(
            f"{hub_url}/api/v1/device/token",
            method="POST",
            data={"device_code": device_code, "code_verifier": "heimdall-req-impl-6-test-code-verifier-aaaa"},
        )
        assert st_tk == 200, f"device token failed: {st_tk} {tk_data}"
        # Write the credential where the bridge expects it, instead of shelling out to
        # `bridge enroll --enrollment-token`, which is deleted.
        bridge_token_file.write_text(tk_data["data"]["access_token"])
        bridge_token_file.chmod(0o600)


        with sqlite3.connect(db_path) as conn:
            c = conn.cursor()
            c.execute("SELECT bridge_id FROM bridges WHERE bridge_id != 'brg_local' ORDER BY created_at DESC LIMIT 1")
            bridge_id = c.fetchone()[0]
        print(f"[*] Bridge enrolled: {bridge_id}")

        # Create coordinator template agent
        st_a, a_data = http_req(
            f"{hub_url}/api/v1/agents",
            method="POST",
            data={"name": "TestCoordinator", "default_provider": "claude", "default_tier": "normal"},
            headers=auth_headers,
        )
        assert st_a in (200, 201), f"Agent create failed: {st_a} {a_data}"
        agent_id = a_data["data"]["agent_id"]
        print(f"[*] Created coordinator agent: {agent_id}")

        # Setup caller instance and subscriber instance in SQLite
        caller_inst_id = "inst_caller_test"
        caller_token = "hlat_caller_tok_123"
        sub_inst_id = "inst_sub_test"
        sub_token = "hlat_sub_tok_456"

        with sqlite3.connect(db_path) as conn:
            for i_id, t_plain in [(caller_inst_id, caller_token), (sub_inst_id, sub_token)]:
                conn.execute(
                    """INSERT OR REPLACE INTO agent_instances
                       (agent_instance_id, owner_user_id, agent_id, bridge_id, display_name, provider, tier,
                        project_id, project_path, chain_id, conversation_id, runtime_status, startup_status,
                        activity_status, last_applied_seq, run_count, created_at, updated_at, started_at, last_seen_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (i_id, "testowner", agent_id, bridge_id, i_id, "claude", "normal",
                     "", "", "", f"chat_{i_id}", "running", "ready", "idle", 1, 1, now_iso, now_iso, now_iso, now_iso),
                )

        # Write bridge providers.json so bridge advertises claude capabilities
        bridge_providers_file = home_dir / ".local" / "share" / "heimdall" / "bridge" / "providers.json"
        bridge_providers_file.parent.mkdir(parents=True, exist_ok=True)
        bridge_providers_file.write_text(json.dumps({
            "default_provider": "claude",
            "default_tier": "normal",
            "providers": [
                {
                    "name": "claude",
                    "command": ["true"],
                    "enabled": True,
                    "models": {
                        "cheap": "claude-haiku",
                        "normal": "claude-sonnet",
                        "smart": "claude-opus",
                    },
                }
            ]
        }))

        # Write tokens to bridge token store
        run_dir_str = str(bridge_run_dir)
        slug = "".join([c if (c.isalnum() or c in "-_.") else "_" for c in run_dir_str])
        token_store_dir = home_dir / ".local" / "share" / "heimdall" / "bridge" / slug
        token_store_dir.mkdir(parents=True, exist_ok=True)
        token_file = token_store_dir / "local-tokens.jsonl"

        rec1 = {
            "token_hash": sha1_token(caller_token),
            "agent_instance_id": caller_inst_id,
            "instance_token": f"hit_{caller_inst_id}",
            "role": "agent",
            "issued_at_unix_ms": int(time.time() * 1000),
            "rotated_at_unix_ms": 0,
            "invalidated_at_unix_ms": 0,
        }
        rec2 = {
            "token_hash": sha1_token(sub_token),
            "agent_instance_id": sub_inst_id,
            "instance_token": f"hit_{sub_inst_id}",
            "role": "agent",
            "issued_at_unix_ms": int(time.time() * 1000),
            "rotated_at_unix_ms": 0,
            "invalidated_at_unix_ms": 0,
        }
        with open(token_file, "w") as f:
            f.write(json.dumps(rec1, separators=(',', ':')) + "\n")
            f.write(json.dumps(rec2, separators=(',', ':')) + "\n")

        # Start bridge
        bridge_data_dir = home_dir / ".local" / "share" / "heimdall"
        bridge_proc = subprocess.Popen(
            [
                "stdbuf", "-oL", "-eL",
                str(BRIDGE_BIN),
                "--bind-host", "127.0.0.1",
                "--port", str(bridge_port),
                "--local-endpoint-port", str(bridge_endpoint_port),
                "--hub", hub_url,
                "--bridge-token-file", str(bridge_token_file),
                "--daemon-id", bridge_id,
                "--local-run-dir", str(bridge_run_dir),
                "--data-dir", str(bridge_data_dir),
                "--agent-command", "true",
            ],
            env=env,
            stdout=bridge_log,
            stderr=subprocess.STDOUT,
        )

        assert wait_for_port(bridge_port), "Bridge did not bind HTTP port"
        time.sleep(1.0)
        print("[*] Bridge is running!")

        # Enable bridge support
        st_bs, bs_data = http_req(
            f"{hub_url}/api/v1/agents/{agent_id}/bridge-support/{bridge_id}",
            method="PATCH",
            data={"enabled": True, "provider": "claude", "tier": "normal"},
            headers=auth_headers,
        )
        assert st_bs == 200, f"Bridge support enablement failed: {st_bs} {bs_data}"

        endpoint = f"unix:{bridge_run_dir}/bridge.sock"

        # -------------------------------------------------------------------------
        # Scenario 1: Agent mode `ham-ctl task-chain create` creates a `team_work`
        # chain, sets title/description, and launches coordinator on the specified bridge.
        # -------------------------------------------------------------------------
        print("\n=== Scenario 1: task-chain create in agent mode ===")
        ctl_env_caller = dict(env)
        ctl_env_caller["HEIMDALL_BRIDGE_ENDPOINT"] = endpoint
        ctl_env_caller["HEIMDALL_AGENT_TOKEN"] = caller_token
        ctl_env_caller["HEIMDALL_AGENT_INSTANCE_ID"] = caller_inst_id

        res_create = subprocess.run(
            [
                str(CTL_BIN), "task-chain", "create",
                "--title", "E2E Subscription Test Chain",
                "--description", "Testing chain create and pub/sub notifications",
                "--coordinator", agent_id,
                "--bridge", bridge_id,
                "--kind", "team_work",
            ],
            env=ctl_env_caller,
            capture_output=True,
            text=True,
        )
        assert res_create.returncode == 0, f"task-chain create failed: {res_create.stderr}"

        create_json = json.loads(res_create.stdout)
        chain_data = create_json.get("data", {}).get("data", {}) or create_json.get("data", {})
        chain_id = chain_data.get("chain_id")
        assert chain_id and chain_id.startswith("chain_"), f"Unexpected chain_id: {chain_id}"
        assert chain_data.get("title") == "E2E Subscription Test Chain", f"Title mismatch: {chain_data.get('title')}"
        assert chain_data.get("description") == "Testing chain create and pub/sub notifications"
        assert chain_data.get("kind") == "team_work", f"Kind mismatch: {chain_data.get('kind')}"
        coord_inst = chain_data.get("coordinator_agent_instance_id")
        assert coord_inst and coord_inst.startswith("inst_"), f"Unexpected coord_inst: {coord_inst}"
        print(f"[PASS] Scenario 1: Created chain {chain_id} with coordinator {coord_inst}")

        coord_run_dir = bridge_run_dir / "instances" / coord_inst
        coord_ctl = coord_run_dir / ".heimdall" / "bin" / "ham-ctl"
        start_wait = time.time()
        while time.time() - start_wait < 5.0:
            if coord_ctl.exists():
                break
            time.sleep(0.1)
        assert coord_ctl.exists(), "Coordinator wrapper script not found"

        tok_match = re.search(r"export HEIMDALL_AGENT_TOKEN='([^']+)'", coord_ctl.read_text())
        assert tok_match, "Coordinator token not found in wrapper"
        coord_token = tok_match.group(1)

        ctl_env_coord = dict(env)
        ctl_env_coord["HEIMDALL_BRIDGE_ENDPOINT"] = endpoint
        ctl_env_coord["HEIMDALL_AGENT_TOKEN"] = coord_token
        ctl_env_coord["HEIMDALL_AGENT_INSTANCE_ID"] = coord_inst

        ctl_env_sub = dict(env)
        ctl_env_sub["HEIMDALL_BRIDGE_ENDPOINT"] = endpoint
        ctl_env_sub["HEIMDALL_AGENT_TOKEN"] = sub_token
        ctl_env_sub["HEIMDALL_AGENT_INSTANCE_ID"] = sub_inst_id

        # -------------------------------------------------------------------------
        # Scenario 2: Agent mode `ham-ctl task-chain subscribe` registers subscription
        # for `chain_status` and `task_status`.
        # -------------------------------------------------------------------------
        print("\n=== Scenario 2: task-chain subscribe in agent mode ===")
        res_sub_chain = subprocess.run(
            [str(CTL_BIN), "task-chain", "subscribe", chain_id, "--events", "chain_status"],
            env=ctl_env_sub,
            capture_output=True,
            text=True,
        )
        assert res_sub_chain.returncode == 0, f"task-chain subscribe chain_status failed: {res_sub_chain.stderr}"

        res_sub_task_events = subprocess.run(
            [str(CTL_BIN), "task-chain", "subscribe", chain_id, "--events", "task_status"],
            env=ctl_env_sub,
            capture_output=True,
            text=True,
        )
        assert res_sub_task_events.returncode == 0, f"task-chain subscribe task_status failed: {res_sub_task_events.stderr}"

        with sqlite3.connect(db_path) as conn:
            c = conn.cursor()
            c.execute(
                "SELECT subscription_id, event_type FROM task_subscriptions "
                "WHERE chain_id = ? AND subscriber_agent_instance_id = ? AND task_id = '' ORDER BY event_type",
                (chain_id, sub_inst_id),
            )
            rows = c.fetchall()
            assert len(rows) == 2, f"Expected 2 chain subscriptions, got {rows}"
            assert rows[0][1] == "chain_status"
            assert rows[1][1] == "task_status"
        print(f"[PASS] Scenario 2: Subscribed to chain events (chain_status, task_status) on {chain_id}")

        # Publish chain so tasks can be created and executed
        res_pub = subprocess.run(
            [str(CTL_BIN), "task-chain", "publish", chain_id],
            env=ctl_env_coord,
            capture_output=True,
            text=True,
        )
        assert res_pub.returncode == 0, f"task-chain publish failed: {res_pub.stderr}"

        # -------------------------------------------------------------------------
        # Scenario 3: Agent mode `ham-ctl task subscribe` registers subscription for
        # a specific task.
        # -------------------------------------------------------------------------
        print("\n=== Scenario 3: task subscribe in agent mode ===")
        res_create_task = subprocess.run(
            [str(CTL_BIN), "task", "create", "--title", "E2E Subscription Test Task", "--chain", chain_id],
            env=ctl_env_coord,
            capture_output=True,
            text=True,
        )
        assert res_create_task.returncode == 0, f"task create failed: {res_create_task.stderr}"
        task_json = json.loads(res_create_task.stdout)
        task_data = task_json.get("data", {}).get("data", {}) or task_json.get("data", {})
        task_id = task_data.get("task_id")
        assert task_id and task_id.startswith("task_"), f"Unexpected task_id: {task_id}"

        res_sub_task = subprocess.run(
            [str(CTL_BIN), "task", "subscribe", task_id, "--events", "task_status"],
            env=ctl_env_sub,
            capture_output=True,
            text=True,
        )
        assert res_sub_task.returncode == 0, f"task subscribe failed: {res_sub_task.stderr}"

        with sqlite3.connect(db_path) as conn:
            c = conn.cursor()
            c.execute(
                "SELECT subscription_id, event_type, task_id FROM task_subscriptions "
                "WHERE task_id = ? AND subscriber_agent_instance_id = ?",
                (task_id, sub_inst_id),
            )
            row = c.fetchone()
            assert row is not None, "Task subscription not found in DB"
            assert row[1] == "task_status"
            assert row[2] == task_id
        print(f"[PASS] Scenario 3: Subscribed to task events on {task_id}")

        # -------------------------------------------------------------------------
        # Scenario 4: Triggering a task status change dispatches `notify_task_nudge`
        # to subscriber instances.
        # -------------------------------------------------------------------------
        print("\n=== Scenario 4: Task status change dispatches notify_task_nudge ===")
        res_status = subprocess.run(
            [str(CTL_BIN), "task", "status", task_id, "--status", "in_progress"],
            env=ctl_env_coord,
            capture_output=True,
            text=True,
        )
        assert res_status.returncode == 0, f"task status failed: {res_status.stderr}"

        found_task_nudge = False
        start_poll = time.time()
        while time.time() - start_poll < 5.0:
            bridge_log.flush()
            if bridge_log_path.exists():
                log_content = bridge_log_path.read_text()
                if "notify_task_nudge" in log_content and sub_inst_id in log_content:
                    found_task_nudge = True
                    break
            time.sleep(0.1)
        assert found_task_nudge, f"notify_task_nudge for {sub_inst_id} not received by bridge"
        print(f"[PASS] Scenario 4: notify_task_nudge delivered to subscriber {sub_inst_id} on task status change")

        # -------------------------------------------------------------------------
        # Scenario 5: Triggering chain completion dispatches `notify_task_nudge`
        # to chain subscribers.
        # -------------------------------------------------------------------------
        print("\n=== Scenario 5: Chain completion dispatches notify_task_nudge ===")
        bridge_log.flush()
        log_pos_before = len(bridge_log_path.read_text())

        res_chain_complete = subprocess.run(
            [str(CTL_BIN), "task-chain", "set-status", "completed", "--chain", chain_id],
            env=ctl_env_coord,
            capture_output=True,
            text=True,
        )
        assert res_chain_complete.returncode == 0, f"task-chain set-status failed: {res_chain_complete.stderr}"

        found_chain_nudge = False
        start_poll = time.time()
        while time.time() - start_poll < 5.0:
            bridge_log.flush()
            if bridge_log_path.exists():
                log_slice = bridge_log_path.read_text()[log_pos_before:]
                if "notify_task_nudge" in log_slice and sub_inst_id in log_slice:
                    found_chain_nudge = True
                    break
            time.sleep(0.1)
        assert found_chain_nudge, f"notify_task_nudge for {sub_inst_id} on chain completion not received by bridge"
        print(f"[PASS] Scenario 5: notify_task_nudge delivered to subscriber {sub_inst_id} on chain completion")

        # -------------------------------------------------------------------------
        # Scenario 6: `ham-ctl task-chain unsubscribe` and `ham-ctl task unsubscribe`
        # cleanly deregister subscriptions.
        # -------------------------------------------------------------------------
        print("\n=== Scenario 6: task-chain and task unsubscribe cleanly deregister ===")
        res_unsub_chain_status = subprocess.run(
            [str(CTL_BIN), "task-chain", "unsubscribe", chain_id, "--events", "chain_status"],
            env=ctl_env_sub,
            capture_output=True,
            text=True,
        )
        assert res_unsub_chain_status.returncode == 0, f"task-chain unsubscribe chain_status failed: {res_unsub_chain_status.stderr}"

        res_unsub_task_events = subprocess.run(
            [str(CTL_BIN), "task-chain", "unsubscribe", chain_id, "--events", "task_status"],
            env=ctl_env_sub,
            capture_output=True,
            text=True,
        )
        assert res_unsub_task_events.returncode == 0, f"task-chain unsubscribe task_status failed: {res_unsub_task_events.stderr}"

        res_unsub_task = subprocess.run(
            [str(CTL_BIN), "task", "unsubscribe", task_id, "--events", "task_status"],
            env=ctl_env_sub,
            capture_output=True,
            text=True,
        )
        assert res_unsub_task.returncode == 0, f"task unsubscribe failed: {res_unsub_task.stderr}"

        with sqlite3.connect(db_path) as conn:
            c = conn.cursor()
            c.execute("SELECT count(*) FROM task_subscriptions WHERE subscriber_agent_instance_id = ?", (sub_inst_id,))
            remaining = c.fetchone()[0]
            assert remaining == 0, f"Expected 0 subscriptions remaining for {sub_inst_id}, got {remaining}"
        print(f"[PASS] Scenario 6: Subscriptions cleanly deregistered (remaining: 0)")

        print("\n=======================================================")
        print("ALL 6 INTEGRATION SCENARIOS PASSED WITH HIGH CONFIDENCE")
        print("=======================================================")
        return 0

    finally:
        if bridge_proc:
            bridge_proc.terminate()
            try:
                bridge_proc.wait(timeout=2.0)
            except Exception:
                bridge_proc.kill()
        if hub_proc:
            hub_proc.terminate()
            try:
                hub_proc.wait(timeout=2.0)
            except Exception:
                hub_proc.kill()
        if bridge_log:
            bridge_log.close()
        if hub_log:
            hub_log.close()
        shutil.rmtree(test_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
