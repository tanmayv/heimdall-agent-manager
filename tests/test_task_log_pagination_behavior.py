#!/usr/bin/env python3
"""Behavioral smoke for task_log limit/cursor pagination.

Starts an isolated ham-daemon, creates a task with comments and a review-ready
completion body, then verifies the durable user-rpc task_log API returns newest
pages first with next_cursor/has_more/total metadata and non-overlapping older
pages. This covers the UI task-comment pagination contract added for
REQ-CONV-016 evidence.
"""

import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = 49438
USER_ID = "operator@local"
CLIENT_ID = "task-log-pagination-user"


def bin_path(repo: Path, preferred: str, fallback: str, binary: str) -> str:
    # Prefer the current `nix build .#ham-daemon` symlink for this regression;
    # older task tests may leave result-daemon/result-* symlinks behind.
    result_path = repo / "result" / "bin" / binary
    if result_path.exists():
        return str(result_path)
    preferred_path = repo / preferred / "bin" / binary
    if preferred_path.exists():
        return str(preferred_path)
    fallback_path = repo / fallback / "bin" / binary
    if fallback_path.exists():
        return str(fallback_path)
    raise RuntimeError(f"{binary} not found; run nix build .#ham-daemon first")


def request_post(url: str, path: str, data: dict) -> dict:
    req = urllib.request.Request(
        f"{url}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as res:
            return json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"POST {path} failed {exc.code}: {body}") from exc


def wait_health(url: str) -> None:
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{url}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def start_daemon(repo: Path, temp_dir: str):
    daemon_bin = bin_path(repo, "result-daemon", "result", "ham-daemon")
    config_path = os.path.join(temp_dir, "config.toml")
    url = f"http://{HOST}:{PORT}"
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{temp_dir}/data"
user_id = "{USER_ID}"

[ctl]
daemon_url = "{url}"
''')
    log_path = os.path.join(temp_dir, "daemon.log")
    log = open(log_path, "a", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=log, stderr=subprocess.STDOUT)
    wait_health(url)
    return proc, log, url


def stop_daemon(proc, log) -> None:
    if not proc:
        return
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    if log:
        log.close()


def user_rpc(url: str, token: str, action: str, **body) -> dict:
    payload = {"action": action, "client_instance_id": CLIENT_ID, "client_token": token}
    payload.update(body)
    return request_post(url, "/user-rpc", payload)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    temp_dir = tempfile.mkdtemp(prefix="heimdall-task-log-pagination-")
    proc = log = None
    try:
        proc, log, url = start_daemon(repo, temp_dir)
        registered = request_post(url, "/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        token = registered.get("client_token")
        require(bool(token), f"missing client token: {registered}")

        chain = user_rpc(url, token, "task_chain_create", chain_id="chain-task-log-pagination", title="Task log pagination chain", kind="coding", coordinator_agent_instance_id=USER_ID)
        require(chain.get("ok"), f"chain create failed: {chain}")
        chain_id = chain.get("chain_id")
        task = user_rpc(url, token, "task_create", chain_id=chain_id, title="Paginated task log", status="queued", assignee_agent_instance_id=USER_ID)
        require(task.get("ok"), f"task create failed: {task}")
        task_id = task.get("task_id")

        comment_ids = []
        for idx in range(3):
            comment = user_rpc(url, token, "task_comment", task_id=task_id, chain_id=chain_id, body=f"pagination comment {idx}")
            require(comment.get("ok"), f"comment {idx} failed: {comment}")
            comment_ids.append(comment.get("comment_id"))
        for comment_id in comment_ids:
            resolved = user_rpc(url, token, "task_comment_resolve", task_id=task_id, chain_id=chain_id, comment_id=comment_id)
            require(resolved.get("ok"), f"comment resolve failed: {resolved}")

        started = user_rpc(url, token, "task_status", task_id=task_id, chain_id=chain_id, status="in_progress", body="Start pagination smoke")
        require(started.get("ok"), f"in_progress status failed: {started}")
        completion_body = "Completion handoff body for pagination smoke"
        done = user_rpc(url, token, "task_status", task_id=task_id, chain_id=chain_id, status="review_ready", body=completion_body)
        require(done.get("ok"), f"review_ready status failed: {done}")

        first = user_rpc(url, token, "task_log", task_id=task_id, limit=2, cursor=0)
        require(first.get("ok"), f"first page failed: {first}")
        first_events = first.get("events") or []
        require(len(first_events) == 2, f"expected first page of 2 events, got {len(first_events)}: {first}")
        require(first.get("has_more") is True, f"expected has_more true on first page: {first}")
        require(int(first.get("next_cursor") or 0) > 0, f"expected positive next_cursor: {first}")
        require(int(first.get("total") or 0) >= 5, f"expected total to include create/comments/status events: {first}")
        require(any(event.get("kind") == "Task_Status_Changed" and event.get("status") == "review_ready" and event.get("body") == completion_body for event in first_events), f"first page should include completion status body: {first_events}")

        second = user_rpc(url, token, "task_log", task_id=task_id, limit=2, cursor=int(first.get("next_cursor") or 0))
        require(second.get("ok"), f"second page failed: {second}")
        second_events = second.get("events") or []
        require(len(second_events) == 2, f"expected second page of 2 events, got {len(second_events)}: {second}")
        first_ids = {event.get("event_id") for event in first_events}
        second_ids = {event.get("event_id") for event in second_events}
        require(first_ids.isdisjoint(second_ids), f"pages should not overlap: first={first_ids} second={second_ids}")
        require(int(second.get("total") or 0) == int(first.get("total") or 0), f"total should remain stable across pages: first={first} second={second}")

        print("PASS: task_log pagination behavior smoke")
        print(json.dumps({
            "task_id": task_id,
            "first_next_cursor": first.get("next_cursor"),
            "first_has_more": first.get("has_more"),
            "total": first.get("total"),
            "first_event_kinds": [event.get("kind") for event in first_events],
            "second_event_kinds": [event.get("kind") for event in second_events],
        }, indent=2))
    finally:
        stop_daemon(proc, log)


if __name__ == "__main__":
    main()
