#!/usr/bin/env python3
"""Regression: legacy memory targeting fields are rejected at CLI/RPC boundaries."""
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
CLIENT_ID = "memory-target-deprecation-client"
DEPRECATED_MESSAGE = "deprecated memory target fields are not accepted; use target_team_kind, target_role, and target_project_id"


def build_bin(repo_dir, package, binary, preferred_links=()):
    for link in preferred_links:
        candidate = os.path.join(repo_dir, link, "bin", binary)
        if os.path.exists(candidate):
            return candidate
    build = subprocess.run(
        ["nix", "build", f".#${package}".replace("$", ""), "--no-link", "--print-out-paths"],
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

    temp_home = tempfile.mkdtemp(prefix="heimdall-memory-target-deprecation-")
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

        for flag in ("--subject-key", "--scope", "--project-ids"):
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
            "agent_class": "memory-target-deprecation",
            "agent_instance_id": "memory-target-deprecation@default",
            "display_name": "Memory Target Deprecation",
        })
        agent_token = reg_res.get("agent_token")
        if status != 200 or not agent_token:
            raise AssertionError(f"agent registration failed: status={status} body={reg_res}")

        status, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if status != 200 or not user_token:
            raise AssertionError(f"user registration failed: status={status} body={user_res}")

        for label, path, payload in (
            ("/memory/propose/new subject_agent", "/memory/propose/new", {"agent_token": agent_token, "subject_agent": "legacy", "type": "fact", "title": "Legacy", "body": "Legacy"}),
            ("/memory/propose/new scope", "/memory/propose/new", {"agent_token": agent_token, "scope": "project", "type": "fact", "title": "Legacy", "body": "Legacy"}),
            ("/memory/list team_id", "/memory/list", {"agent_token": agent_token, "team_id": "legacy"}),
        ):
            status, res = request_post(path, payload)
            assert_deprecated(status, res, label)

        status, res = request_post("/agent-rpc", {"agent_token": agent_token, "action": "memory_list", "project_id": "legacy"})
        assert_deprecated(status, res, "agent-rpc memory_list project_id")

        status, res = request_post("/user-rpc", {"client_instance_id": CLIENT_ID, "client_token": user_token, "action": "memory_list", "role_keys": "coder"})
        assert_deprecated(status, res, "user-rpc memory_list role_keys")

        status, prop = request_post("/memory/propose/new", {
            "agent_token": agent_token,
            "target_team_kind": "coding",
            "target_role": "coder",
            "target_project_id": "heimdall-system",
            "type": "fact",
            "title": "Supported targeting",
            "body": "Target triple should still work.",
        })
        if status != 200 or not prop.get("ok"):
            raise AssertionError(f"supported memory proposal failed: status={status} body={prop}")

        print("PASS: legacy memory targeting fields are rejected at ham-ctl and RPC boundaries")
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
