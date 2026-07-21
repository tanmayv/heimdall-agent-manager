#!/usr/bin/env python3
"""Regression for team-type-first task chain creation defaults."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49647"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "team-type-first-client"


def bin_path(repo_dir, preferred, fallback, binary):
    preferred_path = os.path.join(repo_dir, preferred, "bin", binary)
    if os.path.exists(preferred_path):
        return preferred_path
    return os.path.join(repo_dir, fallback, "bin", binary)


def request_post(path, data, expect_error=False, headers=None):
    h = {"Content-Type": "application/json"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers=h,
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


def request_get(path, headers=None):
    h = {}
    if headers:
        h.update(headers)
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        headers=h,
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status, json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        raise AssertionError(f"HTTP {exc.code}: {body}") from exc


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


def get_chain_tasks(client_token, chain_id):
    status, res = request_get(f"/tasks?chain_id={chain_id}", headers={"Authorization": f"Bearer {client_token}"})
    if status != 200:
        raise AssertionError(f"failed to get tasks: {status} {res}")
    return res.get("tasks")


def get_chain_by_id(client_token, chain_id):
    status, res = request_get(f"/task-chains/{chain_id}", headers={"Authorization": f"Bearer {client_token}"})
    if status != 200:
        raise AssertionError(f"failed to get chain: {status} {res}")
    return res.get("chain")


def user_rpc(client_token, action, **kwargs):
    body = {"action": action, "client_instance_id": CLIENT_ID, "client_token": client_token}
    body.update(kwargs)
    _, res = request_post("/user-rpc", body)
    return res


def assert_contains_all(text, snippets):
    missing = [snippet for snippet in snippets if snippet not in text]
    if missing:
        raise AssertionError(f"missing snippets {missing!r} in text:\n{text}")


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = bin_path(repo_dir, "result-daemon", "result", "ham-daemon")
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-1", "ham-ctl")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-2", "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-team-type-first-")
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

        # Register coordinator agent
        status, agent_res = request_post("/register", {
            "protocol_version": 1,
            "agent_class": "coordinator",
            "agent_instance_id": "coordinator@local",
            "display_name": "Test Coordinator",
        })
        if status != 200:
            raise AssertionError(f"failed to register coordinator: {status} {agent_res}")

        project_res = user_rpc(
            user_token,
            "project_create",
            name="Team type first project",
            anchors=[{"type": "vcs_kind", "value": "none"}],
        )
        project_id = project_res.get("project_id")
        if not project_id:
            raise AssertionError(f"project_create failed: {project_res}")

        default_chain = user_rpc(
            user_token,
            "task_chain_create",
            project_id=project_id,
            title="Team first chain",
            description="Verify team type first chain creation",
            coordinator_agent_instance_id="coordinator@local",
            wants_vcs=False,
        )
        chain_id = default_chain.get("chain_id")
        discovery_task_id = default_chain.get("discovery_task_id")
        coordinator_id = default_chain.get("coordinator_agent_instance_id")
        if not chain_id or not discovery_task_id or not coordinator_id:
            raise AssertionError(f"default task_chain_create missing ids: {default_chain}")
        if default_chain.get("status") != "in_progress":
            raise AssertionError(f"new chain must be active/in_progress by default: {default_chain}")

        chain = get_chain_by_id(user_token, chain_id)
        if chain.get("status") != "in_progress":
            raise AssertionError(f"projected chain status should be in_progress: {chain}")
        if chain.get("title") != "Team first chain":
            raise AssertionError(f"title mismatch: {chain}")
        if chain.get("coordinator_agent_instance_id") != coordinator_id:
            raise AssertionError(f"response/projected coordinator mismatch: response={default_chain} chain={chain}")

        tasks = get_chain_tasks(user_token, chain_id)
        if len(tasks) != 1:
            raise AssertionError(f"default create should create exactly one discovery task, got {len(tasks)}: {tasks}")
        discovery = tasks[0]
        if discovery.get("task_id") != discovery_task_id:
            raise AssertionError(f"discovery task id mismatch: response={default_chain} task={discovery}")
        if discovery.get("status") not in {"queued", "ready"}:
            raise AssertionError(f"discovery task should be ready/queued, got: {discovery}")
        if discovery.get("assignee_agent_instance_id") != coordinator_id:
            raise AssertionError(f"discovery task should be assigned to coordinator: response={default_chain} task={discovery}")
        review_participants = [p for p in discovery.get("participants", []) if p.get("role") == "lgtm_required"]
        if review_participants:
            raise AssertionError(f"discovery task should not introduce a required review participant by default: {discovery}")
        
        # Note: description is lazy loaded, so we must fetch the task details to assert description!
        status, task_detail_res = request_get(f"/tasks/{discovery_task_id}", headers={"Authorization": f"Bearer {user_token}"})
        if status != 200:
             raise AssertionError(f"failed to get task details: {status} {task_detail_res}")
        discovery_detail = task_detail_res.get("task", {})
        assert_contains_all(
            discovery_detail.get("description", ""),
            [
                "Initial coordinator kickoff task for a goal-driven task chain",
                "Read applicable skills, especially `coordinator-playbook`",
                "Clarify the user goal through chain chat",
                "Create downstream tasks with dependencies",
                "Mark this kickoff task done once the downstream task chain is ready to execute",
            ],
        )

        update_res = user_rpc(
            user_token,
            "task_chain_update",
            chain_id=chain_id,
            title="Clarified chain title",
            description="Clarified chain goal",
        )
        if not update_res.get("ok"):
            raise AssertionError(f"chain update failed: {update_res}")
        updated_chain = get_chain_by_id(user_token, chain_id)
        if updated_chain.get("title") != "Clarified chain title" or updated_chain.get("description") != "Clarified chain goal":
            raise AssertionError(f"coordinator/user should be able to update title/description: {updated_chain}")

        print(json.dumps({
            "ok": True,
            "default_chain_id": chain_id,
            "default_chain_status": chain.get("status"),
            "default_chain_title": chain.get("title"),
            "coordinator_agent_instance_id": coordinator_id,
            "discovery_task_id": discovery_task_id,
            "discovery_status": discovery.get("status"),
            "default_task_count": len(tasks),
            "updated_title": updated_chain.get("title"),
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
