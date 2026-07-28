#!/usr/bin/env python3
"""Regression: manual task status start cannot bypass depends_on gating."""
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
CLIENT_ID = "dependency-gating-client"
COORDINATOR_ID = "coord-dependency-gating@bug2-e2e"
ASSIGNEE_ID = "worker-dependency-gating@bug2-e2e"
CHAIN_ID = "chain-dependency-gating-bug2"


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


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = bin_path(repo_dir, "result-daemon", "result", "ham-daemon")
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-1", "ham-ctl")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-2", "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-task-dep-gating-")
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
            "protocol_version": 1,
            "agent_class": "coord-dependency-gating",
            "agent_instance_id": COORDINATOR_ID,
            "display_name": "Dependency Gating Coordinator",
        })
        coord_token = agent_res.get("agent_token")
        if status != 200 or not coord_token:
            raise AssertionError(f"register coordinator failed: status={status} body={agent_res}")

        status, worker_res = request_post("/register", {
            "protocol_version": 1,
            "agent_class": "worker-dependency-gating",
            "agent_instance_id": ASSIGNEE_ID,
            "display_name": "Dependency Gating Worker",
        })
        if status != 200:
            raise AssertionError(f"register worker failed: status={status} body={worker_res}")

        status, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if status != 200 or not user_token:
            raise AssertionError(f"register user failed: status={status} body={user_res}")

        status, chain_res = request_post("/user-rpc", {
            "action": "task_chain_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "title": "Dependency gating regression",
            "chain_id": CHAIN_ID,
            "coordinator_agent_instance_id": COORDINATOR_ID,
            "wants_vcs": False,
        })
        require_ok("create chain", status, chain_res)
        team_id = CHAIN_ID



        status, task_a_res = request_post("/tasks/create", {
            "agent_token": coord_token,
            "chain_id": CHAIN_ID,
            "title": "Step A",
            "assignee_agent_instance_id": ASSIGNEE_ID,
            "status": "planning",
        })
        require_ok("create prerequisite task", status, task_a_res)
        task_a = task_a_res["task_id"]

        status, task_b_res = request_post("/tasks/create", {
            "agent_token": coord_token,
            "chain_id": CHAIN_ID,
            "title": "Step B",
            "assignee_agent_instance_id": ASSIGNEE_ID,
            "depends_on": task_a,
            "status": "planning",
        })
        require_ok("create dependent task", status, task_b_res)
        task_b = task_b_res["task_id"]

        status, blocked = request_post("/user-rpc", {
            "action": "task_status",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "task_id": task_b,
            "chain_id": CHAIN_ID,
            "status": "in_progress",
            "body": "Manual start should be dependency-gated.",
        })
        if status != 409 or blocked.get("error") != "dependency" or task_a not in blocked.get("blocking_task_ids", []):
            raise AssertionError(f"dependent task start was not blocked: status={status} body={blocked}")

        require_ok("start prerequisite", *request_post("/user-rpc", {
            "action": "task_status",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "task_id": task_a,
            "chain_id": CHAIN_ID,
            "status": "in_progress",
            "body": "Start prerequisite.",
        }))
        require_ok("submit prerequisite", *request_post("/user-rpc", {
            "action": "task_status",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "task_id": task_a,
            "chain_id": CHAIN_ID,
            "status": "review_ready",
            "body": "Prerequisite done.",
        }))
        require_ok("approve prerequisite", *request_post("/user-rpc", {
            "action": "task_status",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "task_id": task_a,
            "chain_id": CHAIN_ID,
            "status": "approved",
            "body": "Approve prerequisite.",
        }))

        status, started = request_post("/user-rpc", {
            "action": "task_status",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "task_id": task_b,
            "chain_id": CHAIN_ID,
            "status": "in_progress",
            "body": "Start after dependency approval.",
        })
        require_ok("start dependent after approval", status, started)

        print("PASS: manual in_progress status transition respects depends_on gating")
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
