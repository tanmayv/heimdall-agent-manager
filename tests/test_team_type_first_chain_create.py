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


def chain_by_id(state, chain_id):
    for chain in state.get("chains", []):
        if chain.get("chain_id") == chain_id:
            return chain
    raise AssertionError(f"chain not found in state: {chain_id}")


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
            kind="coding",
            wants_vcs=False,
        )
        chain_id = default_chain.get("chain_id")
        discovery_task_id = default_chain.get("discovery_task_id")
        coordinator_id = default_chain.get("coordinator_agent_instance_id")
        if not chain_id or not discovery_task_id or not coordinator_id:
            raise AssertionError(f"default task_chain_create missing ids: {default_chain}")
        if default_chain.get("status") != "in_progress":
            raise AssertionError(f"new chain must be active/in_progress by default: {default_chain}")

        state = user_rpc(user_token, "list_tasks")
        chain = chain_by_id(state, chain_id)
        if chain.get("status") != "in_progress":
            raise AssertionError(f"projected chain status should be in_progress: {chain}")
        if chain.get("title") in ("", None):
            raise AssertionError(f"title should default to a placeholder: {chain}")
        if chain.get("coordinator_agent_instance_id") != coordinator_id:
            raise AssertionError(f"response/projected coordinator mismatch: response={default_chain} chain={chain}")

        tasks = chain_tasks(state, chain_id)
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
        assert_contains_all(
            discovery.get("description", ""),
            [
                "Contact the user in chain chat",
                "explain the selected team kind and roles",
                "Rename/update the chain title and description",
                "Create downstream tasks/dependencies or apply an appropriate task-bundle template",
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
        updated_state = user_rpc(user_token, "list_tasks")
        updated_chain = chain_by_id(updated_state, chain_id)
        if updated_chain.get("title") != "Clarified chain title" or updated_chain.get("description") != "Clarified chain goal":
            raise AssertionError(f"coordinator/user should be able to update title/description: {updated_chain}")

        legacy_chain = user_rpc(
            user_token,
            "task_chain_create",
            project_id=project_id,
            kind="coding",
            title="Legacy explicit scaffold",
            scaffold="feature",
            wants_vcs=False,
        )
        legacy_chain_id = legacy_chain.get("chain_id")
        if not legacy_chain_id:
            raise AssertionError(f"legacy scaffold chain create failed: {legacy_chain}")
        legacy_state = user_rpc(user_token, "list_tasks")
        legacy_tasks = chain_tasks(legacy_state, legacy_chain_id)
        legacy_titles = [task.get("title", "") for task in legacy_tasks]
        if len(legacy_tasks) <= 1 or not any(title.startswith("Plan:") for title in legacy_titles):
            raise AssertionError(f"explicit legacy scaffold should still append scaffold tasks: {legacy_titles}")

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
            "legacy_chain_id": legacy_chain_id,
            "legacy_task_count": len(legacy_tasks),
            "legacy_titles": legacy_titles,
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
