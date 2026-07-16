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
from urllib.parse import urlencode
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
    temp_dir = Path(tempfile.mkdtemp(prefix="fed-peer-foundations-"))
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
            'daemon_id = "fed-self"',
            'federation_advertised_agent_instance_ids = ["allowed@s-fed"]',
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

        request_json(base, "/agents/create", method="POST", body={
            "agent_instance_id": "allowed@s-fed",
            "display_name": "Allowed",
            "provider_profile": "pi",
            "template_id": "reviewer",
            "project_id": "",
            "model_tier": "normal",
            "agent_role": "reviewer",
        })
        request_json(base, "/agents/create", method="POST", body={
            "agent_instance_id": "hidden@s-fed",
            "display_name": "Hidden",
            "provider_profile": "pi",
            "template_id": "reviewer",
            "project_id": "",
            "model_tier": "normal",
            "agent_role": "reviewer",
        })

        request_json(base, "/federation/peers/reconnect", method="POST", headers=auth, body={"peer_id": "self-peer"})

        advertised = request_json(base, "/federation/agents?" + urlencode({
            "peer_token": "peer-secret",
            "peer_daemon_id": "fed-self",
        }))
        ids = [row.get("agent_instance_id", "") for row in advertised.get("agents", [])]
        require(ids == ["allowed@s-fed"], f"expected only allowlisted advertised agent, got {ids}")

        agent_reg = request_json(base, "/register", method="POST", body={
            "agent_instance_id": "probe@s-fed",
            "agent_class": "probe",
            "display_name": "Probe",
        })
        agent_token = agent_reg["agent_token"]
        agent_auth = {"Authorization": f"Bearer {agent_token}"}

        list_denied = request_json(base, "/federation/peers", headers=agent_auth, expect_status=401)
        require("user client token required" in json.dumps(list_denied), f"expected user-only auth rejection for peer list, got {list_denied}")

        reconnect_denied = request_json(base, "/federation/peers/reconnect", method="POST", headers=agent_auth, body={"peer_id": "self-peer"}, expect_status=401)
        require("user client token required" in json.dumps(reconnect_denied), f"expected user-only auth rejection for peer reconnect, got {reconnect_denied}")

        print("federation_peer_foundations_e2e: ok")
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
