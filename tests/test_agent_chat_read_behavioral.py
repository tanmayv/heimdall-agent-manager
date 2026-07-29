#!/usr/bin/env python3
"""Behavioral tests for low-noise agent chat read filters and metadata."""
import json
import os
import subprocess
import time, tempfile
import urllib.error
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49647"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "chat-fetch-client"
AGENT_ID = "inst-test1"
OTHER_AGENT_ID = "inst-test2"

def bin_path(repo_dir, preferred, fallback, binary):
    preferred_path = os.path.join(repo_dir, preferred, "bin", binary)
    if os.path.exists(preferred_path):
        return preferred_path
    return os.path.join(repo_dir, fallback, "bin", binary)

def request_post(path, data):
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data, separators=(",", ":")).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status, json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read().decode("utf-8"))

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
    repo_dir = "/usr/local/google/home/tanmayvijay/heimdall-agent-manager"
    daemon_bin = bin_path(repo_dir, "result-daemon", "result-1", "ham-daemon")
    if not os.path.exists(daemon_bin):
        raise FileNotFoundError(f"Daemon binary not found: {daemon_bin}")

    proc = None
    cfg_path = os.path.join(tempfile.gettempdir(), f"test_config_{PORT}.toml")
    with open(cfg_path, "w") as f:
        f.write(f"[daemon]\nport = {PORT}\nbridge_url = \"\"\n")

    try:
        proc = subprocess.Popen([daemon_bin, "--config", cfg_path, "--ephemeral-db"])
        wait_for_daemon()

        _, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")

        _, project_res = request_post("/user-rpc", {
            "action": "project_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "name": "Test Project",
            "anchors": [{"type": "vcs_kind", "value": "none"}],
            "description": "test",
        })
        project_id = project_res.get("project_id")
        if not project_id:
            raise AssertionError(f"project_create failed: {project_res}")

        status, chain_res = request_post("/user-rpc", {
            "action": "task_chain_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": project_id,
            "title": "Chat Fetch Test",
            "chain_id": "chain1",
            "coordinator_agent_instance_id": AGENT_ID,
        })
        time.sleep(0.5)

        concrete_agent_id = chain_res.get("coordinator_agent_instance_id")
        if not concrete_agent_id:
            raise AssertionError(f"chain create failed: {chain_res}")

        _, agent_res = request_post("/register", {
            "agent_class": concrete_agent_id.split("@")[0],
            "agent_instance_id": concrete_agent_id,
            "display_name": "Test Agent",
        })
        agent_token = agent_res.get("agent_token")
        if not agent_token:
            raise AssertionError(f"Agent 1 registration failed: {agent_res}")
        
        _, other_res = request_post("/register", {
            "agent_class": OTHER_AGENT_ID.split("@")[0],
            "agent_instance_id": OTHER_AGENT_ID,
            "display_name": "Other Agent",
        })
        other_agent_token = other_res.get("agent_token")
        if not other_agent_token:
            raise AssertionError(f"Agent 2 registration failed: {other_res}")

        request_post("/api/v1/agent-actions/chat/send-to-user", {
            "agent_token": agent_token,
            "agent_instance_id": concrete_agent_id,
            "body": "Outgoing message from agent1",
        })
        time.sleep(0.5)
        
        request_post("/api/v1/agent-actions/chat/send-to-agent", {
            "agent_token": other_agent_token,
            "agent_instance_id": OTHER_AGENT_ID,
            "to_instance": concrete_agent_id,
            "body": "Message from other agent to agent1",
        })
        time.sleep(0.5)

        # Agent1 fetches defaults
        status, fetch_res = request_post("/api/v1/agent-actions/chat/fetch", {
            "agent_token": agent_token,
            "agent_instance_id": concrete_agent_id,
        })
        data = fetch_res.get("data", {})
        if not fetch_res.get("ok"):
            raise AssertionError(f"fetch failed: {fetch_res}")
        messages = data.get("messages", [])
        
        # We expect 1 message since unread_only=True, receiver_only=True, and one inbound was sent.
        assert len(messages) == 1, f"expected 1 inbound message, got {len(messages)}"
        assert messages[0].get("body") == "Message from other agent to agent1"

        # Verify agent.chat.read actually marks read
        request_post("/api/v1/agent-actions/chat/read", {
            "agent_token": agent_token,
            "agent_instance_id": concrete_agent_id,
        })
        time.sleep(0.1)

        # Agent1 fetches defaults again
        status, fetch_res2 = request_post("/api/v1/agent-actions/chat/fetch", {
            "agent_token": agent_token,
            "agent_instance_id": concrete_agent_id,
        })
        messages2 = fetch_res2.get("data", {}).get("messages", [])
        assert len(messages2) == 0, f"expected 0 messages, got {len(messages2)}"

        print("Behavioral test passed successfully!")

    finally:
        if proc:
            proc.terminate()
            proc.wait()

if __name__ == "__main__":
    main()
