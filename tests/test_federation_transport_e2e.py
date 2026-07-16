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


def write_config(path: Path, daemon_id: str, port: int, data_dir: Path, peer_name: str, peer_endpoint: str):
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
            "",
            "[[peer]]",
            f'name = "{peer_name}"',
            f'endpoint = "{peer_endpoint}"',
            f'token = "{SHARED_TOKEN}"',
        ]),
        encoding="utf-8",
    )


def register_agent(base: str, agent_instance_id: str):
    data = request_json(base, "/register", method="POST", body={
        "agent_instance_id": agent_instance_id,
        "display_name": agent_instance_id,
    })
    token = data.get("agent_token", "")
    require(token, f"register should return agent token for {agent_instance_id}: {data}")
    return token


def user_client(base: str):
    data = request_json(base, "/user-client/register", method="POST", body={
        "user_id": "operator@local",
        "client_instance_id": f"ui-{int(time.time() * 1000)}",
        "client_token": "",
    })
    return data["client_token"]


def reconnect_peer(base: str, client_token: str, peer_id: str):
    request_json(base, f"/federation/peers/reconnect?unused=1", method="POST", body={"peer_id": peer_id}, expect_status=401)
    return request_json(base, "/federation/peers/reconnect", method="POST", body={"peer_id": peer_id, "Authorization": None}, expect_status=401)


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


