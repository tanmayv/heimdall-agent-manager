#!/usr/bin/env python3
"""Integration: /agents/start exact-instance project override (set + clear).

Covers the reviewer NGTM for task-19f6895bf3d: a runtime restart of an exact
concrete agent_instance_id must be able to change AND clear the instance's
project when project_id_set=true, while an ordinary start with an empty
project_id (no flag) preserves the stored project.
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
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49752"))
URL = f"http://{HOST}:{PORT}"
ROOT = Path(__file__).resolve().parents[1]


def request_json(method: str, path: str, body=None):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(f"{URL}{path}", data=data, headers={"Content-Type": "application/json"}, method=method)
    with urllib.request.urlopen(req, timeout=10) as res:
        payload = res.read().decode("utf-8")
        return res.status, (json.loads(payload) if payload else {})


def wait_for_health():
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("daemon did not become healthy")


def require(cond: bool, message):
    if not cond:
        raise AssertionError(message)


def show_project(instance_id: str) -> str:
    status, res = request_json("POST", "/agents/show", {"agent_instance_id": instance_id})
    require(status == 200 and res.get("ok"), res)
    return res.get("agent", {}).get("project_id", "")


def main():
    daemon_bin = os.environ.get("HEIMDALL_DAEMON_BIN", str(ROOT / "result" / "bin" / "ham-daemon"))
    require(os.path.exists(daemon_bin), f"missing ham-daemon binary: {daemon_bin}")
    temp_dir = tempfile.mkdtemp(prefix="heimdall-start-projoverride-")
    config_path = os.path.join(temp_dir, "config.toml")
    log_path = os.path.join(temp_dir, "daemon.log")
    data_dir = os.path.join(temp_dir, "data")
    with open(config_path, "w", encoding="utf-8") as f:
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
    log_file = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], cwd=ROOT, stdout=log_file, stderr=subprocess.STDOUT)
    instance = "coder@s-000000000123"
    try:
        wait_for_health()

        status, created = request_json("POST", "/agents/create", {
            "agent_instance_id": instance,
            "template_id": "coder",
            "provider_profile": "pi",
            "model_tier": "normal",
            "project_id": "proj-a",
        })
        require(status == 200 and created.get("ok"), created)
        require(show_project(instance) == "proj-a", "initial project should be proj-a")

        # Runtime restart clearing the project (explicit project_id_set).
        status, _ = request_json("POST", "/agents/start", {"agent_instance_id": instance, "project_id": "", "project_id_set": True})
        require(status == 200, "start clear should succeed")
        require(show_project(instance) == "", "explicit project_id_set='' must clear the instance project")

        # Runtime restart setting a new project.
        status, _ = request_json("POST", "/agents/start", {"agent_instance_id": instance, "project_id": "proj-b", "project_id_set": True})
        require(status == 200, "start set should succeed")
        require(show_project(instance) == "proj-b", "explicit project_id_set='proj-b' must set the instance project")

        # Ordinary start without the flag and empty project must PRESERVE the stored project.
        status, _ = request_json("POST", "/agents/start", {"agent_instance_id": instance, "project_id": ""})
        require(status == 200, "plain start should succeed")
        require(show_project(instance) == "proj-b", "start without project_id_set and empty project must preserve stored project")

        print("test_agents_start_project_override: ok")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        log_file.close()
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
