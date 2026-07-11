#!/usr/bin/env python3
"""Regression: task creation validates depends_on IDs before persisting."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49649"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "dependency-validation-client"
COORDINATOR_ID = "coord-dependency-validation@bug5-e2e"
CHAIN_A = "chain-dependency-validation-a"
CHAIN_B = "chain-dependency-validation-b"


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


def create_chain(user_token, chain_id, title):
    status, body = request_post("/user-rpc", {
        "action": "task_chain_create",
        "client_instance_id": CLIENT_ID,
        "client_token": user_token,
        "project_id": "default",
        "kind": "coding",
        "title": title,
        "chain_id": chain_id,
        "coordinator_agent_instance_id": COORDINATOR_ID,
        "wants_vcs": False,
        "no_scaffold": True,
    })
    require_ok(f"create chain {chain_id}", status, body)
    return body


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = bin_path(repo_dir, "result-daemon", "result", "ham-daemon")
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-1", "ham-ctl")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-2", "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-dependency-validation-")
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
            "agent_class": "coord-dependency-validation",
            "agent_instance_id": COORDINATOR_ID,
            "display_name": "Dependency Validation Coordinator",
        })
        coord_token = agent_res.get("agent_token")
        if status != 200 or not coord_token:
            raise AssertionError(f"register coordinator failed: status={status} body={agent_res}")

        status, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if status != 200 or not user_token:
            raise AssertionError(f"register user failed: status={status} body={user_res}")

        create_chain(user_token, CHAIN_A, "Dependency validation A")
        create_chain(user_token, CHAIN_B, "Dependency validation B")

        status, missing_dep = request_post("/tasks/create", {
            "agent_token": coord_token,
            "chain_id": CHAIN_A,
            "title": "Should reject missing dependency",
            "assignee_agent_instance_id": COORDINATOR_ID,
            "depends_on": "task-does-not-exist",
            "status": "planning",
        })
        if status != 400 or missing_dep.get("error") != "dependency_not_found" or missing_dep.get("dependency_task_ids") != ["task-does-not-exist"]:
            raise AssertionError(f"missing dependency was not rejected clearly: status={status} body={missing_dep}")

        status, task_a = request_post("/tasks/create", {
            "agent_token": coord_token,
            "chain_id": CHAIN_A,
            "title": "Real dependency in chain A",
            "assignee_agent_instance_id": COORDINATOR_ID,
            "status": "planning",
        })
        require_ok("create real task in chain A", status, task_a)
        task_a_id = task_a["task_id"]

        status, cross_chain = request_post("/tasks/create", {
            "agent_token": coord_token,
            "chain_id": CHAIN_B,
            "title": "Should reject cross-chain dependency",
            "assignee_agent_instance_id": COORDINATOR_ID,
            "depends_on": task_a_id,
            "status": "planning",
        })
        if status != 400 or cross_chain.get("error") != "dependency_cross_chain" or cross_chain.get("dependency_task_ids") != [task_a_id]:
            raise AssertionError(f"cross-chain dependency was not rejected clearly: status={status} body={cross_chain}")

        status, task_b = request_post("/tasks/create", {
            "agent_token": coord_token,
            "chain_id": CHAIN_A,
            "title": "Valid same-chain dependency",
            "assignee_agent_instance_id": COORDINATOR_ID,
            "depends_on": task_a_id,
            "status": "planning",
        })
        require_ok("create task with valid same-chain dependency", status, task_b)

        print("PASS: task creation rejects missing and cross-chain dependencies")
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
