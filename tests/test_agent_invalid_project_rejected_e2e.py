#!/usr/bin/env python3
"""
Ensure an agent can NEVER be bound to a non-existent project, and that if one
somehow launches against a bad project the wrapper reports a concrete
startup_failed(invalid_project) instead of silently sticking at startup_unknown.

Checks:
  P0. SETUP     daemon boots; a real project exists.
  P1. START     POST /agents/start with a bogus project_id -> 400 (not launched).
  P2. CREATE    POST /agents/create with a bogus project_id -> 400.
  P3. UPDATE    create a valid agent, then update it to a bogus project_id -> 400.
  P4. ASSOCIATE POST /agents/associate with a bogus project_id -> 400.
  P5. CHAIN     POST /task-chains/create with a bogus project_id -> 400.
  P6. VALID     the same calls with a real project_id succeed (no false positives).

Opt-in: HEIMDALL_DAEMON_BIN or result-daemon/result symlink.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
PASSED = []


def ok(msg):
    PASSED.append(msg)
    print(f"  PASS: {msg}")


def require(cond, msg):
    if not cond:
        print(f"  FAIL: {msg}")
        raise SystemExit(1)


def daemon_bin():
    env = os.environ.get("HEIMDALL_DAEMON_BIN")
    if env and Path(env).exists():
        return env
    for c in ("result-daemon/bin/ham-daemon", "result/bin/ham-daemon"):
        p = ROOT / c
        if p.exists():
            return str(p)
    raise RuntimeError("missing ham-daemon; set HEIMDALL_DAEMON_BIN")


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def request(base, path, method="GET", body=None, headers=None, timeout=10.0):
    data = json.dumps(body).encode() if body is not None else None
    hdrs = {"Content-Type": "application/json"}
    if headers:
        hdrs.update(headers)
    req = Request(base + path, data=data, headers=hdrs, method=method)
    try:
        with urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except HTTPError as err:
        raw = err.read().decode()
        try:
            return err.code, json.loads(raw or "{}")
        except Exception:
            return err.code, {"raw": raw}
    except URLError as err:
        raise RuntimeError(f"{method} {path}: {err}") from err


def wait_health(base):
    for _ in range(200):
        try:
            st, b = request(base, "/health", timeout=5)
            if b.get("ok"):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError("daemon never healthy")


def write_config(path, port, data_dir):
    path.write_text(
        "\n".join([
            "[daemon]",
            'bind_host = "127.0.0.1"',
            f"port = {port}",
            f'data_dir = "{data_dir}"',
            'daemon_id = "proj-test"',
            "[guide_agent]",
            "enabled = false",
            "autostart = false",
            "restart_if_stopped = false",
        ]),
        encoding="utf-8",
    )


def main():
    daemon = daemon_bin()
    tmp = Path(tempfile.mkdtemp(prefix="agent-invalid-project-"))
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    cfg = tmp / "daemon.toml"
    write_config(cfg, port, tmp / "data")
    proc = subprocess.Popen([daemon, "--config", str(cfg)], cwd=str(ROOT),
                            stdout=(tmp / "daemon.log").open("w"), stderr=subprocess.STDOUT, text=True)
    try:
        wait_health(base)
        tok = request(base, "/user-client/register", "POST",
                      {"user_id": "op@local", "client_instance_id": "ui", "client_token": ""})[1]["client_token"]
        auth = {"Authorization": f"Bearer {tok}"}

        real = request(base, "/projects/create", "POST",
                       {"agent_token": tok, "project_id": "real-proj", "name": "Real Project"}, headers=auth)
        require(real[0] == 200, f"project create should succeed: {real}")
        ok("P0 daemon up; real project 'real-proj' created")

        BOGUS = "does-not-exist-proj"

        st, b = request(base, "/agents/start", "POST",
                        {"agent_instance_id": "worker@p1", "project_id": BOGUS, "project_id_set": True}, headers=auth)
        require(st == 400 and "does not exist" in json.dumps(b), f"start with bogus project must 400: {st} {b}")
        ok("P1 /agents/start with invalid project rejected (400, not launched)")

        st, b = request(base, "/agents/create", "POST",
                        {"agent_token": tok, "agent_id": "worker", "display_name": "worker@p2", "project_id": BOGUS}, headers=auth)
        require(st == 400 and "does not exist" in json.dumps(b), f"create with bogus project must 400: {st} {b}")
        ok("P2 /agents/create with invalid project rejected (400)")

        st, b = request(base, "/agents/create", "POST",
                        {"agent_token": tok, "agent_id": "worker", "display_name": "worker@ok", "project_id": "real-proj"}, headers=auth)
        require(st == 200, f"create with valid project should succeed: {st} {b}")
        good_instance = b["agent"]["agent_instance_id"]
        good_record = b["agent"]["agent_record_id"]

        st, b = request(base, "/agents/update", "POST",
                        {"agent_token": tok, "agent_instance_id": good_instance, "project_id": BOGUS}, headers=auth)
        require(st == 400 and "does not exist" in json.dumps(b), f"update to bogus project must 400: {st} {b}")
        ok("P3 /agents/update to invalid project rejected (400)")

        st, b = request(base, "/agents/associate", "POST",
                        {"agent_token": tok, "agent_record_id": good_record, "project_id": BOGUS}, headers=auth)
        require(st == 400 and "does not exist" in json.dumps(b), f"associate with bogus project must 400: {st} {b}")
        ok("P4 /agents/associate with invalid project rejected (400)")

        st, b = request(base, "/task-chains/create", "POST",
                        {"agent_token": tok, "kind": "coding", "title": "bad", "project_id": BOGUS}, headers=auth)
        require(st == 400 and "does not exist" in json.dumps(b), f"chain create with bogus project must 400: {st} {b}")
        ok("P5 /task-chains/create with invalid project rejected (400)")

        st, b = request(base, "/task-chains/create", "POST",
                        {"agent_token": tok, "kind": "coding", "title": "good", "project_id": "real-proj"}, headers=auth)
        require(st == 200 and b.get("chain_id"), f"chain create with valid project should succeed: {st} {b}")
        st, b = request(base, "/agents/associate", "POST",
                        {"agent_token": tok, "agent_record_id": good_record, "project_id": "real-proj"}, headers=auth)
        require(st == 200, f"associate with valid project should succeed: {st} {b}")
        ok("P6 same calls with a real project succeed (no false positives)")

        print("\nagent_invalid_project_rejected_e2e: ok")
        print(f"checks passed: {len(PASSED)}")
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        if os.environ.get("KEEP_LOGS"):
            print(f"logs kept: {tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
