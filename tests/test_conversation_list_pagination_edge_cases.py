#!/usr/bin/env python3
"""Integration: daemon returns chats with keyset pagination covering edge cases.

Edge cases covered:
- Deleting an item between pagination calls (it shouldn't mess up cursor).
- Updating an item's timestamp to bump it out of cursor range.
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
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49784"))
URL = f"http://{HOST}:{PORT}"
ROOT = Path(__file__).resolve().parents[1]
CID = "heimdall-conv-pagination-edge"

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

ERRORS = []
def require(cond, msg):
    if not cond:
        print("FAIL:", msg)
        ERRORS.append(msg)

def start(daemon_bin, cfg, log):
    lf = open(log, "a", encoding="utf-8")
    return subprocess.Popen([daemon_bin, "--config", cfg], cwd=ROOT, stdout=lf, stderr=subprocess.STDOUT), lf

def main():
    daemon_bin = os.environ.get("HEIMDALL_DAEMON_BIN", str(ROOT / "result" / "bin" / "ham-daemon"))
    require(os.path.exists(daemon_bin), f"missing ham-daemon binary: {daemon_bin}")
    tmp = tempfile.mkdtemp(prefix="heimdall-conv-pg-edge-")
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

        instances = []
        for i in range(5):
            _, s = req("POST", "/agents/start", {"agent_id": "conversation"})
            inst_id = s["agent_instance_id"]
            instances.append(inst_id)
            req("POST", "/register", {"protocol_version": 1, "agent_class": "conversation", "agent_instance_id": inst_id, "display_name": f"Chat {i}"})
            rpc("send_to_agent", ctok, agent_instance_id=inst_id, body=f"Message in chat {i}")
            time.sleep(0.5)

        # Ordering (newest first): 4, 3, 2, 1, 0
        data1 = rpc("list_chats", ctok, limit=2)
        chats1 = data1.get("chats", [])
        cursor1 = data1.get("next_cursor")
        require(len(chats1) == 2, f"expected 2 chats in page 1, got {len(chats1)}")
        require(chats1[0]["agent_instance_id"] == instances[4], "first is 4")
        require(chats1[1]["agent_instance_id"] == instances[3], "second is 3")

        # Edge case 1: Delete chat 2 (which is next up).
        # We'll use /agents/delete
        _, del_res = req("POST", "/agents/delete", {"agent_instance_id": instances[2]})
        
        # Now fetch page 2 using cursor1
        data2 = rpc("list_chats", ctok, limit=2, cursor=cursor1)
        chats2 = data2.get("chats", [])
        print("CHATS2:", json.dumps(chats2, indent=2))
        
        # It should skip the deleted chat 2, returning 1 and 0.
        require(len(chats2) == 2, f"expected 2 chats in page 2, got {len(chats2)}. Ids: {[c['agent_instance_id'] for c in chats2]}")
        require(chats2[0]["agent_instance_id"] == instances[1], f"expected {instances[1]} first in page 2 (chat 1)")
        require(chats2[1]["agent_instance_id"] == instances[0], f"expected {instances[0]} second in page 2 (chat 0)")
        
        cursor2 = data2.get("next_cursor")
        print("CURSOR2:", repr(cursor2))

        # Edge case 2: Update an item that was already returned, to bump its timestamp.
        # Let's say chat 1 receives a new message, so its timestamp is newer than our cursor.
        # But wait, chat 1 was just returned in page 2. Let's suppose we are on page 3.
        # There shouldn't be anything on page 3, since we just got the last item (0).
        # BUT if we had more items (say chat -1), we would get it.
        # Let's update chat 3 so it moves to front.
        rpc("send_to_agent", ctok, agent_instance_id=instances[3], body="bump")
        time.sleep(0.1)

        # Does pagination fetch again? 
        # Using cursor2, there are NO items with timestamp < cursor2, so it should be empty.
        data3 = rpc("list_chats", ctok, limit=2, cursor=cursor2)
        chats3 = data3.get("chats", [])
        print("CHATS3:", json.dumps(chats3, indent=2))
        require(len(chats3) == 0, f"expected 0 chats in page 3, got {len(chats3)}")

        if ERRORS:
            print("\n--- ALL FAILURES ---")
            for e in ERRORS: print(e)
            import sys; sys.exit(1)
        print("test_conversation_list_pagination_edge_cases: ok")
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