def main():
    daemon_bin = bin_path()
    temp_dir = Path(tempfile.mkdtemp(prefix="fed-transport-"))
    port_a = free_port()
    port_b = free_port()
    base_a = f"http://127.0.0.1:{port_a}"
    base_b = f"http://127.0.0.1:{port_b}"
    cfg_a = temp_dir / "a.toml"
    cfg_b = temp_dir / "b.toml"
    write_config(cfg_a, "fed-a", port_a, temp_dir / "data-a", "peer-b", base_b)
    write_config(cfg_b, "fed-b", port_b, temp_dir / "data-b", "peer-a", base_a)

    proc_a = subprocess.Popen([daemon_bin, "--config", str(cfg_a)], cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    proc_b = subprocess.Popen([daemon_bin, "--config", str(cfg_b)], cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        wait_for_health(base_a)
        wait_for_health(base_b)

        sender_id = "sender@s-local-a"
        receiver_id = "reviewer@s-remote-b"
        sender_token = register_agent(base_a, sender_id)
        receiver_token = register_agent(base_b, receiver_id)

        client_a = user_client(base_a)
        client_b = user_client(base_b)
        authed_post(base_a, "/federation/peers/reconnect", client_a, {"peer_id": "peer-b"})
        authed_post(base_b, "/federation/peers/reconnect", client_b, {"peer_id": "peer-a"})

        bind = authed_post(base_a, "/federation/proxies/bind", client_a, {
            "peer_id": "peer-b",
            "remote_agent_instance_id": receiver_id,
            "display_name": "Remote Reviewer",
            "template_id": "reviewer",
            "provider_profile": "pi",
            "model_tier": "normal",
            "agent_role": "reviewer",
        })
        proxy_id = bind["agent"]["agent_instance_id"]
        require(proxy_id and proxy_id != receiver_id, f"bind should return local proxy id: {bind}")

        send = request_json(base_a, "/agent-rpc", method="POST", body={
            "agent_token": sender_token,
            "action": "send_message",
            "target_agent_instance_id": proxy_id,
            "body": "hello remote",
        }, expect_status=202)
        message_id = send.get("message_id", "")
        conversation_a = send.get("conversation_id", "")
        require(message_id and conversation_a, f"remote send should return ids: {send}")

        duplicate_payload = {
            "kind": "inbox_message",
            "idempotency_key": f"msg:{message_id}",
            "message_id": message_id,
            "from_agent_instance_id": sender_id,
            "target_agent_instance_id": receiver_id,
            "proxy_agent_instance_id": proxy_id,
            "origin_conversation_id": conversation_a,
            "created_unix_ms": int(time.time() * 1000),
        }
        request_json(base_b, f"/federation/inbox?peer_token={SHARED_TOKEN}&peer_daemon_id=fed-a", method="POST", body=duplicate_payload)

        callback_path_a = f"/federation/callback?peer_token={SHARED_TOKEN}&peer_daemon_id=fed-b"
        forged_conversation = conversation_a + "_forged"
        request_json(base_a, callback_path_a, method="POST", body={
            "kind": "read_receipt",
            "idempotency_key": f"forged-read:{message_id}",
            "message_id": message_id,
            "target_agent_instance_id": sender_id,
            "proxy_agent_instance_id": proxy_id,
            "origin_conversation_id": forged_conversation,
            "read_by_agent_instance_id": receiver_id,
            "read_unix_ms": int(time.time() * 1000),
        }, expect_status=403)
        sender_messages_before = request_json(base_a, "/agent-rpc", method="POST", body={
            "agent_token": sender_token,
            "action": "fetch_messages",
            "conversation_id": conversation_a,
            "include_read": True,
        }).get("messages", [])
        origin_message_before = next((m for m in sender_messages_before if m.get("id") == message_id), None)
        require(origin_message_before is not None and not origin_message_before.get("read"), f"forged read receipt should not mark origin message read: {sender_messages_before}")

        request_json(base_a, callback_path_a, method="POST", body={
            "kind": "inbox_message",
            "idempotency_key": f"forged-reply:{message_id}",
            "message_id": "remote-forged-1",
            "origin_message_id": message_id,
            "from_agent_instance_id": receiver_id,
            "target_agent_instance_id": sender_id,
            "proxy_agent_instance_id": proxy_id,
            "origin_conversation_id": forged_conversation,
            "body": "forged reply",
            "created_unix_ms": int(time.time() * 1000),
        }, expect_status=403)
        forged_messages = request_json(base_a, "/agent-rpc", method="POST", body={
            "agent_token": sender_token,
            "action": "fetch_messages",
            "conversation_id": forged_conversation,
            "include_read": True,
        }).get("messages", [])
        require(not forged_messages, f"forged reply should not create local conversation state: {forged_messages}")

        conversation_b = conv_id(sender_id)
        fetched_b = wait_for(
            lambda: request_json(base_b, "/agent-rpc", method="POST", body={
                "agent_token": receiver_token,
                "action": "fetch_messages",
                "conversation_id": conversation_b,
                "include_read": False,
            }).get("messages"),
            "receiver did not fetch remote message",
        )
        hello_remote = [m for m in fetched_b if m.get("body") == "hello remote"]
        require(len(hello_remote) == 1, f"duplicate inbox delivery should be deduped: {fetched_b}")

        wait_for(
            lambda: any(m.get("id") == message_id and m.get("read") for m in request_json(base_a, "/agent-rpc", method="POST", body={
                "agent_token": sender_token,
                "action": "fetch_messages",
                "conversation_id": conversation_a,
                "include_read": True,
            }).get("messages", [])),
            "origin sender did not observe remote read receipt",
        )

        request_json(base_b, "/agent-rpc", method="POST", body={
            "agent_token": receiver_token,
            "action": "send_message",
            "target_agent_instance_id": sender_id,
            "body": "hello back",
        }, expect_status=202)

        fetched_a = wait_for(
            lambda: request_json(base_a, "/agent-rpc", method="POST", body={
                "agent_token": sender_token,
                "action": "fetch_messages",
                "conversation_id": conversation_a,
                "include_read": True,
            }).get("messages"),
            "origin sender did not receive remote reply",
        )
        require(any(m.get("body") == "hello back" for m in fetched_a), f"remote reply missing from origin conversation: {fetched_a}")

        print("federation_transport_e2e: ok")
    finally:
        for proc in (proc_a, proc_b):
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
