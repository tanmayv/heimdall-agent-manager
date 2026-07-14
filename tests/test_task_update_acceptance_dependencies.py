#!/usr/bin/env python3
"""Regression (TCE-3/4/5/11/12): task_update can edit acceptance criteria and
dependencies with presence semantics and cycle prevention.

Verifies:
- acceptance_criteria only edit does not wipe title/description/depends_on.
- depends_on only edit does not wipe acceptance_criteria.
- depends_on rejects unknown ids, self-references, and cycles before persist.
- valid dependency edit persists and is reflected in /tasks/show.
"""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49661"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "task-update-meta-client"
COORDINATOR_ID = "coord-task-update-meta@tce-e2e"
CHAIN_ID = "chain-task-update-meta"


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


def require_ok(label, status, body):
    if status != 200 or not body.get("ok"):
        raise AssertionError(f"{label} failed: status={status} body={body}")


def show_task(coord_token, task_id):
    status, body = request_post("/tasks/show", {"agent_token": coord_token, "task_id": task_id})
    require_ok(f"show {task_id}", status, body)
    return body["task"]


def create_task(coord_token, title, depends_on=None):
    payload = {
        "agent_token": coord_token,
        "chain_id": CHAIN_ID,
        "title": title,
        "assignee_agent_instance_id": COORDINATOR_ID,
        "status": "planning",
    }
    if depends_on is not None:
        payload["depends_on"] = depends_on
    status, body = request_post("/tasks/create", payload)
    require_ok(f"create task {title}", status, body)
    return body["task_id"]


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = bin_path(repo_dir, "result-daemon", "result", "ham-daemon")
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-1", "ham-ctl")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-2", "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-task-update-meta-")
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

[ctl]
daemon_url = "{DAEMON_URL}"
ham_ctl_bin = "{ctl_bin}"
''')
        daemon_log = open(daemon_log_path, "w", encoding="utf-8")
        daemon_proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=daemon_log, stderr=subprocess.STDOUT)
        wait_for_daemon()

        status, agent_res = request_post("/register", {
            "agent_class": "coord-task-update-meta",
            "agent_instance_id": COORDINATOR_ID,
            "display_name": "Task Update Meta Coordinator",
        })
        coord_token = agent_res.get("agent_token")
        if status != 200 or not coord_token:
            raise AssertionError(f"register coordinator failed: status={status} body={agent_res}")

        status, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if status != 200 or not user_token:
            raise AssertionError(f"register user failed: status={status} body={user_res}")

        status, chain_res = request_post("/user-rpc", {
            "action": "task_chain_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": "default",
            "kind": "coding",
            "title": "Task update metadata regression",
            "chain_id": CHAIN_ID,
            "coordinator_agent_instance_id": COORDINATOR_ID,
            "wants_vcs": False,
            "no_scaffold": True,
        })
        require_ok("create chain", status, chain_res)

        task_a = create_task(coord_token, "Task A")
        task_b = create_task(coord_token, "Task B")
        task_c = create_task(coord_token, "Task C")

        # 1. Seed B with a description + acceptance criteria via update.
        status, body = request_post("/tasks/update", {
            "agent_token": coord_token,
            "task_id": task_b,
            "chain_id": CHAIN_ID,
            "description": "B description",
            "acceptance_criteria": "B accepts when X",
        })
        require_ok("seed B metadata", status, body)
        tb = show_task(coord_token, task_b)
        if tb["description"] != "B description" or tb["acceptance_criteria"] != "B accepts when X":
            raise AssertionError(f"TCE-4 seed failed: {tb}")

        # 2. depends_on-only edit must NOT wipe acceptance_criteria/description.
        status, body = request_post("/tasks/update", {
            "agent_token": coord_token,
            "task_id": task_b,
            "chain_id": CHAIN_ID,
            "depends_on": task_a,
        })
        require_ok("B depends_on A", status, body)
        tb = show_task(coord_token, task_b)
        if tb["depends_on"] != task_a:
            raise AssertionError(f"TCE-4 depends_on not applied: {tb}")
        if tb["acceptance_criteria"] != "B accepts when X" or tb["description"] != "B description":
            raise AssertionError(f"TCE-4 depends-only edit wiped fields: {tb}")

        # 3. acceptance_criteria-only edit must NOT wipe depends_on.
        status, body = request_post("/tasks/update", {
            "agent_token": coord_token,
            "task_id": task_b,
            "chain_id": CHAIN_ID,
            "acceptance_criteria": "B accepts when Y",
        })
        require_ok("B acceptance edit", status, body)
        tb = show_task(coord_token, task_b)
        if tb["acceptance_criteria"] != "B accepts when Y":
            raise AssertionError(f"TCE-4 acceptance edit failed: {tb}")
        if tb["depends_on"] != task_a:
            raise AssertionError(f"TCE-4 acceptance-only edit wiped depends_on: {tb}")

        # 4. unknown dependency id rejected.
        status, body = request_post("/tasks/update", {
            "agent_token": coord_token,
            "task_id": task_c,
            "chain_id": CHAIN_ID,
            "depends_on": "task-does-not-exist",
        })
        if status != 400 or body.get("error") != "dependency_not_found":
            raise AssertionError(f"TCE-5 unknown dep not rejected: status={status} body={body}")

        # 5. self dependency rejected.
        status, body = request_post("/tasks/update", {
            "agent_token": coord_token,
            "task_id": task_c,
            "chain_id": CHAIN_ID,
            "depends_on": task_c,
        })
        if status != 400 or body.get("error") != "self_dependency":
            raise AssertionError(f"TCE-5 self dep not rejected: status={status} body={body}")

        # 6. cycle rejected: B already depends on A. Make A depend on B -> cycle.
        status, body = request_post("/tasks/update", {
            "agent_token": coord_token,
            "task_id": task_a,
            "chain_id": CHAIN_ID,
            "depends_on": task_b,
        })
        if status != 400 or body.get("error") != "dependency_cycle":
            raise AssertionError(f"TCE-5 cycle not rejected: status={status} body={body}")

        # 7. transitive cycle: C depends on B (B->A). Then A depends on C -> cycle.
        status, body = request_post("/tasks/update", {
            "agent_token": coord_token,
            "task_id": task_c,
            "chain_id": CHAIN_ID,
            "depends_on": task_b,
        })
        require_ok("C depends_on B", status, body)
        status, body = request_post("/tasks/update", {
            "agent_token": coord_token,
            "task_id": task_a,
            "chain_id": CHAIN_ID,
            "depends_on": task_c,
        })
        if status != 400 or body.get("error") != "dependency_cycle":
            raise AssertionError(f"TCE-5 transitive cycle not rejected: status={status} body={body}")

        # 8. clearing dependencies with empty string works.
        status, body = request_post("/tasks/update", {
            "agent_token": coord_token,
            "task_id": task_b,
            "chain_id": CHAIN_ID,
            "depends_on": "",
        })
        require_ok("clear B deps", status, body)
        tb = show_task(coord_token, task_b)
        if tb["depends_on"] != "":
            raise AssertionError(f"TCE-4 clearing deps failed: {tb}")

        print("PASS: task_update acceptance criteria + dependency edits with cycle prevention")
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
