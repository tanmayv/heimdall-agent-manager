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
SHARED_TOKEN = "shared-peer-secret"


def require(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)


def bin_path() -> str:
    env = os.environ.get("HEIMDALL_DAEMON_BIN")
    if env and Path(env).exists():
        return env
    candidate = ROOT / "result" / "bin" / "ham-daemon"
    if candidate.exists():
        return str(candidate)
    raise RuntimeError("missing ham-daemon binary; set HEIMDALL_DAEMON_BIN")


def free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def request_json(base: str, path: str, method: str = "GET", body=None, expect_status: int = 200):
    data = None
    headers = {"Content-Type": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = Request(base + path, data=data, headers=headers, method=method)
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


def authed_post(base: str, path: str, client_token: str, body: dict, expect_status: int = 200):
    data = json.dumps(body).encode("utf-8")
    req = Request(base + path, data=data, headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {client_token}",
    }, method="POST")
    try:
        with urlopen(req, timeout=5) as resp:
            payload = resp.read().decode("utf-8")
            status = resp.status
    except HTTPError as err:
        payload = err.read().decode("utf-8")
        status = err.code
    require(status == expect_status, f"POST {path} expected {expect_status}, got {status}: {payload}")
    return json.loads(payload)


def wait_for_health(base: str):
    for _ in range(100):
        try:
            if request_json(base, "/health").get("ok"):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"daemon {base} did not become healthy")


