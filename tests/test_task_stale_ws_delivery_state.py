#!/usr/bin/env python3
"""Regression: failed/stale task nudge delivery is reported as queued and replays.

This test starts an isolated daemon, registers an agent, opens then abruptly resets
its WebSocket to mimic a stale/broken wrapper notification channel, nudges a task,
and verifies:
- the nudge response is honest (not live-delivered; durable queued)
- a reconnect receives the queued Task_Nudged event
- repeated sends before reconnect do not falsely report live delivery
"""

import json
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = 49431
USER_ID = "operator@local"
AGENT_ID = "stale-ws-agent@default"


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
        try:
            return json.loads(body)
        except Exception as parse_exc:
            raise RuntimeError(f"POST {path} failed {exc.code}: {body}") from parse_exc


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


def reset_socket(sock: socket.socket) -> None:
    # Force a TCP RST instead of a graceful close so the daemon may still hold a
    # stale handle until its next write/read notices the break.
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    sock.close()


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
    return proc, log, log_path, url


def stop_daemon(proc, log) -> None:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    log.close()


def setup_task(url: str):
    user = request_post(url, "/user-client/register", {
        "user_id": USER_ID,
        "client_instance_id": "stale-ws-user",
    })
    user_token = user["client_token"]
    request_post(url, "/register", {
        "agent_class": AGENT_ID.split("@", 1)[0],
        "agent_instance_id": AGENT_ID,
        "display_name": "Stale WS Agent",
    })
    chain = request_post(url, "/task-chains/create", {
        "agent_token": user_token,
        "chain_id": "chain-stale-ws",
        "title": "Stale WS chain",
        "coordinator_agent_instance_id": USER_ID,
    })
    task = request_post(url, "/tasks/create", {
        "agent_token": user_token,
        "chain_id": chain["chain_id"],
        "title": "Stale WS task",
        "description": "stale ws delivery state",
        "assignee_agent_instance_id": AGENT_ID,
        "status": "queued",
    })
    return user_token, chain["chain_id"], task["task_id"]


def nudge(url: str, user_token: str, chain_id: str, task_id: str, body: str) -> dict:
    return request_post(url, "/tasks/nudge", {
        "agent_token": user_token,
        "task_id": task_id,
        "chain_id": chain_id,
        "body": body,
        "interrupt": True,
    })


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    temp_dir = tempfile.mkdtemp(prefix="heimdall-stale-ws-")
    proc = log = None
    try:
        proc, log, log_path, url = start_daemon(repo, temp_dir)
        user_token, chain_id, task_id = setup_task(url)

        stale_sock, _ = connect_agent_ws(PORT, AGENT_ID)
        reset_socket(stale_sock)
        # Give the kernel a moment to propagate RST, but not enough to rely on
        # heartbeat/liveness janitors. Either send failure path or ws read-loop
        # clear path is acceptable as long as API state is honest and replay works.
        time.sleep(0.05)

        first = nudge(url, user_token, chain_id, task_id, "stale ws first nudge")
        if not first.get("ok"):
            raise SystemExit(f"first nudge should be durably accepted: {first}")
        if first.get("live_delivered") is not False or first.get("sent") is not False:
            raise SystemExit(f"first nudge falsely reported live delivery: {first}")
        if first.get("durable_queued") is not True or first.get("delivery_state") != "queued":
            raise SystemExit(f"first nudge did not report queued delivery: {first}")

        second = nudge(url, user_token, chain_id, task_id, "stale ws second nudge")
        if not second.get("ok"):
            raise SystemExit(f"second nudge should be durably accepted: {second}")
        if second.get("live_delivered") is not False or second.get("sent") is not False:
            raise SystemExit(f"second nudge falsely reported live delivery: {second}")
        if second.get("durable_queued") is not True or second.get("delivery_state") != "queued":
            raise SystemExit(f"second nudge did not report queued delivery: {second}")

        sock, remaining = connect_agent_ws(PORT, AGENT_ID)
        received_bodies = []
        try:
            deadline = time.time() + 3
            while time.time() < deadline and len(received_bodies) < 2:
                try:
                    frame = recv_ws_text(sock, remaining)
                    remaining = b""
                except socket.timeout:
                    break
                if not frame:
                    break
                payload = json.loads(frame)
                if payload.get("type") == "task_event" and payload.get("event") == "Task_Nudged":
                    received_bodies.append(payload.get("body"))
        finally:
            sock.close()

        if "stale ws first nudge" not in received_bodies or "stale ws second nudge" not in received_bodies:
            raise SystemExit(f"reconnect did not replay queued nudges: {received_bodies}")

        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            daemon_log = f.read()
        stale_cleared = "cleared stale WebSocket" in daemon_log or "has no active WebSocket connection" in daemon_log
        if not stale_cleared:
            raise SystemExit("daemon log did not show stale/no-active WS handling")

        print(json.dumps({
            "ok": True,
            "first_response": first,
            "second_response": second,
            "replayed_bodies": received_bodies,
            "log_showed_stale_handling": stale_cleared,
        }, indent=2, sort_keys=True))
        print("TASK STALE WS DELIVERY STATE TEST PASSED")
    finally:
        if proc is not None:
            stop_daemon(proc, log)
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp_dir}")
        else:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
