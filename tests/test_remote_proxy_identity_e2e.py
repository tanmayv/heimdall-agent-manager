#!/usr/bin/env python3
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


def require(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)


def bin_path() -> str:
    env = os.environ.get("HEIMDALL_DAEMON_BIN")
    if env and Path(env).exists():
        return env
    for candidate in [
        ROOT / "result" / "bin" / "ham-daemon",
        ROOT / "result-daemon" / "bin" / "ham-daemon",
        ROOT / "result" / "result-daemon" / "ham-daemon",
    ]:
        if candidate.exists():
            return str(candidate)
    raise RuntimeError("missing ham-daemon binary; set HEIMDALL_DAEMON_BIN or run nix build .#ham-daemon")


def free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def request_json(base: str, path: str, method: str = "GET", body=None, headers=None, expect_status: int = 200):
    data = None
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = Request(base + path, data=data, headers=req_headers, method=method)
    try:
        with urlopen(req, timeout=5) as resp:
            payload = resp.read().decode("utf-8")
            status = resp.status
    except HTTPError as err:
        payload = err.read().decode("utf-8")
        status = err.code
    except URLError as err:
        raise RuntimeError(f"request failed: {path}: {err}") from err
    require(status == expect_status, f"{method} {path} expected {expect_status}, got {status}: {payload}")
    return json.loads(payload)


def wait_for_health(base: str):
    for _ in range(100):
        try:
            data = request_json(base, "/health")
            if data.get("ok"):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def main():
    daemon_bin = bin_path()
    temp_dir = Path(tempfile.mkdtemp(prefix="remote-proxy-identity-"))
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    data_dir = temp_dir / "data"
    cfg_path = temp_dir / "config.toml"
    cfg_path.write_text(
        "\n".join([
            "[daemon]",
            'bind_host = "127.0.0.1"',
            f"port = {port}",
            f'data_dir = "{data_dir}"',
            'daemon_id = "remote-proxy-self"',
            "",
            "[guide_agent]",
            "enabled = false",
            "autostart = false",
            "restart_if_stopped = false",
            "",
            "[[peer]]",
            'name = "self-peer"',
            f'endpoint = "{base}"',
            'token = "peer-secret"',
        ]),
        encoding="utf-8",
    )

    proc = subprocess.Popen(
        [daemon_bin, "--config", str(cfg_path)],
        cwd=str(ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        wait_for_health(base)
        reg = request_json(base, "/user-client/register", method="POST", body={
            "user_id": "operator",
            "client_instance_id": "ui-test",
            "client_token": "",
        })
        client_token = reg["client_token"]
        auth = {"Authorization": f"Bearer {client_token}"}

        request_json(base, "/federation/peers/reconnect", method="POST", headers=auth, body={"peer_id": "self-peer"})

        first = request_json(base, "/federation/proxies/bind", method="POST", headers=auth, body={
            "peer_id": "self-peer",
            "origin_daemon_id": "remote-proxy-self",
            "remote_agent_instance_id": "reviewer@s-remote-1",
            "display_name": "Remote Reviewer",
            "template_id": "reviewer",
            "provider_profile": "pi",
            "model_tier": "smart",
            "agent_role": "reviewer",
        })
        first_agent = first["agent"]
        require(first_agent["agent_kind"] == "remote_proxy", f"expected remote_proxy kind, got {first_agent}")
        require(first_agent.get("remote", {}).get("peer_id") == "self-peer", f"missing peer_id remote block: {first_agent}")
        require(first_agent.get("remote", {}).get("origin_daemon_id") == "remote-proxy-self", f"missing origin daemon id remote block: {first_agent}")
        require(first_agent.get("remote", {}).get("remote_agent_instance_id") == "reviewer@s-remote-1", f"missing remote agent id block: {first_agent}")
        local_proxy_id = first_agent["agent_instance_id"]
        require(local_proxy_id and local_proxy_id != "reviewer@s-remote-1", "expected concrete local proxy id distinct from remote id")

        second = request_json(base, "/federation/proxies/bind", method="POST", headers=auth, body={
            "peer_id": "self-peer",
            "origin_daemon_id": "remote-proxy-self",
            "remote_agent_instance_id": "reviewer@s-remote-1",
        })
        require(second["agent"]["agent_instance_id"] == local_proxy_id, "expected bind to reuse existing proxy id")

        show = request_json(base, "/agents/show", method="POST", body={"agent_instance_id": local_proxy_id})
        shown = show["agent"]
        require(shown["agent_kind"] == "remote_proxy", f"show should preserve remote_proxy kind: {shown}")
        require(shown.get("remote", {}).get("peer_id") == "self-peer", f"show should include remote block: {shown}")
        require(shown.get("remote", {}).get("origin_daemon_id") == "remote-proxy-self", f"show should include origin daemon id: {shown}")

        reorder = request_json(base, "/user-rpc", method="POST", body={
            "action": "agent_reorder",
            "client_instance_id": "ui-test",
            "client_token": client_token,
            "agent_ids": [local_proxy_id],
        })
        require(reorder.get("ok") is True, f"expected reorder ok, got {reorder}")

        reordered = request_json(base, "/agents/show", method="POST", body={"agent_instance_id": local_proxy_id})["agent"]
        require(reordered["agent_kind"] == "remote_proxy", f"reorder should preserve remote_proxy kind: {reordered}")
        require(reordered.get("remote", {}).get("peer_id") == "self-peer", f"reorder should preserve remote peer block: {reordered}")
        require(reordered.get("remote", {}).get("origin_daemon_id") == "remote-proxy-self", f"reorder should preserve origin daemon id block: {reordered}")
        require(reordered.get("remote", {}).get("remote_agent_instance_id") == "reviewer@s-remote-1", f"reorder should preserve remote agent id block: {reordered}")

        start_forwarded = request_json(base, "/agents/start", method="POST", body={
            "agent_instance_id": local_proxy_id,
            "provider_profile": "pi",
            "template_id": "reviewer",
            "model_tier": "normal",
        }, expect_status=404)
        require("target agent not found on owner daemon" in json.dumps(start_forwarded), f"expected owner-forwarded start miss, got {start_forwarded}")

        print("remote_proxy_identity_e2e: ok")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
        if proc.stdout is not None:
            output = proc.stdout.read()
            if proc.returncode not in (0, -15):
                sys.stderr.write(output)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
