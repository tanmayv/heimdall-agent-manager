#!/usr/bin/env python3
"""Regression (TCE-6/TCE-11/TCE-12): first-class task delete.

Verifies:
- task_delete removes a task from active chain/task reads (not via cancelled).
- deleting a task with dependents is rejected with blocking_dependents ids.
- participants/comments are cleaned up (task no longer returned; comments gone).
- delete survives daemon restart (relational rows removed, not resurrected).
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
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49701"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "task-delete-client"
COORDINATOR_ID = "coord-task-delete@tce-e2e"
CHAIN_ID = "chain-task-delete"


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


def request_get(path, token=None):
    if token:
        sep = "&" if "?" in path else "?"
        path = f"{path}{sep}token={token}"
    req = urllib.request.Request(f"{DAEMON_URL}{path}", method="GET")
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


def chain_task_ids(coord_token):
    status, body = request_get(f"/task-chains/{CHAIN_ID}/tasks", token=coord_token)
    if status != 200:
        raise AssertionError(f"list chain tasks failed: status={status} body={body}")
    return [t["task_id"] for t in body.get("tasks", [])]


def start_daemon(daemon_bin, config_path, log_path):
    log = open(log_path, "a", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=log, stderr=subprocess.STDOUT)
    wait_for_daemon()
    return proc, log


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = bin_path(repo_dir, "result-daemon", "result", "ham-daemon")
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-1", "ham-ctl")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-2", "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-task-delete-")
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
        daemon_proc, daemon_log = start_daemon(daemon_bin, config_path, daemon_log_path)

        status, agent_res = request_post("/register", {
            "agent_class": "coord-task-delete",
            "agent_instance_id": COORDINATOR_ID,
            "display_name": "Task Delete Coordinator",
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
            "title": "Task delete regression",
            "chain_id": CHAIN_ID,
            "coordinator_agent_instance_id": COORDINATOR_ID,
            "wants_vcs": False,
            "no_scaffold": True,
        })
        require_ok("create chain", status, chain_res)

        task_a = create_task(coord_token, "Task A")
        task_b = create_task(coord_token, "Task B depends on A", depends_on=task_a)
        task_c = create_task(coord_token, "Task C standalone")

        # Add a comment to C so we can prove comment cleanup.
        status, cbody = request_post("/tasks/comment", {
            "agent_token": coord_token,
            "task_id": task_c,
            "chain_id": CHAIN_ID,
            "body": "comment on C",
        })
        require_ok("comment on C", status, cbody)

        # 1. Deleting A (which B depends on) must be rejected with dependents.
        status, body = request_post("/tasks/delete", {
            "agent_token": coord_token,
            "task_id": task_a,
            "chain_id": CHAIN_ID,
        })
        if status != 409 or body.get("error") != "blocking_dependents" or task_b not in body.get("blocking_dependents", []):
            raise AssertionError(f"TCE-6 dependent rejection failed: status={status} body={body}")

        # A must still be present after rejected delete.
        ids = chain_task_ids(coord_token)
        if task_a not in ids:
            raise AssertionError(f"TCE-6 task A wrongly removed after rejected delete: {ids}")

        # 2. Delete standalone C -> success; removed from active reads.
        status, body = request_post("/tasks/delete", {
            "agent_token": coord_token,
            "task_id": task_c,
            "chain_id": CHAIN_ID,
        })
        require_ok("delete C", status, body)
        if not body.get("deleted"):
            raise AssertionError(f"TCE-11 delete C missing deleted flag: {body}")

        ids = chain_task_ids(coord_token)
        if task_c in ids:
            raise AssertionError(f"TCE-6 task C still present after delete: {ids}")
        if task_a not in ids or task_b not in ids:
            raise AssertionError(f"TCE-6 delete removed unrelated tasks: {ids}")

        # /tasks/show for C must 404 (not cancelled row).
        status, show_c = request_post("/tasks/show", {"agent_token": coord_token, "task_id": task_c})
        if status == 200 and show_c.get("ok"):
            raise AssertionError(f"TCE-6 deleted task C still shown: {show_c}")

        # Comments for C must be gone.
        status, comments = request_get(f"/tasks/{task_c}/comments", token=coord_token)
        if status == 200 and comments.get("comments"):
            raise AssertionError(f"TCE-6 deleted task C comments not cleaned: {comments}")

        # 3. Delete B (dependent), then A is deletable.
        require_ok("delete B", *request_post("/tasks/delete", {"agent_token": coord_token, "task_id": task_b, "chain_id": CHAIN_ID}))
        status, body = request_post("/tasks/delete", {"agent_token": coord_token, "task_id": task_a, "chain_id": CHAIN_ID})
        require_ok("delete A after detaching B", status, body)

        # A/B/C must all be gone from active reads (the chain may still carry a
        # daemon-created discovery task, which is unrelated to our deletes).
        ids = chain_task_ids(coord_token)
        for tid in (task_a, task_b, task_c):
            if tid in ids:
                raise AssertionError(f"TCE-6 task {tid} not removed: {ids}")

        # 4. Restart durability: deleted tasks must not resurrect.
        daemon_proc.terminate()
        try:
            daemon_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon_proc.kill()
        daemon_proc, daemon_log = start_daemon(daemon_bin, config_path, daemon_log_path)

        ids = chain_task_ids(coord_token)
        for tid in (task_a, task_b, task_c):
            if tid in ids:
                raise AssertionError(f"TCE-12 deleted task {tid} resurrected after restart: {ids}")

        print("PASS: first-class task delete (dependent rejection, cleanup, restart durability)")
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
