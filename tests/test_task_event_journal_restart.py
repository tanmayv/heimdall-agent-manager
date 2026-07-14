#!/usr/bin/env python3
"""Restart recovery regression for durable task event journal and projections.

Safe to run: starts an isolated ham-daemon on localhost with a temporary data_dir,
registers synthetic agents/user, and removes temp files unless
KEEP_HEIMDALL_TEST_TMP=1 is set.
"""

import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = 49421
URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CODER = "journal-coder@default"
REVIEWER = "journal-reviewer@default"


def bin_path(repo: Path, preferred: str, fallback: str, binary: str) -> str:
    preferred_path = repo / preferred / "bin" / binary
    if preferred_path.exists():
        return str(preferred_path)
    return str(repo / fallback / "bin" / binary)


def request(path: str, data: dict) -> dict:
    req = urllib.request.Request(
        f"{URL}{path}",
        data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as res:
            return json.loads(res.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        raise RuntimeError(f"POST {path} failed {exc.code}: {body}") from exc


def wait_health() -> None:
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def start_daemon(repo: Path, temp_dir: str):
    daemon_bin = bin_path(repo, "result-daemon", "result", "ham-daemon")
    wrapper_bin = bin_path(repo, "result-wrapper", "result-1", "ham-wrapper")
    ctl_bin = bin_path(repo, "result-ctl", "result-2", "ham-ctl")
    config_path = os.path.join(temp_dir, "config.toml")
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{temp_dir}/data"
user_id = "{USER_ID}"
wrapper_bin = "{wrapper_bin}"

[ctl]
daemon_url = "{URL}"
ham_ctl_bin = "{ctl_bin}"
''')
    log_path = os.path.join(temp_dir, "daemon.log")
    log = open(log_path, "a", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=log, stderr=subprocess.STDOUT)
    wait_health()
    return proc, log


def stop_daemon(proc, log) -> None:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
    log.close()


def assert_status(label: str, expected: str, task_id: str, token: str) -> dict:
    res = request("/tasks/show", {"agent_token": token, "task_id": task_id})
    actual = res.get("task", {}).get("status")
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected}, got {actual}: {res}")
    return res["task"]


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    temp_dir = tempfile.mkdtemp(prefix="heimdall-task-journal-restart-")
    proc = log = None
    try:
        proc, log = start_daemon(repo, temp_dir)

        # Simulate production task.db files created by an older schema revision
        # that included a NOT NULL tasks.coordinator_agent_instance_id column.
        # Current Task_State no longer stores this field, so task saves must
        # still supply a compatibility value or tasks persist in memory only
        # and disappear after daemon restart.
        db_path = Path(temp_dir) / "data" / "tasks" / "task.db"
        with sqlite3.connect(db_path) as conn:
            conn.execute("ALTER TABLE tasks ADD COLUMN coordinator_agent_instance_id TEXT NOT NULL DEFAULT ''")
            conn.commit()

        user = request("/user-client/register", {"user_id": USER_ID, "client_instance_id": "journal-user"})
        user_token = user["client_token"]
        coder_token = request("/register", {"agent_class": "journal-coder", "agent_instance_id": CODER, "display_name": "Journal Coder"})["agent_token"]
        reviewer_token = request("/register", {"agent_class": "journal-reviewer", "agent_instance_id": REVIEWER, "display_name": "Journal Reviewer"})["agent_token"]

        project_id = request("/projects/create", {"agent_token": user_token, "name": "Journal Restart", "description": "restart recovery"})["project_id"]
        chain = request("/task-chains/create", {
            "agent_token": user_token,
            "project_id": project_id,
            "kind": "coding",
            "status": "planning",
            "no_scaffold": True,
            "title": "Journal Chain",
            "description": "journal recovery",
            "coordinator_agent_instance_id": USER_ID,
            "default_reviewer_agent_instance_id": REVIEWER,
        })
        chain_id = chain["chain_id"]

        task_a = request("/tasks/create", {
            "agent_token": user_token,
            "chain_id": chain_id,
            "title": "Task A",
            "assignee_agent_instance_id": CODER,
            "reviewer_agent_instance_id": REVIEWER,
        })["task_id"]
        task_b = request("/tasks/create", {
            "agent_token": user_token,
            "chain_id": chain_id,
            "title": "Task B waits for A",
            "assignee_agent_instance_id": CODER,
            "depends_on": task_a,
        })["task_id"]
        task_manual = request("/tasks/create", {
            "agent_token": user_token,
            "chain_id": chain_id,
            "title": "Manually deferred task",
            "assignee_agent_instance_id": "manual-agent@default",
        })["task_id"]

        request("/register", {"agent_class": "manual-agent", "agent_instance_id": "manual-agent@default", "display_name": "Manual Agent"})
        request("/task-chains/activate", {"agent_token": user_token, "chain_id": chain_id})

        assert_status("Task A after activation", "in_progress", task_a, user_token)
        assert_status("Task B dependency waits", "planning", task_b, user_token)
        assert_status("Manual task auto-claimed before defer", "in_progress", task_manual, user_token)

        # Agent defers work with a human/manual reason. After restart this must
        # remain queued and not auto-claim merely because task_latest_status_body
        # lost its in-memory event history.
        request("/tasks/status", {"agent_token": user_token, "task_id": task_manual, "chain_id": chain_id, "status": "queued", "body": "manual defer across restart"})
        assert_status("Manual task queued before restart", "queued", task_manual, user_token)

        request("/tasks/comment", {"agent_token": user_token, "task_id": task_a, "chain_id": chain_id, "body": "journal comment"})
        unresolved = request("/tasks/comments", {"agent_token": user_token, "task_id": task_a})
        comment_id = unresolved["comments"][0]["comment_id"]
        request("/tasks/comment-resolve", {"agent_token": user_token, "task_id": task_a, "chain_id": chain_id, "comment_id": comment_id})
        request("/tasks/done", {"agent_token": coder_token, "task_id": task_a, "chain_id": chain_id, "body": "ready for review"})
        assert_status("Task A review ready before restart", "review_ready", task_a, user_token)
        request("/tasks/nudge", {"agent_token": user_token, "task_id": task_a, "chain_id": chain_id, "body": "journal nudge", "interrupt": True})

        pre_log = request("/tasks/log", {"agent_token": user_token, "task_id": task_a})
        pre_kinds = [e.get("kind") for e in pre_log.get("events", [])]
        assert "Task_Comment" in pre_kinds and "Task_Comment_Resolved" in pre_kinds and "Task_Nudged" in pre_kinds and "Task_Status_Changed" in pre_kinds, pre_log

        stop_daemon(proc, log)
        proc = log = None
        proc, log = start_daemon(repo, temp_dir)

        # Recover tokens/agents after daemon restart.
        request("/register", {"agent_class": "journal-coder", "agent_instance_id": CODER, "display_name": "Journal Coder Restarted"})
        request("/register", {"agent_class": "journal-reviewer", "agent_instance_id": REVIEWER, "display_name": "Journal Reviewer Restarted"})
        request("/register", {"agent_class": "manual-agent", "agent_instance_id": "manual-agent@default", "display_name": "Manual Agent Restarted"})

        task_a_state = assert_status("Task A review_ready survives restart", "review_ready", task_a, user_token)
        if task_a_state.get("reviewer_agent_instance_id") != REVIEWER:
            raise AssertionError(f"reviewer requirement not recovered: {task_a_state}")
        if task_a_state.get("unresolved_comment_count") != 0:
            raise AssertionError(f"resolved comments did not persist: {task_a_state}")
        assert_status("Dependent Task B still planning before approval", "planning", task_b, user_token)
        manual_after = assert_status("Manual queued task remains queued after restart", "queued", task_manual, user_token)
        if "queued" != manual_after.get("not_actionable_reason"):
            raise AssertionError(f"manual queued reason should remain queued, got {manual_after}")

        post_log = request("/tasks/log", {"agent_token": user_token, "task_id": task_a})
        post_kinds = [e.get("kind") for e in post_log.get("events", [])]
        missing = {"Task_Created", "Task_Comment", "Task_Comment_Resolved", "Task_Status_Changed", "Task_Nudged"} - set(post_kinds)
        if missing:
            raise AssertionError(f"task event journal missing after restart: {missing}; log={post_log}")

        # Approval after restart should free coder slot and promote/auto-claim dependent task.
        request("/tasks/vote", {"agent_token": reviewer_token, "task_id": task_a, "chain_id": chain_id, "result": "lgtm", "comment": "approved after restart"})
        assert_status("Task A approved after restart", "approved", task_a, user_token)
        assert_status("Dependent Task B auto-claimed after approval", "in_progress", task_b, user_token)

        final_log = request("/tasks/log", {"agent_token": user_token, "task_id": task_a})
        final_kinds = [e.get("kind") for e in final_log.get("events", [])]
        if "Task_Review_Vote" not in final_kinds:
            raise AssertionError(f"post-restart vote not journaled: {final_log}")

        print(json.dumps({
            "ok": True,
            "task_a_events_after_restart": post_kinds,
            "task_b_status_after_approval": "in_progress",
            "manual_task_status_after_restart": "queued",
        }, indent=2, sort_keys=True))
        print("TASK EVENT JOURNAL RESTART TEST PASSED")
    finally:
        if proc is not None:
            stop_daemon(proc, log)
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp_dir}")
        else:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
