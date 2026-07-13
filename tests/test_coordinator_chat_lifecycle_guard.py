#!/usr/bin/env python3
"""Regression: startup-report downgrade is ignored and coordinator chat send stays pure delivery."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49645"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "coord-chat-lifecycle-client"
COORDINATOR_ID = "coord-chat-lifecycle@task19-e2e"
CHAIN_ID = "chain-coord-chat-lifecycle-task19"


def bin_path(repo_dir, preferred, fallback, binary):
    preferred_path = os.path.join(repo_dir, preferred, "bin", binary)
    if os.path.exists(preferred_path):
        return preferred_path
    return os.path.join(repo_dir, fallback, "bin", binary)


def parse_json(raw, context):
    try:
        return json.loads(raw)
    except json.JSONDecodeError as err:
        raise AssertionError(f"{context} returned invalid JSON: {raw}") from err


def request_post(path, data):
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            raw = res.read().decode("utf-8")
            return res.status, parse_json(raw, path)
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8")
        return err.code, parse_json(raw, f"{path} error")


def request_get_json(path, token=None):
    if token:
        sep = "&" if "?" in path else "?"
        path = f"{path}{sep}token={urllib.parse.quote(token)}"
    with urllib.request.urlopen(f"{DAEMON_URL}{path}", timeout=10) as res:
        return res.status, parse_json(res.read().decode("utf-8"), path)


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


def find_agent(payload, agent_instance_id):
    matches = [a for a in payload.get("agents", []) if a.get("agent_instance_id") == agent_instance_id]
    if len(matches) != 1:
        raise AssertionError(f"agent {agent_instance_id} not found exactly once: {payload}")
    return matches[0]


def read_log_since(path, start_offset):
    with open(path, "r", encoding="utf-8") as f:
        f.seek(start_offset)
        return f.read()


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = bin_path(repo_dir, "result-daemon", "result", "ham-daemon")
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-1", "ham-ctl")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-2", "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-coord-chat-lifecycle-")
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

        status, coord_res = request_post("/register", {
            "agent_class": "coord-chat-lifecycle",
            "agent_instance_id": COORDINATOR_ID,
            "display_name": "Coordinator Chat Lifecycle",
        })
        if status != 200 or not coord_res.get("agent_token"):
            raise AssertionError(f"coordinator registration failed: status={status} body={coord_res}")
        coord_token = coord_res["agent_token"]

        status, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        if status != 200 or not user_res.get("client_token"):
            raise AssertionError(f"user registration failed: status={status} body={user_res}")
        user_token = user_res["client_token"]

        status, chain_res = request_post("/user-rpc", {
            "action": "task_chain_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": "default",
            "kind": "solo",
            "title": "Coordinator lifecycle guard",
            "chain_id": CHAIN_ID,
            "coordinator_agent_instance_id": COORDINATOR_ID,
            "wants_vcs": False,
            "no_scaffold": True,
        })
        if status != 200 or not chain_res.get("ok") or chain_res.get("chain_id") != CHAIN_ID:
            raise AssertionError(f"task_chain_create failed: status={status} body={chain_res}")

        status, start_success = request_post("/agent-rpc", {
            "agent_token": coord_token,
            "action": "start_success",
        })
        if status != 200 or not start_success.get("ok") or start_success.get("status") != "ready":
            raise AssertionError(f"start_success failed: status={status} body={start_success}")

        _, agents_before = request_get_json("/agents")
        before = find_agent(agents_before, COORDINATOR_ID)
        if before.get("startup_status") != "ready" or before.get("startup_reason_code") != "start_success":
            raise AssertionError(f"coordinator not ready before stale report: {before}")

        status, stale_report = request_post("/startup", {
            "agent_instance_id": COORDINATOR_ID,
            "startup_status": "startup_unknown",
            "reason_code": "no_pattern_matched",
            "safe_diagnostic": "No configured startup pattern matched before timeout",
        })
        if status != 200 or not stale_report.get("ok"):
            raise AssertionError(f"startup report failed: status={status} body={stale_report}")

        _, agents_after = request_get_json("/agents")
        after = find_agent(agents_after, COORDINATOR_ID)
        if after.get("startup_status") != "ready" or after.get("startup_reason_code") != "start_success":
            raise AssertionError(f"stale startup report downgraded ready/start_success: {after}")

        status, completed = request_post("/user-rpc", {
            "action": "task_chain_status",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "chain_id": CHAIN_ID,
            "status": "completed",
            "final_summary": "done",
        })
        if status != 200 or not completed.get("ok"):
            raise AssertionError(f"task_chain_status completed failed: status={status} body={completed}")

        log_offset = os.path.getsize(daemon_log_path)
        body = "completed-chain message must stay chain-scoped without boot"
        status, send_res = request_post("/chat/send-to-coordinator", {
            "token": user_token,
            "chain_id": CHAIN_ID,
            "body": body,
        })
        if status != 200 or not send_res.get("ok") or not send_res.get("message_id"):
            raise AssertionError(f"send-to-coordinator failed: status={status} body={send_res}")
        if send_res.get("chain_id") != CHAIN_ID:
            raise AssertionError(f"send-to-coordinator lost chain_id: {send_res}")
        if send_res.get("coordinator_boot_requested") is not False:
            raise AssertionError(f"chat send should not request coordinator boot: {send_res}")
        message_id = send_res["message_id"]

        time.sleep(0.2)
        post_send_log = read_log_since(daemon_log_path, log_offset)
        if "source=coordinator_message" in post_send_log:
            raise AssertionError(f"chat send still triggered coordinator lifecycle reconcile: {post_send_log}")

        _, direct_fetch = request_post("/user-rpc", {
            "action": "fetch_chat",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "agent_instance_id": COORDINATOR_ID,
            "unread_only": False,
            "limit": 20,
        })
        direct_matches = [m for m in direct_fetch.get("messages", []) if m.get("message_id") == message_id]
        if len(direct_matches) != 1:
            raise AssertionError(f"direct fetch could not see chain-scoped coordinator message: {direct_fetch}")
        direct_msg = direct_matches[0]
        if direct_msg.get("direction") != "user_to_agent" or direct_msg.get("body") != body or direct_msg.get("chain_id") != CHAIN_ID:
            raise AssertionError(f"unexpected direct fetch payload: {direct_msg}")

        _, chain_fetch = request_get_json(f"/chats/{urllib.parse.quote(COORDINATOR_ID)}/messages?chain_id={CHAIN_ID}", user_token)
        chain_matches = [m for m in chain_fetch.get("messages", []) if m.get("message_id") == message_id]
        if len(chain_matches) != 1:
            raise AssertionError(f"chain-filtered fetch missing coordinator message: {chain_fetch}")
        if chain_matches[0].get("chain_id") != CHAIN_ID or chain_matches[0].get("body") != body:
            raise AssertionError(f"chain-filtered fetch lost chain metadata/body: {chain_matches[0]}")

        print("PASS: stale startup downgrade ignored and send-to-coordinator stays pure chain-scoped delivery")
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
