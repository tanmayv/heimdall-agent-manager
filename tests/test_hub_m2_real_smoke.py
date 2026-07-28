#!/usr/bin/env python3
"""M2 smoke against real ham-hub binary for HBR-8/HBR-9/HBR-18 task lifecycle API."""
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
    hub_bin = Path(os.environ.get("HAM_HUB_BIN", "/tmp/ham-hub-phase2"))
    if not hub_bin.exists():
        raise SystemExit(f"missing HAM_HUB_BIN: {hub_bin}")
    port = free_port()
    alice = {"X-authentik-username": "alice", "X-authentik-name": "Alice"}
    bob = {"X-authentik-username": "bob", "X-authentik-name": "Bob"}
    with tempfile.TemporaryDirectory(prefix="ham-hub-m2-") as tmp:
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
            status, chain = request("POST", f"{base}/task-chains", {"title": "M2 Real Chain", "owner_user_id": "mallory"}, alice)
            assert status == 201 and chain["data"]["publish_state"] == "draft", chain
            chain_id = chain["data"]["chain_id"]
            status, bob_detail = request("GET", f"{base}/task-chains/{chain_id}", headers=bob)
            assert status == 404 and bob_detail["error"]["code"] == "not_found", bob_detail
            status, task = request("POST", f"{base}/task-chains/{chain_id}/tasks", {"title": "M2 Real Task"}, alice)
            assert status == 201 and task["data"]["publish_state"] == "draft", task
            task_id = task["data"]["task_id"]
            status, draft_nudge = request("POST", f"{base}/task-chains/{chain_id}/tasks/{task_id}/nudge", {"message": "wake"}, alice)
            assert status == 409 and draft_nudge["error"]["code"] == "conflict", draft_nudge
            status, publish_task_before_chain = request("POST", f"{base}/task-chains/{chain_id}/tasks/{task_id}/publish", headers=alice)
            assert status == 409, publish_task_before_chain
            status, other_chain = request("POST", f"{base}/task-chains", {"title": "Wrong Parent Chain"}, alice)
            assert status == 201, other_chain
            other_chain_id = other_chain["data"]["chain_id"]
            status, chain_pub = request("POST", f"{base}/task-chains/{chain_id}/publish", headers=alice)
            assert status == 200 and chain_pub["data"]["publish_state"] == "published" and chain_pub["data"]["status"] == "active", chain_pub
            status, wrong_parent_publish = request("POST", f"{base}/task-chains/{other_chain_id}/tasks/{task_id}/publish", headers=alice)
            assert status == 404 and wrong_parent_publish["error"]["code"] == "not_found", wrong_parent_publish
            status, task_pub = request("POST", f"{base}/task-chains/{chain_id}/tasks/{task_id}/publish", headers=alice)
            assert status == 200 and task_pub["data"]["status"] == "assigned", task_pub
            status, wrong_parent_status = request("POST", f"{base}/task-chains/{other_chain_id}/tasks/{task_id}/status", {"status": "in_progress"}, alice)
            assert status == 404 and wrong_parent_status["error"]["code"] == "not_found", wrong_parent_status
            status, wrong_parent_nudge = request("POST", f"{base}/task-chains/{other_chain_id}/tasks/{task_id}/nudge", {"message": "wrong"}, alice)
            assert status == 404 and wrong_parent_nudge["error"]["code"] == "not_found", wrong_parent_nudge
            for next_status in ["in_progress", "in_validation", "validated_not_good", "in_progress", "in_validation", "validated_good", "completed"]:
                status, transitioned = request("POST", f"{base}/task-chains/{chain_id}/tasks/{task_id}/status", {"status": next_status}, alice)
                assert status == 200 and transitioned["data"]["status"] == next_status, transitioned
            status, terminal = request("POST", f"{base}/task-chains/{chain_id}/tasks/{task_id}/status", {"status": "in_progress"}, alice)
            assert status == 409, terminal
            status, paused_task = request("POST", f"{base}/task-chains/{chain_id}/tasks", {"title": "Paused"}, alice)
            paused_id = paused_task["data"]["task_id"]
            request("POST", f"{base}/task-chains/{chain_id}/tasks/{paused_id}/publish", headers=alice)
            status, paused = request("POST", f"{base}/task-chains/{chain_id}/tasks/{paused_id}/status", {"status": "paused"}, alice)
            assert status == 200 and paused["data"]["unblocks_dependents"] is False, paused
            status, nudged_task = request("POST", f"{base}/task-chains/{chain_id}/tasks", {"title": "Nudged"}, alice)
            nudged_id = nudged_task["data"]["task_id"]
            request("POST", f"{base}/task-chains/{chain_id}/tasks/{nudged_id}/publish", headers=alice)
            status, nudge = request("POST", f"{base}/task-chains/{chain_id}/tasks/{nudged_id}/nudge", {"message": "ping"}, alice)
            assert status == 200 and nudge["data"]["nudged"] is True and nudge["data"]["target"] == "assignee", nudge
            status, tasks = request("GET", f"{base}/task-chains/{chain_id}/tasks", headers=alice)
            assert status == 200 and any(t["task_id"] == task_id and t["unblocks_dependents"] is True for t in tasks["data"]), tasks
            assert any(t["task_id"] == nudged_id and t["status"] == "assigned" for t in tasks["data"]), tasks
        finally:
            hub.terminate()
            try:
                hub.wait(timeout=3)
            except subprocess.TimeoutExpired:
                hub.kill()
    print("PASS: hub M2 real smoke")


if __name__ == "__main__":
    main()
