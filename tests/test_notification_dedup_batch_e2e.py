#!/usr/bin/env python3
"""
Two fixes for the "late agent bombarded with task nudges" problem:

  1. DEDUP: while an agent is offline, repeated notifications for the SAME task
     supersede prior undelivered ones, so the outbox holds at most one live row
     per task (not one per nudge/status change).
  2. SINGLE MESSAGE: on reconnect the whole pending backlog is delivered as ONE
     task_event_batch message, not N separate task_event injections.

Checks:
  N0. SETUP     daemon up; project/chain; agent + coordinator registered.
  N1. DEDUP     repeatedly nudge one offline task -> outbox keeps exactly 1 pending
                row for that (recipient, task).
  N2. MULTI     three offline tasks each nudged several times -> 3 pending rows
                (one per task, not per nudge).
  N3. BATCH     on reconnect the agent receives a single task_event_batch whose
                events[] has one entry per task.

Opt-in: HEIMDALL_DAEMON_BIN or result-daemon/result symlink.
"""
import json
import os
import shutil
import socket
import sqlite3
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


def request(base, path, body=None, timeout=10.0):
    data = json.dumps(body).encode() if body is not None else None
    req = Request(base + path, data=data, headers={"Content-Type": "application/json"}, method="POST" if body is not None else "GET")
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
        raise RuntimeError(f"{path}: {err}") from err


def wait_health(base):
    for _ in range(200):
        try:
            st, b = request(base, "/health")
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
            'daemon_id = "notif-test"',
            # Disable the nudge scheduler so this test controls exactly how many
            # notifications get queued (no background nudges racing our asserts).
            "nudge_enabled = false",
            "[guide_agent]",
            "enabled = false",
            "autostart = false",
            "restart_if_stopped = false",
        ]),
        encoding="utf-8",
    )


def ws_handshake(agent_id, host, port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((host, port))
    hs = (
        f"GET /ws/{agent_id} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    s.sendall(hs.encode())
    resp = s.recv(4096)
    end = resp.find(b"\r\n\r\n")
    require(end >= 0 and b"101 Switching Protocols" in resp[:end], "ws upgrade failed")
    return s, resp[end + 4:]


def recv_ws_text(s, initial=b""):
    buf = initial

    def read_exactly(n):
        nonlocal buf
        while len(buf) < n:
            chunk = s.recv(n - len(buf))
            if not chunk:
                break
            buf += chunk
        r = buf[:n]
        buf = buf[n:]
        return r

    header = read_exactly(2)
    if len(header) < 2:
        return None
    plen = header[1] & 0x7f
    if plen == 126:
        plen = int.from_bytes(read_exactly(2), "big")
    elif plen == 127:
        plen = int.from_bytes(read_exactly(8), "big")
    return read_exactly(plen).decode("utf-8"), buf


def pending_rows(db_path, recipient):
    con = sqlite3.connect(db_path)
    try:
        cur = con.execute(
            "SELECT dedupe_key, COUNT(*) FROM task_notification_outbox "
            "WHERE recipient_agent_instance_id = ? AND delivered_unix_ms = 0 GROUP BY dedupe_key",
            (recipient,),
        )
        return {row[0]: row[1] for row in cur.fetchall()}
    finally:
        con.close()


def main():
    daemon = daemon_bin()
    tmp = Path(tempfile.mkdtemp(prefix="notif-dedup-batch-"))
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    data_dir = tmp / "data"
    cfg = tmp / "daemon.toml"
    write_config(cfg, port, data_dir)
    db_path = str(data_dir / "tasks" / "task.db")
    proc = subprocess.Popen([daemon, "--config", str(cfg)], cwd=str(ROOT),
                            stdout=(tmp / "daemon.log").open("w"), stderr=subprocess.STDOUT, text=True)
    agent_id = "worker@notif"
    try:
        wait_health(base)

        user = request(base, "/user-client/register", {"user_id": "op@local", "client_instance_id": "ui"})[1]["client_token"]
        agent_token = request(base, "/register", {"agent_instance_id": agent_id, "display_name": "Worker"})[1]["agent_token"]
        request(base, "/register", {"agent_instance_id": "coordinator@notif", "display_name": "Coord"})

        proj = request(base, "/projects/create", {"agent_token": user, "name": "Notif Proj"})[1]["project_id"]
        chain = request(base, "/task-chains/create", {
            "agent_token": user, "project_id": proj, "kind": "coding", "status": "planning",
            "no_scaffold": True, "title": "Notif Chain", "coordinator_agent_instance_id": "coordinator@notif",
        })[1]["chain_id"]

        task_ids = []
        for i in range(3):
            tid = request(base, "/tasks/create", {
                "agent_token": user, "chain_id": chain, "title": f"Task {i}",
                "assignee_agent_instance_id": agent_id,
            })[1]["task_id"]
            task_ids.append(tid)
        request(base, "/task-chains/activate", {"agent_token": user, "chain_id": chain})
        ok("N0 setup: project/chain/3 tasks; agent offline (no WS)")

        # N1. DEDUP one task: nudge it 5 times while offline.
        for _ in range(5):
            r = request(base, "/tasks/nudge", {"agent_token": user, "task_id": task_ids[0], "chain_id": chain, "body": "ping"})
            require(r[1].get("ok"), f"nudge failed: {r}")
            time.sleep(0.05)
        rows = pending_rows(db_path, agent_id)
        key0 = f"task:{task_ids[0]}"
        require(rows.get(key0) == 1, f"expected exactly 1 pending row for task0, got {rows}")
        ok(f"N1 dedup: 5 nudges to one offline task -> 1 pending outbox row ({rows.get(key0)})")

        # N2. Multiple tasks: nudge the other two a few times each.
        for tid in task_ids[1:]:
            for _ in range(3):
                request(base, "/tasks/nudge", {"agent_token": user, "task_id": tid, "chain_id": chain, "body": "ping"})
                time.sleep(0.05)
        rows = pending_rows(db_path, agent_id)
        task_keys = {f"task:{t}" for t in task_ids}
        pending_task_rows = {k: v for k, v in rows.items() if k in task_keys}
        require(len(pending_task_rows) == 3 and all(v == 1 for v in pending_task_rows.values()),
                f"expected 1 pending row per task (3 total), got {rows}")
        ok(f"N2 multi: 3 tasks nudged repeatedly -> exactly 3 pending rows (1/task)")

        # N3. BATCH on reconnect: connect WS, expect a single task_event_batch.
        s, extra = ws_handshake(agent_id, "127.0.0.1", port)
        s.settimeout(4.0)
        try:
            frame, _ = recv_ws_text(s, extra)
        finally:
            s.close()
        require(frame, "no frame received on reconnect")
        msg = json.loads(frame)
        require(msg.get("type") == "task_event_batch", f"reconnect must deliver a single task_event_batch, got type={msg.get('type')}: {frame[:200]}")
        events = msg.get("events", [])
        got_tasks = {e.get("task_id") for e in events}
        require(got_tasks == set(task_ids), f"batch must contain one event per task; got {got_tasks} vs {set(task_ids)}")
        require(msg.get("count") == 3, f"batch count should be 3: {msg.get('count')}")
        ok(f"N3 batch: reconnect delivered ONE task_event_batch with {len(events)} events (1/task)")

        print("\nnotification_dedup_batch_e2e: ok")
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
