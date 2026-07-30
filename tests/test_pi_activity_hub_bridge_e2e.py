#!/usr/bin/env python3
"""Opt-in E2E: ham-hub + ham-bridge + real Pi activity extension.

This launches an isolated local ham-hub, ham-bridge sidecar, and real `pi` agent
through ham-wrapper. It does not send an LLM prompt; Pi only starts its TUI and
loads the generated Heimdall activity extension, which should post an idle
`pi_extension` activity report to the hub.

Required binaries can be supplied with:
  HEIMDALL_HUB_BIN, HEIMDALL_BRIDGE_BIN, HEIMDALL_WRAPPER_BIN, HEIMDALL_CTL_BIN
or by building local result symlinks (for example `nix build .#ham-hub ...`).
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
BRIDGE_TOKEN = "loopback-secret"
ROOT = Path(__file__).resolve().parents[1]


def binary_path(env_name: str, candidates: list[str], binary: str) -> Path:
    env = os.environ.get(env_name)
    if env:
        path = Path(env)
        if path.exists():
            return path
        raise RuntimeError(f"{env_name} points to missing binary: {path}")
    for rel in candidates:
        path = ROOT / rel
        if path.exists():
            return path
    raise RuntimeError(f"missing {binary}; set {env_name} or build one of: {', '.join(candidates)}")


def hub_bin() -> Path:
    return binary_path("HEIMDALL_HUB_BIN", ["result-hub/bin/ham-hub", "result/bin/ham-hub"], "ham-hub")


def bridge_bin() -> Path:
    return binary_path("HEIMDALL_BRIDGE_BIN", ["result-bridge/bin/ham-bridge", "result/bin/ham-bridge"], "ham-bridge")


def wrapper_bin() -> Path:
    return binary_path("HEIMDALL_WRAPPER_BIN", ["result-wrapper/bin/ham-wrapper", "result/bin/ham-wrapper"], "ham-wrapper")


def ctl_bin() -> Path:
    return binary_path("HEIMDALL_CTL_BIN", ["result-ctl/bin/ham-ctl", "result/bin/ham-ctl"], "ham-ctl")


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind((HOST, 0))
        return sock.getsockname()[1]


def request_json(method: str, url: str, body=None, timeout=5, headers=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, data=data, method=method, headers=req_headers)
    with urllib.request.urlopen(req, timeout=timeout) as res:
        payload = res.read().decode("utf-8")
        return res.status, json.loads(payload) if payload else {}


def wait_for(fn, label: str, timeout=30, interval=0.25):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            value = fn()
            if value:
                return value
            last = value
        except Exception as exc:  # noqa: BLE001 - keep diagnostics for E2E failures
            last = repr(exc)
        time.sleep(interval)
    raise RuntimeError(f"timed out waiting for {label}; last={last!r}")


def read_log(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return ""


def main() -> None:
    hub = hub_bin()
    bridge = bridge_bin()
    wrapper = wrapper_bin()
    ctl = ctl_bin()
    pi_path = Path(os.environ.get("HEIMDALL_PI_BIN") or shutil.which("pi") or "")
    if not pi_path.exists():
        raise RuntimeError("missing pi; set HEIMDALL_PI_BIN or put pi on PATH")
    if not shutil.which("tmux"):
        raise RuntimeError("missing tmux on PATH")

    temp = Path(tempfile.mkdtemp(prefix="heimdall-pi-activity-e2e-"))
    daemon_port = free_port()
    bridge_port = free_port()
    base = f"http://{HOST}:{daemon_port}"
    bridge_base = f"http://{HOST}:{bridge_port}"
    tmux_session = f"ham-pi-e2e-{int(time.time())}-{os.getpid()}"
    instance_id = "pi@activity-e2e"
    cfg = temp / "hub.toml"
    bridge_cfg = temp / "bridge.toml"
    hub_log_path = temp / "hub.log"
    bridge_log_path = temp / "bridge.log"

    # The config section is still named [daemon] for compatibility with the
    # current config loader; the launched binary is ham-hub.
    cfg.write_text(f'''
[daemon]
bind_host = "{HOST}"
port = {daemon_port}
data_dir = "{temp}/hub-data"
user_id = "operator@local"
daemon_id = "local-hub"
wrapper_bin = "{wrapper}"
bridge_url = "{bridge_base}"
bridge_token = "{BRIDGE_TOKEN}"
default_agent_provider_profile = "pi"
default_agent_model_tier = "normal"

[guide_agent]
enabled = false
autostart = false
restart_if_stopped = false
agent_instance_id = "guide@heimdall"
template_id = "guide"
provider_profile = "pi"
model_tier = "smart"

[ctl]
daemon_url = "{base}"
ham_ctl_bin = "{ctl}"

[wrapper]
daemon_url = "{base}"
credentials_path = "{temp}/hub-data/wrapper-credentials.json"
agent_name = "pi"
default_agent = "pi"
display_name = "{{instance}}"
tmux_session = "{tmux_session}"
tmux_window_prefix = "agent"
agent_run_dir = "{temp}/runs"
project = ""
memory_templates = []
ham_ctl_bin = "{ctl}"

[wrapper.agent-cmd.pi]
command = ["{pi_path}"]
yolo_flags = []
prompt_flags = []
prompt_delivery = "none"
project = ""
memory_templates = []

[wrapper.agent-cmd.pi.models]
flag = "--model"
normal = "openai-codex/gpt-5.4"
cheap = "openai-codex/gpt-5.4"
smart = "openai-codex/gpt-5.5"

[wrapper.agent-cmd.pi.startup_detection]
enabled = false

[wrapper.agent-cmd.pi.activity_detection]
enabled = true
sample_line_count = 20
ignore_bottom_lines = 0
check_interval_seconds = 2
min_gap_ms = 100
max_gap_ms = 300
''', encoding="utf-8")

    bridge_cfg.write_text(f'''
[daemon]
daemon_id = "local-hub"
bridge_token = "{BRIDGE_TOKEN}"

[wrapper]
daemon_url = "{base}"
''', encoding="utf-8")

    procs: list[subprocess.Popen] = []
    hub_log = None
    bridge_log = None
    try:
        subprocess.run(["tmux", "kill-session", "-t", tmux_session], capture_output=True)
        hub_log = hub_log_path.open("w", encoding="utf-8")
        bridge_log = bridge_log_path.open("w", encoding="utf-8")
        procs.append(subprocess.Popen([str(hub), "--config", str(cfg)], cwd=str(ROOT), stdout=hub_log, stderr=subprocess.STDOUT, text=True))
        wait_for(lambda: request_json("GET", f"{base}/health")[0] == 200, "hub health", timeout=20)
        procs.append(subprocess.Popen([str(bridge), "--config", str(bridge_cfg), "--bind-host", HOST, "--port", str(bridge_port), "--bridge-token", BRIDGE_TOKEN], cwd=str(ROOT), stdout=bridge_log, stderr=subprocess.STDOUT, text=True))
        bridge_headers = {"Authorization": f"Bearer {BRIDGE_TOKEN}"}
        wait_for(lambda: request_json("GET", f"{bridge_base}/bridge/health", headers=bridge_headers)[0] == 200, "bridge health", timeout=20)

        _, user = request_json("POST", f"{base}/user-client/register", {"user_id": "operator@local", "client_instance_id": "pi-e2e-ui", "client_token": ""})
        client_token = user.get("client_token", "")

        status, start = request_json("POST", f"{base}/agents/start", {
            "agent_instance_id": instance_id,
            "agent": "pi",
            "provider": "pi",
            "template_id": "pi",
            "project_id": "",
            "model_tier": "normal",
        }, timeout=10)
        if status != 200 or not start.get("ok", True):
            raise RuntimeError(f"/agents/start failed: status={status} body={start}")

        def agent_record():
            _, agents = request_json("GET", f"{base}/agents", timeout=5)
            for agent in agents.get("agents", []):
                if agent.get("agent_instance_id") == instance_id:
                    return agent
            return None

        def agent_with_run_dir():
            rec = agent_record()
            run_dir = str((rec or {}).get("run_dir") or "")
            return rec if run_dir and Path(run_dir).exists() else None

        rec = wait_for(agent_with_run_dir, "agent run_dir", timeout=30)
        run_dir = Path(rec["run_dir"])
        extension_path = run_dir / ".heimdall" / "heimdall-pi-activity.ts"
        wait_for(lambda: extension_path.exists() and extension_path.read_text(encoding="utf-8"), "managed Pi activity extension", timeout=20)
        ext_text = extension_path.read_text(encoding="utf-8")
        assert "HEIMDALL-MANAGED-BOOTSTRAP" in ext_text
        assert "/agent-activity" in ext_text
        assert "pi_extension" in ext_text

        def pi_extension_activity():
            rec = agent_record()
            if rec and rec.get("activity_source") == "pi_extension":
                return rec
            return None

        rec = wait_for(pi_extension_activity, "pi_extension activity report", timeout=45)
        _, clients = request_json("GET", f"{base}/clients", timeout=5)
        client_rec = next((agent for agent in clients.get("agents", []) if agent.get("agent_instance_id") == instance_id), None)
        assert client_rec, clients
        assert client_rec.get("activity_source") == "pi_extension", client_rec

        bridge_status, bridge_health = request_json("GET", f"{bridge_base}/bridge/health", timeout=5, headers=bridge_headers)
        assert bridge_status == 200, bridge_health
        peers_status, peers = request_json("GET", f"{base}/federation/peers", timeout=5, headers={"Authorization": f"Bearer {client_token}"})
        assert peers_status == 200, peers

        print(json.dumps({
            "ok": True,
            "hub_bin": str(hub),
            "hub_url": base,
            "bridge_url": bridge_base,
            "pi_path": str(pi_path),
            "agent_instance_id": instance_id,
            "run_dir": str(run_dir),
            "activity_status": rec.get("activity_status"),
            "activity_source": rec.get("activity_source"),
            "activity_summary": rec.get("activity_summary", ""),
            "clients_activity_source": client_rec.get("activity_source"),
            "bridge_health": bridge_health,
            "peer_count": len(peers.get("peers", [])),
        }, indent=2, sort_keys=True))
        print("pi_activity_hub_bridge_e2e: ok")
    except Exception:
        print("\n--- hub.log ---", file=sys.stderr)
        print(read_log(hub_log_path)[-5000:], file=sys.stderr)
        print("\n--- bridge.log ---", file=sys.stderr)
        print(read_log(bridge_log_path)[-5000:], file=sys.stderr)
        print(f"temp_dir={temp}", file=sys.stderr)
        raise
    finally:
        for proc in reversed(procs):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=8)
        subprocess.run(["tmux", "kill-session", "-t", tmux_session], capture_output=True)
        if hub_log:
            hub_log.close()
        if bridge_log:
            bridge_log.close()
        if os.environ.get("KEEP_HEIMDALL_PI_E2E_TMP") == "1":
            print(f"kept temp dir: {temp}")
        else:
            shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    main()
