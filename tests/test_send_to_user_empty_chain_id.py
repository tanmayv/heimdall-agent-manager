#!/usr/bin/env python3
"""Regression for agent send_to_user with empty message chain_id."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49642"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
AGENT_ID = "coord-empty-chain@task18-e2e"
CLIENT_ID = "empty-chain-client"


def bin_path(repo_dir, preferred, fallback, binary):
    preferred_path = os.path.join(repo_dir, preferred, "bin", binary)
    if os.path.exists(preferred_path):
        return preferred_path
    return os.path.join(repo_dir, fallback, "bin", binary)


def request_post(path, data):
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as res:
        return json.loads(res.read().decode("utf-8"))


def wait_for_daemon():
    for _ in range(60):
        try:
            with urllib.request.urlopen(f"{DAEMON_URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("daemon did not become healthy")


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = bin_path(repo_dir, "result-daemon", "result", "ham-daemon")
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-1", "ham-ctl")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-2", "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-empty-chain-send-user-")
    config_path = os.path.join(temp_home, "config.toml")
    daemon_log_path = os.path.join(temp_home, "daemon.log")
    daemon_proc = None
    daemon_log = None
    try:
        with open(config_path, "w", encoding="utf-8") as f:
            f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{temp_home}/data"
user_id = "{USER_ID}"
wrapper_bin = "{wrapper_bin}"

[ctl]
daemon_url = "{DAEMON_URL}"
ham_ctl_bin = "{ctl_bin}"
''')
        daemon_log = open(daemon_log_path, "w", encoding="utf-8")
        daemon_proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=daemon_log, stderr=subprocess.STDOUT)
        wait_for_daemon()

        agent_res = request_post("/register", {
            "agent_class": "coord-empty-chain",
            "agent_instance_id": AGENT_ID,
            "display_name": "Empty Chain Coordinator",
        })
        agent_token = agent_res.get("agent_token")
        if not agent_token:
            raise AssertionError(f"agent registration failed: {agent_res}")

        user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if not user_token:
            raise AssertionError(f"user registration failed: {user_res}")

        body = "coordinator reply with intentionally empty chain id"
        send_res = request_post("/agent-rpc", {
            "agent_token": agent_token,
            "action": "send_to_user",
            "user_id": USER_ID,
            "body": body,
        })
        if not send_res.get("ok") or not send_res.get("message_id"):
            raise AssertionError(f"send_to_user did not persist empty-chain message: {send_res}")
        message_id = send_res["message_id"]

        fetch_res = request_post("/user-rpc", {
            "action": "fetch_chat",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "agent_instance_id": AGENT_ID,
            "unread_only": True,
            "limit": 10,
        })
        matches = [m for m in fetch_res.get("messages", []) if m.get("message_id") == message_id]
        if len(matches) != 1:
            raise AssertionError(f"user could not fetch persisted send_to_user message: {fetch_res}")
        msg = matches[0]
        if msg.get("direction") != "agent_to_user" or msg.get("body") != body:
            raise AssertionError(f"unexpected message payload: {msg}")
        if msg.get("chain_id") != "":
            raise AssertionError(f"expected empty string chain_id, got: {msg!r}")

        mark_res = request_post("/user-rpc", {
            "action": "mark_read",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "agent_instance_id": AGENT_ID,
            "message_id": message_id,
        })
        if not mark_res.get("ok"):
            raise AssertionError(f"mark_read failed for empty-chain message: {mark_res}")

        fetch_after = request_post("/user-rpc", {
            "action": "fetch_chat",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "agent_instance_id": AGENT_ID,
            "unread_only": True,
            "limit": 10,
        })
        if any(m.get("message_id") == message_id for m in fetch_after.get("messages", [])):
            raise AssertionError(f"message remained unread after user mark_read: {fetch_after}")

        print("PASS: send_to_user persists and fetches empty-chain agent_to_user message")
    finally:
        if daemon_proc is not None:
            daemon_proc.terminate()
            try:
                daemon_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon_proc.kill()
        if daemon_log is not None:
            daemon_log.close()
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp_home}")
        else:
            shutil.rmtree(temp_home, ignore_errors=True)


if __name__ == "__main__":
    main()
