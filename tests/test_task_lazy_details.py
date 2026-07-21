#!/usr/bin/env python3
"""Integration: task list excludes description/comments, detail endpoint includes them."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49784"))
URL = f"http://{HOST}:{PORT}"
ROOT = Path(__file__).resolve().parents[1]
CID = "heimdall-task-lazy-test"


def req(method, path, body=None, headers=None):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    h = {"Content-Type": "application/json"}
    if headers:
        h.update(headers)
    r = urllib.request.Request(f"{URL}{path}", data=data, headers=h, method=method)
    with urllib.request.urlopen(r, timeout=10) as res:
        payload = res.read().decode("utf-8")
        return res.status, (json.loads(payload) if payload else {})


def rpc(action, ctok, **fields):
    body = {"action": action, "client_instance_id": CID, "client_token": ctok}
    body.update(fields)
    _, data = req("POST", "/user-rpc", body)
    return data


def wait_health():
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("daemon did not become healthy")


def require(cond, msg):
    if not cond:
        raise AssertionError(msg)


def start(daemon_bin, cfg, log):
    lf = open(log, "a", encoding="utf-8")
    return subprocess.Popen([daemon_bin, "--config", cfg], cwd=ROOT, stdout=lf, stderr=subprocess.STDOUT), lf


def bin_path(repo_dir, preferred, fallback, binary):
    preferred_path = os.path.join(repo_dir, preferred, "bin", binary)
    if os.path.exists(preferred_path):
        return preferred_path
    return os.path.join(repo_dir, fallback, "bin", binary)


def main():
    daemon_bin = os.environ.get(
        "HEIMDALL_DAEMON_BIN",
        bin_path(str(ROOT), "result-daemon", "result", "ham-daemon")
    )
    require(os.path.exists(daemon_bin), f"missing ham-daemon binary: {daemon_bin}")
    tmp = tempfile.mkdtemp(prefix="heimdall-task-lazy-")
    cfg = os.path.join(tmp, "config.toml")
    log = os.path.join(tmp, "daemon.log")
    data_dir = os.path.join(tmp, "data")
    with open(cfg, "w", encoding="utf-8") as f:
        f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{data_dir}"
user_id = "operator@local"
wrapper_bin = "/bin/sh"

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
    proc, lf = start(daemon_bin, cfg, log)
    try:
        wait_health()
        _, reg = req("POST", "/user-client/register", {"user_id": "operator@local", "client_instance_id": CID})
        ctok = reg["client_token"]

        # Register coordinator agent
        status, agent_res = req("POST", "/register", {
            "protocol_version": 1,
            "agent_class": "coordinator",
            "agent_instance_id": "coordinator@local",
            "display_name": "Test Coordinator"
        })
        require(status == 200, f"failed to register coordinator: {status} {agent_res}")

        # 1. Create a task chain
        chain_id = "chain-test-lazy"
        chain_res = rpc("task_chain_create", ctok, chain_id=chain_id, title="Test Chain", coordinator_agent_instance_id="coordinator@local")
        require(chain_res.get("ok"), "failed to create chain")

        # 2. Create a task with description and AC
        desc = "This is a very long description that should be lazy loaded"
        ac = "AC: Must load lazily"
        task_res = rpc("task_create", ctok, chain_id=chain_id, title="Test Task", description=desc, acceptance_criteria=ac, status="in_progress")
        require(task_res.get("ok"), "failed to create task")
        task_id = task_res.get("task_id")
        require(bool(task_id), "missing task_id in response")

        # 3. Add a comment to the task
        comment_body = "This is a test comment body"
        comment_res = rpc("task_comment", ctok, task_id=task_id, chain_id=chain_id, body=comment_body)
        require(comment_res.get("ok"), "failed to add comment")
        comment_id = comment_res.get("comment_id")
        require(bool(comment_id), "missing comment_id in response")

        # 4. Fetch chain tasks list (GET /task-chains/{chain_id}/tasks)
        # We use direct HTTP request since it's a REST endpoint
        status, list_data = req("GET", f"/task-chains/{chain_id}/tasks", headers={"Authorization": f"Bearer {ctok}"})
        require(status == 200, f"failed to fetch chain tasks: {status}")
        tasks = list_data.get("tasks", [])
        require(len(tasks) >= 2, f"expected at least 2 tasks, got {len(tasks)}")
        # Find our task
        our_tasks = [t for t in tasks if t.get("task_id") == task_id]
        require(len(our_tasks) == 1, f"expected to find our task {task_id} in list")
        task = our_tasks[0]
        
        # Verify description and AC are omitted in list
        print("Task from list:", json.dumps(task, indent=2))
        require("description" not in task, "expected description to be omitted in list")
        require("acceptance_criteria" not in task, "expected acceptance_criteria to be omitted in list")
        
        # Verify unresolved_comments is NOT present, and comment_ids is present
        require("unresolved_comments" not in task, "expected unresolved_comments to be absent")
        require(task.get("comment_ids") == [comment_id], f"expected comment_ids {[comment_id]}, got {task.get('comment_ids')}")

        # 5. Fetch task detail (GET /tasks/{task_id})
        status, detail_data = req("GET", f"/tasks/{task_id}", headers={"Authorization": f"Bearer {ctok}"})
        require(status == 200, f"failed to fetch task detail: {status}")
        detail_task = detail_data.get("task", {})
        
        # Verify description and AC are present in detail
        print("Task from detail:", json.dumps(detail_task, indent=2))
        require(detail_task.get("description") == desc, f"expected description '{desc}', got '{detail_task.get('description')}'")
        require(detail_task.get("acceptance_criteria") == ac, f"expected AC '{ac}', got '{detail_task.get('acceptance_criteria')}'")

        # 6. Fetch comment detail (GET /tasks/{task_id}/comments/{comment_id})
        status, comment_data = req("GET", f"/tasks/{task_id}/comments/{comment_id}", headers={"Authorization": f"Bearer {ctok}"})
        require(status == 200, f"failed to fetch comment detail: {status}")
        comment = comment_data.get("comment", {})
        print("Comment from detail:", json.dumps(comment, indent=2))
        require(comment.get("body") == comment_body, f"expected comment body '{comment_body}', got '{comment.get('body')}'")
        require(comment.get("comment_id") == comment_id, "comment_id mismatch")
        print("test_task_lazy_details: ok")
    except Exception as e:
        print("Test failed. Daemon log:")
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        lf.close()
        try:
            with open(log, "r") as f:
                print(f.read())
        except Exception as log_err:
            print(f"Could not read daemon log: {log_err}")
        raise e
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        lf.close()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
