#!/usr/bin/env python3
"""E2E regression for multi-instance start lifecycle and exact-instance resume.

Covers:
- REQ-CONV-003: starting by durable agent_id mints a new concrete instance by default
- REQ-CONV-004: exact-instance resume preserves chat history + conversation identity,
  including across a daemon restart and durable replay
- REQ-CONV-005: multiple concurrent instances per agent_id are allowed and coalescing
  only applies to the same exact agent_instance_id
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
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49662"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
AGENT_ID = "conversation"
SESSION_RE = re.compile(r"^conversation@s-[0-9a-f]{12}$")


def bin_path(repo_dir: Path, binary: str, *candidates: str) -> str:
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
    raise FileNotFoundError(f"could not locate {binary} from {repo_dir}")


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


def wait_for(predicate, timeout: float = 5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    return predicate()


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
    fake_wrapper_tmp = tempfile.mkdtemp(prefix="heimdall-conv-start-lifecycle-")
    wrapper_calls = Path(fake_wrapper_tmp) / "wrapper-calls.log"
    fake_wrapper = Path(fake_wrapper_tmp) / "fake-wrapper.sh"
    fake_wrapper.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\n' \"$*\" >> \"$FAKE_WRAPPER_CALLS\"\n"
        "sleep 30\n",
        encoding="utf-8",
    )
    fake_wrapper.chmod(0o755)

    temp_home = tempfile.mkdtemp(prefix="heimdall-conv-start-lifecycle-home-")
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
daemon_id = "daemon-start-lifecycle-test"
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

        env = os.environ.copy()
        env["FAKE_WRAPPER_CALLS"] = str(wrapper_calls)
        proc, log = start_daemon(daemon_bin, config_path, log_path, env)

        # Seed a durable identity with default provider/tier/project.
        status, create_res = request_json("POST", "/agents/create", {
            "agent_instance_id": "conversation@legacy",
            "display_name": "Conversation Durable",
            "template_id": "conversation",
            "provider_profile": "durable-provider",
            "model_tier": "smart",
            "project_id": "proj-conv",
        })
        if status != 200 or not create_res.get("ok"):
            raise AssertionError(f"seed create failed: status={status} body={create_res}")

        status, start1 = request_json("POST", "/agents/start", {"agent_id": AGENT_ID})
        if status != 200 or not start1.get("ok"):
            raise AssertionError(f"first agent_id start failed: status={status} body={start1}")
        if start1.get("start_mode") != "new_instance":
            raise AssertionError(f"agent_id start should default to new_instance: {start1}")
        inst1 = start1.get("agent_instance_id", "")
        if not SESSION_RE.match(inst1):
            raise AssertionError(f"first agent_id start did not mint session-token instance: {start1}")
        if start1.get("agent_id") != AGENT_ID or start1.get("project_id") != "proj-conv":
            raise AssertionError(f"first agent_id start did not inherit durable identity/project: {start1}")
        if start1.get("provider_profile") != "durable-provider" or start1.get("model_tier") != "smart":
            raise AssertionError(f"first agent_id start did not inherit durable provider/tier defaults: {start1}")

        status, start2 = request_json("POST", "/agents/start", {"agent_id": AGENT_ID})
        if status != 200 or not start2.get("ok"):
            raise AssertionError(f"second agent_id start failed: status={status} body={start2}")
        inst2 = start2.get("agent_instance_id", "")
        if not SESSION_RE.match(inst2) or inst1 == inst2:
            raise AssertionError(f"second agent_id start should mint a distinct concrete instance: {start2}")
        if start2.get("project_id") != "proj-conv":
            raise AssertionError(f"second agent_id start lost inherited project: {start2}")

        def read_calls():
            if not wrapper_calls.exists():
                return []
            return [line for line in wrapper_calls.read_text(encoding="utf-8").splitlines() if line.strip()]

        calls_after_two = wait_for(lambda: read_calls() if len(read_calls()) >= 2 else None)
        if len(calls_after_two) != 2:
            raise AssertionError(f"expected two wrapper launches for two distinct agent_id starts: {calls_after_two}")
        if sum(inst1 in line for line in calls_after_two) != 1 or sum(inst2 in line for line in calls_after_two) != 1:
            raise AssertionError(f"wrapper launches did not target the two distinct concrete instances: {calls_after_two}")

        # Exact-instance relaunch while the same concrete instance is already launching
        # should coalesce instead of spawning a third wrapper process.
        status, coalesced = request_json("POST", "/agents/start", {"agent_instance_id": inst1})
        if status != 200 or not coalesced.get("ok") or coalesced.get("message") != "already running or launch in progress":
            raise AssertionError(f"exact-instance start should coalesce while launching: status={status} body={coalesced}")
        time.sleep(0.2)
        calls_after_coalesce = read_calls()
        if len(calls_after_coalesce) != 2 or sum(inst1 in line for line in calls_after_coalesce) != 1:
            raise AssertionError(f"coalesced exact-instance start spawned a duplicate wrapper: {calls_after_coalesce}")

        # Register the concrete instance using the pre-issued token so we can append
        # durable chat history keyed to that exact instance id.
        status, reg1 = request_json("POST", "/register", {
            "agent_class": AGENT_ID,
            "agent_instance_id": inst1,
            "display_name": "Conversation Durable",
            "agent_token": start1.get("agent_token", ""),
        })
        if status != 200 or reg1.get("agent_instance_id") != inst1:
            raise AssertionError(f"manual register for exact instance failed: status={status} body={reg1}")

        status, user = request_json("POST", "/user-client/register", {
            "user_id": USER_ID,
            "client_instance_id": "conv-start-lifecycle-user",
        })
        if status != 200 or not user.get("client_token"):
            raise AssertionError(f"user register failed: status={status} body={user}")
        client_token = user["client_token"]

        status, send_res = request_json("POST", "/user-rpc", {
            "action": "send_to_agent",
            "client_instance_id": "conv-start-lifecycle-user",
            "client_token": client_token,
            "agent_instance_id": inst1,
            "body": "resume-history-message",
        })
        if status != 200 or not send_res.get("ok"):
            raise AssertionError(f"send_to_agent failed: status={status} body={send_res}")

        status, chat_before = request_json("POST", "/user-rpc", {
            "action": "fetch_chat",
            "client_instance_id": "conv-start-lifecycle-user",
            "client_token": client_token,
            "agent_instance_id": inst1,
            "unread_only": False,
            "limit": 20,
        })
        if status != 200:
            raise AssertionError(f"fetch_chat before resume failed: status={status} body={chat_before}")
        messages_before = chat_before.get("messages", [])
        if not any(msg.get("body") == "resume-history-message" for msg in messages_before):
            raise AssertionError(f"chat history missing before resume: {chat_before}")

        status, stop_done = request_json("POST", "/agents/stop-done", {"agent_instance_id": inst1})
        if status != 200 or not stop_done.get("ok"):
            raise AssertionError(f"stop-done failed: status={status} body={stop_done}")

        # REQ-CONV-004 must survive durable replay, not just same-process state.
        stop_daemon(proc, log)
        proc = None
        log = None
        time.sleep(0.2)
        proc, log = start_daemon(daemon_bin, config_path, log_path, env)

        status, user_after_restart = request_json("POST", "/user-client/register", {
            "user_id": USER_ID,
            "client_instance_id": "conv-start-lifecycle-user-restart",
        })
        if status != 200 or not user_after_restart.get("client_token"):
            raise AssertionError(f"user register after restart failed: status={status} body={user_after_restart}")
        client_token_after_restart = user_after_restart["client_token"]

        status, resume = request_json("POST", "/agents/start", {"agent_instance_id": inst1})
        if status != 200 or not resume.get("ok"):
            raise AssertionError(f"exact-instance resume failed: status={status} body={resume}")
        if resume.get("start_mode") != "reuse_instance":
            raise AssertionError(f"exact-instance resume should default to reuse_instance: {resume}")
        if resume.get("agent_instance_id") != inst1:
            raise AssertionError(f"exact-instance resume should target the same concrete instance: {resume}")
        if resume.get("agent_token") != start1.get("agent_token"):
            raise AssertionError(f"exact-instance resume should reuse the same agent token across daemon restart: before={start1} after={resume}")
        if resume.get("conversation_id") != start1.get("conversation_id"):
            raise AssertionError(f"exact-instance resume should preserve conversation_id across daemon restart: before={start1} after={resume}")

        calls_after_resume = wait_for(lambda: read_calls() if sum(inst1 in line for line in read_calls()) >= 2 else None)
        if sum(inst1 in line for line in calls_after_resume) != 2:
            raise AssertionError(f"exact-instance resume should spawn a second launch for the same stopped instance after daemon restart: {calls_after_resume}")

        status, chat_after = request_json("POST", "/user-rpc", {
            "action": "fetch_chat",
            "client_instance_id": "conv-start-lifecycle-user-restart",
            "client_token": client_token_after_restart,
            "agent_instance_id": inst1,
            "unread_only": False,
            "limit": 20,
        })
        if status != 200:
            raise AssertionError(f"fetch_chat after resume failed: status={status} body={chat_after}")
        messages_after = chat_after.get("messages", [])
        if [msg.get("message_id") for msg in messages_after] != [msg.get("message_id") for msg in messages_before]:
            raise AssertionError(f"exact-instance resume did not preserve exact chat history: before={chat_before} after={chat_after}")

        print(json.dumps({
            "ok": True,
            "instance_1": inst1,
            "instance_2": inst2,
            "conversation_id": start1.get("conversation_id"),
            "wrapper_calls": calls_after_resume,
            "messages_preserved": len(messages_after),
        }, indent=2, sort_keys=True))
        print("PASS: conversation multi-instance start lifecycle")
    finally:
        stop_daemon(proc, log)
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dirs: {fake_wrapper_tmp} {temp_home}")
        else:
            shutil.rmtree(fake_wrapper_tmp, ignore_errors=True)
            shutil.rmtree(temp_home, ignore_errors=True)


if __name__ == "__main__":
    main()
