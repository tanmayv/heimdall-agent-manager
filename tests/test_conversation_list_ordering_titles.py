#!/usr/bin/env python3
"""Integration: daemon returns conversations most-recent-first with persisted titles.

Covers task-19f68ea0b7a:
- /user-rpc list_chats returns rows ordered by last_message_unix_ms DESC;
- each row carries a daemon-derived title (first user message), agent_id, project_id;
- ordering + titles survive a daemon restart (durable message store);
- sending a newer message reorders the conversation to the top.
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
CID = "heimdall-convlist-test"


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
    tmp = tempfile.mkdtemp(prefix="heimdall-convlist-")
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

        # Create two conversation instances and register them so sends persist.
        _, s1 = req("POST", "/agents/start", {"agent_id": "conversation"})
        c1 = s1["agent_instance_id"]
        time.sleep(0.2)
        _, s2 = req("POST", "/agents/start", {"agent_id": "conversation"})
        c2 = s2["agent_instance_id"]
        for cid in (c1, c2):
            req("POST", "/register", {"protocol_version": 1, "agent_class": "conversation", "agent_instance_id": cid, "display_name": ""})

        rpc("send_to_agent", ctok, agent_instance_id=c1, body="Fix the flaky websocket reconnect loop please")
        time.sleep(1.1)
        rpc("send_to_agent", ctok, agent_instance_id=c2, body="Explain how registry.odin works in detail")

        data = rpc("list_chats", ctok)
        chats = data.get("chats", [])
        require(len(chats) == 2, f"expected 2 conversations, got {len(chats)}")
        # c2 sent last -> must be first.
        require(chats[0]["agent_instance_id"] == c2, f"expected {c2} first, got {chats[0]['agent_instance_id']}")
        require(chats[0]["title"] == "Explain how registry.odin works in detail", f"unexpected title: {chats[0]['title']!r}")
        require(chats[1]["title"] == "Fix the flaky websocket reconnect loop please", f"unexpected title: {chats[1]['title']!r}")
        require(chats[0]["last_message_unix_ms"] > chats[1]["last_message_unix_ms"], "rows must be ordered by last_message_unix_ms desc")
        require(chats[0].get("agent_id") == "conversation", "row must carry durable agent_id")

        # Newer message on c1 reorders it to the top; title unchanged (first user msg).
        time.sleep(1.1)
        rpc("send_to_agent", ctok, agent_instance_id=c1, body="another follow up")
        data = rpc("list_chats", ctok)
        chats = data.get("chats", [])
        require(chats[0]["agent_instance_id"] == c1, "newer message must move conversation to top")
        require(chats[0]["title"] == "Fix the flaky websocket reconnect loop please", "title must stay the first user message")

        # Restart -> ordering + titles preserved from durable message store.
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        lf.close()
        proc, lf = start(daemon_bin, cfg, log)
        wait_health()
        req("POST", "/user-client/register", {"user_id": "operator@local", "client_instance_id": CID, "client_token": ctok})
        data = rpc("list_chats", ctok)
        chats = data.get("chats", [])
        require(len(chats) == 2, "conversations must survive restart")
        require(chats[0]["agent_instance_id"] == c1, "order must survive restart")
        require(chats[0]["title"] == "Fix the flaky websocket reconnect loop please", "title must survive restart")

        print("test_conversation_list_ordering_titles: ok")
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
