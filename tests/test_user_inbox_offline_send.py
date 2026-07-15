import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HOST = "127.0.0.1"
PORT = 49331
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
AGENT_ID = "offline-user-inbox-agent@default"


def bin_path(repo_dir, preferred, fallback, binary):
    env_key = {
        "ham-daemon": "HEIMDALL_DAEMON_BIN",
        "ham-ctl": "HEIMDALL_CTL_BIN",
        "ham-wrapper": "HEIMDALL_WRAPPER_BIN",
    }.get(binary, "")
    env_override = os.environ.get(env_key, "") if env_key else ""
    if env_override and os.path.exists(env_override):
        return env_override

    preferred_path = os.path.join(repo_dir, preferred, "bin", binary)
    if os.path.exists(preferred_path):
        return preferred_path

    fallback_path = os.path.join(repo_dir, fallback, "bin", binary)
    if os.path.exists(fallback_path):
        return fallback_path

    for path in sorted(glob.glob(os.path.join(repo_dir, "result*", "bin", binary))):
        if os.path.exists(path):
            return path

    which = shutil.which(binary)
    if which:
        return which

    raise FileNotFoundError(f"could not locate {binary}")


def request_post(path, data):
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=5) as res:
        return json.loads(res.read().decode("utf-8"))


def run_ctl(ctl_bin, *args):
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


def wait_for_daemon():
    for _ in range(40):
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
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-2", "ham-ctl")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-1", "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-offline-user-inbox-")
    daemon_log_path = os.path.join(temp_home, "daemon.log")
    config_path = os.path.join(temp_home, "config.toml")
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
        daemon_proc = subprocess.Popen(
            [daemon_bin, "--config", config_path],
            stdout=daemon_log,
            stderr=subprocess.STDOUT,
        )
        wait_for_daemon()

        agent_res = request_post("/register", {
            "agent_class": "offline-user-inbox-agent",
            "agent_instance_id": AGENT_ID,
            "display_name": "Offline User Inbox Agent",
        })
        agent_token = agent_res.get("agent_token")
        if not agent_token:
            raise AssertionError(f"agent registration did not return token: {agent_res}")

        body = "offline durable hello"
        send_res = run_ctl(
            ctl_bin,
            "chat", "send-to-user",
            "--token", agent_token,
            "--user-id", USER_ID,
            "--body", body,
        )
        if not send_res.get("ok") or not send_res.get("message_id"):
            raise AssertionError(f"offline send-to-user did not persist successfully: {send_res}")
        message_id = send_res["message_id"]

        unknown_res = run_ctl(
            ctl_bin,
            "chat", "send-to-user",
            "--token", agent_token,
            "--user-id", "unknown-offline-user@local",
            "--body", "should fail",
        )
        if unknown_res.get("ok") is not False or "unknown user_id" not in unknown_res.get("message", ""):
            raise AssertionError(f"expected unknown user to remain a hard error, got: {unknown_res}")

        user_res = request_post("/user-client/register", {
            "user_id": USER_ID,
            "client_instance_id": "offline-user-inbox-client",
        })
        user_token = user_res.get("client_token")
        if not user_token:
            raise AssertionError(f"user registration did not return token: {user_res}")

        list_res = run_ctl(
            ctl_bin,
            "chat", "list",
            "--client-instance-id", "offline-user-inbox-client",
            "--token", user_token,
        )
        chats = list_res.get("chats", [])
        chat = next((c for c in chats if c.get("agent_instance_id") == AGENT_ID), None)
        if not chat or chat.get("unread_count") != 1:
            raise AssertionError(f"expected unread_count=1 for durable message, got: {list_res}")

        fetch_res = run_ctl(
            ctl_bin,
            "chat", "fetch",
            "--client-instance-id", "offline-user-inbox-client",
            "--token", user_token,
            "--agent-instance-id", AGENT_ID,
        )
        messages = fetch_res.get("messages", [])
        matches = [m for m in messages if m.get("message_id") == message_id]
        if len(matches) != 1:
            raise AssertionError(f"durable message not fetched after user registration: {fetch_res}")
        msg = matches[0]
        if msg.get("direction") != "agent_to_user" or msg.get("body") != body:
            raise AssertionError(f"fetched message content mismatch: {msg}")
        if msg.get("delivery_failed_unix_ms", 0) <= 0 or "no active user websocket" not in msg.get("delivery_error", ""):
            raise AssertionError(f"expected delivery failure metadata for offline UI delivery, got: {msg}")

        mark_res = run_ctl(
            ctl_bin,
            "chat", "mark-read",
            "--client-instance-id", "offline-user-inbox-client",
            "--token", user_token,
            "--agent-instance-id", AGENT_ID,
            "--message-id", message_id,
        )
        if not mark_res.get("ok"):
            raise AssertionError(f"mark-read failed: {mark_res}")

        list_after_read = run_ctl(
            ctl_bin,
            "chat", "list",
            "--client-instance-id", "offline-user-inbox-client",
            "--token", user_token,
        )
        chat_after_read = next((c for c in list_after_read.get("chats", []) if c.get("agent_instance_id") == AGENT_ID), None)
        if not chat_after_read or chat_after_read.get("unread_count") != 0:
            raise AssertionError(f"expected unread_count=0 after mark-read, got: {list_after_read}")

        print("ALL OFFLINE USER INBOX TESTS PASSED!")
    finally:
        if daemon_proc is not None:
            daemon_proc.terminate()
            try:
                daemon_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon_proc.kill()
        if daemon_log is not None:
            daemon_log.close()
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") != "1":
            shutil.rmtree(temp_home, ignore_errors=True)
        else:
            print(f"kept temp dir: {temp_home}")


if __name__ == "__main__":
    main()
