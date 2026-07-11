#!/usr/bin/env python3
"""Regression: ordinary comments must not regress approved tasks."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49648"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "approved-comment-client"
COORDINATOR_ID = "coord-approved-comment@bug4-e2e"
ASSIGNEE_ID = "worker-approved-comment@bug4-e2e"
CHAIN_ID = "chain-approved-comment-bug4"


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

    temp_home = tempfile.mkdtemp(prefix="heimdall-approved-comment-")
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
            "agent_class": "coord-approved-comment",
            "agent_instance_id": COORDINATOR_ID,
            "display_name": "Approved Comment Coordinator",
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
            "title": "Approved comment regression",
            "chain_id": CHAIN_ID,
            "coordinator_agent_instance_id": COORDINATOR_ID,
            "wants_vcs": False,
            "no_scaffold": True,
        })
        require_ok("create chain", status, chain_res)
        team_id = chain_res.get("team_id")
        if not team_id:
            raise AssertionError(f"create chain missing team_id: {chain_res}")

        status, add_member_res = request_post("/teams/add-member", {
            "agent_token": coord_token,
            "team_id": team_id,
            "role_key": "worker",
            "agent_instance_id": ASSIGNEE_ID,
        })
        require_ok("add assignee", status, add_member_res)

        status, task_res = request_post("/tasks/create", {
            "agent_token": coord_token,
            "chain_id": CHAIN_ID,
            "title": "Approved task should not regress",
            "assignee_agent_instance_id": ASSIGNEE_ID,
            "status": "planning",
        })
        require_ok("create task", status, task_res)
        task_id = task_res["task_id"]

        status, approve_res = request_post("/user-rpc", {
            "action": "task_status",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "task_id": task_id,
            "chain_id": CHAIN_ID,
            "status": "approved",
            "body": "Manual approval for regression setup.",
        })
        require_ok("approve task", status, approve_res)

        status, comment_res = request_post("/tasks/comment", {
            "agent_token": coord_token,
            "task_id": task_id,
            "chain_id": CHAIN_ID,
            "body": "Informational follow-up: thanks for the evidence.",
        })
        require_ok("add informational comment", status, comment_res)

        status, show_res = request_post("/tasks/show", {"agent_token": coord_token, "task_id": task_id})
        require_ok("show task", status, show_res)
        task = show_res.get("task", {})
        if task.get("status") != "approved":
            raise AssertionError(f"approved task regressed after ordinary comment: {show_res}")

        status, log_res = request_post("/tasks/log", {"agent_token": coord_token, "task_id": task_id})
        require_ok("task log", status, log_res)
        revert_events = [
            event for event in log_res.get("events", [])
            if event.get("kind") == "Task_Status_Changed" and event.get("author_agent_instance_id") == "system-comment-revert"
        ]
        if revert_events:
            raise AssertionError(f"ordinary comment emitted system-comment-revert: {revert_events}")

        print("PASS: ordinary comments do not regress approved tasks")
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
