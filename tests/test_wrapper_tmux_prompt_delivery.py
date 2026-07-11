#!/usr/bin/env python3
"""Regression for wrapper starter prompt delivery modes.

Starts an isolated daemon and launches three fake agents through ham-wrapper:
- default flag-injection appends prompt_flags + rendered prompt to argv
- tmux delivery omits prompt flags/arg and sends rendered prompt into pane
- none delivery omits both argv prompt and tmux prompt injection
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = 49440


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


def assert_not_exists(path: Path, duration: float = 1.0) -> None:
    deadline = time.time() + duration
    while time.time() < deadline:
        if path.exists() and path.read_text(encoding="utf-8"):
            raise AssertionError(f"unexpected prompt delivery at {path}: {path.read_text()!r}")
        time.sleep(0.1)


def write_fake_agent(path: Path, argv_path: Path, prompt_path: Path) -> None:
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


def start_agent(url: str, agent_name: str, instance_id: str) -> None:
    reg = request_post(url, "/register", {
        "agent_class": instance_id.split("@", 1)[0],
        "agent_instance_id": instance_id,
        "display_name": instance_id,
    })
    res = request_post(url, "/agents/start", {
        "agent_instance_id": instance_id,
        "agent_token": reg["agent_token"],
        "agent": agent_name,
    })
    if not res.get("ok"):
        raise RuntimeError(f"start failed for {instance_id}: {res}")


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    temp = repo / "tests" / "temp_tmux_prompt_delivery"
    if temp.exists():
        shutil.rmtree(temp)
    temp.mkdir(parents=True)

    tmux_session = "ham-prompt-delivery-test"
    subprocess.run(["tmux", "kill-session", "-t", tmux_session], capture_output=True)

    daemon_bin = bin_path(repo, "result-daemon", "result-1", "ham-daemon")
    wrapper_bin = bin_path(repo, "result-wrapper", "result", "ham-wrapper")
    ctl_bin = bin_path(repo, "result-ctl", "result-2", "ham-ctl")
    url = f"http://{HOST}:{PORT}"

    fake = temp / "fake-agent.sh"
    # argv/prompt paths are passed as first two command args by config; script
    # writes argv to first, then shifts and writes stdin line to second.
    write_fake_agent(fake, temp / "unused-argv", temp / "unused-prompt")

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
display_name = "{{{{instance}}}}"
tmux_session = "{tmux_session}"
tmux_window_prefix = "agent"
agent_run_dir = "{temp}/runs"
project = ""
memory_templates = []
ham_ctl_bin = "{ctl_bin}"

[wrapper.agent-cmd.flag-agent]
command = ["{fake}", "{temp}/flag.argv", "{temp}/flag.prompt"]
prompt_flags = ["--prompt"]
starter_prompt = "FLAG hello {{agent_instance_id}} via {{daemon_url}}"

[wrapper.agent-cmd.tmux-agent]
command = ["{fake}", "{temp}/tmux.argv", "{temp}/tmux.prompt"]
prompt_flags = ["--prompt"]
starter_prompt = "TMUX hello {{agent_instance_id}} via {{daemon_url}}"
prompt_delivery = "tmux"
prompt_tmux_delay_ms = 100
prompt_tmux_enter = true

[wrapper.agent-cmd.none-agent]
command = ["{fake}", "{temp}/none.argv", "{temp}/none.prompt"]
prompt_flags = ["--prompt"]
starter_prompt = "NONE hello {{agent_instance_id}} via {{daemon_url}}"
prompt_delivery = "none"
''', encoding="utf-8")

    daemon_log = open(temp / "daemon.log", "w", encoding="utf-8")
    daemon = subprocess.Popen([daemon_bin, "--config", str(config)], stdout=daemon_log, stderr=subprocess.STDOUT)
    try:
        wait_health(url)
        start_agent(url, "flag-agent", "flag-agent@case")
        start_agent(url, "tmux-agent", "tmux-agent@case")
        start_agent(url, "none-agent", "none-agent@case")

        flag_argv = wait_for(temp / "flag.argv")
        if "--prompt" not in flag_argv or "FLAG hello flag-agent@case" not in flag_argv:
            raise AssertionError(f"flag injection argv missing prompt: {flag_argv!r}")
        assert_not_exists(temp / "flag.prompt")

        tmux_argv = wait_for(temp / "tmux.argv")
        if "--prompt" in tmux_argv or "TMUX hello" in tmux_argv:
            raise AssertionError(f"tmux delivery leaked prompt into argv: {tmux_argv!r}")
        tmux_prompt = wait_for(temp / "tmux.prompt")
        if "TMUX hello tmux-agent@case via" not in tmux_prompt:
            raise AssertionError(f"tmux prompt was not rendered/injected: {tmux_prompt!r}")

        none_argv = wait_for(temp / "none.argv")
        if "--prompt" in none_argv or "NONE hello" in none_argv:
            raise AssertionError(f"none delivery leaked prompt into argv: {none_argv!r}")
        assert_not_exists(temp / "none.prompt")

        print(json.dumps({
            "ok": True,
            "flag_argv": flag_argv.strip(),
            "tmux_argv": tmux_argv.strip(),
            "tmux_prompt": tmux_prompt.strip(),
            "none_argv": none_argv.strip(),
        }, indent=2, sort_keys=True))
        print("WRAPPER TMUX PROMPT DELIVERY TEST PASSED")
    finally:
        daemon.terminate()
        try:
            daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon.kill()
        daemon_log.close()
        subprocess.run(["tmux", "kill-session", "-t", tmux_session], capture_output=True)
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp}")
        else:
            shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    main()
