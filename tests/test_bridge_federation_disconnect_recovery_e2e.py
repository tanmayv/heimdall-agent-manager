#!/usr/bin/env python3
"""
Bridge daemon-federation DISCONNECT / RECONNECT eventual-consistency E2E.

Two independent Heimdall homes linked over ham-bridge sidecars. We deliberately break
the bridge<->bridge link (and later the whole peer daemon), send work while the peer is
DOWN, and assert the system reaches EVENTUAL CONSISTENCY once connectivity returns --
no message lost, no duplicate applied.

Topology:  daemon A (home-a) <-> bridge A  <==WS==>  bridge B <-> daemon B (home-b)

Scenarios (each an explicit PASS/FAIL):

  D0. SETUP+LINK   Two homes boot; bridges link; a remote_proxy for reviewer@B is bound on A.
  D1. BRIDGE DOWN  Kill bridge B. A must observe the peer flip to `unreachable`
                   (liveness = session presence).
  D2. SEND WHILE   A sends an inbox DM to the remote proxy while the peer is down. The send
      DOWN         must be durably ACCEPTED locally (queued to A's federation outbox), not
                   hard-failed/lost.
  D3. RECONNECT    Restart bridge B. A must observe the peer flip back to `linked`.
  D4. EVENTUAL     Without any manual retry, the queued DM must eventually be delivered to
      CONSISTENCY  B's durable inbox (poll-driven outbox replay on reconnect).
  D5. PEER DAEMON  Kill daemon B ENTIRELY (home offline). Send a 2nd DM from A. Restart
      RESTART      daemon B + bridge B. The 2nd DM must also eventually land (survives a full
                   peer restart mid-exchange, durable-accept-before-ack).
  D6. NO DUP       Exactly one copy of each message exists on B (idempotency across retries).
  D7. TEARDOWN     Clean shutdown.

Opt-in binaries: HEIMDALL_DAEMON_BIN / HEIMDALL_BRIDGE_BIN or result-daemon/result-bridge.
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
BRIDGE_TOKEN = "loopback-secret"
PEER_TOKEN = "mesh-shared-secret"
PASSED = []


def ok(msg: str):
    PASSED.append(msg)
    print(f"  PASS: {msg}")


def require(condition: bool, message: str):
    if not condition:
        print(f"  FAIL: {message}")
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
    return binary_path("HEIMDALL_BRIDGE_BIN", ["result-bridge/bin/ham-bridge", "result/bin/ham-bridge"])


def free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def request(base, path, method="GET", body=None, headers=None, expect=200, timeout=10.0):
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
    require(status == expect, f"{method} {path} expected {expect}, got {status}: {payload[:400]}")
    return json.loads(payload) if payload else {}


def wait_for_health(base, name):
    for _ in range(200):
        try:
            if request(base, "/health", timeout=5).get("ok"):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"{name} ({base}) did not become healthy")


def wait_for(predicate, message, timeout=40.0, interval=0.3):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            last = predicate()
            if last:
                return last
        except Exception as err:
            last = err
        time.sleep(interval)
    raise RuntimeError(f"{message}: {last!r}")


def conv_id(agent_instance_id):
    out = ["conv_"]
    for ch in agent_instance_id:
        out.append(ch if (ch.isalnum() or ch in "_-") else "_")
    return "".join(out)


def write_daemon_config(path, port, daemon_id, bridge_port, home_dir):
    path.write_text(
        "\n".join([
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
        ]),
        encoding="utf-8",
    )


def write_bridge_config(path, daemon_id, daemon_port, peer_id, peer_bridge_port):
    path.write_text(
        "\n".join([
            "[daemon]",
            f'daemon_id = "{daemon_id}"',
            f'bridge_token = "{BRIDGE_TOKEN}"',
            "[wrapper]",
            f'daemon_url = "http://127.0.0.1:{daemon_port}"',
            "[[peer]]",
            f'name = "{peer_id}"',
            f'endpoint = "http://127.0.0.1:{peer_bridge_port}"',
            f'token = "{PEER_TOKEN}"',
        ]),
        encoding="utf-8",
    )


def start(cmd, log_path):
    return subprocess.Popen(cmd, cwd=str(ROOT), stdout=log_path.open("w"), stderr=subprocess.STDOUT, text=True)


def stop(proc):
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)


def peer_status(base, operator_token):
    peers = request(base, "/federation/peers", headers={"Authorization": f"Bearer {operator_token}"}).get("peers", [])
    return peers[0]["status"] if peers else None


def count_body_on_b(base_b, receiver_token, conversation_b, body):
    msgs = request(base_b, "/agent-rpc", "POST", {
        "agent_token": receiver_token,
        "action": "fetch_messages",
        "conversation_id": conversation_b,
        "include_read": True,
    }).get("messages", [])
    return sum(1 for m in msgs if m.get("body") == body)


def main():
    daemon = daemon_bin()
    bridge = bridge_bin()
    print(f"daemon: {daemon}")
    print(f"bridge: {bridge}")

    temp_dir = Path(tempfile.mkdtemp(prefix="bridge-fed-disc-"))
    home_a = temp_dir / "heimdall-home-a"
    home_b = temp_dir / "heimdall-home-b"

    da_port, db_port = free_port(), free_port()
    ba_port, bb_port = free_port(), free_port()
    base_a = f"http://127.0.0.1:{da_port}"
    base_b = f"http://127.0.0.1:{db_port}"
    cfg_da, cfg_db = temp_dir / "daemon-a.toml", temp_dir / "daemon-b.toml"
    cfg_ba, cfg_bb = temp_dir / "bridge-a.toml", temp_dir / "bridge-b.toml"
    write_daemon_config(cfg_da, da_port, "home-a", ba_port, home_a)
    write_daemon_config(cfg_db, db_port, "home-b", bb_port, home_b)
    write_bridge_config(cfg_ba, "home-a", da_port, "home-b", bb_port)
    write_bridge_config(cfg_bb, "home-b", db_port, "home-a", ba_port)

    daemon_a = daemon_b = bridge_a = bridge_b = None

    def start_bridge_a():
        return start([bridge, "--config", str(cfg_ba), "--port", str(ba_port), "--peer-auth-token", PEER_TOKEN], temp_dir / "bridge-a.log")

    def start_bridge_b():
        return start([bridge, "--config", str(cfg_bb), "--port", str(bb_port), "--peer-auth-token", PEER_TOKEN], temp_dir / "bridge-b.log")

    def start_daemon_b():
        return start([daemon, "--config", str(cfg_db)], temp_dir / "daemon-b.log")

    try:
        # ---- D0. SETUP + LINK ----
        daemon_a = start([daemon, "--config", str(cfg_da)], temp_dir / "daemon-a.log")
        daemon_b = start_daemon_b()
        wait_for_health(base_a, "daemon A")
        wait_for_health(base_b, "daemon B")
        bridge_a = start_bridge_a()
        bridge_b = start_bridge_b()

        operator_a = request(base_a, "/user-client/register", "POST", {"user_id": "op@a", "client_instance_id": "ui-a", "client_token": ""})["client_token"]
        operator_b = request(base_b, "/user-client/register", "POST", {"user_id": "op@b", "client_instance_id": "ui-b", "client_token": ""})["client_token"]

        sender_id = "planner@home-a"
        receiver_id = "reviewer@home-b"
        sender_token = request(base_a, "/register", "POST", {"agent_instance_id": sender_id, "display_name": sender_id})["agent_token"]
        receiver_token = request(base_b, "/register", "POST", {"agent_instance_id": receiver_id, "display_name": receiver_id})["agent_token"]
        conversation_b = conv_id(receiver_id)

        wait_for(lambda: peer_status(base_a, operator_a) == "linked", "bridge A never linked")
        wait_for(lambda: peer_status(base_b, operator_b) == "linked", "bridge B never linked")

        bind = request(base_a, "/federation/proxies/bind", "POST", {
            "peer_id": "home-b",
            "origin_daemon_id": "home-b",
            "remote_agent_instance_id": receiver_id,
            "display_name": "Remote Reviewer (B)",
            "template_id": "reviewer",
            "template_id": "reviewer",
        }, headers={"Authorization": f"Bearer {operator_a}"})
        proxy_id = bind["agent"]["agent_instance_id"]
        ok(f"D0 linked; remote_proxy {proxy_id} -> {receiver_id}@home-b")

        # ---- D1. BRIDGE DOWN: kill bridge B -> A sees peer unreachable ----
        stop(bridge_b)
        bridge_b = None
        wait_for(lambda: peer_status(base_a, operator_a) == "unreachable", "peer A did not flip to unreachable after bridge B died", timeout=30.0)
        ok("D1 bridge B killed; A observes peer `unreachable` (session-presence liveness)")

        # ---- D2. SEND WHILE DOWN: durable-accept (queued), not lost ----
        send1 = request(base_a, "/agent-rpc", "POST", {
            "agent_token": sender_token,
            "action": "send_message",
            "target_agent_instance_id": proxy_id,
            "body": "msg-while-bridge-down",
        }, expect=202)
        require(send1.get("message_id"), f"send while down should still be accepted+queued: {send1}")
        # It must NOT be on B yet (peer is offline).
        require(count_body_on_b(base_b, receiver_token, conversation_b, "msg-while-bridge-down") == 0,
                "message must not reach B while the bridge is down")
        ok("D2 send while peer down is durably accepted (queued to A outbox), not delivered/lost")

        # ---- D3. RECONNECT: restart bridge B -> peer linked again ----
        bridge_b = start_bridge_b()
        wait_for(lambda: peer_status(base_a, operator_a) == "linked", "peer A did not relink after bridge B restart", timeout=30.0)
        ok("D3 bridge B restarted; A observes peer `linked` again")

        # ---- D4. EVENTUAL CONSISTENCY: queued DM delivers with no manual retry ----
        wait_for(lambda: count_body_on_b(base_b, receiver_token, conversation_b, "msg-while-bridge-down") == 1,
                 "queued DM never reached B after reconnect (eventual consistency failure)",
                 timeout=40.0)
        ok("D4 queued DM eventually delivered to B after reconnect (poll-driven outbox replay)")

        # ---- D5. PEER DAEMON RESTART: kill daemon B entirely, send, restart ----
        stop(bridge_b); bridge_b = None
        stop(daemon_b); daemon_b = None
        wait_for(lambda: peer_status(base_a, operator_a) == "unreachable", "peer A did not flip unreachable after daemon B died", timeout=30.0)
        send2 = request(base_a, "/agent-rpc", "POST", {
            "agent_token": sender_token,
            "action": "send_message",
            "target_agent_instance_id": proxy_id,
            "body": "msg-while-daemon-down",
        }, expect=202)
        require(send2.get("message_id"), f"send while daemon down should be accepted+queued: {send2}")
        # Restart the whole peer home + its bridge.
        daemon_b = start_daemon_b()
        wait_for_health(base_b, "daemon B (restarted)")
        receiver_token = request(base_b, "/register", "POST", {"agent_instance_id": receiver_id, "display_name": receiver_id})["agent_token"]
        bridge_b = start_bridge_b()
        wait_for(lambda: peer_status(base_a, operator_a) == "linked", "peer A did not relink after daemon B restart", timeout=30.0)
        wait_for(lambda: count_body_on_b(base_b, receiver_token, conversation_b, "msg-while-daemon-down") == 1,
                 "2nd DM never reached B after full peer restart",
                 timeout=40.0)
        ok("D5 DM sent during full peer-daemon outage eventually delivered after peer restart")

        # ---- D6. NO DUP: idempotency across retries ----
        require(count_body_on_b(base_b, receiver_token, conversation_b, "msg-while-bridge-down") == 1,
                "duplicate of msg-while-bridge-down detected on B")
        require(count_body_on_b(base_b, receiver_token, conversation_b, "msg-while-daemon-down") == 1,
                "duplicate of msg-while-daemon-down detected on B")
        ok("D6 exactly one copy of each message on B (idempotency holds across retries)")

        print("\nbridge_federation_disconnect_recovery_e2e: ok")
        print(f"checks passed: {len(PASSED)}")
    finally:
        for proc in (bridge_a, bridge_b, daemon_a, daemon_b):
            stop(proc)
        if os.environ.get("KEEP_LOGS"):
            print(f"logs kept: {temp_dir}")
        else:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
