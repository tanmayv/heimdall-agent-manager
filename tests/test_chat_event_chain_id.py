#!/usr/bin/env python3
"""Regression: chain-scoped chat_event payloads include compact chain_id metadata."""
import base64
import hashlib
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
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49644"))
USER_ID = "operator@local"
CLIENT_ID = "chat-event-chain-client"
AGENT_ID = "coord-chat-event-chain@task19-e2e"
CHAIN_ID = "chain-chat-event-chain-task19"


def bin_path(repo_dir, preferred, fallback, binary):
    preferred_path = os.path.join(repo_dir, preferred, "bin", binary)
    if os.path.exists(preferred_path):
        return preferred_path
    return os.path.join(repo_dir, fallback, "bin", binary)


def request_post(url, path, data):
    req = urllib.request.Request(
        f"{url}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as res:
        return json.loads(res.read().decode("utf-8"))


def wait_for_daemon(url):
    for _ in range(60):
        try:
            with urllib.request.urlopen(f"{url}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("daemon did not become healthy")


def connect_user_ws(port, client_id, token):
    sock = socket.create_connection((HOST, port), timeout=5)
    key = "dGhlIHNhbXBsZSBub25jZQ=="
    request = (
        f"GET /user-ws/{client_id}?client_token={token} HTTP/1.1\r\n"
        f"Host: {HOST}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    ).encode("utf-8")
    sock.sendall(request)
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("websocket handshake failed")
        response += chunk
    header, remaining = response.split(b"\r\n\r\n", 1)
    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("utf-8")).digest()).decode("utf-8")
    if b"101 Switching Protocols" not in header or accept.encode("utf-8") not in header:
        raise RuntimeError(f"unexpected websocket handshake: {header!r}")
    return sock, remaining


def recv_ws_text(sock, initial=b"", timeout=5):
    sock.settimeout(timeout)
    data = initial
    while len(data) < 2:
        data += sock.recv(4096)
    b1, b2 = data[0], data[1]
    opcode = b1 & 0x0F
    if opcode == 0x8:
        return None
    payload_len = b2 & 0x7F
    idx = 2
    if payload_len == 126:
        while len(data) < idx + 2:
            data += sock.recv(4096)
        payload_len = int.from_bytes(data[idx:idx + 2], "big")
        idx += 2
    elif payload_len == 127:
        while len(data) < idx + 8:
            data += sock.recv(4096)
        payload_len = int.from_bytes(data[idx:idx + 8], "big")
        idx += 8
    masked = (b2 & 0x80) != 0
    if masked:
        while len(data) < idx + 4:
            data += sock.recv(4096)
        mask = data[idx:idx + 4]
        idx += 4
    else:
        mask = b""
    while len(data) < idx + payload_len:
        data += sock.recv(4096)
    payload = bytearray(data[idx:idx + payload_len])
    if masked:
        for i in range(payload_len):
            payload[i] ^= mask[i % 4]
    return payload.decode("utf-8")


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    daemon_bin = bin_path(str(repo), "result-daemon", "result", "ham-daemon")
    ctl_bin = bin_path(str(repo), "result-ctl", "result-1", "ham-ctl")
    wrapper_bin = bin_path(str(repo), "result-wrapper", "result-2", "ham-wrapper")
    temp = tempfile.mkdtemp(prefix="heimdall-chat-event-chain-")
    url = f"http://{HOST}:{PORT}"
    config = os.path.join(temp, "config.toml")
    log_path = os.path.join(temp, "daemon.log")
    proc = log = None
    try:
        with open(config, "w", encoding="utf-8") as f:
            f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{temp}/data"
user_id = "{USER_ID}"
wrapper_bin = "{wrapper_bin}"

[ctl]
daemon_url = "{url}"
ham_ctl_bin = "{ctl_bin}"
''')
        log = open(log_path, "w", encoding="utf-8")
        proc = subprocess.Popen([daemon_bin, "--config", config], stdout=log, stderr=subprocess.STDOUT)
        wait_for_daemon(url)

        user = request_post(url, "/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user["client_token"]
        agent = request_post(url, "/register", {"agent_class": "coord-chat-event-chain", "agent_instance_id": AGENT_ID, "display_name": "Chain Event Coordinator"})
        agent_token = agent["agent_token"]

        chain = request_post(url, "/user-rpc", {
            "action": "task_chain_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": "default",
            "kind": "solo",
            "title": "Chain chat event test",
            "chain_id": CHAIN_ID,
            "coordinator_agent_instance_id": AGENT_ID,
            "wants_vcs": False,
            "no_scaffold": True,
        })
        if not chain.get("ok"):
            raise SystemExit(f"task_chain_create failed: {chain}")

        sock, remaining = connect_user_ws(PORT, CLIENT_ID, user_token)
        try:
            time.sleep(0.1)
            send = request_post(url, "/agent-rpc", {
                "agent_token": agent_token,
                "action": "send_to_user",
                "user_id": USER_ID,
                "body": "scoped coordinator reply",
                "chain_id": CHAIN_ID,
            })
            if not send.get("ok"):
                raise SystemExit(f"send_to_user failed: {send}")
            frame = recv_ws_text(sock, remaining)
            if not frame:
                raise SystemExit("no user WS chat_event received")
            payload = json.loads(frame)
            if payload.get("type") != "chat_event" or payload.get("message_id") != send.get("message_id"):
                raise SystemExit(f"unexpected chat_event: {payload}")
            if payload.get("chain_id") != CHAIN_ID:
                raise SystemExit(f"missing chain_id in chain-scoped chat_event: {payload}")
            if "message" in payload:
                raise SystemExit("compact chain-scoped chat_event should not embed full message")
            print(json.dumps({"ok": True, "message_id": send.get("message_id"), "chain_id": payload.get("chain_id")}, indent=2, sort_keys=True))
            print("CHAT EVENT CHAIN ID TEST PASSED")
        finally:
            sock.close()
    finally:
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        if log is not None:
            log.close()
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp}")
        else:
            shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    main()
