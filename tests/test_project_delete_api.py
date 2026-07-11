#!/usr/bin/env python3
"""Regression for project delete via user-rpc."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49645"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "project-delete-client"


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


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = bin_path(repo_dir, "result-daemon", "result", "ham-daemon")
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-1", "ham-ctl")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-2", "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-project-delete-")
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
        daemon_log = open(daemon_log_path, "w", encoding="utf-8")
        daemon_proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=daemon_log, stderr=subprocess.STDOUT)
        wait_for_daemon()

        _, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if not user_token:
            raise AssertionError(f"user registration failed: {user_res}")

        status, create_res = request_post("/user-rpc", {
            "action": "project_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "name": "Delete Me",
            "description": "project delete regression",
            "anchors": [
                {"type": "directory", "value": temp_home, "note": "local project directory for VCS detection"},
                {"type": "vcs_kind", "value": "auto", "note": "auto-detect VCS backend"},
            ],
        })
        if status != 200 or not create_res.get("ok") or not create_res.get("project_id"):
            raise AssertionError(f"project_create failed: status={status} body={create_res}")
        project_id = create_res["project_id"]

        status, show_res = request_post("/user-rpc", {
            "action": "project_show",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": project_id,
        })
        if status != 200 or show_res.get("project", {}).get("project_id") != project_id:
            raise AssertionError(f"project_show before delete failed: status={status} body={show_res}")
        anchors = {a.get("type"): a.get("value") for a in show_res.get("project", {}).get("anchors", [])}
        if anchors.get("directory") != temp_home or anchors.get("vcs_kind") != "auto":
            raise AssertionError(f"project VCS directory anchors were not persisted: {show_res}")

        status, delete_res = request_post("/user-rpc", {
            "action": "project_delete",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": project_id,
        })
        if status != 200 or not delete_res.get("ok") or delete_res.get("project_id") != project_id:
            raise AssertionError(f"project_delete failed: status={status} body={delete_res}")

        status, list_res = request_post("/user-rpc", {
            "action": "project_list",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
        })
        if status != 200:
            raise AssertionError(f"project_list failed: status={status} body={list_res}")
        if any(p.get("project_id") == project_id for p in list_res.get("projects", [])):
            raise AssertionError(f"deleted project remained in list: {list_res}")

        status, deleted_show = request_post("/user-rpc", {
            "action": "project_show",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": project_id,
        })
        if status != 404 or deleted_show.get("ok") is not False:
            raise AssertionError(f"deleted project should 404 on show: status={status} body={deleted_show}")

        print("PASS: project_delete removes project from list and show")
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
