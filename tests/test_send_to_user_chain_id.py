#!/usr/bin/env python3
"""Regression for chain-scoped agent send_to_user replies."""
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
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49643"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "chain-send-user-client"
COORDINATOR_ID = "coord-chain-send@task19-e2e"
OTHER_AGENT_ID = "non-coord-chain-send@task19-e2e"
CHAIN_ID = "chain-send-to-user-task19"
OTHER_CHAIN_ID = "chain-send-to-user-other"


def bin_path(repo_dir, preferred, fallback, binary):
    preferred_path = os.path.join(repo_dir, preferred, "bin", binary)
    if os.path.exists(preferred_path):
        return preferred_path
    return os.path.join(repo_dir, fallback, "bin", binary)


class HttpError(RuntimeError):
    def __init__(self, status, payload):
        super().__init__(f"HTTP {status}: {payload}")
        self.status = status
        self.payload = payload


def request_post(path, data):
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status, json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        payload = json.loads(err.read().decode("utf-8"))
        return err.code, payload


def request_get_json(path, token):
    sep = "&" if "?" in path else "?"
    req = urllib.request.Request(f"{DAEMON_URL}{path}{sep}token={urllib.parse.quote(token)}", method="GET")
    with urllib.request.urlopen(req, timeout=10) as res:
        return res.status, json.loads(res.read().decode("utf-8"))


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


