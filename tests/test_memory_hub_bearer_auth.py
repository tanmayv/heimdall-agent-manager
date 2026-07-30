#!/usr/bin/env python3
"""Regression: Memory UI/auth path uses ham-hub Bearer auth.

The UI should call /memory/* endpoints with Authorization: Bearer <client token>
instead of relying on deprecated body-token /user-rpc memory mutations.
"""

import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
ROOT = Path(__file__).resolve().parents[1]


def binary_path() -> str:
    env = os.environ.get("HEIMDALL_HUB_BIN")
    if env:
        if os.path.exists(env):
            return env
        raise RuntimeError(f"HEIMDALL_HUB_BIN points to missing binary: {env}")
    for rel in ("result-hub/bin/ham-hub", "result/bin/ham-hub"):
        path = ROOT / rel
        if path.exists():
            return str(path)
    raise RuntimeError("missing ham-hub; set HEIMDALL_HUB_BIN or build .#ham-hub")


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind((HOST, 0))
        return sock.getsockname()[1]


def request(method: str, base: str, path: str, body=None, token: str = "", allow_error: bool = False):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"{base}{path}", data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            payload = res.read().decode("utf-8")
            return res.status, json.loads(payload) if payload else {}
    except urllib.error.HTTPError as err:
        payload = err.read().decode("utf-8")
        if allow_error:
            return err.code, json.loads(payload) if payload else {}
        raise


def wait_for_health(base: str):
    for _ in range(80):
        try:
            if request("GET", base, "/health")[0] == 200:
                return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("ham-hub did not become healthy")


def main():
    hub = binary_path()
    port = free_port()
    base = f"http://{HOST}:{port}"
    temp_dir = Path(tempfile.mkdtemp(prefix="heimdall-memory-bearer-"))
    cfg = temp_dir / "hub.toml"
    cfg.write_text(f'''
[daemon]
bind_host = "{HOST}"
port = {port}
data_dir = "{temp_dir}/data"
user_id = "operator@local"

[guide_agent]
enabled = false
autostart = false
restart_if_stopped = false
''', encoding="utf-8")
    log_file = open(temp_dir / "hub.log", "w", encoding="utf-8")
    proc = subprocess.Popen([hub, "--config", str(cfg)], cwd=str(ROOT), stdout=log_file, stderr=subprocess.STDOUT)
    try:
        wait_for_health(base)
        _, user = request("POST", base, "/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "memory-ui-auth",
            "client_token": "",
        })
        token = user["client_token"]

        status, unauth = request("POST", base, "/memory/list", {"include_all_statuses": True}, allow_error=True)
        assert status == 401, unauth

        status, proposed = request("POST", base, "/memory/propose/new", {
            "type": "fact",
            "title": "Bearer memory auth smoke",
            "body": "v1",
            "reason": "test",
            "evidence": "test",
        }, token=token)
        assert status == 200 and proposed.get("ok") is True, proposed

        status, approved = request("POST", base, "/memory/decide", {
            "proposal_id": proposed["proposal_id"],
            "decision": "approve",
            "reason": "approve bearer smoke",
        }, token=token)
        assert status == 200 and approved.get("ok") is True, approved

        status, shown = request("POST", base, "/memory/show", {"memory_id": proposed["memory_id"]}, token=token)
        assert status == 200 and shown.get("record", {}).get("status") == "active", shown
        version = shown["record"]["version"]

        status, edited = request("POST", base, "/memory/propose/edit", {
            "memory_id": proposed["memory_id"],
            "expected_version": version,
            "type": "fact",
            "title": "Bearer memory auth smoke edited",
            "body": "v2",
            "reason": "test edit",
            "evidence": "test",
        }, token=token)
        assert status == 200 and edited.get("ok") is True, edited

        print(json.dumps({
            "ok": True,
            "memory_id": proposed["memory_id"],
            "edit_proposal_id": edited["proposal_id"],
        }, indent=2, sort_keys=True))
        print("memory_hub_bearer_auth: ok")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
        log_file.close()
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp_dir}")
        else:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
