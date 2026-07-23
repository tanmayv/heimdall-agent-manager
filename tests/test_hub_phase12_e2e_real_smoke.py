#!/usr/bin/env python3
"""Phase 12 fresh-Hub E2E through ham-dev-proxy."""
from __future__ import annotations

import json
import os
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def free_port() -> int:
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def wait_get(url: str, timeout: float = 10.0) -> None:
    end = time.time() + timeout
    while time.time() < end:
        try:
            urllib.request.urlopen(url, timeout=.5).close(); return
        except Exception:
            time.sleep(.1)
    raise RuntimeError(url)


def req(method: str, url: str, body: dict | None = None, headers: dict | None = None) -> tuple[int, dict]:
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json", **(headers or {})}, method=method)
    try:
        with urllib.request.urlopen(request, timeout=5) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode())


def wait_bridge_online(base: str, bridge_id: str, headers: dict, timeout: float = 15.0) -> dict:
    end = time.time() + timeout
    while time.time() < end:
        st, detail = req("GET", f"{base}/bridges/{bridge_id}", headers=headers)
        if st == 200 and detail["data"].get("status") == "online":
            return detail
        time.sleep(.25)
    raise RuntimeError(f"bridge {bridge_id} did not become online")


def wait_instance_status(base: str, instance_id: str, headers: dict, status: str, timeout: float = 15.0) -> dict:
    end = time.time() + timeout
    while time.time() < end:
        st, detail = req("GET", f"{base}/agent-instances/{instance_id}", headers=headers)
        if st == 200 and detail["data"].get("runtime_status") == status:
            return detail
        time.sleep(.25)
    raise RuntimeError(f"instance {instance_id} did not reach {status}")


def toml_value(text: str, key: str) -> str:
    for line in text.splitlines():
        if line.startswith(key):
            return line.split("=", 1)[1].strip().strip('"')
    raise KeyError(key)


