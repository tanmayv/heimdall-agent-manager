#!/usr/bin/env python3
"""Integration + static checks for conversation template seeding and guards."""

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
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49663"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"


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
    raise FileNotFoundError(f"could not locate {binary}")


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
    persona_text = (repo_dir / "src/prompts/conversation_persona.md").read_text(encoding="utf-8").strip()
    instructions_text = (repo_dir / "src/prompts/conversation_instructions.md").read_text(encoding="utf-8").strip()
    scheduler_src = (repo_dir / "src/daemon/task_nudge_scheduler.odin").read_text(encoding="utf-8")
    if 'if rec.template_id == "conversation" do continue' not in scheduler_src:
        raise AssertionError("REQ-CONV-007 guard missing: conversation idle shutdown exemption not found")

    fake_wrapper_tmp = tempfile.mkdtemp(prefix="heimdall-conversation-template-")
    fake_wrapper = Path(fake_wrapper_tmp) / "fake-wrapper.sh"
    fake_wrapper.write_text("#!/usr/bin/env bash\nsleep 30\n", encoding="utf-8")
    fake_wrapper.chmod(0o755)

    temp_home = tempfile.mkdtemp(prefix="heimdall-conversation-template-home-")
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
daemon_id = "daemon-conversation-template-test"
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

        status, templates = request_json("GET", "/agents/templates")
        if status != 200 or not templates.get("ok"):
            raise AssertionError(f"/agents/templates failed: status={status} body={templates}")
        by_id = {t["template_id"]: t for t in templates.get("templates", [])}
        conversation = by_id.get("conversation")
        if not conversation:
            raise AssertionError(f"conversation template missing from templates list: {templates}")
        if conversation.get("display_name") != "Conversation" or conversation.get("role_hint") != "conversation":
            raise AssertionError(f"conversation template metadata incorrect: {conversation}")

        status, start1 = request_json("POST", "/agents/start", {"agent_id": "conversation"})
        status2, start2 = request_json("POST", "/agents/start", {"agent_id": "conversation"})
        if status != 200 or not start1.get("ok") or status2 != 200 or not start2.get("ok"):
            raise AssertionError(f"conversation starts failed: start1={start1} start2={start2}")
        inst1 = start1.get("agent_instance_id", "")
        inst2 = start2.get("agent_instance_id", "")
        if not inst1.startswith("conversation@s-") or not inst2.startswith("conversation@s-") or inst1 == inst2:
            raise AssertionError(f"conversation start should mint unique conversation instances: {start1} {start2}")
        if start1.get("template_id") != "conversation" or start2.get("template_id") != "conversation":
            raise AssertionError(f"conversation start should resolve conversation template: {start1} {start2}")

        status, reg1 = request_json("POST", "/register", {
            "agent_class": "conversation",
            "agent_instance_id": inst1,
            "display_name": "Conversation",
            "agent_token": start1.get("agent_token", ""),
        })
        status2, reg2 = request_json("POST", "/register", {
            "agent_class": "conversation",
            "agent_instance_id": inst2,
            "display_name": "Conversation",
            "agent_token": start2.get("agent_token", ""),
        })
        if status != 200 or reg1.get("agent_instance_id") != inst1 or status2 != 200 or reg2.get("agent_instance_id") != inst2:
            raise AssertionError(f"conversation register failed: reg1={reg1} reg2={reg2}")
        if reg1.get("template_persona", "").strip() != persona_text:
            raise AssertionError("conversation register did not return seeded persona text")
        if reg1.get("template_instructions", "").strip() != instructions_text:
            raise AssertionError("conversation register did not return seeded instructions text")

        status, user = request_json("POST", "/user-client/register", {
            "user_id": USER_ID,
            "client_instance_id": "conversation-template-user",
        })
        if status != 200 or not user.get("client_token"):
            raise AssertionError(f"user-client/register failed: {user}")
        client_token = user["client_token"]

        status, sent = request_json("POST", "/user-rpc", {
            "action": "send_to_agent",
            "client_instance_id": "conversation-template-user",
            "client_token": client_token,
            "agent_instance_id": inst1,
            "body": "hello-conversation-one",
        })
        if status != 200 or not sent.get("ok"):
            raise AssertionError(f"send_to_agent failed: {sent}")

        status, chat1 = request_json("POST", "/user-rpc", {
            "action": "fetch_chat",
            "client_instance_id": "conversation-template-user",
            "client_token": client_token,
            "agent_instance_id": inst1,
            "unread_only": False,
            "limit": 20,
        })
        status2, chat2 = request_json("POST", "/user-rpc", {
            "action": "fetch_chat",
            "client_instance_id": "conversation-template-user",
            "client_token": client_token,
            "agent_instance_id": inst2,
            "unread_only": False,
            "limit": 20,
        })
        if status != 200 or status2 != 200:
            raise AssertionError(f"fetch_chat failed: chat1={chat1} chat2={chat2}")
        msgs1 = [m.get("body") for m in chat1.get("messages", [])]
        msgs2 = [m.get("body") for m in chat2.get("messages", [])]
        if "hello-conversation-one" not in msgs1:
            raise AssertionError(f"first conversation thread missing sent message: {chat1}")
        if "hello-conversation-one" in msgs2:
            raise AssertionError(f"second conversation thread should have isolated chat context: {chat2}")

        print(json.dumps({
            "ok": True,
            "instance_1": inst1,
            "instance_2": inst2,
            "template_role_hint": conversation.get("role_hint"),
            "isolated_thread_messages": {"inst1": msgs1, "inst2": msgs2},
        }, indent=2, sort_keys=True))
        print("PASS: conversation template backend")
    finally:
        stop_daemon(proc, log)
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp_home}")
        else:
            shutil.rmtree(fake_wrapper_tmp, ignore_errors=True)
            shutil.rmtree(temp_home, ignore_errors=True)


if __name__ == "__main__":
    main()