def wait_for(predicate, message: str, timeout: float = 5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError(message)


def conv_id(agent_instance_id: str) -> str:
    out = ["conv_"]
    for ch in agent_instance_id:
        if ch.isalnum() or ch in "_-":
            out.append(ch)
        else:
            out.append("_")
    return "".join(out)


def write_config(path: Path, daemon_id: str, port: int, data_dir: Path, peers):
    lines = [
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
    ]
    for peer_name, peer_endpoint in peers:
        lines.extend([
            "",
            "[[peer]]",
            f'name = "{peer_name}"',
            f'endpoint = "{peer_endpoint}"',
            f'token = "{SHARED_TOKEN}"',
        ])
    path.write_text("\n".join(lines), encoding="utf-8")


def register_agent(base: str, agent_instance_id: str):
    data = request_json(base, "/register", method="POST", body={
        "agent_instance_id": agent_instance_id,
        "display_name": agent_instance_id,
    })
    token = data.get("agent_token", "")
    require(token, f"register should return token for {agent_instance_id}: {data}")
    return token


def user_client(base: str):
    data = request_json(base, "/user-client/register", method="POST", body={
        "user_id": "operator@local",
        "client_instance_id": f"ui-{int(time.time() * 1000)}",
        "client_token": "",
    })
    return data["client_token"]


def main():
    daemon_bin = bin_path()
    temp_dir = Path(tempfile.mkdtemp(prefix="fed-transport-dedupe-"))
    port_a = free_port()
    port_b = free_port()
    port_c = free_port()
    base_a = f"http://127.0.0.1:{port_a}"
    base_b = f"http://127.0.0.1:{port_b}"
    base_c = f"http://127.0.0.1:{port_c}"

    cfg_a = temp_dir / "a.toml"
    cfg_b = temp_dir / "b.toml"
    cfg_c = temp_dir / "c.toml"
    write_config(cfg_a, "fed-a", port_a, temp_dir / "data-a", [("peer-b", base_b)])
    write_config(cfg_b, "fed-b", port_b, temp_dir / "data-b", [("peer-a", base_a), ("peer-c", base_c)])
    write_config(cfg_c, "fed-c", port_c, temp_dir / "data-c", [("peer-b", base_b)])

    proc_a = subprocess.Popen([daemon_bin, "--config", str(cfg_a)], cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    proc_b = subprocess.Popen([daemon_bin, "--config", str(cfg_b)], cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    proc_c = subprocess.Popen([daemon_bin, "--config", str(cfg_c)], cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        wait_for_health(base_a)
        wait_for_health(base_b)
        wait_for_health(base_c)

        sender_a = "sender-a@s-local-a"
        sender_c = "sender-c@s-local-c"
        receiver_b = "reviewer@s-remote-b"
        sender_a_token = register_agent(base_a, sender_a)
        sender_c_token = register_agent(base_c, sender_c)
        receiver_b_token = register_agent(base_b, receiver_b)

        client_a = user_client(base_a)
        client_b = user_client(base_b)
        client_c = user_client(base_c)
        authed_post(base_a, "/federation/peers/reconnect", client_a, {"peer_id": "peer-b"})
        authed_post(base_b, "/federation/peers/reconnect", client_b, {"peer_id": "peer-a"})
        authed_post(base_b, "/federation/peers/reconnect", client_b, {"peer_id": "peer-c"})
        authed_post(base_c, "/federation/peers/reconnect", client_c, {"peer_id": "peer-b"})

        bind_a = authed_post(base_a, "/federation/proxies/bind", client_a, {
            "peer_id": "peer-b",
            "remote_agent_instance_id": receiver_b,
            "display_name": "Remote Reviewer",
            "template_id": "reviewer",
            "provider_profile": "pi",
            "model_tier": "normal",
            "agent_role": "reviewer",
        })
        bind_c = authed_post(base_c, "/federation/proxies/bind", client_c, {
            "peer_id": "peer-b",
            "remote_agent_instance_id": receiver_b,
            "display_name": "Remote Reviewer",
            "template_id": "reviewer",
            "provider_profile": "pi",
            "model_tier": "normal",
            "agent_role": "reviewer",
        })
        proxy_a = bind_a["agent"]["agent_instance_id"]
        proxy_c = bind_c["agent"]["agent_instance_id"]
        require(proxy_a and proxy_c, f"bind should return proxy ids: {bind_a} / {bind_c}")

        send_a = request_json(base_a, "/agent-rpc", method="POST", body={
            "agent_token": sender_a_token,
            "action": "send_message",
            "target_agent_instance_id": proxy_a,
            "body": "hello from A",
        }, expect_status=202)
        send_c = request_json(base_c, "/agent-rpc", method="POST", body={
            "agent_token": sender_c_token,
            "action": "send_message",
            "target_agent_instance_id": proxy_c,
            "body": "hello from C",
        }, expect_status=202)
        require(send_a.get("message_id"), f"expected non-empty local message id on A: {send_a}")
        require(send_c.get("message_id"), f"expected non-empty local message id on C: {send_c}")

        callback_path_a = f"/federation/callback?peer_token={SHARED_TOKEN}&peer_daemon_id=fed-b"
        duplicate_reply = {
            "kind": "inbox_message",
            "idempotency_key": "reply:fed-b:reply-msg-1",
            "message_id": "reply-msg-1",
            "origin_message_id": send_a["message_id"],
            "from_agent_instance_id": receiver_b,
            "target_agent_instance_id": sender_a,
            "proxy_agent_instance_id": proxy_a,
            "origin_conversation_id": send_a["conversation_id"],
            "body": "duplicate-safe reply",
            "created_unix_ms": int(time.time() * 1000),
        }
        request_json(base_a, callback_path_a, method="POST", body=duplicate_reply)
        request_json(base_a, callback_path_a, method="POST", body=duplicate_reply)
        sender_a_messages = wait_for(
            lambda: request_json(base_a, "/agent-rpc", method="POST", body={
                "agent_token": sender_a_token,
                "action": "fetch_messages",
                "conversation_id": send_a["conversation_id"],
                "include_read": True,
            }).get("messages"),
            "origin sender A did not receive duplicate-safe reply",
        )
        replies = [m for m in sender_a_messages if m.get("body") == "duplicate-safe reply"]
        require(len(replies) == 1, f"duplicate callback reply should inject exactly one local reply: {sender_a_messages}")

        receiver_messages = wait_for(
            lambda: request_json(base_b, "/agent-rpc", method="POST", body={
                "agent_token": receiver_b_token,
                "action": "fetch_messages",
                "conversation_id": conv_id(receiver_b),
                "include_read": False,
            }).get("messages"),
            "receiver on B did not get remote messages",
        )
        require(any(m.get("body") == "hello from A" for m in receiver_messages), f"missing sender A message on B: {receiver_messages}")
        require(any(m.get("body") == "hello from C" for m in receiver_messages), f"missing sender C message on B: {receiver_messages}")

        print("federation_transport_dedupe_e2e: ok")
    finally:
        for proc in (proc_a, proc_b, proc_c):
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
