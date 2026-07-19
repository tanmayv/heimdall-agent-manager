#!/usr/bin/env python3
"""Phase 1 regression: default durable agents and role/default-use map.

Covers TR-2/TR-3/TR-4 for an empty data dir:
- seed durable agent ids conversation/guide/coordinator/worker/reviewer
- seed conversation and generic worker templates
- expose/read configurable default-agent map
- set a map value via /agents/defaults (the ham-ctl command uses the same route)
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
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49761"))
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
default_agent_provider_profile = "pi"
default_agent_model_tier = "normal"
default_agent_id_conversation = "conversation"
default_agent_id_guide = "guide"
default_agent_id_coordinator = "coordinator"
default_agent_id_worker = "worker"
default_agent_id_assignee = "worker"
default_agent_id_coder = "worker"
default_agent_id_tester = "worker"
default_agent_id_researcher = "worker"
default_agent_id_specialist = "worker"
default_agent_id_reviewer = "reviewer"

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


def main():
    daemon_bin = os.environ.get("HEIMDALL_DAEMON_BIN", str(ROOT / "result" / "bin" / "ham-daemon"))
    ctl_bin = os.environ.get("HEIMDALL_CTL_BIN", str(ROOT / "result" / "bin" / "ham-ctl"))
    require(os.path.exists(daemon_bin), f"missing ham-daemon binary: {daemon_bin}")
    require(os.path.exists(ctl_bin), f"missing ham-ctl binary: {ctl_bin}")
    temp_dir = tempfile.mkdtemp(prefix="heimdall-phase1-default-agents-")
    config_path = os.path.join(temp_dir, "config.toml")
    log_path = os.path.join(temp_dir, "daemon.log")
    data_dir = os.path.join(temp_dir, "data")
    write_config(config_path, data_dir)
    log_file = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], cwd=ROOT, stdout=log_file, stderr=subprocess.STDOUT)
    try:
        wait_for_health()

        # Register a user client token for authenticated defaults reads/sets.
        status, reg = request_json("POST", "/user-client/register", {"user_id": "operator@local", "client_instance_id": "phase1-defaults", "client_token": ""})
        require(status == 200 and reg.get("client_token"), reg)
        token = reg["client_token"]

        status, agents = request_json("GET", "/agents?include_identities=true")
        require(status == 200 and agents.get("ok"), agents)
        identities = {row.get("agent_id"): row for row in agents.get("identities", [])}
        for aid in ("conversation", "guide", "coordinator", "worker", "reviewer"):
            require(aid in identities, f"missing seeded durable identity {aid}: {identities}")
        require(identities["worker"].get("template_id") == "worker", identities["worker"])

        status, templates = request_json("GET", "/agents/templates")
        require(status == 200 and templates.get("ok"), templates)
        template_ids = {row.get("template_id") for row in templates.get("templates", [])}
        require("worker" in template_ids, "generic worker template not seeded")
        require("conversation" in template_ids, "conversation template not seeded")

        # Read defaults via ham-ctl (TR-4 surface) and assert alias map (TR-3).
        out = subprocess.check_output([ctl_bin, "--config", config_path, "agents", "defaults", "--token", token], cwd=ROOT, text=True)
        defaults = json.loads(out)
        mapping = {row["use"]: row["agent_id"] for row in defaults.get("defaults", [])}
        require(mapping.get("coordinator") == "coordinator", mapping)
        require(mapping.get("worker") == "worker", mapping)
        require(mapping.get("reviewer") == "reviewer", mapping)
        for alias in ("assignee", "coder", "tester", "researcher", "specialist"):
            require(mapping.get(alias) == "worker", f"alias {alias} should map to worker: {mapping}")

        # Alias assignment: a coordinator/skill assigning the default-use "coder"
        # should materialize a concrete worker instance on an empty DB.
        status, task = request_json("POST", "/tasks/create", {
            "agent_token": token,
            "standalone": True,
            "title": "Alias resolution proof",
            "status": "planning",
            "assignee_agent_instance_id": "coder",
        })
        require(status == 200 and task.get("ok"), task)
        status, agents_after_task = request_json("GET", "/agents?include_identities=true")
        concrete_worker_ids = [row.get("agent_instance_id", "") for row in agents_after_task.get("agents", []) if row.get("agent_id") == "worker"]
        require(any(agent_id.startswith("worker@") for agent_id in concrete_worker_ids), concrete_worker_ids)

        # Set via ham-ctl and read back.
        out = subprocess.check_output([ctl_bin, "--config", config_path, "agents", "defaults", "set", "--token", token, "--use", "reviewer", "--agent-id", "custom-reviewer"], cwd=ROOT, text=True)
        changed = json.loads(out)
        require(changed.get("ok") and changed.get("default", {}).get("agent_id") == "custom-reviewer", changed)
        out = subprocess.check_output([ctl_bin, "--config", config_path, "agents", "defaults", "--token", token, "--use", "reviewer"], cwd=ROOT, text=True)
        reviewer_default = json.loads(out)
        require(reviewer_default.get("defaults", [{}])[0].get("agent_id") == "custom-reviewer", reviewer_default)

        # Idempotent restart: seeded identities remain one logical identity each.
        proc.terminate()
        proc.wait(timeout=5)
        log_file.close()
        log_file2 = open(log_path, "a", encoding="utf-8")
        proc2 = subprocess.Popen([daemon_bin, "--config", config_path], cwd=ROOT, stdout=log_file2, stderr=subprocess.STDOUT)
        proc = proc2
        wait_for_health()
        status, agents = request_json("GET", "/agents?include_identities=true")
        identities_after = [row.get("agent_id") for row in agents.get("identities", [])]
        for aid in ("conversation", "guide", "coordinator", "worker", "reviewer"):
            require(identities_after.count(aid) == 1, f"identity {aid} should be idempotent after restart: {identities_after}")
        log_file2.close()
        print("test_phase1_default_agents: ok")
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        try:
            log_file.close()
        except Exception:
            pass
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
