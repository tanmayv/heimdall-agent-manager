#!/usr/bin/env python3
"""Legacy federation peer-management retirement E2E.

Federation v2 moved peer link/reconnect/remove control to ham-bridge config and
its websocket dialer. This test keeps the old daemon endpoint names honest by
asserting they now return 410 Gone instead of pretending direct-daemon peer
management is still active.

Live bridge transport coverage is superseded by:
- tests/test_bridge_federation_two_homes_e2e.py
- tests/test_bridge_federation_disconnect_recovery_e2e.py
"""
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
    for candidate in (
        ROOT / "result-daemon" / "bin" / "ham-daemon",
        ROOT / "result" / "bin" / "ham-daemon",
    ):
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
    merged_headers = {"Content-Type": "application/json"}
    if headers:
        merged_headers.update(headers)
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = Request(base + path, data=data, headers=merged_headers, method=method)
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
            if request_json(base, "/health").get("ok"):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"daemon {base} did not become healthy")


def write_config(path: Path, daemon_id: str, port: int, data_dir: Path):
    path.write_text(
        "\n".join([
            "[daemon]",
            'bind_host = "127.0.0.1"',
            f"port = {port}",
            f'data_dir = "{data_dir}"',
            f'daemon_id = "{daemon_id}"',
            "",
            "[guide_agent]",
            "enabled = false",
            "autostart = false",
            "restart_if_stopped = false",
        ]),
        encoding="utf-8",
    )


def user_client_token(base: str) -> str:
    data = request_json(base, "/user-client/register", method="POST", body={
        "user_id": "operator@local",
        "client_instance_id": f"ui-{int(time.time() * 1000)}",
        "client_token": "",
    })
    token = data.get("client_token", "")
    require(token, f"user-client/register must return a token: {data}")
    return token


def authed_post(base: str, path: str, token: str, body: dict, expect_status: int):
    return request_json(
        base,
        path,
        method="POST",
        body=body,
        headers={"Authorization": f"Bearer {token}"},
        expect_status=expect_status,
    )


def main():
    daemon_bin = bin_path()
    temp_dir = Path(tempfile.mkdtemp(prefix="fed-transport-v2-"))
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    cfg = temp_dir / "daemon.toml"
    write_config(cfg, "fed-v2", port, temp_dir / "data")

    proc = subprocess.Popen([daemon_bin, "--config", str(cfg)], cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        wait_for_health(base)
        client_token = user_client_token(base)

        link = authed_post(base, "/federation/peers/link", client_token, {"peer_id": "peer-b"}, 410)
        require(link.get("message") == "peer link endpoint moved to ham-bridge config", f"unexpected link retirement payload: {link}")

        reconnect = authed_post(base, "/federation/peers/reconnect", client_token, {"peer_id": "peer-b"}, 410)
        require(reconnect.get("message") == "peer reconnect moved to ham-bridge websocket dialer", f"unexpected reconnect retirement payload: {reconnect}")

        remove = authed_post(base, "/federation/peers/remove", client_token, {"peer_id": "peer-b"}, 410)
        require(remove.get("message") == "peer removal moved to ham-bridge config", f"unexpected remove retirement payload: {remove}")

        peers = request_json(base, "/federation/peers", headers={"Authorization": f"Bearer {client_token}"})
        require(peers.get("ok") is True, f"federation peers listing should still respond: {peers}")

        print("federation_transport_e2e: ok")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
