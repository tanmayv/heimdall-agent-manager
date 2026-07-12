#!/usr/bin/env python3
"""Regression: subject_key/subject_agent inputs are deprecated at ham-ctl and RPC boundaries."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49664"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "memory-subject-deprecation-client"
DEPRECATED_MESSAGE = "subject_key and subject_agent are deprecated; use project, role, and task-chain targeting fields instead"


def build_bin(repo_dir, package, binary, preferred_links=()):
    for link in preferred_links:
        candidate = os.path.join(repo_dir, link, "bin", binary)
        if os.path.exists(candidate):
            return candidate
    build = subprocess.run(
        ["nix", "build", f".#{package}", "--no-link", "--print-out-paths"],
        cwd=repo_dir,
        capture_output=True,
        text=True,
        check=True,
    )
    out_path = build.stdout.strip().splitlines()[-1]
    return os.path.join(out_path, "bin", binary)


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
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{DAEMON_URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("daemon did not become healthy")


def assert_deprecated(status, payload, label):
    if status != 400 or payload.get("ok") is not False or DEPRECATED_MESSAGE not in payload.get("message", ""):
        raise AssertionError(f"{label} should fail with deprecation error: status={status} payload={payload}")


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ctl_bin = build_bin(repo_dir, "ham-ctl", "ham-ctl", ("result-ctl", "result-1", "result"))
    daemon_bin = build_bin(repo_dir, "ham-daemon", "ham-daemon", ("result-daemon", "result"))

    temp_home = tempfile.mkdtemp(prefix="heimdall-memory-subject-deprecation-")
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
wrapper_bin = "/bin/false"

[ctl]
daemon_url = "{DAEMON_URL}"
ham_ctl_bin = "{ctl_bin}"
''')

        # ham-ctl rejects deprecated memory flags before attempting a daemon request.
        for flag in ("--subject-key", "--subject-agent", "--agent"):
            proc = subprocess.run(
                [ctl_bin, "--config", config_path, "--daemon-url", "http://127.0.0.1:1", "memory", "list", "--token", "agt_test", flag, "legacy"],
                cwd=repo_dir,
                capture_output=True,
                text=True,
                check=True,
            )
            payload = json.loads(proc.stdout.strip().splitlines()[-1])
            if payload.get("ok") is not False or DEPRECATED_MESSAGE not in payload.get("message", ""):
                raise AssertionError(f"ham-ctl {flag} did not return deprecation error: {payload}")

        daemon_log = open(daemon_log_path, "w", encoding="utf-8")
        daemon_proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=daemon_log, stderr=subprocess.STDOUT)
        wait_for_daemon()

        status, reg_res = request_post("/register", {
            "agent_class": "memory-subject-deprecation",
            "agent_instance_id": "memory-subject-deprecation@default",
            "display_name": "Memory Subject Deprecation",
        })
        agent_token = reg_res.get("agent_token")
        if status != 200 or not agent_token:
            raise AssertionError(f"agent registration failed: status={status} body={reg_res}")

        status, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if status != 200 or not user_token:
            raise AssertionError(f"user registration failed: status={status} body={user_res}")

        # Direct memory HTTP boundary rejects explicit deprecated fields, including empty values.
        for label, path, payload in (
            ("/memory/propose/new subject_agent", "/memory/propose/new", {"agent_token": agent_token, "subject_agent": "legacy", "type": "fact", "title": "Legacy", "body": "Legacy"}),
            ("/memory/propose/new subject_key empty", "/memory/propose/new", {"agent_token": agent_token, "subject_key": "", "type": "fact", "title": "Legacy", "body": "Legacy"}),
            ("/memory/list agent", "/memory/list", {"agent_token": agent_token, "agent": "legacy"}),
        ):
            status, res = request_post(path, payload)
            assert_deprecated(status, res, label)

        # Agent RPC and user RPC memory boundaries reject the same deprecated targeting fields.
        status, res = request_post("/agent-rpc", {"agent_token": agent_token, "action": "memory_list", "subject_key": "pr:legacy"})
        assert_deprecated(status, res, "agent-rpc memory_list subject_key")

        status, res = request_post("/user-rpc", {"client_instance_id": CLIENT_ID, "client_token": user_token, "action": "memory_list", "subject_agent": "legacy"})
        assert_deprecated(status, res, "user-rpc memory_list subject_agent")

        # Positive control: supported template targeting still works without deprecated fields.
        status, prop = request_post("/memory/propose/new", {
            "agent_token": agent_token,
            "scope": "template",
            "template_key": "subject-deprecation-positive",
            "type": "fact",
            "title": "Supported targeting",
            "body": "Template targeting should still work.",
        })
        if status != 200 or not prop.get("ok"):
            raise AssertionError(f"supported memory proposal failed: status={status} body={prop}")

        status, listed = request_post("/memory/list", {"agent_token": agent_token, "scope": "template", "type": "fact", "status": "pending"})
        if status != 200 or not listed.get("ok"):
            raise AssertionError(f"supported memory list failed: status={status} body={listed}")
        if not any(record.get("title") == "Supported targeting" for record in listed.get("records", [])):
            raise AssertionError(f"supported memory proposal was not listed: {listed}")

        print("PASS: memory subject_key/subject_agent deprecation enforced at ham-ctl and RPC boundaries")
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
