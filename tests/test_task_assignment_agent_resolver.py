#!/usr/bin/env python3
"""Regression for task assignment resolver semantics (REQ-CONV-008)."""

import glob
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49664"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"


def bin_path(repo_dir: Path, binary: str, *candidates: str) -> str:
    env_override = os.environ.get("HEIMDALL_DAEMON_BIN") if binary == "ham-daemon" else ""
    if env_override and os.path.exists(env_override):
        return env_override
    for rel in candidates:
        path = repo_dir / rel / "bin" / binary
        if path.exists():
            return str(path)
    for path in sorted(glob.glob(str(repo_dir / "result*" / "bin" / binary))):
        if os.path.exists(path):
            return path
    which = shutil.which(binary)
    if which:
        return which
    raise FileNotFoundError(f"could not locate {binary}")


def request_json(method: str, path: str, data=None):
    body = None if data is None else json.dumps(data, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=body,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status, json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read().decode("utf-8"))


def wait_for_daemon() -> None:
    for _ in range(100):
        try:
            with urllib.request.urlopen(f"{DAEMON_URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def start_daemon(daemon_bin: str, config_path: str, log_path: str, env: dict):
    log = open(log_path, "a", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=log, stderr=subprocess.STDOUT, env=env)
    wait_for_daemon()
    return proc, log


def stop_daemon(proc, log):
    if proc is not None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    if log is not None:
        log.close()


def task_request(agent_token: str, path: str, payload: dict):
    data = {"agent_token": agent_token, **payload}
    return request_json("POST", path, data)


def main() -> None:
    repo_dir = Path(__file__).resolve().parents[1]
    daemon_bin = bin_path(repo_dir, "ham-daemon", "result", "result-daemon", "result-1")
    fake_wrapper_tmp = tempfile.mkdtemp(prefix="heimdall-task-resolver-")
    fake_wrapper = Path(fake_wrapper_tmp) / "fake-wrapper.sh"
    fake_wrapper.write_text("#!/usr/bin/env bash\nsleep 30\n", encoding="utf-8")
    fake_wrapper.chmod(0o755)

    temp_home = tempfile.mkdtemp(prefix="heimdall-task-resolver-home-")
    config_path = os.path.join(temp_home, "config.toml")
    log_path = os.path.join(temp_home, "daemon.log")
    proc = None
    log = None
    try:
        with open(config_path, "w", encoding="utf-8") as f:
            f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{temp_home}/data"
daemon_id = "daemon-task-resolver-test"
user_id = "{USER_ID}"
wrapper_bin = "{fake_wrapper}"
nudge_enabled = false

[guide_agent]
enabled = false
autostart = false
restart_if_stopped = false

[ctl]
daemon_url = "{DAEMON_URL}"
ham_ctl_bin = "/usr/bin/true"
''')
        proc, log = start_daemon(daemon_bin, config_path, log_path, os.environ.copy())

        status, author_reg = request_json("POST", "/register", {
            "agent_class": "author",
            "agent_instance_id": "author@s-task-resolver",
            "display_name": "Task Resolver Author",
        })
        if status != 200 or not author_reg.get("agent_token"):
            raise AssertionError(f"author register failed: status={status} body={author_reg}")
        author_token = author_reg["agent_token"]

        for payload in [
            {
                "agent_instance_id": "conversation@legacy",
                "display_name": "Conversation Durable",
                "template_id": "conversation",
                "provider_profile": "pi",
                "model_tier": "normal",
                "project_id": "proj-task-resolver",
            },
            {
                "agent_instance_id": "reviewer@s-stopped",
                "display_name": "Reviewer Durable",
                "template_id": "reviewer",
                "provider_profile": "pi",
                "model_tier": "smart",
                "project_id": "proj-task-resolver",
            },
        ]:
            status, created = request_json("POST", "/agents/create", payload)
            if status != 200 or not created.get("ok"):
                raise AssertionError(f"seed /agents/create failed: status={status} body={created}")

        # Create by durable assignee id + exact reviewer instance id.
        status, created_task = task_request(author_token, "/tasks/create", {
            "standalone": True,
            "title": "Durable agent_id create resolver",
            "description": "Create should resolve durable assignee ids to concrete instances.",
            "assignee_agent_instance_id": "conversation",
            "reviewer_agent_instance_id": "reviewer@s-stopped",
        })
        if status != 200 or not created_task.get("ok"):
            raise AssertionError(f"task create failed: status={status} body={created_task}")
        task_id_1 = created_task["task_id"]

        status, shown_1 = task_request(author_token, "/tasks/show", {"task_id": task_id_1})
        if status != 200:
            raise AssertionError(f"task show failed: status={status} body={shown_1}")
        task_1 = shown_1["task"]
        assignee_1 = task_1.get("assignee_agent_instance_id", "")
        if assignee_1 == "conversation" or not assignee_1.startswith("conversation@s-"):
            raise AssertionError(f"durable assignee should resolve to concrete conversation instance: {task_1}")
        if task_1.get("reviewer_agent_instance_id") != "reviewer@s-stopped":
            raise AssertionError(f"exact reviewer instance should be preserved: {task_1}")

        # Participant path should also resolve durable agent ids to new concrete instances.
        status, participant_added = task_request(author_token, "/tasks/participant", {
            "task_id": task_id_1,
            "agent_instance_id": "reviewer",
            "role": "lgtm_optional",
        })
        if status != 200 or not participant_added.get("ok"):
            raise AssertionError(f"participant add failed: status={status} body={participant_added}")
        participant_inst = participant_added.get("agent_instance_id", "")
        if participant_inst == "reviewer" or not participant_inst.startswith("reviewer@s-") or participant_inst == "reviewer@s-stopped":
            raise AssertionError(f"durable reviewer participant should mint new concrete instance: {participant_added}")

        status, shown_1b = task_request(author_token, "/tasks/show", {"task_id": task_id_1})
        if status != 200:
            raise AssertionError(f"task re-show failed: status={status} body={shown_1b}")
        participants = shown_1b["task"].get("participants", [])
        if not any(p.get("agent_instance_id") == participant_inst and p.get("role") == "lgtm_optional" for p in participants):
            raise AssertionError(f"resolved reviewer participant not persisted as concrete instance: {shown_1b}")

        # Exact-instance assignment should preserve the same stopped concrete instance id.
        status, created_task_2 = task_request(author_token, "/tasks/create", {
            "standalone": True,
            "title": "Exact stopped instance assignment",
            "description": "Assign should preserve exact concrete instances.",
        })
        if status != 200 or not created_task_2.get("ok"):
            raise AssertionError(f"second task create failed: status={status} body={created_task_2}")
        task_id_2 = created_task_2["task_id"]
        status, assigned_exact = task_request(author_token, "/tasks/assign", {
            "task_id": task_id_2,
            "agent_instance_id": "reviewer@s-stopped",
        })
        if status != 200 or not assigned_exact.get("ok"):
            raise AssertionError(f"exact assignment failed: status={status} body={assigned_exact}")
        if assigned_exact.get("agent_instance_id") != "reviewer@s-stopped":
            raise AssertionError(f"exact assignment should preserve stopped instance id: {assigned_exact}")

        status, shown_2 = task_request(author_token, "/tasks/show", {"task_id": task_id_2})
        if status != 200 or shown_2["task"].get("assignee_agent_instance_id") != "reviewer@s-stopped":
            raise AssertionError(f"exact assignment not persisted: {shown_2}")

        # Assign by durable agent_id should mint a fresh concrete instance each time.
        status, created_task_3 = task_request(author_token, "/tasks/create", {
            "standalone": True,
            "title": "Durable assignment",
            "description": "Assign should mint new concrete instances for durable agent ids.",
        })
        if status != 200 or not created_task_3.get("ok"):
            raise AssertionError(f"third task create failed: status={status} body={created_task_3}")
        task_id_3 = created_task_3["task_id"]
        status, assigned_durable = task_request(author_token, "/tasks/assign", {
            "task_id": task_id_3,
            "agent_instance_id": "conversation",
        })
        if status != 200 or not assigned_durable.get("ok"):
            raise AssertionError(f"durable assignment failed: status={status} body={assigned_durable}")
        assignee_3 = assigned_durable.get("agent_instance_id", "")
        if assignee_3 == "conversation" or not assignee_3.startswith("conversation@s-"):
            raise AssertionError(f"durable assignment should mint concrete instance: {assigned_durable}")
        if assignee_3 == assignee_1:
            raise AssertionError(f"durable assignment should mint a fresh instance instead of reusing prior task assignee: first={assignee_1} second={assignee_3}")

        status, shown_3 = task_request(author_token, "/tasks/show", {"task_id": task_id_3})
        if status != 200 or shown_3["task"].get("assignee_agent_instance_id") != assignee_3:
            raise AssertionError(f"durable assignment not persisted as concrete instance: {shown_3}")

        print(json.dumps({
            "ok": True,
            "task_1_assignee": assignee_1,
            "task_1_exact_reviewer": task_1.get("reviewer_agent_instance_id"),
            "task_1_optional_reviewer": participant_inst,
            "task_2_exact_assignee": shown_2["task"].get("assignee_agent_instance_id"),
            "task_3_durable_assignee": assignee_3,
        }, indent=2, sort_keys=True))
        print("PASS: task assignment agent resolver")
    finally:
        stop_daemon(proc, log)
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp_home}")
        else:
            shutil.rmtree(fake_wrapper_tmp, ignore_errors=True)
            shutil.rmtree(temp_home, ignore_errors=True)


if __name__ == "__main__":
    main()
