#!/usr/bin/env python3
"""Regression for user/client read marks consuming agent unread chat."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49641"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
AGENT_ID = "coord-read-race@task18-e2e"
CLIENT_ID = "read-race-client"


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
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-2", "ham-ctl")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-1", "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-chat-read-race-")
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
            "agent_class": "coord-read-race",
            "agent_instance_id": AGENT_ID,
            "display_name": "Read Race Coordinator",
        })
        agent_token = agent_res.get("agent_token")
        if not agent_token:
            raise AssertionError(f"agent registration failed: {agent_res}")

        user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if not user_token:
            raise AssertionError(f"user registration failed: {user_res}")

        project_res = request_post("/user-rpc", {
            "action": "project_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "name": "Read race project",
        })
        project_id = project_res.get("project_id")
        if not project_id:
            raise AssertionError(f"project_create failed: {project_res}")
        chain_res = request_post("/user-rpc", {
            "action": "task_chain_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": project_id,
            "title": "Read race chain",
            "description": "regression",
            "kind": "solo",
            "coordinator_agent_instance_id": AGENT_ID,
            "no_scaffold": True,
        })
        chain_id = chain_res.get("chain_id")
        if not chain_id:
            raise AssertionError(f"task_chain_create failed: {chain_res}")

        body = "Task 18 coordinator instruction must stay unread for agent"
        send_res = request_post("/chat/send-to-coordinator", {
            "token": user_token,
            "chain_id": chain_id,
            "body": body,
        })
        if not send_res.get("ok") or not send_res.get("message_id"):
            raise AssertionError(f"send-to-coordinator failed: {send_res}")
        message_id = send_res["message_id"]

        # Simulate ChainView/user-client behavior after sending/opening chat. This must only
        # mark agent_to_user messages as read for the user, and must not consume the
        # user_to_agent message before the target agent fetches unread chat.
        mark_res = request_post("/user-rpc", {
            "action": "mark_read",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "agent_instance_id": AGENT_ID,
        })
        if not mark_res.get("ok"):
            raise AssertionError(f"user mark_read failed: {mark_res}")

        fetch_res = request_post("/agent-rpc", {
            "agent_token": agent_token,
            "action": "fetch_user_chat",
            "user_id": USER_ID,
            "unread_only": True,
            "limit": 3,
        })
        messages = fetch_res.get("messages", [])
        match = [m for m in messages if m.get("message_id") == message_id]
        if len(match) != 1:
            raise AssertionError(f"agent unread fetch lost user_to_agent message after user mark_read: {fetch_res}")
        if match[0].get("direction") != "user_to_agent" or match[0].get("body") != body:
            raise AssertionError(f"unexpected fetched message: {match[0]}")

        fetch_again = request_post("/agent-rpc", {
            "agent_token": agent_token,
            "action": "fetch_user_chat",
            "user_id": USER_ID,
            "unread_only": True,
            "limit": 3,
        })
        if fetch_again.get("messages"):
            raise AssertionError(f"agent fetch should mark message read for subsequent unread fetches: {fetch_again}")

        print("PASS: directional user mark_read does not consume agent unread chat")
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
