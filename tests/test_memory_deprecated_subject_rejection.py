#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = 49426
URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
AGENT_ID = "memory-deprecation-coder@default"
MESSAGE_FRAGMENT = "deprecated memory target fields"


def bin_path(repo: Path, binary: str) -> str:
    env_key = {
        "ham-daemon": "HAM_DAEMON_BIN",
        "ham-wrapper": "HAM_WRAPPER_BIN",
        "ham-ctl": "HAM_CTL_BIN",
    }[binary]
    if os.environ.get(env_key):
        return os.environ[env_key]
    for base in ["result-daemon-new", "result-daemon", "result-wrapper", "result-ctl", "result", "result-1", "result-2"]:
        path = repo / base / "bin" / binary
        if path.exists():
            return str(path)
    package = {
        "ham-daemon": "ham-daemon",
        "ham-wrapper": "ham-wrapper",
        "ham-ctl": "ham-ctl",
    }[binary]
    build = subprocess.run(["nix", "build", f".#${package}".replace("$", ""), "--no-link", "--print-out-paths"], cwd=repo, capture_output=True, text=True, check=True)
    out_path = build.stdout.strip().splitlines()[-1]
    return str(Path(out_path) / "bin" / binary)


def post(path: str, data: dict) -> tuple[int, dict]:
    req = urllib.request.Request(
        f"{URL}{path}",
        data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as res:
            return res.status, json.loads(res.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode())


def wait_health() -> None:
    for _ in range(100):
        try:
            with urllib.request.urlopen(f"{URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def start_daemon(repo: Path, temp_dir: str):
    daemon_bin = bin_path(repo, "ham-daemon")
    wrapper_bin = bin_path(repo, "ham-wrapper")
    ctl_bin = bin_path(repo, "ham-ctl")
    config_path = os.path.join(temp_dir, "config.toml")
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{temp_dir}/data"
user_id = "{USER_ID}"
wrapper_bin = "{wrapper_bin}"

[ctl]
daemon_url = "{URL}"
ham_ctl_bin = "{ctl_bin}"
''')
    log_path = os.path.join(temp_dir, "daemon.log")
    log = open(log_path, "a", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=log, stderr=subprocess.STDOUT)
    wait_health()
    return proc, log


def stop_daemon(proc, log) -> None:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
    log.close()


def expect_deprecated(status: int, payload: dict, label: str) -> None:
    if status != 400:
        raise AssertionError(f"{label}: expected HTTP 400, got {status}: {payload}")
    message = str(payload.get("message", ""))
    if MESSAGE_FRAGMENT not in message:
        raise AssertionError(f"{label}: expected deprecated message, got {payload}")


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    temp_dir = tempfile.mkdtemp(prefix="heimdall-memory-deprecated-")
    proc = log = None
    try:
        proc, log = start_daemon(repo, temp_dir)

        status, reg = post(
            "/register",
            {
                "agent_class": "memory-deprecation-coder",
                "agent_instance_id": AGENT_ID,
                "display_name": "Memory Deprecation Coder",
            },
        )
        if status != 200:
            raise AssertionError(f"agent register failed: {reg}")
        agent_token = reg["agent_token"]

        rpc_cases = [
            ("agent-rpc propose new subject_key", "/agent-rpc", {
                "agent_token": agent_token,
                "action": "memory_propose_new",
                "subject_key": "legacy",
                "type": "fact",
                "title": "Legacy subject key",
                "body": "should fail",
            }),
            ("agent-rpc propose new scope", "/agent-rpc", {
                "agent_token": agent_token,
                "action": "memory_propose_new",
                "scope": "project",
                "type": "fact",
                "title": "Legacy scope",
                "body": "should fail",
            }),
            ("agent-rpc list project_ids", "/agent-rpc", {
                "agent_token": agent_token,
                "action": "memory_list",
                "project_ids": "legacy-project",
            }),
        ]
        for label, path, payload in rpc_cases:
            status, res = post(path, payload)
            expect_deprecated(status, res, label)

        ham_ctl = bin_path(repo, "ham-ctl")
        for flag, value in [
            ("--subject-key", "legacy"),
            ("--scope", "project"),
            ("--project-ids", "legacy-project"),
        ]:
            cmd = [ham_ctl, "--daemon-url", URL, "memory", "list", "--token", agent_token, flag, value]
            ctl_res = subprocess.run(cmd, capture_output=True, text=True, check=False)
            ctl_text = (ctl_res.stdout or "") + (ctl_res.stderr or "")
            if MESSAGE_FRAGMENT not in ctl_text:
                raise AssertionError(f"ham-ctl rejection missing deprecated message for {flag}: {ctl_text}")

        print("ok: deprecated memory target inputs are rejected before validation in RPC and ham-ctl")
    finally:
        if proc is not None and log is not None:
            stop_daemon(proc, log)


if __name__ == "__main__":
    main()
