#!/usr/bin/env python3
"""Isolated Electron smoke for ChainView coordinator composer visibility and send."""
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parents[1]
HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49648"))
URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "chain-composer-smoke"


def bin_path(preferred: str, fallback: str, binary: str) -> str:
    p = ROOT / preferred / "bin" / binary
    if p.exists():
        return str(p)
    return str(ROOT / fallback / "bin" / binary)


def request_json(path: str, data: Optional[dict] = None, base_url: str = URL) -> dict:
    req = urllib.request.Request(
        base_url + path,
        data=None if data is None else json.dumps(data).encode(),
        headers={"Content-Type": "application/json"} if data is not None else {},
        method="POST" if data is not None else "GET",
    )
    with urllib.request.urlopen(req, timeout=20) as res:
        return json.loads(res.read().decode() or "{}")


def wait_health() -> None:
    for _ in range(80):
        try:
            urllib.request.urlopen(URL + "/health", timeout=1)
            return
        except Exception:
            time.sleep(0.25)
    raise RuntimeError("daemon health timeout")


def debug_json(debug_url: str, method: str, path: str, body: Optional[dict] = None):
    return request_json(path, body, debug_url) if method == "POST" else request_json(path, None, debug_url)


def wait_visible(debug_url: str, debug_id: str, timeout: float = 20) -> dict:
    end = time.time() + timeout
    last = []
    while time.time() < end:
        last = debug_json(debug_url, "GET", "/elements")
        for element in last:
            if element.get("debugId") == debug_id and element.get("visible"):
                return element
        time.sleep(0.25)
    visible = [e.get("debugId") for e in last if e.get("visible") and "chain" in str(e.get("debugId"))]
    raise AssertionError(f"missing visible {debug_id}; visible chain ids={visible[:80]}")


