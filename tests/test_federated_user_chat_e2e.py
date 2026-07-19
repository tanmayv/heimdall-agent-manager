#!/usr/bin/env python3
"""Federated user chat E2E over two daemons and two ham-bridges."""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
BRIDGE_TOKEN = "loopback-secret"
PEER_TOKEN = "mesh-shared-secret"


def require(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        raise SystemExit(1)


def binary_path(env_name: str, candidates) -> str:
    env = os.environ.get(env_name)
    if env and Path(env).exists():
        return env
    for candidate in candidates:
        p = ROOT / candidate
        if p.exists():
            return str(p)
    raise RuntimeError(f"missing binary; set {env_name}")


def daemon_bin() -> str:
    return binary_path("HEIMDALL_DAEMON_BIN", ["result-daemon/bin/ham-daemon", "result/bin/ham-daemon"])


def bridge_bin() -> str:
    return binary_path("HEIMDALL_BRIDGE_BIN", ["result-bridge/bin/ham-bridge", "result-1/bin/ham-bridge"])


def free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def request(base: str, path: str, method: str = "GET", body=None, headers=None, expect: int = 200, timeout: float = 10.0):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    req = Request(base + path, data=data, headers=req_headers, method=method)
    try:
        with urlopen(req, timeout=timeout) as resp:
            payload = resp.read().decode("utf-8")
            status = resp.status
    except HTTPError as err:
        payload = err.read().decode("utf-8")
        status = err.code
    except URLError as err:
        raise RuntimeError(f"{method} {path} failed: {err}") from err
    require(status == expect, f"{method} {path} expected {expect}, got {status}: {payload[:500]}")
    return json.loads(payload) if payload else {}


def wait_for_health(base: str):
    for _ in range(200):
        try:
            if request(base, "/health", timeout=5).get("ok"):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"daemon {base} did not become healthy")


def wait_for(predicate, message: str, timeout: float = 20.0):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            last = predicate()
            if last:
                return last
        except Exception as err:
            last = err
        time.sleep(0.2)
    raise RuntimeError(f"{message}: {last!r}")


def write_daemon_config(path: Path, port: int, daemon_id: str, bridge_port: int, home_dir: Path):
    path.write_text("\n".join([
        "[daemon]",
        'bind_host = "127.0.0.1"',
        f"port = {port}",
        f'data_dir = "{home_dir}"',
        f'daemon_id = "{daemon_id}"',
        f'bridge_url = "http://127.0.0.1:{bridge_port}"',
        f'bridge_token = "{BRIDGE_TOKEN}"',
        "",
        "[guide_agent]",
        "enabled = false",
        "autostart = false",
        "restart_if_stopped = false",
    ]), encoding="utf-8")


def write_bridge_config(path: Path, daemon_id: str, daemon_port: int, peer_id: str, peer_bridge_port: int):
    path.write_text("\n".join([
        "[daemon]",
        f'daemon_id = "{daemon_id}"',
        f'bridge_token = "{BRIDGE_TOKEN}"',
        "[wrapper]",
        f'daemon_url = "http://127.0.0.1:{daemon_port}"',
        "[[peer]]",
        f'name = "{peer_id}"',
        f'endpoint = "http://127.0.0.1:{peer_bridge_port}"',
        f'token = "{PEER_TOKEN}"',
    ]), encoding="utf-8")


def start(cmd, log_path: Path):
    return subprocess.Popen(cmd, cwd=str(ROOT), stdout=log_path.open("w"), stderr=subprocess.STDOUT, text=True)


def stop(proc):
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)


def user_rpc(base: str, client_token: str, action: str, fields: dict):
    body = {"action": action, "client_instance_id": "ui-a", "client_token": client_token}
    body.update(fields)
    return request(base, "/user-rpc", "POST", body)


def agent_rpc(base: str, agent_token: str, action: str, fields: dict):
    body = {"action": action, "agent_token": agent_token}
    body.update(fields)
    return request(base, "/agent-rpc", "POST", body)


