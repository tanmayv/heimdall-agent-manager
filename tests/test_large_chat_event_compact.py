#!/usr/bin/env python3
"""Regression: large chat messages do not make user WS chat_event exceed cap."""

import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = 49450
USER_ID = "operator@local"
CLIENT_ID = "large-chat-client"
AGENT_ID = "large-chat-agent@default"


def bin_path(repo: Path, preferred: str, fallback: str, binary: str) -> str:
    p = repo / preferred / "bin" / binary
    if p.exists():
        return str(p)
    return str(repo / fallback / "bin" / binary)


def request_post(url: str, path: str, data: dict) -> dict:
    req = urllib.request.Request(f"{url}{path}", data=json.dumps(data).encode(), headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=5) as res:
        return json.loads(res.read().decode())


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
        out = buffer[:n]
        buffer = buffer[n:]
        return out

    header = read_exactly(2)
    if len(header) < 2:
        return None
    payload_len = header[1] & 0x7F
    if payload_len == 126:
        payload_len = int.from_bytes(read_exactly(2), "big")
    elif payload_len == 127:
        payload_len = int.from_bytes(read_exactly(8), "big")
    return read_exactly(payload_len).decode()


def connect_user_ws(port: int, client_id: str, token: str):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(3)
    sock.connect((HOST, port))
    path = f"/user-ws/{client_id}?client_token={token}"
    handshake = (
        f"GET {path} HTTP/1.1\r\n"
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
    wrapper_bin = bin_path(repo, "result-wrapper", "result-2", "ham-wrapper")
    ctl_bin = bin_path(repo, "result-ctl", "result-1", "ham-ctl")
    config = os.path.join(temp_dir, "config.toml")
    url = f"http://{HOST}:{PORT}"
    with open(config, "w", encoding="utf-8") as f:
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
    log = open(os.path.join(temp_dir, "daemon.log"), "a", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config], stdout=log, stderr=subprocess.STDOUT)
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
    temp = tempfile.mkdtemp(prefix="heimdall-large-chat-")
    proc = log = None
    try:
        proc, log, url = start_daemon(repo, temp)
        user = request_post(url, "/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user["client_token"]
        agent = request_post(url, "/register", {"agent_class": "large-chat-agent", "agent_instance_id": AGENT_ID, "display_name": "Large Chat Agent"})
        agent_token = agent["agent_token"]

        sock, remaining = connect_user_ws(PORT, CLIENT_ID, user_token)
        try:
            time.sleep(0.1)
            large_body = "large-message-" + ("x" * 4510)
            res = request_post(url, "/agent-rpc", {"agent_token": agent_token, "action": "send_to_user", "user_id": USER_ID, "body": large_body})
            if not res.get("ok"):
                raise SystemExit(f"send_to_user failed: {res}")
            frame = recv_ws_text(sock, remaining)
            if not frame:
                raise SystemExit("no user WS chat_event received")
            if len(frame.encode()) > 4090:
                raise SystemExit(f"chat_event exceeded WS cap: {len(frame.encode())}")
            payload = json.loads(frame)
            if payload.get("type") != "chat_event" or payload.get("message_id") != res.get("message_id"):
                raise SystemExit(f"unexpected chat_event: {payload}")
            if "message" in payload:
                raise SystemExit("compact chat_event should not embed full message")

            fetched = request_post(url, "/user-rpc", {"client_instance_id": CLIENT_ID, "client_token": user_token, "action": "fetch_chat", "agent_instance_id": AGENT_ID, "unread_only": False, "limit": 10})
            bodies = [m.get("body") for m in fetched.get("messages", [])]
            if large_body not in bodies:
                raise SystemExit("large persisted message was not fetchable after compact event")
            print(json.dumps({"ok": True, "frame_bytes": len(frame.encode()), "message_id": res.get("message_id")}, indent=2, sort_keys=True))
            print("LARGE CHAT EVENT COMPACT TEST PASSED")
        finally:
            sock.close()
    finally:
        if proc is not None:
            stop_daemon(proc, log)
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp}")
        else:
            shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    main()