def main() -> None:
    hub_bin = Path(os.environ.get("HAM_HUB_BIN", "/tmp/ham-hub-phase12"))
    bridge_bin = Path(os.environ.get("HAM_BRIDGE_BIN", "/tmp/ham-bridge-phase12"))
    proxy_bin = Path(os.environ.get("HAM_DEV_PROXY_BIN", "/tmp/ham-dev-proxy-phase12"))
    for name, path in [("HAM_HUB_BIN", hub_bin), ("HAM_BRIDGE_BIN", bridge_bin), ("HAM_DEV_PROXY_BIN", proxy_bin)]:
        if not path.exists():
            raise SystemExit(f"missing {name}: {path}")

    hub_port = free_port(); proxy_port = free_port(); bridge_port = free_port()
    hub_base = f"http://127.0.0.1:{hub_port}/api/v1"
    proxy_root = f"http://127.0.0.1:{proxy_port}"
    base = f"{proxy_root}/api/v1"
    alice = {"X-Dev-User": "tanmay"}
    bob = {"X-Dev-User": "reviewer"}

    with tempfile.TemporaryDirectory(prefix="ham-phase12-") as tmp_s:
        tmp = Path(tmp_s)
        hub = subprocess.Popen([str(hub_bin), "--listen", f"127.0.0.1:{hub_port}", "--db", str(tmp / "hub.db"), "--logout-url", "/_dev/logout"], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        proxy = None; bridge = None
        try:
            wait_get(f"{hub_base}/health")
            proxy = subprocess.Popen([str(proxy_bin), "--listen", f"127.0.0.1:{proxy_port}", "--hub-url", f"http://127.0.0.1:{hub_port}"], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            wait_get(f"{base}/health")

            st, me = req("GET", f"{base}/me", headers=alice); assert st == 200 and me["data"]["user_id"].endswith("tanmay"), me
            st, enr = req("POST", f"{base}/bridge-enrollments", {"label": "phase12"}, alice); assert st == 201, enr
            cfg = tmp / "bridge.toml"
            bridge_hub_url = f"http://127.0.0.1:{hub_port}"
            out = subprocess.run([str(bridge_bin), "enroll", "--config", str(cfg), "--hub", bridge_hub_url, "--enrollment-token", enr["data"]["enrollment_token"]], cwd=ROOT, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
            assert "bridge enrolled" in out and bridge_hub_url in cfg.read_text(), out
            cfg_text = cfg.read_text(); bridge_id = toml_value(cfg_text, "daemon_id")
            bridge = subprocess.Popen([str(bridge_bin), "--config", str(cfg), "--bind-host", "127.0.0.1", "--port", str(bridge_port)], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            detail = wait_bridge_online(base, bridge_id, alice); assert detail["data"]["hub_url"] == bridge_hub_url, detail

            st, agent = req("POST", f"{base}/agents", {"name": "Phase12 Agent", "slug": "phase12-agent", "default_provider": "claude", "default_tier": "normal", "instructions": "Phase12"}, alice); assert st == 201, agent
            agent_id = agent["data"]["agent_id"]
            st, support = req("PATCH", f"{base}/agents/{agent_id}/bridge-support/{bridge_id}", {"enabled": True, "provider": "claude", "tier": "normal", "priority": 1}, alice); assert st == 200, support
            project_path = tmp / "project"; project_path.mkdir()
            st, project = req("POST", f"{base}/projects", {"name": "Phase12 Project", "slug": "phase12-project", "default_path": str(project_path), "vcs_kind": "none"}, alice); assert st == 201, project
            project_id = project["data"]["project_id"]
            st, bob_project = req("GET", f"{base}/projects/{project_id}", headers=bob); assert st == 404, bob_project
            st, created = req("POST", f"{base}/agent-instances", {"agent_id": agent_id, "bridge_id": bridge_id, "project_id": project_id}, alice); assert st == 201, created
            instance_id = created["data"]["agent_instance_id"]
            running = wait_instance_status(base, instance_id, alice, "running"); assert running["data"]["bridge_id"] == bridge_id, running
            st, task_chain = req("POST", f"{base}/task-chains", {"title": "Phase12 chain", "description": "E2E", "publish_state": "published"}, alice); assert st == 201, task_chain
            st, msg = req("POST", f"{base}/chats/{created['data']['conversation_id']}/messages", {"body": "phase12 hello"}, alice); assert st == 201, msg
            st, msgs = req("GET", f"{base}/chats/{created['data']['conversation_id']}/messages?limit=5", headers=alice); assert st == 200 and any(m.get("body") == "phase12 hello" for m in msgs["data"]), msgs
        except Exception:
            if bridge and bridge.stdout:
                bridge.terminate();
                try: bridge.wait(timeout=3)
                except subprocess.TimeoutExpired: bridge.kill()
                print("--- bridge log ---"); print(bridge.stdout.read())
                bridge = None
            if proxy and proxy.stdout:
                proxy.terminate();
                try: proxy.wait(timeout=3)
                except subprocess.TimeoutExpired: proxy.kill()
                print("--- proxy log ---"); print(proxy.stdout.read())
                proxy = None
            if hub and hub.stdout:
                hub.terminate();
                try: hub.wait(timeout=3)
                except subprocess.TimeoutExpired: hub.kill()
                print("--- hub log ---"); print(hub.stdout.read())
            raise
        finally:
            if bridge:
                bridge.terminate();
                try: bridge.wait(timeout=3)
                except subprocess.TimeoutExpired: bridge.kill()
            if proxy:
                proxy.terminate();
                try: proxy.wait(timeout=3)
                except subprocess.TimeoutExpired: proxy.kill()
            hub.terminate();
            try: hub.wait(timeout=3)
            except subprocess.TimeoutExpired: hub.kill()
    print("PASS: hub phase12 E2E real smoke")


if __name__ == "__main__":
    main()
