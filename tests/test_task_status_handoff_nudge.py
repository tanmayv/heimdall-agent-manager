#!/usr/inner/env python3
"""Regression: task status handoff nudges are delivered to correct agents.

This test asserts that when a task is moved to in_validation by someone other than the reviewer,
the reviewer receives a notify_task_nudge WS payload.
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
PORT = 49430
USER_ID = "operator@local"
AGENT_ID = "compact-nudge-agent@default"
REVIEWER_ID = "reviewer-agent@default"


def bin_path(repo: Path, preferred: str, fallback: str, binary: str) -> str:
    preferred_path = repo / preferred / "bin" / binary
    if preferred_path.exists():
        return str(preferred_path)
    return str(repo / fallback / "bin" / binary)


def request_post(url: str, path: str, data: dict) -> dict:
    req = urllib.request.Request(
        f"{url}{path}",
        data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as res:
            return json.loads(res.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        raise RuntimeError(f"POST {path} failed {exc.code}: {body}") from exc


def wait_health(url: str) -> None:
    for _ in range(50):
        try:
            with urllib.request.urlopen(f"{url}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def recv_ws_text(sock: socket.socket, initial_buffer: bytes = b""):
    buffer = initial_buffer

    def read_exactly(n: int) -> bytes:
        nonlocal buffer
        while len(buffer) < n:
            chunk = sock.recv(n - len(buffer))
            if not chunk:
                break
            buffer += chunk
        result = buffer[:n]
        buffer = buffer[n:]
        return result

    header = read_exactly(2)
    if len(header) < 2:
        return None
    payload_len = header[1] & 0x7F
    if payload_len == 126:
        payload_len = int.from_bytes(read_exactly(2), "big")
    elif payload_len == 127:
        payload_len = int.from_bytes(read_exactly(8), "big")
    return read_exactly(payload_len).decode()


def connect_agent_ws(port: int, agent_id: str):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(3)
    sock.connect((HOST, port))
    handshake = (
        f"GET /ws/{agent_id} HTTP/1.1\r\n"
        f"Host: {HOST}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(handshake.encode())
    response = sock.recv(4096)
    header_end = response.find(b"\r\n\r\n")
    if header_end < 0 or b"101 Switching Protocols" not in response[:header_end]:
        raise RuntimeError(f"websocket upgrade failed: {response!r}")
    return sock, response[header_end + 4:]


def start_daemon(repo: Path, temp_dir: str):
    daemon_bin = bin_path(repo, "result-daemon", "result", "ham-daemon")
    wrapper_bin = bin_path(repo, "result-wrapper", "result-1", "ham-wrapper")
    ctl_bin = bin_path(repo, "result-ctl", "result-2", "ham-ctl")
    config_path = os.path.join(temp_dir, "config.toml")
    url = f"http://{HOST}:{PORT}"
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{temp_dir}/data"
user_id = "{USER_ID}"
wrapper_bin = "{wrapper_bin}"

[ctl]
daemon_url = "{url}"
ham_ctl_bin = "{ctl_bin}"
''')
    log_path = os.path.join(temp_dir, "daemon.log")
    log = open(log_path, "a", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=log, stderr=subprocess.STDOUT)
    wait_health(url)
    return proc, log, url


def stop_daemon(proc, log) -> None:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    log.close()


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    temp_dir = tempfile.mkdtemp(prefix="heimdall-handoff-nudge-")
    proc = log = None
    try:
        proc, log, url = start_daemon(repo, temp_dir)
        user = request_post(url, "/user-client/register", {
            "user_id": USER_ID,
            "client_instance_id": "compact-nudge-user",
        })
        user_token = user["client_token"]
        
        # Register both agents
        request_post(url, "/register", {
            "agent_class": AGENT_ID.split("@", 1)[0],
            "agent_instance_id": AGENT_ID,
            "display_name": "Compact Nudge Agent",
        })
        request_post(url, "/register", {
            "agent_class": REVIEWER_ID.split("@", 1)[0],
            "agent_instance_id": REVIEWER_ID,
            "display_name": "Reviewer Agent",
        })
        
        chain = request_post(url, "/task-chains/create", {
            "agent_token": user_token,
            "chain_id": "chain-compact-nudge",
            "title": "Compact nudge chain",
            "coordinator_agent_instance_id": AGENT_ID,
        })
        
        task = request_post(url, "/tasks/create", {
            "agent_token": user_token,
            "chain_id": chain["chain_id"],
            "title": "Status handoff nudge task",
            "description": "desc",
            "assignee_agent_instance_id": AGENT_ID,
            "status": "in_progress",
        })

        # Set reviewer
        request_post(url, "/tasks/update", {
            "agent_token": user_token,
            "task_id": task["task_id"],
            "chain_id": chain["chain_id"],
            "reviewer_agent_instance_ids": [REVIEWER_ID],
        })

        # Connect the Reviewer to WS
        sock, remaining = connect_agent_ws(PORT, REVIEWER_ID)
        try:
            # Drain any existing notification frame from registration/task creation.
            sock.settimeout(0.25)
            while True:
                try:
                    recv_ws_text(sock, remaining)
                    remaining = b""
                except socket.timeout:
                    break
            sock.settimeout(3)

            # Move status to in_validation (with actor = AGENT_ID implicitly since we use user_token but it doesn't matter, we just test if the reviewer receives it)
            update = request_post(url, "/tasks/update", {
                "agent_token": user_token,
                "task_id": task["task_id"],
                "chain_id": chain["chain_id"],
                "status": "in_validation",
            })
            if not update.get("ok"):
                raise SystemExit(f"status update failed: {update}")

            frame = recv_ws_text(sock)
            if not frame:
                raise SystemExit("no task handoff nudge WS frame received")
            payload = json.loads(frame)
            
            if payload.get("type") != "notify_task_nudge":
                raise SystemExit(f"unexpected WS payload type (expected notify_task_nudge): {payload}")
                
            if payload.get("task_id") != task["task_id"] or payload.get("new_status") != "in_validation":
                raise SystemExit(f"invalid nudge payload details: {payload}")
            
            print(json.dumps({
                "ok": True,
                "payload_bytes": len(frame.encode()),
            }, indent=2, sort_keys=True))
            print("TASK HANDOFF NUDGE TEST PASSED")
        finally:
            sock.close()
    finally:
        if proc is not None:
            stop_daemon(proc, log)
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp_dir}")
        else:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
