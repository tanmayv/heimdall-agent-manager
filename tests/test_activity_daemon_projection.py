#!/usr/bin/env python3
"""Regression: daemon projects heartbeat activity fields through runtime APIs."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49663"))
URL = f"http://{HOST}:{PORT}"


def request(method: str, path: str, body=None):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        f"{URL}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=10) as res:
        payload = res.read().decode("utf-8")
        return res.status, json.loads(payload) if payload else {}


def wait_for_health():
    for _ in range(60):
        try:
            with urllib.request.urlopen(f"{URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("daemon did not become healthy")


def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = os.environ["HEIMDALL_DAEMON_BIN"]
    temp_dir = tempfile.mkdtemp(prefix="heimdall-activity-daemon-")
    config_path = os.path.join(temp_dir, "config.toml")
    log_path = os.path.join(temp_dir, "daemon.log")
    proc = None
    log_file = None
    try:
        with open(config_path, "w", encoding="utf-8") as f:
            f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{temp_dir}/data"
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
        log_file = open(log_path, "w", encoding="utf-8")
        proc = subprocess.Popen([daemon_bin, "--config", config_path], cwd=repo, stdout=log_file, stderr=subprocess.STDOUT)
        wait_for_health()

        status, register = request("POST", "/register", {
            "protocol_version": 1,
            "agent_class": "coder",
            "agent_instance_id": "coder@activity-test",
            "display_name": "Activity Test Agent",
        })
        assert status == 200 and register.get("agent_token"), register
        agent_token = register["agent_token"]

        heartbeat = {
            "agent_instance_id": "coder@activity-test",
            "agent_token": agent_token,
            "display_name": "Activity Test Agent",
            "provider_profile": "pi",
            "provider_tier": "normal",
            "project_id": "",
            "tmux_pane": "%1",
            "run_dir": "/tmp/activity-test",
            "exec_state": "running",
            "blocked_reason": "",
            "startup_status": "ready",
            "startup_reason_code": "",
            "startup_safe_diagnostic": "",
            "activity_status": "idle",
            "activity_source": "tmux_pane_sampler",
            "activity_checked_unix_ms": 123456789,
            "pid": 999,
            "exec_state_since_unix_ms": 123456000,
        }
        status, hb = request("POST", "/heartbeat", heartbeat)
        assert status == 200 and hb.get("ok") is True, hb

        status, clients = request("GET", "/clients")
        assert status == 200 and clients.get("agents"), clients
        agent = next((a for a in clients["agents"] if a.get("agent_instance_id") == "coder@activity-test"), None)
        assert agent, clients
        assert agent.get("activity_status") == "idle", agent
        assert agent.get("activity_source") == "tmux_pane_sampler", agent
        assert agent.get("activity_checked_unix_ms") == 123456789, agent
        assert "spinner" not in json.dumps(agent), agent

        status, agents = request("GET", "/agents")
        assert status == 200 and agents.get("agents"), agents
        listed = next((a for a in agents["agents"] if a.get("agent_instance_id") == "coder@activity-test"), None)
        assert listed, agents
        assert listed.get("activity_status") == "idle", listed
        assert listed.get("activity_source") == "tmux_pane_sampler", listed
        assert listed.get("activity_checked_unix_ms") == 123456789, listed

        print("test_activity_daemon_projection: ok")
    finally:
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        if log_file is not None:
            log_file.close()
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
