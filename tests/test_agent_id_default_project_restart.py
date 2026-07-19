#!/usr/bin/env python3
"""Integration: clearing an agent_id default project survives daemon restart.

Reproduces the reviewer NGTM scenario for task-19f67425326:
  1. Create durable `coder` with default project proj-a (seeds an instance event).
  2. Start a concrete instance (more older instance events carry proj-a).
  3. Clear the default project via /agents/update update_agent_id_defaults=true.
  4. Restart the daemon so replay + backfill run.
  5. The durable default project MUST stay cleared (backfill must not rehydrate
     proj-a from older instance events), and a freshly started instance must NOT
     inherit proj-a.
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
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49743"))
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


def write_config(path: str, data_dir: str):
    with open(path, "w", encoding="utf-8") as f:
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


def start_daemon(daemon_bin, config_path, log_path):
    log_file = open(log_path, "a", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], cwd=ROOT, stdout=log_file, stderr=subprocess.STDOUT)
    return proc, log_file


def stop_daemon(proc, log_file):
    if proc is not None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    if log_file is not None:
        log_file.close()


def main():
    daemon_bin = os.environ.get("HEIMDALL_DAEMON_BIN", str(ROOT / "result" / "bin" / "ham-daemon"))
    require(os.path.exists(daemon_bin), f"missing ham-daemon binary: {daemon_bin}")
    temp_dir = tempfile.mkdtemp(prefix="heimdall-agentid-projclear-")
    config_path = os.path.join(temp_dir, "config.toml")
    log_path = os.path.join(temp_dir, "daemon.log")
    data_dir = os.path.join(temp_dir, "data")
    write_config(config_path, data_dir)

    proc = None
    log_file = None
    try:
        proc, log_file = start_daemon(daemon_bin, config_path, log_path)
        wait_for_health()

        # Project must exist before an agent can be bound to it.
        status, reg = request_json("POST", "/user-client/register", {"user_id": "operator@local", "client_instance_id": "ui-defproj", "client_token": ""})
        require(status == 200 and reg.get("client_token"), reg)
        status, pres = request_json("POST", "/projects/create", {"agent_token": reg["client_token"], "project_id": "proj-a", "name": "proj-a"})
        require(status == 200 and pres.get("ok"), pres)

        # 1. Create durable coder with default project proj-a.
        status, created = request_json("POST", "/agents/create", {
            "agent_instance_id": "coder",
            "template_id": "coder",
            "provider_profile": "pi",
            "model_tier": "normal",
            "project_id": "proj-a",
        })
        require(status == 200 and created.get("ok"), created)

        # 2. Start a concrete instance -> seeds an older instance event with proj-a.
        status, started = request_json("POST", "/agents/start", {"agent_id": "coder"})
        require(status == 200 and started.get("ok"), started)

        # 3. Clear default project via authoritative durable update.
        status, updated = request_json("POST", "/agents/update", {
            "agent_instance_id": "coder",
            "provider_profile": "jetski",
            "model_tier": "smart",
            "project_id": "",
            "update_agent_id_defaults": True,
        })
        require(status == 200 and updated.get("ok"), updated)

        # 4. Restart daemon so replay + backfill run.
        stop_daemon(proc, log_file)
        proc, log_file = start_daemon(daemon_bin, config_path, log_path)
        wait_for_health()

        # 5a. The durable id-events file must not have rehydrated proj-a: the last
        #     coder upsert with an explicit set must remain cleared.
        id_events = Path(data_dir) / "agents" / "id-events.jsonl"
        require(id_events.exists(), f"missing id-events file: {id_events}")
        last_explicit_project = None
        for line in id_events.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            ev = json.loads(line)
            if ev.get("agent_id") != "coder":
                continue
            if ev.get("default_project_set"):
                last_explicit_project = ev.get("default_project_id")
        require(last_explicit_project == "", f"explicit default project should stay cleared after restart, got {last_explicit_project!r}")

        # 5b. A freshly started instance must NOT inherit proj-a.
        status, fresh = request_json("POST", "/agents/start", {"agent_id": "coder"})
        require(status == 200 and fresh.get("ok"), fresh)
        fresh_id = fresh.get("agent_instance_id")
        status, show = request_json("POST", "/agents/show", {"agent_instance_id": fresh_id})
        require(status == 200 and show.get("ok"), show)
        fresh_project = show.get("agent", {}).get("project_id", "")
        require(fresh_project == "", f"fresh instance must not inherit cleared default project, got {fresh_project!r}")

        print("test_agent_id_default_project_restart: ok")
    finally:
        stop_daemon(proc, log_file)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
