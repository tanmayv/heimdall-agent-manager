#!/usr/bin/env python3
"""REQ-CONV-009 regression for enriched conversation chat list entries."""

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
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49666"))
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


def request_json(method: str, path: str, data=None, headers=None):
    body = None if data is None else json.dumps(data, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=body,
        headers={"Content-Type": "application/json", **(headers or {})},
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


def main() -> None:
    repo_dir = Path(__file__).resolve().parents[1]
    daemon_bin = bin_path(repo_dir, "ham-daemon", "result", "result-daemon", "result-1")
    chat_events_src = (repo_dir / "src/daemon/chat_events.odin").read_text(encoding="utf-8")
    if '","body":"' in chat_events_src:
        raise AssertionError("chat websocket notifications must remain metadata-only; body found in chat_events.odin")
    if '"unread_count":' not in chat_events_src or '"message_id":' not in chat_events_src:
        raise AssertionError("chat websocket notifications should still carry metadata fields")

    fake_wrapper_tmp = tempfile.mkdtemp(prefix="heimdall-chat-list-")
    fake_wrapper = Path(fake_wrapper_tmp) / "fake-wrapper.sh"
    fake_wrapper.write_text("#!/usr/bin/env bash\nsleep 30\n", encoding="utf-8")
    fake_wrapper.chmod(0o755)

    temp_home = tempfile.mkdtemp(prefix="heimdall-chat-list-home-")
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
daemon_id = "daemon-chat-list-test"
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

        agents = [
            ("conversation@s-alpha-1", "project-alpha"),
            ("conversation@s-beta-1", "project-beta"),
            ("conversation@s-alpha-2", "project-alpha"),
        ]
        agent_tokens = {}
        for agent_instance_id, project_id in agents:
            status, created = request_json("POST", "/agents/create", {
                "agent_instance_id": agent_instance_id,
                "display_name": f"Conversation {agent_instance_id}",
                "template_id": "conversation",
                "provider_profile": "pi",
                "model_tier": "normal",
                "project_id": project_id,
            })
            if status != 200 or not created.get("ok"):
                raise AssertionError(f"/agents/create failed for {agent_instance_id}: status={status} body={created}")
            status, reg = request_json("POST", "/register", {
                "agent_class": "conversation",
                "agent_instance_id": agent_instance_id,
                "display_name": f"Conversation {agent_instance_id}",
            })
            token = reg.get("agent_token", "")
            if status != 200 or not token:
                raise AssertionError(f"/register failed for {agent_instance_id}: status={status} body={reg}")
            agent_tokens[agent_instance_id] = token

        status, user = request_json("POST", "/user-client/register", {
            "user_id": USER_ID,
            "client_instance_id": "chat-list-user",
        })
        client_token = user.get("client_token", "")
        if status != 200 or not client_token:
            raise AssertionError(f"/user-client/register failed: status={status} body={user}")

        send_order = [
            ("conversation@s-alpha-1", "oldest"),
            ("conversation@s-beta-1", "middle"),
            ("conversation@s-alpha-2", "newest"),
        ]
        for agent_instance_id, body in send_order:
            status, sent = request_json("POST", "/agent-rpc", {
                "agent_token": agent_tokens[agent_instance_id],
                "action": "send_to_user",
                "user_id": USER_ID,
                "body": body,
            })
            if status != 200 or not sent.get("ok"):
                raise AssertionError(f"send_to_user failed for {agent_instance_id}: status={status} body={sent}")
            time.sleep(0.03)

        status, list_rpc = request_json("POST", "/user-rpc", {
            "action": "list_chats",
            "client_instance_id": "chat-list-user",
            "client_token": client_token,
        })
        if status != 200 or not list_rpc.get("ok"):
            raise AssertionError(f"user-rpc list_chats failed: status={status} body={list_rpc}")

        chats = list_rpc.get("chats", [])
        expected_order = ["conversation@s-alpha-2", "conversation@s-beta-1", "conversation@s-alpha-1"]
        actual_order = [chat.get("agent_instance_id") for chat in chats]
        if actual_order != expected_order:
            raise AssertionError(f"chat list order should follow last_message_unix_ms desc: expected={expected_order} actual={actual_order} body={list_rpc}")

        expected_projects = {
            "conversation@s-alpha-1": "project-alpha",
            "conversation@s-beta-1": "project-beta",
            "conversation@s-alpha-2": "project-alpha",
        }
        last_seen = None
        for chat in chats:
            agent_instance_id = chat.get("agent_instance_id", "")
            if chat.get("agent_id") != "conversation":
                raise AssertionError(f"chat list must expose authoritative agent_id for {agent_instance_id}: {chat}")
            if chat.get("project_id") != expected_projects.get(agent_instance_id):
                raise AssertionError(f"chat list must expose authoritative project_id for {agent_instance_id}: {chat}")
            if chat.get("unread_count") != 1:
                raise AssertionError(f"chat list unread_count should remain intact for {agent_instance_id}: {chat}")
            ts = chat.get("last_message_unix_ms", 0)
            if not isinstance(ts, int) or ts <= 0:
                raise AssertionError(f"chat list must expose last_message_unix_ms for {agent_instance_id}: {chat}")
            if last_seen is not None and ts > last_seen:
                raise AssertionError(f"chat list timestamps must be descending: previous={last_seen} current={ts} chat={chat}")
            last_seen = ts

        status, list_rest = request_json("GET", "/chats", headers={"Authorization": f"Bearer {client_token}"})
        if status != 200:
            raise AssertionError(f"GET /chats failed: status={status} body={list_rest}")
        rest_chats = list_rest.get("chats", [])
        if rest_chats != chats:
            raise AssertionError(f"REST /chats should expose the same enriched chat entries as user-rpc: rest={rest_chats} rpc={chats}")

        print(json.dumps({
            "ok": True,
            "order": actual_order,
            "projects": {chat["agent_instance_id"]: chat["project_id"] for chat in chats},
            "timestamps": {chat["agent_instance_id"]: chat["last_message_unix_ms"] for chat in chats},
        }, indent=2, sort_keys=True))
        print("PASS: chat list sidebar backend")
    finally:
        stop_daemon(proc, log)
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp_home}")
        else:
            shutil.rmtree(fake_wrapper_tmp, ignore_errors=True)
            shutil.rmtree(temp_home, ignore_errors=True)


if __name__ == "__main__":
    main()