def create_chain(user_token, title, chain_id, coordinator_id):
    status, res = request_post(
        "/user-rpc",
        {
            "action": "task_chain_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": "default",
            "kind": "solo",
            "title": title,
            "chain_id": chain_id,
            "coordinator_agent_instance_id": coordinator_id,
            "wants_vcs": False,
            "no_scaffold": True,
        },
    )
    if status != 200 or not res.get("ok"):
        raise AssertionError(f"task_chain_create failed: status={status} body={res}")
    if res.get("chain_id") != chain_id:
        raise AssertionError(f"unexpected chain response: {res}")


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = bin_path(repo_dir, "result-daemon", "result", "ham-daemon")
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-1", "ham-ctl")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-2", "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-chain-send-user-")
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

        _, coord_res = request_post("/register", {
            "agent_class": "coord-chain-send",
            "agent_instance_id": COORDINATOR_ID,
            "display_name": "Chain Send Coordinator",
        })
        coord_token = coord_res.get("agent_token")
        if not coord_token:
            raise AssertionError(f"coordinator registration failed: {coord_res}")

        _, other_res = request_post("/register", {
            "agent_class": "non-coord-chain-send",
            "agent_instance_id": OTHER_AGENT_ID,
            "display_name": "Non Coordinator Sender",
        })
        other_token = other_res.get("agent_token")
        if not other_token:
            raise AssertionError(f"other agent registration failed: {other_res}")

        _, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if not user_token:
            raise AssertionError(f"user registration failed: {user_res}")

        create_chain(user_token, "Chain-scoped send_to_user", CHAIN_ID, COORDINATOR_ID)

        auto_body = "coordinator reply auto-inferred into chain chat"
        status, auto_res = request_post("/agent-rpc", {
            "agent_token": coord_token,
            "action": "send_to_user",
            "user_id": USER_ID,
            "body": auto_body,
        })
        if status != 200 or not auto_res.get("ok") or not auto_res.get("message_id"):
            raise AssertionError(f"auto-inferred send_to_user failed: status={status} body={auto_res}")
        if auto_res.get("chain_id") != CHAIN_ID:
            raise AssertionError(f"expected inferred chain_id in response, got: {auto_res}")

        create_chain(user_token, "Other chain for filtering", OTHER_CHAIN_ID, COORDINATOR_ID)

        body = "coordinator reply persisted in chain chat"
        status, send_res = request_post("/agent-rpc", {
            "agent_token": coord_token,
            "action": "send_to_user",
            "user_id": USER_ID,
            "body": body,
            "chain_id": CHAIN_ID,
        })
        if status != 200 or not send_res.get("ok") or not send_res.get("message_id"):
            raise AssertionError(f"chain-scoped send_to_user failed: status={status} body={send_res}")
        if send_res.get("chain_id") != CHAIN_ID:
            raise AssertionError(f"expected chain_id in response, got: {send_res}")
        message_id = send_res["message_id"]

        _, fetch_res = request_post("/user-rpc", {
            "action": "fetch_chat",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "agent_instance_id": COORDINATOR_ID,
            "unread_only": False,
            "limit": 20,
        })
        matches = [m for m in fetch_res.get("messages", []) if m.get("message_id") == message_id]
        if len(matches) != 1:
            raise AssertionError(f"direct fetch could not see chain-scoped reply: {fetch_res}")
        msg = matches[0]
        if msg.get("direction") != "agent_to_user" or msg.get("body") != body or msg.get("chain_id") != CHAIN_ID:
            raise AssertionError(f"unexpected direct fetch payload: {msg}")

        _, chain_fetch = request_get_json(f"/chats/{urllib.parse.quote(COORDINATOR_ID)}/messages?chain_id={CHAIN_ID}", user_token)
        chain_matches = [m for m in chain_fetch.get("messages", []) if m.get("message_id") == message_id]
        if len(chain_matches) != 1:
            raise AssertionError(f"chain-filtered fetch missing reply: {chain_fetch}")
        if chain_matches[0].get("chain_id") != CHAIN_ID:
            raise AssertionError(f"chain-filtered fetch lost chain_id: {chain_matches[0]}")

        _, wrong_chain_fetch = request_get_json(f"/chats/{urllib.parse.quote(COORDINATOR_ID)}/messages?chain_id={OTHER_CHAIN_ID}", user_token)
        if any(m.get("message_id") == message_id for m in wrong_chain_fetch.get("messages", [])):
            raise AssertionError(f"reply leaked into wrong chain view: {wrong_chain_fetch}")

        status, bad_chain = request_post("/agent-rpc", {
            "agent_token": coord_token,
            "action": "send_to_user",
            "user_id": USER_ID,
            "body": "should fail",
            "chain_id": "chain-does-not-exist",
        })
        if status != 404 or bad_chain.get("ok") is not False or "unknown chain_id" not in bad_chain.get("message", ""):
            raise AssertionError(f"unknown chain_id did not fail clearly: status={status} body={bad_chain}")

        redirected_body = "please ask the user for clarification"
        status, non_coord = request_post("/agent-rpc", {
            "agent_token": other_token,
            "action": "send_to_user",
            "user_id": USER_ID,
            "body": redirected_body,
            "chain_id": CHAIN_ID,
        })
        if status != 200 or not non_coord.get("ok") or not non_coord.get("redirected_to_coordinator"):
            raise AssertionError(f"non-coordinator send was not redirected: status={status} body={non_coord}")
        if non_coord.get("coordinator_agent_instance_id") != COORDINATOR_ID or non_coord.get("delivered_to_user") is not False:
            raise AssertionError(f"unexpected redirect response: {non_coord}")
        redirect_id = non_coord.get("message_id")
        _, redirect_fetch = request_get_json(f"/chats/{urllib.parse.quote(COORDINATOR_ID)}/messages?chain_id={CHAIN_ID}", user_token)
        redirect_matches = [m for m in redirect_fetch.get("messages", []) if m.get("message_id") == redirect_id]
        if len(redirect_matches) != 1:
            raise AssertionError(f"redirect did not reach coordinator chain chat: {redirect_fetch}")
        if redirected_body not in redirect_matches[0].get("body", "") or OTHER_AGENT_ID not in redirect_matches[0].get("body", ""):
            raise AssertionError(f"redirect did not preserve original agent/body context: {redirect_matches[0]}")
        if redirect_matches[0].get("direction") != "user_to_agent":
            raise AssertionError(f"redirect should be delivered as coordinator inbox message: {redirect_matches[0]}")

        status, ambiguous = request_post("/agent-rpc", {
            "agent_token": coord_token,
            "action": "send_to_user",
            "user_id": USER_ID,
            "body": "ambiguous without chain id",
        })
        if status != 409 or ambiguous.get("ok") is not False or "multiple possible active chains" not in ambiguous.get("message", ""):
            raise AssertionError(f"ambiguous coordinator send did not request explicit chain_id: status={status} body={ambiguous}")

        print("PASS: send_to_user persists/infer coordinator chain replies and redirects non-coordinator sends")
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
