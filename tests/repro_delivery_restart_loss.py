#!/usr/bin/env python3
"""Regression for durable task notification replay across daemon restart.

Safe to run: starts an isolated ham-daemon on localhost with a temporary data_dir,
registers synthetic user/agent IDs, and removes its temp directory unless
KEEP_HEIMDALL_TEST_TMP=1 is set.
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
PORT_BASE = 49410
USER_ID = "operator@local"
AGENT_ID = "delivery-repro-agent@default"


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
    return sock, response[header_end + 4 :]


def start_daemon(repo: Path, temp_dir: str, port: int):
    daemon_bin = bin_path(repo, "result-daemon", "result", "ham-daemon")
    wrapper_bin = bin_path(repo, "result-wrapper", "result-1", "ham-wrapper")
    ctl_bin = bin_path(repo, "result-ctl", "result-2", "ham-ctl")
    config_path = os.path.join(temp_dir, "config.toml")
    url = f"http://{HOST}:{port}"
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {port}
data_dir = "{temp_dir}/data"
user_id = "{USER_ID}"
wrapper_bin = "{wrapper_bin}"

[ctl]
daemon_url = "{url}"
ham_ctl_bin = "{ctl_bin}"
''')
    log_path = os.path.join(temp_dir, f"daemon-{port}.log")
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


def setup_task(url: str, case_name: str) -> tuple[str, str, str, str]:
    user = request_post(url, "/user-client/register", {
        "user_id": USER_ID,
        "client_instance_id": f"delivery-repro-user-{case_name}",
    })
    user_token = user["client_token"]
    agent_id = f"delivery-repro-agent-{case_name}@default"
    request_post(url, "/register", {
        "agent_class": agent_id.split("@", 1)[0],
        "agent_instance_id": agent_id,
        "display_name": f"Delivery Repro {case_name}",
    })
    chain = request_post(url, "/task-chains/create", {
        "agent_token": user_token,
        "chain_id": f"chain-delivery-{case_name}",
        "title": f"Delivery {case_name}",
        "coordinator_agent_instance_id": USER_ID,
    })
    task = request_post(url, "/tasks/create", {
        "agent_token": user_token,
        "chain_id": chain["chain_id"],
        "title": "Delivery repro task",
        "description": "offline notification repro",
        "assignee_agent_instance_id": agent_id,
        "status": "queued",
    })
    return agent_id, chain["chain_id"], task["task_id"], user_token


def drain_agent_ws(port: int, agent_id: str, timeout: float = 1.0) -> list[dict]:
    sock, remaining = connect_agent_ws(port, agent_id)
    deadline = time.time() + timeout
    seen = []
    try:
        while time.time() < deadline:
            try:
                frame = recv_ws_text(sock, remaining)
                remaining = b""
            except socket.timeout:
                break
            if not frame:
                break
            seen.append(json.loads(frame))
        return seen
    finally:
        sock.close()


def send_nudge(url: str, user_token: str, chain_id: str, task_id: str, case_name: str) -> None:
    request_post(url, "/tasks/nudge", {
        "agent_token": user_token,
        "task_id": task_id,
        "chain_id": chain_id,
        "body": f"delivery nudge {case_name}",
        "interrupt": True,
    })


def wait_for_task_nudge(port: int, agent_id: str, timeout: float = 3.0) -> tuple[bool, list[dict]]:
    sock, remaining = connect_agent_ws(port, agent_id)
    deadline = time.time() + timeout
    seen = []
    try:
        while time.time() < deadline:
            try:
                frame = recv_ws_text(sock, remaining)
                remaining = b""
            except socket.timeout:
                break
            if not frame:
                break
            payload = json.loads(frame)
            seen.append(payload)
            if payload.get("type") == "task_event" and payload.get("event") == "Task_Nudged":
                return True, seen
        return False, seen
    finally:
        sock.close()


def fetch_task_log(url: str, user_token: str, task_id: str) -> dict:
    return request_post(url, "/tasks/log", {"agent_token": user_token, "task_id": task_id})


def run_case(repo: Path, restart_before_reconnect: bool, port: int) -> dict:
    temp_dir = tempfile.mkdtemp(prefix=f"heimdall-delivery-repro-{port}-")
    proc = log = None
    try:
        proc, log, url = start_daemon(repo, temp_dir, port)
        agent_id, chain_id, task_id, user_token = setup_task(url, f"case{port}")
        drained = drain_agent_ws(port, agent_id)
        send_nudge(url, user_token, chain_id, task_id, f"case{port}")
        if restart_before_reconnect:
            stop_daemon(proc, log)
            proc, log, url = start_daemon(repo, temp_dir, port)
            request_post(url, "/register", {
                "agent_class": agent_id.split("@", 1)[0],
                "agent_instance_id": agent_id,
                "display_name": "Delivery Repro Restarted",
            })
        delivered, frames = wait_for_task_nudge(port, agent_id)
        task_log = fetch_task_log(url, user_token, task_id)
        nudge_events = [e for e in task_log.get("events", []) if e.get("kind") == "Task_Nudged"]
        task_list = request_post(url, "/tasks/list", {"agent_token": user_token})
        matching_tasks = [t for t in task_list.get("tasks", []) if t.get("task_id") == task_id]
        return {
            "restart_before_reconnect": restart_before_reconnect,
            "delivered_on_reconnect": delivered,
            "drained_before_nudge": [f.get("event") for f in drained],
            "ws_frame_count": len(frames),
            "ws_events": [f.get("event") for f in frames],
            "task_log_nudge_events_after_reconnect": len(nudge_events),
            "task_state_recovered_after_restart": bool(matching_tasks),
            "temp_dir": temp_dir,
        }
    finally:
        if proc is not None:
            stop_daemon(proc, log)
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp_dir}")
        else:
            shutil.rmtree(temp_dir, ignore_errors=True)


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    baseline = run_case(repo, restart_before_reconnect=False, port=PORT_BASE)
    restart = run_case(repo, restart_before_reconnect=True, port=PORT_BASE + 1)
    result = {"baseline_no_restart": baseline, "restart_before_reconnect": restart}
    print(json.dumps(result, indent=2, sort_keys=True))
    if not baseline["delivered_on_reconnect"]:
        raise SystemExit("baseline failed: offline queued task nudge was not delivered without restart")
    if not restart["delivered_on_reconnect"]:
        raise SystemExit("restart case failed: durable pending task nudge was not delivered after daemon restart")
    if not restart["task_state_recovered_after_restart"]:
        raise SystemExit("restart case did not recover task state; repro setup invalid")
    print("DELIVERY RESTART REPRO PASSED")


if __name__ == "__main__":
    main()
