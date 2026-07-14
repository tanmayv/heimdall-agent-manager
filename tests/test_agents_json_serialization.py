#!/usr/bin/env python3
"""Regression: /agents emits parseable JSON with distinct identity_state/current_task_id fields."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49664"))
URL = f"http://{HOST}:{PORT}"
ROOT = Path(__file__).resolve().parents[1]


def request_raw(method: str, path: str, body=None):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        f"{URL}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=10) as res:
        payload = res.read().decode("utf-8")
        return res.status, payload


def request_json(method: str, path: str, body=None):
    status, payload = request_raw(method, path, body)
    return status, json.loads(payload) if payload else {}


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


def require(cond: bool, message: str):
    if not cond:
        raise AssertionError(message)


def assert_field_boundary(raw_payload: str, state: str):
    needle = f'"identity_state":"{state}","current_task_id":""'
    require(needle in raw_payload, f"missing field boundary snippet: {needle}\n{raw_payload}")


def main():
    agents_start = (ROOT / "src/daemon/agents_start.odin").read_text(encoding="utf-8")
    agent_store = (ROOT / "src/daemon/agent_store.odin").read_text(encoding="utf-8")
    require(
        'strings.write_string(builder, `,"identity_state":"`); json_write_string(builder, agent_record_identity_state(rec)); strings.write_string(builder, `"`)' in agents_start,
        "agent_instance_record_json must close identity_state before current_task_id",
    )
    require(
        'strings.write_string(builder, `,"current_task_id":"`); json_write_string(builder, rec.current_task_id)' in agents_start,
        "agent_instance_record_json must emit current_task_id as a separate field",
    )
    # Archived records are excluded from public /agents and /agents/show responses,
    # so cover the archived serializer branch at the source-helper boundary.
    require(
        'if rec.archived_at_unix_ms != 0 do return AGENT_IDENTITY_STATE_ARCHIVED' in agent_store,
        "archived records must project archived identity_state",
    )

    daemon_bin = os.environ.get("HEIMDALL_DAEMON_BIN", str(ROOT / "result" / "bin" / "ham-daemon"))
    require(os.path.exists(daemon_bin), f"missing ham-daemon binary: {daemon_bin}")
    temp_dir = tempfile.mkdtemp(prefix="heimdall-agents-json-")
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
        proc = subprocess.Popen([daemon_bin, "--config", config_path], cwd=ROOT, stdout=log_file, stderr=subprocess.STDOUT)
        wait_for_health()

        status, created_raw = request_raw("POST", "/agents/create", {
            "agent_instance_id": "coder@agents-json-provisioned",
            "display_name": "Provisioned Agent",
            "template_id": "coder",
            "provider_profile": "pi",
        })
        require(status == 200, created_raw)
        created = json.loads(created_raw)
        require(created.get("ok") is True, created)
        require(created["agent"]["identity_state"] == "provisioned", created)
        require(created["agent"]["current_task_id"] == "", created)
        assert_field_boundary(created_raw, "provisioned")

        status, register = request_json("POST", "/register", {
            "protocol_version": 1,
            "agent_class": "coder",
            "agent_instance_id": "coder@agents-json-running",
            "display_name": "Running Agent",
        })
        require(status == 200 and register.get("agent_token"), register)

        status, agents_raw = request_raw("GET", "/agents")
        require(status == 200, agents_raw)
        agents = json.loads(agents_raw)
        provisioned = next((a for a in agents.get("agents", []) if a.get("agent_instance_id") == "coder@agents-json-provisioned"), None)
        running = next((a for a in agents.get("agents", []) if a.get("agent_instance_id") == "coder@agents-json-running"), None)
        require(provisioned is not None, agents)
        require(running is not None, agents)
        require(provisioned.get("identity_state") == "provisioned", provisioned)
        require(provisioned.get("current_task_id") == "", provisioned)
        require(running.get("identity_state") == "running", running)
        require(running.get("current_task_id") == "", running)
        assert_field_boundary(agents_raw, "provisioned")
        assert_field_boundary(agents_raw, "running")

        status, archive_res = request_json("POST", "/agents/archive", {
            "agent_instance_id": "coder@agents-json-provisioned",
        })
        require(status == 200 and archive_res.get("ok") is True, archive_res)

        print("test_agents_json_serialization: ok")
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
