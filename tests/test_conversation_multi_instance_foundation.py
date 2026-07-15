#!/usr/bin/env python3
"""Regression coverage for conversation multi-instance identity foundation.

Validates:
- /daemon/info exposes stable daemon_id + version across restart
- generated instance ids use <agent_id>@s-<opaque-token>
- project_id stays authoritative stored data, not parsed from the suffix
"""
import glob
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49661"))
DAEMON_URL = f"http://{HOST}:{PORT}"
SESSION_RE = re.compile(r"^conversation@s-[0-9a-f]{12}$")


def bin_path(repo_dir, binary, *candidates):
    for rel in candidates:
        path = os.path.join(repo_dir, rel, "bin", binary)
        if os.path.exists(path):
            return path
    for path in sorted(glob.glob(os.path.join(repo_dir, "result*", "bin", binary))):
        if os.path.exists(path):
            return path
    which = shutil.which(binary)
    if which:
        return which
    raise FileNotFoundError(f"could not locate {binary} in {repo_dir}")


def request_json(method, path, data=None):
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


def wait_for_daemon():
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{DAEMON_URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def start_daemon(daemon_bin, config_path, log_path):
    log = open(log_path, "a", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=log, stderr=subprocess.STDOUT)
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


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = bin_path(repo_dir, "ham-daemon", "result", "result-daemon", "result-1")
    # This regression never launches wrappers or calls ham-ctl; harmless placeholders
    # keep the daemon config self-contained even in minimal review worktrees.
    wrapper_bin = shutil.which("true") or "/usr/bin/true"
    ctl_bin = shutil.which("true") or "/usr/bin/true"

    temp_home = tempfile.mkdtemp(prefix="heimdall-conv-foundation-")
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
daemon_id = "daemon-foundation-test"
user_id = "operator@local"
wrapper_bin = "{wrapper_bin}"

[ctl]
daemon_url = "{DAEMON_URL}"
ham_ctl_bin = "{ctl_bin}"
''')

        proc, log = start_daemon(daemon_bin, config_path, log_path)

        status, info1 = request_json("GET", "/daemon/info")
        if status != 200 or info1.get("daemon_id") != "daemon-foundation-test" or not info1.get("version"):
            raise AssertionError(f"/daemon/info failed before restart: status={status} body={info1}")

        status, legacy = request_json("POST", "/agents/create", {
            "agent_instance_id": "conversation@legacy",
            "display_name": "Conversation Identity",
            "template_id": "conversation",
            "provider_profile": "pi",
            "model_tier": "normal",
            "project_id": "proj-alpha",
        })
        if status != 200 or not legacy.get("ok"):
            raise AssertionError(f"legacy identity seed failed: status={status} body={legacy}")

        status, created = request_json("POST", "/agents/create", {
            "display_name": "conversation",
            "template_id": "conversation",
            "provider_profile": "pi",
            "model_tier": "normal",
        })
        if status != 200 or not created.get("ok"):
            raise AssertionError(f"generated create failed: status={status} body={created}")

        agent = created.get("agent", {})
        instance_id = agent.get("agent_instance_id", "")
        if not SESSION_RE.match(instance_id):
            raise AssertionError(f"generated instance id is not session-token based: {instance_id!r}")
        if agent.get("agent_id") != "conversation":
            raise AssertionError(f"agent_id should be durable prefix 'conversation': {agent}")
        if agent.get("project_id") != "proj-alpha":
            raise AssertionError(f"project_id should come from durable identity default, not suffix parsing: {agent}")
        if "proj-alpha" in instance_id:
            raise AssertionError(f"project leaked into opaque session suffix: {instance_id}")

        status, shown = request_json("POST", "/agents/show", {"agent_instance_id": instance_id})
        if status != 200 or shown.get("agent", {}).get("project_id") != "proj-alpha":
            raise AssertionError(f"stored project_id was not authoritative on show: status={status} body={shown}")

        stop_daemon(proc, log)
        proc, log = None, None

        proc, log = start_daemon(daemon_bin, config_path, log_path)
        status, info2 = request_json("GET", "/daemon/info")
        if status != 200 or info2.get("daemon_id") != info1.get("daemon_id") or info2.get("version") != info1.get("version"):
            raise AssertionError(f"/daemon/info not stable across restart: before={info1} after={info2}")

        status, shown_after = request_json("POST", "/agents/show", {"agent_instance_id": instance_id})
        if status != 200 or shown_after.get("agent", {}).get("project_id") != "proj-alpha":
            raise AssertionError(f"instance project_id did not survive restart: status={status} body={shown_after}")

        print("PASS: conversation multi-instance foundation")
    finally:
        stop_daemon(proc, log)
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp_home}")
        else:
            shutil.rmtree(temp_home, ignore_errors=True)


if __name__ == "__main__":
    main()
