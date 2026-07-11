#!/usr/bin/env python3
"""Regression for explicit coordinator --force review bypass."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.request
import urllib.error

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49643"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "force-gates-client"
COORDINATOR_ID = "lead@gates"
NON_COORDINATOR_ID = "coder@gates"


def bin_path(repo_dir, preferred, fallback, binary):
    preferred_path = os.path.join(repo_dir, preferred, "bin", binary)
    if os.path.exists(preferred_path):
        return preferred_path
    return os.path.join(repo_dir, fallback, "bin", binary)


def request_post(path, data, expect_error=False):
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status, json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        if expect_error:
            return exc.code, json.loads(body)
        raise AssertionError(f"HTTP {exc.code}: {body}") from exc


def run_ctl_json(ctl_bin, *args):
    proc = subprocess.run(
        [ctl_bin, "--daemon-url", DAEMON_URL, *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        raise AssertionError(f"ham-ctl failed rc={proc.returncode}\nSTDOUT={proc.stdout}\nSTDERR={proc.stderr}")
    for line in reversed([line.strip() for line in proc.stdout.splitlines() if line.strip()]):
        if line.startswith("{"):
            return json.loads(line)
    raise AssertionError(f"ham-ctl did not emit JSON: {proc.stdout!r}\nSTDERR={proc.stderr}")


def wait_for_daemon():
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{DAEMON_URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("daemon did not become healthy")


def chain_tasks(state, chain_id):
    return [task for task in state.get("tasks", []) if task.get("chain_id") == chain_id]


def required_reviewers(task):
    return [p.get("agent_instance_id") for p in task.get("participants", []) if p.get("role") == "lgtm_required"]


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = bin_path(repo_dir, "result-daemon", "result", "ham-daemon")
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-1", "ham-ctl")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-2", "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-force-gates-")
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
nudge_enabled = false

[ctl]
daemon_url = "{DAEMON_URL}"
ham_ctl_bin = "{ctl_bin}"
''')
        daemon_log = open(daemon_log_path, "w", encoding="utf-8")
        daemon_proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=daemon_log, stderr=subprocess.STDOUT)
        wait_for_daemon()

        _, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if not user_token:
            raise AssertionError(f"user registration failed: {user_res}")
        _, coord_res = request_post("/register", {"agent_class": "lead", "agent_instance_id": COORDINATOR_ID, "display_name": "Coordinator"})
        coordinator_token = coord_res.get("agent_token")
        if not coordinator_token:
            raise AssertionError(f"coordinator registration failed: {coord_res}")
        _, noncoord_res = request_post("/register", {"agent_class": "coder", "agent_instance_id": NON_COORDINATOR_ID, "display_name": "Non Coordinator"})
        noncoord_token = noncoord_res.get("agent_token")
        if not noncoord_token:
            raise AssertionError(f"non-coordinator registration failed: {noncoord_res}")

        _, project_res = request_post("/user-rpc", {
            "action": "project_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "name": "Force gates project",
            "anchors": [{"type": "vcs_kind", "value": "none"}],
        })
        project_id = project_res.get("project_id")
        if not project_id:
            raise AssertionError(f"project_create failed: {project_res}")

        _, chain_res = request_post("/user-rpc", {
            "action": "task_chain_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": project_id,
            "kind": "coding",
            "scaffold": "feature",
            "title": "Coordinator force regression",
            "description": "Plan keeps reviewer gate; coordinator can explicitly force.",
            "coordinator_agent_instance_id": COORDINATOR_ID,
            "wants_vcs": False,
        })
        chain_id = chain_res.get("chain_id")
        if not chain_id:
            raise AssertionError(f"task_chain_create failed: {chain_res}")

        _, state = request_post("/user-rpc", {"action": "list_tasks", "client_instance_id": CLIENT_ID, "client_token": user_token})
        tasks = chain_tasks(state, chain_id)
        by_title = {task.get("title", "").split(":", 1)[0].lower(): task for task in tasks}
        plan = by_title.get("plan")
        implement = by_title.get("implement")
        if not plan or not implement:
            raise AssertionError(f"expected plan and implement scaffold tasks, got: {tasks}")
        plan_reviewers = required_reviewers(plan)
        if not plan_reviewers:
            raise AssertionError(f"Plan must retain an explicit required reviewer gate: {plan}")
        impl_reviewers = required_reviewers(implement)
        if not impl_reviewers:
            raise AssertionError(f"Implement must retain required reviewer gate: {implement}")

        status, denied = request_post("/tasks/done", {
            "agent_token": noncoord_token,
            "task_id": plan["task_id"],
            "chain_id": chain_id,
            "body": "non coordinator should not force",
            "force": True,
        }, expect_error=True)
        if status != 403 or "force requires chain coordinator" not in denied.get("message", ""):
            raise AssertionError(f"expected non-coordinator force denial, got status={status} body={denied}")

        _, activate = request_post("/user-rpc", {
            "action": "task_chain_status",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "chain_id": chain_id,
            "status": "in_progress",
            "final_summary": "",
        })
        if not activate.get("ok"):
            raise AssertionError(f"chain activation failed: {activate}")

        force_reason = "Coordinator owns this control-plane Plan gate; no user decision required."
        forced = run_ctl_json(
            ctl_bin,
            "tasks", "done",
            "--token", coordinator_token,
            "--task-id", plan["task_id"],
            "--chain-id", chain_id,
            "--comment", force_reason,
            "--force",
        )
        if not forced.get("ok") or forced.get("status") != "approved":
            raise AssertionError(f"coordinator force done failed: {forced}")

        _, state_after = request_post("/user-rpc", {"action": "list_tasks", "client_instance_id": CLIENT_ID, "client_token": user_token})
        tasks_after = {task.get("task_id"): task for task in chain_tasks(state_after, chain_id)}
        plan_after = tasks_after[plan["task_id"]]
        implement_after = tasks_after[implement["task_id"]]
        if plan_after.get("status") != "approved":
            raise AssertionError(f"Plan should be approved by explicit coordinator force: {plan_after}")
        if implement_after.get("status") not in {"queued", "in_progress"}:
            raise AssertionError(f"Implement should unblock after forced Plan approval: {implement_after}")
        if not required_reviewers(implement_after):
            raise AssertionError(f"Implement lost required reviewer gate after force: {implement_after}")

        _, plan_log = request_post("/user-rpc", {
            "action": "task_log",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "task_id": plan["task_id"],
        })
        events = plan_log.get("events", [])
        if any(event.get("kind") == "Task_Review_Vote" for event in events):
            raise AssertionError(f"Force must not fabricate LGTM votes: {plan_log}")
        audit_events = [event for event in events if event.get("kind") == "Task_Status_Changed" and "FORCE_REVIEW_BYPASS" in event.get("body", "")]
        if len(audit_events) != 1:
            raise AssertionError(f"expected exactly one force audit status event, got: {plan_log}")
        audit = audit_events[0].get("body", "")
        for expected in [plan["task_id"], chain_id, COORDINATOR_ID, "prior_status=", "new_status=approved", force_reason, "timestamp_unix_ms="]:
            if expected not in audit:
                raise AssertionError(f"missing audit field {expected!r} in {audit!r}")

        print(json.dumps({
            "ok": True,
            "chain_id": chain_id,
            "plan_task_id": plan["task_id"],
            "plan_status": plan_after.get("status"),
            "plan_required_reviewers": required_reviewers(plan_after),
            "implement_task_id": implement["task_id"],
            "implement_status": implement_after.get("status"),
            "implement_required_reviewers": required_reviewers(implement_after),
            "force_audit": audit,
        }, indent=2))
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
