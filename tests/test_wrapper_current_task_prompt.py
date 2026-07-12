#!/usr/bin/env python3
"""Regression for wrapper current-task prompt/bootstrap context.

Launches ham-wrapper directly with --current-task-id and verifies:
- starter prompt renders {task_id}
- starter prompt includes explicit task-start guidance
- generated AGENTS.md includes the concrete current task line
"""

import json
import os
import shutil
import stat
import subprocess
import time
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = 49441
TASK_ID = "task-123abc"


def bin_path(repo: Path, preferred: str, fallback: str, binary: str) -> str:
    preferred_path = repo / preferred / "bin" / binary
    if preferred_path.exists():
        return str(preferred_path)
    return str(repo / fallback / "bin" / binary)


def request_post(url: str, path: str, data: dict) -> dict:
    req = urllib.request.Request(
        f"{url}{path}",
        data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=5) as res:
        return json.loads(res.read().decode())


def wait_health(url: str) -> None:
    for _ in range(50):
        try:
            with urllib.request.urlopen(f"{url}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def wait_for(path: Path, timeout: float = 8.0) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            text = path.read_text(encoding="utf-8")
            if text:
                return text
        time.sleep(0.1)
    raise RuntimeError(f"timed out waiting for {path}")


def wait_for_glob(base: Path, pattern: str, timeout: float = 8.0) -> Path:
    deadline = time.time() + timeout
    while time.time() < deadline:
        matches = list(base.glob(pattern))
        if matches:
            return matches[0]
        time.sleep(0.1)
    raise RuntimeError(f"timed out waiting for {pattern} under {base}")


def write_fake_agent(path: Path) -> None:
    path.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\n' \"$*\" > \"$1\"\n"
        "shift\n"
        "if IFS= read -r line; then\n"
        "  printf '%s\\n' \"$line\" > \"$1\"\n"
        "fi\n"
        "sleep 60\n",
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    temp = repo / "tests" / "temp_wrapper_current_task_prompt"
    if temp.exists():
        shutil.rmtree(temp)
    temp.mkdir(parents=True)

    tmux_session = "ham-current-task-test"
    subprocess.run(["tmux", "kill-session", "-t", tmux_session], capture_output=True)

    daemon_bin = bin_path(repo, "result-daemon", "result-1", "ham-daemon")
    wrapper_bin = bin_path(repo, "result-wrapper", "result", "ham-wrapper")
    ctl_bin = bin_path(repo, "result-ctl", "result-2", "ham-ctl")
    url = f"http://{HOST}:{PORT}"

    fake = temp / "fake-agent.sh"
    write_fake_agent(fake)

    config = temp / "config.toml"
    config.write_text(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{temp}/data"
user_id = "operator@local"
wrapper_bin = "{wrapper_bin}"

[ctl]
daemon_url = "{url}"
ham_ctl_bin = "{ctl_bin}"

[wrapper]
daemon_url = "{url}"
credentials_path = "{temp}/data/wrapper-credentials.json"
agent_name = "flag-agent"
default_agent = "flag-agent"
display_name = "{{instance}}"
tmux_session = "{tmux_session}"
tmux_window_prefix = "agent"
agent_run_dir = "{temp}/runs"
project = ""
memory_templates = []
ham_ctl_bin = "{ctl_bin}"

[wrapper.agent-cmd.flag-agent]
command = ["{fake}", "{temp}/flag.argv", "{temp}/flag.prompt"]
prompt_flags = ["--prompt"]
starter_prompt = "FLAG hello {{agent_instance_id}} via {{daemon_url}} for {{task_id}}"
''', encoding="utf-8")

    daemon_log = open(temp / "daemon.log", "w", encoding="utf-8")
    daemon = subprocess.Popen([daemon_bin, "--config", str(config)], stdout=daemon_log, stderr=subprocess.STDOUT)
    wrapper_log = open(temp / "wrapper.log", "w", encoding="utf-8")
    wrapper = None
    try:
        wait_health(url)
        request_post(url, "/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "test-current-task-wrapper",
        })
        setup_agent = request_post(url, "/register", {
            "agent_class": "setup-agent",
            "agent_instance_id": "setup-agent@default",
            "display_name": "Setup Agent",
        })
        request_post(url, "/projects/create", {
            "agent_token": setup_agent["agent_token"],
            "project_id": "default",
            "name": "default",
            "description": "wrapper current-task prompt test",
        })

        wrapper = subprocess.Popen(
            [
                wrapper_bin,
                "--config", str(config),
                "--agent", "flag-agent",
                "--current-task-id", TASK_ID,
                "flag-agent@case",
            ],
            stdout=wrapper_log,
            stderr=subprocess.STDOUT,
        )

        flag_argv = wait_for(temp / "flag.argv")
        if TASK_ID not in flag_argv:
            raise AssertionError(f"task id missing from rendered prompt argv: {flag_argv!r}")
        if f"for {TASK_ID}" not in flag_argv:
            raise AssertionError(f"{{task_id}} placeholder was not rendered: {flag_argv!r}")
        if f"begin your assigned task {TASK_ID}" not in flag_argv:
            raise AssertionError(f"task-start guidance missing from prompt: {flag_argv!r}")
        if f"tasks show --token" not in flag_argv or TASK_ID not in flag_argv:
            raise AssertionError(f"tasks show guidance missing from prompt: {flag_argv!r}")

        agents_md = wait_for_glob(temp / "runs" / "default", "*/AGENTS.md")
        agents_text = wait_for(agents_md)
        expected = f"- Current task: `{TASK_ID}` (already auto-claimed for this launch)."
        if expected not in agents_text:
            raise AssertionError(f"AGENTS current-task line missing from {agents_md}: {agents_text!r}")
        if f"tasks show --token <token> --task-id {TASK_ID}" not in agents_text:
            raise AssertionError(f"AGENTS task-show guidance missing from {agents_md}: {agents_text!r}")

        print("WRAPPER CURRENT TASK PROMPT TEST PASSED")
    finally:
        if wrapper is not None:
            wrapper.terminate()
            try:
                wrapper.wait(timeout=5)
            except subprocess.TimeoutExpired:
                wrapper.kill()
        daemon.terminate()
        try:
            daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon.kill()
        wrapper_log.close()
        daemon_log.close()
        subprocess.run(["tmux", "kill-session", "-t", tmux_session], capture_output=True)
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp}")
        else:
            shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    main()
