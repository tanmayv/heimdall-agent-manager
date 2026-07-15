#!/usr/bin/env python3
"""REQ-CONV-010 regression for ham-ctl agents run/instances and resolver-aware task assignment."""

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
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49667"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"


def bin_path(repo_dir: Path, binary: str, *candidates: str) -> str:
    env_key = {
        "ham-daemon": "HEIMDALL_DAEMON_BIN",
        "ham-ctl": "HEIMDALL_CTL_BIN",
    }.get(binary, "")
    env_override = os.environ.get(env_key, "") if env_key else ""
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


def run_ctl(ctl_bin: str, *args: str):
    proc = subprocess.run(
        [ctl_bin, "--daemon-url", DAEMON_URL, *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        raise AssertionError(f"ham-ctl failed rc={proc.returncode}\nSTDOUT={proc.stdout}\nSTDERR={proc.stderr}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise AssertionError(f"ham-ctl did not return JSON: {proc.stdout!r}\nSTDERR={proc.stderr}") from exc


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


def main() -> None:
    repo_dir = Path(__file__).resolve().parents[1]
    daemon_bin = bin_path(repo_dir, "ham-daemon", "result", "result-daemon", "result-1")
    ctl_bin = bin_path(repo_dir, "ham-ctl", "result-2", "result-ctl", "result")

    fake_wrapper_tmp = tempfile.mkdtemp(prefix="heimdall-ctl-run-")
    fake_wrapper = Path(fake_wrapper_tmp) / "fake-wrapper.sh"
    fake_wrapper.write_text("#!/usr/bin/env bash\nsleep 30\n", encoding="utf-8")
    fake_wrapper.chmod(0o755)

    temp_home = tempfile.mkdtemp(prefix="heimdall-ctl-run-home-")
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
daemon_id = "daemon-ctl-run-test"
user_id = "{USER_ID}"
wrapper_bin = "{fake_wrapper}"
nudge_enabled = false

[guide_agent]
enabled = false
autostart = false
restart_if_stopped = false

[ctl]
daemon_url = "{DAEMON_URL}"
ham_ctl_bin = "{ctl_bin}"
''')
        proc, log = start_daemon(daemon_bin, config_path, log_path, os.environ.copy())

        run_one = run_ctl(ctl_bin, "agents", "run", "conversation", "--project", "proj-cli-one", "--tier", "smart")
        inst_one = run_one.get("agent_instance_id", "")
        if not run_one.get("ok") or not inst_one.startswith("conversation@s-"):
            raise AssertionError(f"agents run should mint a concrete instance for durable agent_id: {run_one}")
        if run_one.get("start_mode") != "new_instance" or run_one.get("project_id") != "proj-cli-one" or run_one.get("model_tier") != "smart":
            raise AssertionError(f"agents run should forward project/tier and report new_instance: {run_one}")

        resume_one = run_ctl(ctl_bin, "agents", "run", inst_one)
        if resume_one.get("agent_instance_id") != inst_one or resume_one.get("start_mode") != "reuse_instance":
            raise AssertionError(f"agents run on exact instance should resume exact instance: {resume_one}")

        run_two = run_ctl(ctl_bin, "agents", "run", "conversation", "--new", "--project", "proj-cli-two")
        inst_two = run_two.get("agent_instance_id", "")
        if inst_two == inst_one or not inst_two.startswith("conversation@s-"):
            raise AssertionError(f"agents run --new should mint a fresh instance: {run_two}")

        list_instances = run_ctl(ctl_bin, "agents", "instances", "conversation", "--json")
        agents = list_instances.get("agents", [])
        ids = {agent.get("agent_instance_id") for agent in agents}
        if inst_one not in ids or inst_two not in ids:
            raise AssertionError(f"agents instances should list concrete instances for durable agent_id: {list_instances}")
        by_id = {agent.get("agent_instance_id"): agent for agent in agents}
        if by_id[inst_one].get("agent_id") != "conversation" or by_id[inst_one].get("project_id") != "proj-cli-one":
            raise AssertionError(f"agents instances should include agent_id/project_id for first instance: {by_id[inst_one]}")
        if by_id[inst_two].get("project_id") != "proj-cli-two":
            raise AssertionError(f"agents instances should include second project binding: {by_id[inst_two]}")

        status, author_reg = request_json("POST", "/register", {
            "agent_class": "author",
            "agent_instance_id": "author@s-cli-runner",
            "display_name": "CLI Author",
        })
        author_token = author_reg.get("agent_token", "")
        if status != 200 or not author_token:
            raise AssertionError(f"author register failed: status={status} body={author_reg}")

        created_task = run_ctl(ctl_bin, "tasks", "create", "--token", author_token, "--standalone", "--title", "CLI assign durable", "--description", "Check CLI assignment by durable agent id")
        task_id_1 = created_task.get("task_id", "")
        if not created_task.get("ok") or not task_id_1:
            raise AssertionError(f"tasks create failed: {created_task}")

        assigned_durable = run_ctl(ctl_bin, "tasks", "assign", "--token", author_token, "--task-id", task_id_1, "--agent", "conversation")
        assigned_inst = assigned_durable.get("agent_instance_id", "")
        if not assigned_durable.get("ok") or not assigned_inst.startswith("conversation@s-"):
            raise AssertionError(f"tasks assign --agent <agent_id> should mint a concrete instance: {assigned_durable}")
        if assigned_inst in {inst_one, inst_two}:
            raise AssertionError(f"durable CLI assignment should mint a fresh instance instead of reusing prior threads: {assigned_durable}")

        shown_task_1 = run_ctl(ctl_bin, "tasks", "show", "--token", author_token, "--task-id", task_id_1)
        if shown_task_1.get("task", {}).get("assignee_agent_instance_id") != assigned_inst:
            raise AssertionError(f"CLI durable assignment should persist resolved concrete instance: {shown_task_1}")

        created_task_2 = run_ctl(ctl_bin, "tasks", "create", "--token", author_token, "--standalone", "--title", "CLI assign exact", "--description", "Check CLI exact instance assignment")
        task_id_2 = created_task_2.get("task_id", "")
        assigned_exact = run_ctl(ctl_bin, "tasks", "assign", "--token", author_token, "--task-id", task_id_2, "--agent", inst_one)
        if assigned_exact.get("agent_instance_id") != inst_one:
            raise AssertionError(f"tasks assign --agent <agent_instance_id> should preserve exact target: {assigned_exact}")

        created_task_3 = run_ctl(ctl_bin, "tasks", "create", "--token", author_token, "--standalone", "--title", "CLI assign forced new", "--description", "Check CLI --new-instance surface")
        task_id_3 = created_task_3.get("task_id", "")
        assigned_forced_new = run_ctl(ctl_bin, "tasks", "assign", "--token", author_token, "--task-id", task_id_3, "--agent", inst_one, "--new-instance")
        forced_inst = assigned_forced_new.get("agent_instance_id", "")
        if not forced_inst.startswith("conversation@s-") or forced_inst in {inst_one, inst_two, assigned_inst}:
            raise AssertionError(f"tasks assign --new-instance should promote exact target to a fresh durable-instance assignment: {assigned_forced_new}")

        print(json.dumps({
            "ok": True,
            "run_instance_1": inst_one,
            "run_instance_2": inst_two,
            "assigned_durable_instance": assigned_inst,
            "assigned_exact_instance": assigned_exact.get("agent_instance_id"),
            "assigned_forced_new_instance": forced_inst,
        }, indent=2, sort_keys=True))
        print("PASS: cli agents instances commands")
    finally:
        stop_daemon(proc, log)
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp_home}")
        else:
            shutil.rmtree(fake_wrapper_tmp, ignore_errors=True)
            shutil.rmtree(temp_home, ignore_errors=True)


if __name__ == "__main__":
    main()
