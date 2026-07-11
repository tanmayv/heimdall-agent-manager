#!/usr/bin/env python3
"""Regression: task nudges to wrappers use compact WS payloads.

A long task description previously made task_event notifications exceed the daemon
WS sender's 4090-byte fixed-frame limit. This test keeps an agent WebSocket open,
nudges a task with a long description, and asserts the wrapper-directed payload is
small, delivered live, and does not embed full task/chain JSON.
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
    temp_dir = tempfile.mkdtemp(prefix="heimdall-compact-nudge-")
    proc = log = None
    try:
        proc, log, url = start_daemon(repo, temp_dir)
        user = request_post(url, "/user-client/register", {
            "user_id": USER_ID,
            "client_instance_id": "compact-nudge-user",
        })
        user_token = user["client_token"]
        request_post(url, "/register", {
            "agent_class": AGENT_ID.split("@", 1)[0],
            "agent_instance_id": AGENT_ID,
            "display_name": "Compact Nudge Agent",
        })
        chain = request_post(url, "/task-chains/create", {
            "agent_token": user_token,
            "chain_id": "chain-compact-nudge",
            "title": "Compact nudge chain",
            "coordinator_agent_instance_id": USER_ID,
        })
        long_description = "large description " + ("x" * 3600)
        task = request_post(url, "/tasks/create", {
            "agent_token": user_token,
            "chain_id": chain["chain_id"],
            "title": "Compact nudge task",
            "description": long_description,
            "assignee_agent_instance_id": AGENT_ID,
            "status": "queued",
        })

        sock, remaining = connect_agent_ws(PORT, AGENT_ID)
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

            nudge = request_post(url, "/tasks/nudge", {
                "agent_token": user_token,
                "task_id": task["task_id"],
                "chain_id": chain["chain_id"],
                "body": "compact payload nudge",
                "interrupt": True,
            })
            if not nudge.get("ok"):
                raise SystemExit(f"nudge failed: {nudge}")
            if nudge.get("sent") is not True or nudge.get("live_delivered") is not True:
                raise SystemExit(f"nudge was not reported live-delivered: {nudge}")
            if nudge.get("delivery_state") != "delivered":
                raise SystemExit(f"nudge did not report delivered state: {nudge}")
            if nudge.get("durable_queued") is not False or nudge.get("failed") is not False:
                raise SystemExit(f"live delivery should not report queued/failed: {nudge}")

            frame = recv_ws_text(sock)
            if not frame:
                raise SystemExit("no task nudge WS frame received")
            payload = json.loads(frame)
            if payload.get("type") != "task_event" or payload.get("event") != "Task_Nudged":
                raise SystemExit(f"unexpected WS payload: {payload}")
            if len(frame.encode()) > 4090:
                raise SystemExit(f"compact payload still exceeds WS limit: {len(frame.encode())}")
            if "task" in payload or "chain" in payload:
                raise SystemExit(f"agent payload should not embed full task/chain: {payload.keys()}")
            if payload.get("task_id") != task["task_id"] or payload.get("body") != "compact payload nudge":
                raise SystemExit(f"compact payload lost nudge context: {payload}")
            print(json.dumps({
                "ok": True,
                "payload_bytes": len(frame.encode()),
                "nudge_response": nudge,
            }, indent=2, sort_keys=True))
            print("TASK NUDGE COMPACT PAYLOAD TEST PASSED")
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
