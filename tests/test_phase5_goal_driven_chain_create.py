#!/usr/bin/env python3
"""Phase 5 regression: goal-driven, kind-free task-chain creation.

Covers TR-10/TR-11/TR-19:
- chain create rejects legacy kind/scaffold input;
- a no-VCS chain creates only the coordinator kickoff/planning task;
- an explicit VCS request creates a distinct VCS setup task;
- scaffold/chain-planning recipes are seeded as editable active skill memories.
"""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49766"))
URL = f"http://{HOST}:{PORT}"
ROOT = Path(__file__).resolve().parents[1]

RECIPE_SKILLS = {
    "scaffold-coding-feature",
    "scaffold-coding-bugfix",
    "scaffold-research",
    "scaffold-solo",
    "vcs-workspace-setup",
}


def request_json(method: str, path: str, body=None):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(f"{URL}{path}", data=data, headers={"Content-Type": "application/json"}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            payload = res.read().decode("utf-8")
            return res.status, (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as e:
        payload = e.read().decode("utf-8")
        return e.code, (json.loads(payload) if payload else {})


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
default_agent_id_coordinator = "coordinator"
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


def tasks_for_chain(token: str, chain_id: str):
    status, res = request_json("GET", f"/task-chains/{chain_id}/tasks?agent_token={token}")
    require(status == 200, res)
    return res.get("tasks", [])


def assert_no_kind_payload(obj, label):
    dumped = json.dumps(obj, sort_keys=True)
    require('"kind"' not in dumped, f"{label} leaked kind field: {dumped}")


def assert_no_kind_or_team_payload(obj, label):
    dumped = json.dumps(obj, sort_keys=True)
    require('"kind"' not in dumped, f"{label} leaked kind field: {dumped}")
    require('"team_id"' not in dumped, f"{label} leaked team_id field: {dumped}")


def main():
    daemon_bin = os.environ.get("HEIMDALL_DAEMON_BIN", str(ROOT / "result" / "bin" / "ham-daemon"))
    ctl_bin = os.environ.get("HEIMDALL_CTL_BIN", str(ROOT / "result" / "bin" / "ham-ctl"))
    require(os.path.exists(daemon_bin), f"missing ham-daemon binary: {daemon_bin}")
    require(os.path.exists(ctl_bin), f"missing ham-ctl binary: {ctl_bin}")

    temp_dir = tempfile.mkdtemp(prefix="heimdall-phase5-goal-chain-")
    config_path = os.path.join(temp_dir, "config.toml")
    log_path = os.path.join(temp_dir, "daemon.log")
    data_dir = os.path.join(temp_dir, "data")
    write_config(config_path, data_dir)
    log_file = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], cwd=ROOT, stdout=log_file, stderr=subprocess.STDOUT)
    try:
        wait_for_health()
        status, reg = request_json("POST", "/register", {
            "agent_class": "phase5-goal-chain",
            "agent_instance_id": "phase5-goal-chain@default",
            "display_name": "Phase 5 Goal Chain",
        })
        require(status == 200 and reg.get("agent_token"), reg)
        token = reg["agent_token"]

        # TR-11: recipe skills are normal active, globally applicable skill memories.
        status, listed = request_json("POST", "/memory/list", {"agent_token": token, "type": "skill"})
        require(status == 200 and listed.get("ok"), listed)
        by_title = {rec.get("title"): rec for rec in listed.get("records", [])}
        missing = RECIPE_SKILLS - set(by_title)
        require(not missing, f"missing recipe skill seeds: {sorted(missing)}")
        for title in RECIPE_SKILLS:
            rec = by_title[title]
            require(rec.get("status") == "active" and rec.get("type") == "skill", rec)
            require(rec.get("target_agent_id", "") == "" and rec.get("target_project_id", "") == "", rec)
            require(f"name: {title}" in rec.get("body", "") and "description:" in rec.get("body", ""), rec)
            require(rec.get("source_task_id") == "task-19f7ae4a44c", rec)

        # TR-10: legacy kind/scaffold chain create input fails closed.
        status, bad = request_json("POST", "/task-chains/create", {
            "agent_token": token,
            "kind": "coding",
            "title": "Legacy kind should fail",
            "description": "legacy input",
        })
        require(status == 400 and "no longer accepts kind/scaffold" in bad.get("message", ""), bad)
        ctl_out = subprocess.check_output([ctl_bin, "--config", config_path, "task-chains", "create", "--token", token, "--kind", "coding", "--goal", "legacy"], cwd=ROOT, text=True)
        require("no longer accepts kind/scaffold" in ctl_out, ctl_out)
        ctl_out = subprocess.check_output([ctl_bin, "--config", config_path, "task-chains", "create", "--token", token, "--kind=coding", "--goal", "legacy"], cwd=ROOT, text=True)
        require("no longer accepts kind/scaffold" in ctl_out, ctl_out)
        ctl_out = subprocess.check_output([ctl_bin, "--config", config_path, "task-chains", "create", "--token", token, "--scaffold=feature", "--goal", "legacy"], cwd=ROOT, text=True)
        require("no longer accepts kind/scaffold" in ctl_out, ctl_out)

        # TR-10: goal-only no-VCS creation starts with exactly one coordinator kickoff task.
        status, chain = request_json("POST", "/task-chains/create", {
            "agent_token": token,
            "title": "Goal-only research chain",
            "goal": "Research the safest migration plan",
            "wants_vcs": False,
        })
        require(status == 200 and chain.get("ok"), chain)
        assert_no_kind_or_team_payload(chain, "create response")
        chain_id = chain["chain_id"]
        tasks = tasks_for_chain(token, chain_id)
        require(len(tasks) == 1, tasks)
        kickoff = tasks[0]
        require(kickoff.get("task_id") == chain.get("coordinator_kickoff_task_id"), (chain, tasks))
        require(kickoff.get("title") == "Plan task chain from goal", kickoff)
        require("no daemon-selected chain kind" in kickoff.get("description", ""), kickoff)
        require("scaffold-coding-feature" in kickoff.get("description", ""), kickoff)
        require(kickoff.get("assignee_agent_instance_id", "").startswith("coordinator@"), kickoff)

        status, shown = request_json("GET", f"/task-chains/{chain_id}?agent_token={token}")
        require(status == 200, shown)
        assert_no_kind_payload(shown, "chain show")

        # TR-19: explicit VCS request adds a distinct setup task visible in the plan.
        status, vcs_chain = request_json("POST", "/task-chains/create", {
            "agent_token": token,
            "title": "Goal chain with VCS",
            "goal": "Implement a small change with a workspace",
            "wants_vcs": True,
        })
        require(status == 200 and vcs_chain.get("ok"), vcs_chain)
        assert_no_kind_or_team_payload(vcs_chain, "vcs create response")
        require(vcs_chain.get("workspace_setup_task_id") and vcs_chain.get("coordinator_kickoff_task_id"), vcs_chain)
        require(vcs_chain["workspace_setup_task_id"] != vcs_chain["coordinator_kickoff_task_id"], vcs_chain)
        vcs_tasks = tasks_for_chain(token, vcs_chain["chain_id"])
        require(len(vcs_tasks) == 2, vcs_tasks)
        setup = [t for t in vcs_tasks if t.get("task_id") == vcs_chain["workspace_setup_task_id"]][0]
        require(setup.get("title") == "Prepare chain workspace", setup)
        require("vcs-workspace-setup" in setup.get("description", ""), setup)
        require(setup.get("depends_on") == vcs_chain["coordinator_kickoff_task_id"], setup)

        print("test_phase5_goal_driven_chain_create: ok")
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
