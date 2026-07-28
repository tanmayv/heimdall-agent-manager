#!/usr/bin/env python3
"""Integration: daemon returns chats with keyset pagination.

Covers task-19f836f0dc9 (AI-1):
- /user-rpc list_chats supports limit and cursor;
- returns next_cursor and has_more.
"""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49783"))
URL = f"http://{HOST}:{PORT}"
ROOT = Path(__file__).resolve().parents[1]
CID = "heimdall-conv-pagination-test"


def req(method, path, body=None, headers=None):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    h = {"Content-Type": "application/json"}
    if headers:
        h.update(headers)
    r = urllib.request.Request(f"{URL}{path}", data=data, headers=h, method=method)
    with urllib.request.urlopen(r, timeout=10) as res:
        payload = res.read().decode("utf-8")
        return res.status, (json.loads(payload) if payload else {})


def rpc(action, ctok, **fields):
    body = {"action": action, "client_instance_id": CID, "client_token": ctok}
    body.update(fields)
    _, data = req("POST", "/user-rpc", body)
    return data


def wait_health():
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("daemon did not become healthy")


def require(cond, msg):
    if not cond:
        raise AssertionError(msg)


def start(daemon_bin, cfg, log):
    lf = open(log, "a", encoding="utf-8")
    return subprocess.Popen([daemon_bin, "--config", cfg], cwd=ROOT, stdout=lf, stderr=subprocess.STDOUT), lf


def main():
    daemon_bin = os.environ.get("HEIMDALL_DAEMON_BIN", str(ROOT / "result" / "bin" / "ham-daemon"))
    require(os.path.exists(daemon_bin), f"missing ham-daemon binary: {daemon_bin}")
    tmp = tempfile.mkdtemp(prefix="heimdall-conv-pg-")
    cfg = os.path.join(tmp, "config.toml")
    log = os.path.join(tmp, "daemon.log")
    data_dir = os.path.join(tmp, "data")
    with open(cfg, "w", encoding="utf-8") as f:
        f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{data_dir}"
user_id = "operator@local"
wrapper_bin = "/bin/sh"

[guide_agent]
enabled = false
autostart = false
restart_if_stopped = false
agent_instance_id = "guide@heimdall"
template_id = "guide"
provider_profile = "pi"
model_tier = "smart"

[ctl]
daemon_url = "{URL}"
''')
    proc, lf = start(daemon_bin, cfg, log)
    try:
        wait_health()
        _, reg = req("POST", "/user-client/register", {"user_id": "operator@local", "client_instance_id": CID})
        ctok = reg["client_token"]

        # Create 5 conversations
        instances = []
        for i in range(5):
            _, s = req("POST", "/agents/start", {"agent_id": "conversation"})
            inst_id = s["agent_instance_id"]
            instances.append(inst_id)
            req("POST", "/register", {"protocol_version": 1, "agent_class": "conversation", "agent_instance_id": inst_id, "display_name": f"Chat {i}"})
            # Send message to set last_message_unix_ms
            rpc("send_to_agent", ctok, agent_instance_id=inst_id, body=f"Message in chat {i}")
            time.sleep(0.5) # ensure distinct timestamps

        # We want to verify pagination.
        # Order should be (newest first): inst4, inst3, inst2, inst1, inst0.
        
        # Page 1: limit=2
        data1 = rpc("list_chats", ctok, limit=2)
        print("Page 1 response:")
        print(json.dumps(data1, indent=2))
        chats1 = data1.get("chats", [])
        require(len(chats1) == 2, f"expected 2 chats in page 1, got {len(chats1)}")
        require(chats1[0]["agent_instance_id"] == instances[4], f"expected {instances[4]} first")
        require(chats1[1]["agent_instance_id"] == instances[3], f"expected {instances[3]} second")
        require(data1.get("has_more") is True, "expected has_more=True in page 1")
        cursor1 = data1.get("next_cursor")
        require(bool(cursor1), "expected non-empty next_cursor in page 1")

        # Page 2: limit=2, cursor=cursor1
        data2 = rpc("list_chats", ctok, limit=2, cursor=cursor1)
        print("Page 2 response:")
        print(json.dumps(data2, indent=2))
        chats2 = data2.get("chats", [])
        require(len(chats2) == 2, f"expected 2 chats in page 2, got {len(chats2)}")
        require(chats2[0]["agent_instance_id"] == instances[2], f"expected {instances[2]} first in page 2")
        require(chats2[1]["agent_instance_id"] == instances[1], f"expected {instances[1]} second in page 2")
        require(data2.get("has_more") is True, "expected has_more=True in page 2")
        cursor2 = data2.get("next_cursor")
        require(bool(cursor2), "expected non-empty next_cursor in page 2")

        # Page 3: limit=2, cursor=cursor2
        data3 = rpc("list_chats", ctok, limit=2, cursor=cursor2)
        print("Page 3 response:")
        print(json.dumps(data3, indent=2))
        chats3 = data3.get("chats", [])
        require(len(chats3) == 1, f"expected 1 chat in page 3, got {len(chats3)}")
        require(chats3[0]["agent_instance_id"] == instances[0], f"expected {instances[0]} in page 3")
        require(data3.get("has_more") is False, "expected has_more=False in page 3")

        print("test_conversation_list_pagination: ok")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        lf.close()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
