#!/usr/bin/env python3
"""Backend regression coverage for memory subject-field removal.

Covers:
- public list/show/history/applicable JSON omits subject_agent/subject_key
- expertise dedup uses canonical target + title, not only scope/project
- legacy rows with empty project_ids but retained scope+subject_key normalize after restart
"""

import json
import os
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = 49423
URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
AGENT_ID = "memory-backend-coder@default"


def bin_path(repo: Path, binary: str) -> str:
    env_key = {
        "ham-daemon": "HAM_DAEMON_BIN",
        "ham-wrapper": "HAM_WRAPPER_BIN",
        "ham-ctl": "HAM_CTL_BIN",
    }[binary]
    if os.environ.get(env_key):
        return os.environ[env_key]
    for base in ["result-daemon-new", "result-daemon", "result-wrapper", "result-ctl", "result", "result-1", "result-2"]:
        path = repo / base / "bin" / binary
        if path.exists():
            return str(path)
    raise RuntimeError(f"could not find {binary}")


def post(path: str, data: dict) -> dict:
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
    for _ in range(100):
        try:
            with urllib.request.urlopen(f"{URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def start_daemon(repo: Path, temp_dir: str):
    daemon_bin = bin_path(repo, "ham-daemon")
    wrapper_bin = bin_path(repo, "ham-wrapper")
    ctl_bin = bin_path(repo, "ham-ctl")
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
    return proc, log, log_path


def stop_daemon(proc, log) -> None:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
    log.close()


def assert_no_subject_fields(payload: dict, label: str) -> None:
    text = json.dumps(payload)
    if "subject_agent" in text or "subject_key" in text:
        raise AssertionError(f"{label} unexpectedly exposed subject fields: {payload}")


def memory_show(agent_token: str, memory_id: str) -> dict:
    return post("/memory/show", {"agent_token": agent_token, "memory_id": memory_id})


def memory_list(agent_token: str, **body) -> dict:
    payload = {"agent_token": agent_token}
    payload.update(body)
    return post("/memory/list", payload)


def memory_history(agent_token: str, memory_id: str) -> dict:
    return post("/memory/history", {"agent_token": agent_token, "memory_id": memory_id})


def propose(agent_token: str, action: str, body: dict) -> dict:
    payload = {"agent_token": agent_token}
    payload.update(body)
    return post(f"/memory/propose/{action}", payload)


def approve(agent_token: str, proposal_id: str) -> dict:
    return post("/memory/decide", {"agent_token": agent_token, "proposal_id": proposal_id, "decision": "approve"})


def create_project(user_client: dict, project_id: str) -> None:
    res = post(
        "/user-rpc",
        {
            "action": "project_create",
            "client_instance_id": user_client["client_instance_id"],
            "client_token": user_client["client_token"],
            "project_id": project_id,
            "name": "Memory Backend",
            "description": "memory backend subject removal regression",
        },
    )
    if not res.get("ok"):
        raise AssertionError(f"project_create failed: {res}")


def active_status_by_id(records: list[dict]) -> dict[str, str]:
    return {rec["memory_id"]: rec["status"] for rec in records}


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    temp_dir = tempfile.mkdtemp(prefix="heimdall-memory-backend-")
    proc = log = None
    try:
        proc, log, log_path = start_daemon(repo, temp_dir)

        user_client = post("/user-client/register", {"user_id": USER_ID, "client_instance_id": "memory-backend-user"})
        user_client["client_instance_id"] = "memory-backend-user"
        create_project(user_client, "memory-backend-project")
        create_project(user_client, "memory-backend-project-2")

        agent_token = post(
            "/register",
            {
                "agent_class": "memory-backend-coder",
                "agent_instance_id": AGENT_ID,
                "display_name": "Memory Backend Coder",
            },
        )["agent_token"]
        agent_create = post(
            "/agents/create",
            {
                "agent_instance_id": AGENT_ID,
                "display_name": "Memory Backend Coder",
                "provider_profile": "pi",
                "template_id": "coder",
                "model_tier": "normal",
                "project_id": "memory-backend-project",
            },
        )
        if not agent_create.get("ok"):
            raise AssertionError(f"agents/create failed: {agent_create}")

        prop1 = propose(
            agent_token,
            "new",
            {
                "scope": "project",
                "project_id": "memory-backend-project",
                "type": "expertise",
                "title": "Build cache",
                "body": "Use nix build outputs for daemon binaries.",
                "reason": "backend test",
                "evidence": "step-1",
            },
        )
        approve(agent_token, prop1["proposal_id"])
        mem1 = prop1["memory_id"]

        show1 = memory_show(agent_token, mem1)
        list1 = memory_list(agent_token, scope="project", project_id="memory-backend-project", include_all_statuses=True)
        history1 = memory_history(agent_token, mem1)
        applicable1 = post(
            "/memory/applicable",
            {
                "agent_token": agent_token,
                "agent_instance_id": AGENT_ID,
                "project_id": "memory-backend-project",
            },
        )

        assert_no_subject_fields(show1, "show1")
        assert_no_subject_fields(list1, "list1")
        assert_no_subject_fields(history1, "history1")
        assert_no_subject_fields(applicable1, "applicable1")
        if show1["record"]["project_ids"] != ["memory-backend-project"]:
            raise AssertionError(show1)
        if applicable1["records"][0]["memory_id"] != mem1:
            raise AssertionError(applicable1)

        # Same title + same target should archive prior expertise.
        prop2 = propose(
            agent_token,
            "new",
            {
                "scope": "project",
                "project_id": "memory-backend-project",
                "type": "expertise",
                "title": "Build cache",
                "body": "Use --print-out-paths for evidence when needed.",
                "reason": "backend test",
                "evidence": "step-2",
            },
        )
        approve(agent_token, prop2["proposal_id"])
        mem2 = prop2["memory_id"]

        # Different title on same target should stay active.
        prop3 = propose(
            agent_token,
            "new",
            {
                "scope": "project",
                "project_id": "memory-backend-project",
                "type": "expertise",
                "title": "SQLite inspection",
                "body": "Legacy normalization can be tested by mutating memory.db directly.",
                "reason": "backend test",
                "evidence": "step-3",
            },
        )
        approve(agent_token, prop3["proposal_id"])
        mem3 = prop3["memory_id"]

        all_records = memory_list(agent_token, include_all_statuses=True, status="all")
        statuses = active_status_by_id(all_records["records"])
        if statuses[mem1] != "archived":
            raise AssertionError(f"expected first expertise archived, got {statuses}")
        if statuses[mem2] != "active" or statuses[mem3] != "active":
            raise AssertionError(f"expected second and third expertise active, got {statuses}")

        # Same logical multi-value targets in different orders should dedup.
        prop4 = propose(
            agent_token,
            "new",
            {
                "scope": "project",
                "project_id": "memory-backend-project",
                "project_ids": "memory-backend-project,memory-backend-project-2",
                "role_keys": "reviewer,coder",
                "task_chain_types": "research,coding",
                "type": "expertise",
                "title": "Cross-project coordination",
                "body": "Initial ordered target set.",
                "reason": "backend test",
                "evidence": "step-4",
            },
        )
        approve(agent_token, prop4["proposal_id"])
        mem4 = prop4["memory_id"]
        prop5 = propose(
            agent_token,
            "new",
            {
                "scope": "project",
                "project_id": "memory-backend-project",
                "project_ids": "memory-backend-project-2,memory-backend-project",
                "role_keys": "coder,reviewer",
                "task_chain_types": "coding,research",
                "type": "expertise",
                "title": "Cross-project coordination",
                "body": "Same logical target set, reversed ordering.",
                "reason": "backend test",
                "evidence": "step-5",
            },
        )
        approve(agent_token, prop5["proposal_id"])
        mem5 = prop5["memory_id"]

        all_records = memory_list(agent_token, include_all_statuses=True, status="all")
        statuses = active_status_by_id(all_records["records"])
        if statuses[mem4] != "archived" or statuses[mem5] != "active":
            raise AssertionError(f"reordered multi-target expertise did not dedup canonically: {statuses}")

        # Emulate legacy rows that only retain scope + subject_key, then restart.
        stop_daemon(proc, log)
        proc = log = None
        db_path = Path(temp_dir) / "data" / "memory" / "memory.db"
        with sqlite3.connect(db_path) as conn:
            conn.execute(
                "UPDATE memories SET project_ids = '' WHERE memory_id = ?",
                (mem2,),
            )
            conn.commit()

        proc, log, log_path = start_daemon(repo, temp_dir)
        agent_token = post(
            "/register",
            {
                "agent_class": "memory-backend-coder",
                "agent_instance_id": AGENT_ID,
                "display_name": "Memory Backend Coder Restarted",
            },
        )["agent_token"]

        show2 = memory_show(agent_token, mem2)
        list2 = memory_list(agent_token, scope="project", project_id="memory-backend-project", include_all_statuses=True)
        history2 = memory_history(agent_token, mem2)
        applicable2 = post(
            "/memory/applicable",
            {
                "agent_token": agent_token,
                "agent_instance_id": AGENT_ID,
                "project_id": "memory-backend-project",
            },
        )

        assert_no_subject_fields(show2, "show2")
        assert_no_subject_fields(list2, "list2")
        assert_no_subject_fields(history2, "history2")
        assert_no_subject_fields(applicable2, "applicable2")
        if show2["record"]["project_ids"] != ["memory-backend-project"]:
            raise AssertionError(f"legacy normalization failed after restart: {show2}")
        if mem2 not in {rec["memory_id"] for rec in applicable2["records"]}:
            raise AssertionError(f"applicable lost legacy-normalized memory after restart: {applicable2}")

        print(
            json.dumps(
                {
                    "ok": True,
                    "before_show": show1["record"],
                    "before_history_event": history1["events"][0] if history1["events"] else {},
                    "after_restart_show": show2["record"],
                    "statuses": statuses,
                    "reordered_bucket_archive": {"archived": mem4, "active": mem5},
                    "daemon_log": log_path,
                },
                indent=2,
            )
        )
    finally:
        if proc and log:
            stop_daemon(proc, log)


if __name__ == "__main__":
    main()
