#!/usr/bin/env python3
"""Regression for supported chain team member add -> task assignment."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49646"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "team-add-member-client"
COORDINATOR_ID = "coord-team-add@bug1-e2e"
REAL_AGENT_ID = "researcher@swe-team"
CHAIN_ID = "chain-team-add-member-bug1"


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

    temp_home = tempfile.mkdtemp(prefix="heimdall-team-add-member-")
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

        _, agent_res = request_post("/register", {
            "agent_class": "coord-team-add",
            "agent_instance_id": COORDINATOR_ID,
            "display_name": "Team Add Coordinator",
        })
        coord_token = agent_res.get("agent_token")
        if not coord_token:
            raise AssertionError(f"coordinator registration failed: {agent_res}")

        _, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if not user_token:
            raise AssertionError(f"user registration failed: {user_res}")

        status, chain_res = request_post("/user-rpc", {
            "action": "task_chain_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": "default",
            "kind": "coding",
            "title": "Team add member regression",
            "chain_id": CHAIN_ID,
            "coordinator_agent_instance_id": COORDINATOR_ID,
            "wants_vcs": False,
            "no_scaffold": True,
        })
        if status != 200 or not chain_res.get("ok"):
            raise AssertionError(f"task_chain_create failed: status={status} body={chain_res}")
        team_id = chain_res.get("team_id")
        if not team_id:
            raise AssertionError(f"chain create missing team_id: {chain_res}")

        status, blocked_create = request_post("/tasks/create", {
            "agent_token": coord_token,
            "chain_id": CHAIN_ID,
            "title": "Should initially fail",
            "assignee_agent_instance_id": REAL_AGENT_ID,
        })
        if status == 200 or "member" not in blocked_create.get("message", ""):
            raise AssertionError(f"assignment unexpectedly succeeded before add-member: status={status} body={blocked_create}")

        status, add_res = request_post("/teams/add-member", {
            "agent_token": coord_token,
            "team_id": team_id,
            "role_key": "specialist",
            "agent_instance_id": REAL_AGENT_ID,
        })
        if status != 200 or not add_res.get("ok"):
            raise AssertionError(f"teams add-member failed: status={status} body={add_res}")
        member = add_res.get("member", {})
        if member.get("agent_instance_id") != REAL_AGENT_ID or member.get("route_to") != REAL_AGENT_ID:
            raise AssertionError(f"added member did not expose routed real agent: {add_res}")

        status, created = request_post("/tasks/create", {
            "agent_token": coord_token,
            "chain_id": CHAIN_ID,
            "title": "Should succeed after add-member",
            "assignee_agent_instance_id": REAL_AGENT_ID,
            "status": "planning",
        })
        if status != 200 or not created.get("ok"):
            raise AssertionError(f"task assignment failed after add-member: status={status} body={created}")

        print("PASS: teams add-member enables assignment to routed real agent")
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