def main():
    temp_dir = Path(tempfile.mkdtemp(prefix="fed-user-chat-"))
    procs = []
    try:
        daemon = daemon_bin()
        bridge = bridge_bin()
        da_port, db_port = free_port(), free_port()
        ba_port, bb_port = free_port(), free_port()
        cfg_da, cfg_db = temp_dir / "daemon-a.toml", temp_dir / "daemon-b.toml"
        cfg_ba, cfg_bb = temp_dir / "bridge-a.toml", temp_dir / "bridge-b.toml"
        write_daemon_config(cfg_da, da_port, "home-a", ba_port, temp_dir / "home-a")
        write_daemon_config(cfg_db, db_port, "home-b", bb_port, temp_dir / "home-b")
        write_bridge_config(cfg_ba, "home-a", da_port, "home-b", bb_port)
        write_bridge_config(cfg_bb, "home-b", db_port, "home-a", ba_port)
        base_a = f"http://127.0.0.1:{da_port}"
        base_b = f"http://127.0.0.1:{db_port}"

        procs.append(start([daemon, "--config", str(cfg_da)], temp_dir / "daemon-a.log"))
        procs.append(start([daemon, "--config", str(cfg_db)], temp_dir / "daemon-b.log"))
        wait_for_health(base_a)
        wait_for_health(base_b)
        procs.append(start([bridge, "--config", str(cfg_ba), "--port", str(ba_port), "--peer-auth-token", PEER_TOKEN], temp_dir / "bridge-a.log"))
        procs.append(start([bridge, "--config", str(cfg_bb), "--port", str(bb_port), "--peer-auth-token", PEER_TOKEN], temp_dir / "bridge-b.log"))

        client_token = request(base_a, "/user-client/register", "POST", {
            "user_id": "operator@local",
            "client_instance_id": "ui-a",
            "client_token": "",
        })["client_token"]
        peer_headers = {"Authorization": f"Bearer {client_token}"}
        wait_for(lambda: request(base_a, "/federation/peers", headers=peer_headers).get("peers", [{}])[0].get("status") == "linked", "peer did not link")

        real_agent = "remoteagent@home-b"
        agent_token = request(base_b, "/register", "POST", {"agent_instance_id": real_agent, "display_name": real_agent})["agent_token"]
        bind = request(base_a, "/federation/proxies/bind", "POST", {
            "peer_id": "home-b",
            "origin_daemon_id": "home-b",
            "remote_agent_instance_id": real_agent,
            "display_name": "Remote Agent Proxy",
            "template_id": "remoteagent",
            "provider_profile": "pi",
            "model_tier": "normal",
        }, headers=peer_headers)
        proxy_id = bind["agent"]["agent_instance_id"]
        synthetic_user = f"fed.home-a.{proxy_id}.operator@local"

        send = user_rpc(base_a, client_token, "send_to_agent", {"agent_instance_id": proxy_id, "body": "hello remote user chat"})
        require(send.get("ok") is True, f"remote user chat send failed: {send}")

        remote_messages = wait_for(
            lambda: (lambda rows: rows if any(m.get("body") == "hello remote user chat" for m in rows) else None)(agent_rpc(base_b, agent_token, "fetch_user_chat", {"user_id": synthetic_user, "include_read": True, "limit": 10}).get("messages", [])),
            "remote agent did not receive federated user chat",
        )
        require(any(m.get("body") == "hello remote user chat" for m in remote_messages), f"missing remote body: {remote_messages}")

        reply = agent_rpc(base_b, agent_token, "send_to_user", {"user_id": synthetic_user, "body": "hello home user"})
        require(reply.get("ok") is True, f"remote reply failed: {reply}")

        home_messages = wait_for(
            lambda: (lambda rows: rows if any(m.get("direction") == "agent_to_user" and m.get("body") == "hello home user" for m in rows) else None)(user_rpc(base_a, client_token, "fetch_chat", {"agent_instance_id": proxy_id, "unread_only": False, "limit": 10}).get("messages", [])),
            "home user did not receive remote reply",
        )
        require(any(m.get("direction") == "agent_to_user" and m.get("body") == "hello home user" for m in home_messages), f"missing home reply: {home_messages}")
        print("federated_user_chat_e2e: ok")
    finally:
        for proc in reversed(procs):
            stop(proc)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