def main() -> None:
    keep = os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1"
    tmp = Path(tempfile.mkdtemp(prefix="heimdall-chain-composer-smoke-"))
    artifact_dir = Path(os.environ.get("HEIMDALL_TEST_ARTIFACT_DIR", str(tmp)))
    artifact_dir.mkdir(parents=True, exist_ok=True)
    daemon_bin = bin_path("result-daemon", "result", "ham-daemon")
    wrapper_bin = bin_path("result-wrapper", "result-2", "ham-wrapper")
    ctl_bin = bin_path("result-ctl", "result-1", "ham-ctl")
    config = tmp / "config.toml"
    config.write_text(f'''
[daemon]
bind_host = "{HOST}"
advertise_host = "{HOST}"
port = {PORT}
data_dir = "{tmp}/data"
wrapper_bin = "{wrapper_bin}"
nudge_enabled = false

[wrapper]
daemon_url = "{URL}"
ham_ctl_bin = "{ctl_bin}"
agent_name = "pi"
command = ["/bin/sh", "-lc", "sleep 1"]
agent_run_dir = "{tmp}/runs"

[ctl]
daemon_url = "{URL}"
''')
    daemon_log = open(tmp / "daemon.log", "w", encoding="utf-8")
    daemon_proc = subprocess.Popen([daemon_bin, "--config", str(config)], stdout=daemon_log, stderr=subprocess.STDOUT)
    ui_proc = None
    ui_log = None
    try:
        wait_health()
        user = request_json("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        token = user["client_token"]
        project = request_json("/projects/create", {"agent_token": token, "name": "composer smoke", "anchors": [{"type": "vcs_kind", "value": "none"}]})
        chain = request_json("/task-chains/create", {
            "agent_token": token,
            "project_id": project["project_id"],
            "kind": "coding",
            "scaffold": "feature",
            "title": "Composer smoke chain",
            "description": "Verify coordinator composer visibility and send.",
            "coordinator_agent_instance_id": "pi@composer-smoke",
            "wants_vcs": False,
        })
        chain_id = chain["chain_id"]
        request_json("/task-chains/status", {"agent_token": token, "chain_id": chain_id, "status": "in_progress"})

        electron = ROOT / "node_modules" / ".bin" / "electron"
        env = os.environ.copy()
        env["HEIMDALL_DAEMON_URL"] = URL
        env["HEIMDALL_UI_DEBUG"] = "1"
        env["ELECTRON_DISABLE_SECURITY_WARNINGS"] = "1"
        ui_log = open(tmp / "electron.log", "w", encoding="utf-8")
        ui_proc = subprocess.Popen([str(electron), "."], cwd=str(ROOT), env=env, stdout=ui_log, stderr=subprocess.STDOUT)
        debug_port = None
        for _ in range(120):
            text = (tmp / "electron.log").read_text(errors="ignore")
            match = re.search(r"debug_server_port=(\d+)", text)
            if match:
                debug_port = int(match.group(1))
                break
            if ui_proc.poll() is not None:
                raise RuntimeError("Electron exited before debug server was ready")
            time.sleep(0.25)
        if not debug_port:
            raise RuntimeError("debug server port not found")
        debug_url = f"http://{HOST}:{debug_port}"

        wait_visible(debug_url, f"home-chain-open-btn-{chain_id}", 25)
        click = debug_json(debug_url, "POST", "/click", {"query": f'[data-debug-id="home-chain-open-btn-{chain_id}"]'})
        composer = wait_visible(debug_url, "chain-coordinator-composer-input", 20)
        send = wait_visible(debug_url, "chain-coordinator-send-btn", 5)
        body = "Composer smoke instruction"
        debug_json(debug_url, "POST", "/type", {"query": '[data-debug-id="chain-coordinator-composer-input"]', "text": body})
        debug_json(debug_url, "POST", "/click", {"query": '[data-debug-id="chain-coordinator-send-btn"]'})

        rendered = False
        state_after = {}
        for _ in range(40):
            state_after = debug_json(debug_url, "GET", "/state")
            chat = (((state_after.get("chainView") or {}).get("chatByChainId") or {}).get(chain_id) or [])
            if any(message.get("body") == body for message in chat):
                rendered = True
                break
            time.sleep(0.25)
        if not rendered:
            raise AssertionError("sent coordinator message did not render in ChainView state")

        fetch = request_json("/user-rpc", {"action": "fetch_chat", "client_instance_id": CLIENT_ID, "client_token": token, "agent_instance_id": "pi@composer-smoke", "unread_only": False, "limit": 20})
        persisted = any(message.get("body") == body and message.get("chain_id") == chain_id for message in fetch.get("messages", []))
        if not persisted:
            raise AssertionError(f"sent coordinator message did not persist in daemon chat: {fetch}")

        evidence = {
            "ok": True,
            "tmp": str(tmp),
            "debug_port": debug_port,
            "chain_id": chain_id,
            "click": click,
            "surface": (state_after.get("home") or {}).get("surface"),
            "selected_chain_id": (state_after.get("home") or {}).get("selectedChainId"),
            "composer_visible": True,
            "send_visible": True,
            "composer_rect": composer.get("rect"),
            "send_rect": send.get("rect"),
            "sent_body": body,
            "rendered_in_redux": rendered,
            "persisted_in_daemon_chat": persisted,
        }
        evidence_path = artifact_dir / "chain-composer-smoke-evidence.json"
        evidence_path.write_text(json.dumps(evidence, indent=2, sort_keys=True), encoding="utf-8")
        print(json.dumps({"ok": True, "evidence_path": str(evidence_path), **evidence}, indent=2, sort_keys=True))
    finally:
        if ui_proc is not None:
            ui_proc.terminate()
            try:
                ui_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                ui_proc.kill()
        if ui_log is not None:
            ui_log.close()
        daemon_proc.terminate()
        try:
            daemon_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon_proc.kill()
        daemon_log.close()
        if not keep:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
