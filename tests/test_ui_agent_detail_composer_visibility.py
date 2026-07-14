#!/usr/bin/env python3
"""Electron smoke for agent-detail composer affordance and direct-agent send."""
import base64
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
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49649"))
URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "agent-detail-composer-smoke"


def bin_path(preferred: str, fallback: str, binary: str) -> str:
    env_map = {
        "ham-daemon": "HAM_DAEMON_BIN",
        "ham-wrapper": "HAM_WRAPPER_BIN",
        "ham-ctl": "HAM_CTL_BIN",
    }
    env_key = env_map.get(binary)
    if env_key and os.environ.get(env_key):
        return os.environ[env_key]
    for base in [preferred, fallback, "result-daemon", "result-wrapper", "result-ctl", "result", "result-1", "result-2"]:
        p = ROOT / base / "bin" / binary
        if p.exists():
            return str(p)
    resolved = shutil.which(binary)
    if resolved:
        return resolved
    raise FileNotFoundError(binary)


def ui_tool(tool: str) -> str:
    direct = ROOT / "node_modules" / ".bin" / tool
    if direct.exists():
        return str(direct)
    for parent in ROOT.parents:
        candidate = parent / "node_modules" / ".bin" / tool
        if candidate.exists():
            return str(candidate)
    try:
        worktrees = subprocess.check_output(["git", "worktree", "list", "--porcelain"], cwd=str(ROOT), text=True)
        for line in worktrees.splitlines():
            if not line.startswith("worktree "):
                continue
            candidate = Path(line.split(" ", 1)[1]) / "node_modules" / ".bin" / tool
            if candidate.exists():
                return str(candidate)
    except Exception:
        pass
    for candidate in Path.home().glob(f"*/node_modules/.bin/{tool}"):
        if candidate.exists():
            return str(candidate)
    resolved = shutil.which(tool)
    if resolved:
        return resolved
    raise FileNotFoundError(tool)


def request_json(path: str, data: Optional[dict] = None, base_url: str = URL, headers: Optional[dict] = None) -> dict:
    merged_headers = dict(headers or {})
    if data is not None:
        merged_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(
        base_url + path,
        data=None if data is None else json.dumps(data).encode(),
        headers=merged_headers,
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
    raise AssertionError(f"missing visible {debug_id}; visible ids={[e.get('debugId') for e in last if e.get('visible')][:120]}")


def ensure_built() -> None:
    vite = Path(ui_tool("vite"))
    root_node_modules = ROOT / "node_modules"
    source_node_modules = vite.parent.parent
    if not root_node_modules.exists() and source_node_modules.exists():
        root_node_modules.symlink_to(source_node_modules)
    subprocess.run([str(vite), "build"], cwd=str(ROOT), check=True)


def main() -> None:
    keep = os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1"
    tmp = Path(tempfile.mkdtemp(prefix="heimdall-agent-detail-composer-smoke-"))
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
        ensure_built()
        user = request_json("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        token = user["client_token"]
        agent_id = "specialist@agent-detail-smoke"
        create_agent = request_json("/agents/create", {
            "agent_instance_id": agent_id,
            "display_name": "Agent Detail Smoke",
            "provider_profile": "pi",
            "template_id": "specialist",
            "model_tier": "normal",
            "agent_role": "specialist",
        })
        if not create_agent.get("ok", True):
            raise AssertionError(f"agent create failed: {create_agent}")
        artifact = request_json("/artifacts/create", {
            "name": "agent-detail-smoke.md",
            "kind": "markdown",
            "mime": "text/markdown",
            "origin_kind": "test",
            "origin_ref": agent_id,
            "content_base64": base64.b64encode(b"# agent detail smoke\n").decode(),
        }, base_url=URL, headers={"Authorization": f"Bearer {token}"})
        artifact_link = artifact.get("link") or f"artifact://{artifact.get('artifact', {}).get('artifact_id', '')}"
        if not artifact_link.startswith("artifact://art_"):
            raise AssertionError(f"unexpected artifact link from create: {artifact}")

        electron = ui_tool("electron")
        env = os.environ.copy()
        env["HEIMDALL_DAEMON_URL"] = URL
        env["HEIMDALL_UI_DEBUG"] = "1"
        env["ELECTRON_DISABLE_SECURITY_WARNINGS"] = "1"
        ui_log = open(tmp / "electron.log", "w", encoding="utf-8")
        ui_proc = subprocess.Popen([electron, "."], cwd=str(ROOT), env=env, stdout=ui_log, stderr=subprocess.STDOUT)
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

        sidebar_btn = wait_visible(debug_url, f"sidebar-agent-{agent_id}", 25)
        open_click = debug_json(debug_url, "POST", "/click", {"query": f'[data-debug-id="sidebar-agent-{agent_id}"]'})
        page = wait_visible(debug_url, "agent-detail-page", 20)
        composer_shell = wait_visible(debug_url, "agent-detail-chat-composer-shell", 10)
        composer = wait_visible(debug_url, "agent-detail-chat-input", 10)
        upload_btn = wait_visible(debug_url, "agent-detail-chat-artifact-upload-btn", 10)
        send_btn = wait_visible(debug_url, "agent-detail-chat-send-btn", 10)
        if str(upload_btn.get("text") or "").strip() != "＋":
            raise AssertionError(f"expected plus upload button, got {upload_btn}")
        body = f"Agent detail smoke\n{artifact_link}"
        debug_json(debug_url, "POST", "/type", {"query": '[data-debug-id="agent-detail-chat-input"]', "text": body})
        debug_json(debug_url, "POST", "/click", {"query": '[data-debug-id="agent-detail-chat-send-btn"]'})

        send_error = None
        composer_after_send = None
        for _ in range(40):
            elements = debug_json(debug_url, "GET", "/elements")
            send_error = next((e for e in elements if e.get("debugId") == "agent-detail-chat-send-error" and e.get("visible")), None)
            composer_after_send = next((e for e in elements if e.get("debugId") == "agent-detail-chat-input" and e.get("visible")), None)
            if send_error:
                break
            time.sleep(0.25)
        if not send_error:
            raise AssertionError("expected agent-detail send failure UI for self-contained offline agent smoke")
        composer_text = str((composer_after_send or {}).get("text") or "")
        if "Agent detail smoke" not in composer_text or artifact_link not in composer_text:
            raise AssertionError(f"draft was not preserved after failed agent-detail send: {composer_after_send}")

        evidence = {
            "ok": True,
            "tmp": str(tmp),
            "debug_port": debug_port,
            "agent_id": agent_id,
            "sidebar_button_rect": sidebar_btn.get("rect"),
            "open_click": open_click,
            "page_rect": page.get("rect"),
            "composer_shell_rect": composer_shell.get("rect"),
            "composer_rect": composer.get("rect"),
            "artifact_upload_rect": upload_btn.get("rect"),
            "artifact_upload_text": upload_btn.get("text"),
            "send_rect": send_btn.get("rect"),
            "artifact_link": artifact_link,
            "typed_body": body,
            "draft_after_failed_send": composer_text,
            "send_error_text": send_error.get("text"),
        }
        evidence_path = artifact_dir / "agent-detail-composer-smoke-evidence.json"
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
        if keep:
            print(json.dumps({"kept_tmp": str(tmp)}))
        else:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
