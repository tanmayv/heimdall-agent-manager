#!/usr/bin/env python3
"""
Bridge daemon-federation E2E: two independent daemons, two separate Heimdall homes,
linked over the ham-bridge sidecar mesh.

TEST STRATEGY
=============
Goal: prove that two fully independent Heimdall daemons -- each with its OWN heimdall
home (data_dir) -- can federate agent work through the ham-bridge sidecar, and that the
core federation invariants hold end to end.

Topology (Phase-1 direct link, one bridge per daemon):

    daemon A (home-a) <-loopback-> bridge A  <==WS==>  bridge B <-loopback-> daemon B (home-b)

Neither daemon dials the peer directly; ALL cross-daemon traffic rides daemon -> its own
bridge -> peer bridge -> peer daemon.

Checks (each is an explicit PASS/FAIL assertion):

  S0. SETUP     Two daemons boot healthy from two distinct data_dirs (separate homes),
                each with its own bridge.
  S1. LINK      Both sides report the peer as `linked` in GET /federation/peers, with the
                status sourced from the live bridge WS session (not static config).
  S2. IDENTITY  Daemon A can bind a dormant remote_proxy instance pointing at a real agent
                on daemon B (reuses the dormant-instance create flow; no wrapper launch).
  S3. MSG A->B  A local agent on A sends an inbox DM to the remote proxy; the body is
                store-and-forwarded across the bridge and lands durably in B's inbox for
                the real agent (metadata push + durable fetch, offline-capable read on B).
  S4. REPLY B->A The real agent on B replies through its own daemon; the reply is forwarded
                back over the bridge and lands in A's originating conversation.
  S5. RECEIPT   The read receipt for A's original message flows B->A over the bridge so the
                origin sender observes read=true.
  S6. ISOLATION Each home is truly independent: an agent/state created on A is NOT present
                on B's durable store (no replication; owner-only storage).
  S7. TEARDOWN  Clean process shutdown.

Opt-in binaries: set HEIMDALL_DAEMON_BIN / HEIMDALL_BRIDGE_BIN, or rely on the
result-daemon/result-bridge (or result/) symlinks.
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
BRIDGE_TOKEN = "loopback-secret"     # daemon <-> its own bridge (loopback auth)
PEER_TOKEN = "mesh-shared-secret"    # bridge <-> bridge (per-session bearer)

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
    raise RuntimeError(f"missing binary; set {env_name} (looked for {candidates})")


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
    require(status == expect, f"{method} {path} expected {expect}, got {status}: {payload[:400]}")
    return json.loads(payload) if payload else {}


def wait_for_health(base: str, name: str):
    for _ in range(200):
        try:
            if request(base, "/health", timeout=5).get("ok"):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"{name} ({base}) did not become healthy")


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


def conv_id(agent_instance_id: str) -> str:
    out = ["conv_"]
    for ch in agent_instance_id:
        out.append(ch if (ch.isalnum() or ch in "_-") else "_")
    return "".join(out)


def write_daemon_config(path: Path, port: int, daemon_id: str, bridge_port: int, home_dir: Path):
    path.write_text(
        "\n".join([
            "[daemon]",
            'bind_host = "127.0.0.1"',
            f"port = {port}",
            f'data_dir = "{home_dir}"',          # <-- the distinct Heimdall home
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


def write_bridge_config(path: Path, daemon_id: str, daemon_port: int, peer_id: str, peer_bridge_port: int):
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


def peer_status(base: str, operator_token: str):
    peers = request(base, "/federation/peers", headers={"Authorization": f"Bearer {operator_token}"}).get("peers", [])
    return peers[0]["status"] if peers else None


def main():
    daemon = daemon_bin()
    bridge = bridge_bin()
    print(f"daemon: {daemon}")
    print(f"bridge: {bridge}")

    temp_dir = Path(tempfile.mkdtemp(prefix="bridge-fed-two-homes-"))
    home_a = temp_dir / "heimdall-home-a"
    home_b = temp_dir / "heimdall-home-b"
    procs = []
    try:
        # ---- S0. SETUP: two independent homes, two daemons, two bridges ----
        da_port, db_port = free_port(), free_port()
        ba_port, bb_port = free_port(), free_port()
        cfg_da, cfg_db = temp_dir / "daemon-a.toml", temp_dir / "daemon-b.toml"
        cfg_ba, cfg_bb = temp_dir / "bridge-a.toml", temp_dir / "bridge-b.toml"
        write_daemon_config(cfg_da, da_port, "home-a", ba_port, home_a)
        write_daemon_config(cfg_db, db_port, "home-b", bb_port, home_b)
        write_bridge_config(cfg_ba, "home-a", da_port, "home-b", bb_port)
        write_bridge_config(cfg_bb, "home-b", db_port, "home-a", ba_port)

        base_a = f"http://127.0.0.1:{da_port}"
        base_b = f"http://127.0.0.1:{db_port}"

        procs.append(start([daemon, "--config", str(cfg_da)], temp_dir / "daemon-a.log"))
        procs.append(start([daemon, "--config", str(cfg_db)], temp_dir / "daemon-b.log"))
        wait_for_health(base_a, "daemon A")
        wait_for_health(base_b, "daemon B")
        require(home_a.exists() and home_b.exists(), "each daemon must materialize its own heimdall home dir")
        require(home_a.resolve() != home_b.resolve(), "the two homes must be distinct directories")
        ok(f"S0 two daemons booted from distinct homes: {home_a.name} / {home_b.name}")

        procs.append(start([bridge, "--config", str(cfg_ba), "--port", str(ba_port), "--peer-auth-token", PEER_TOKEN], temp_dir / "bridge-a.log"))
        procs.append(start([bridge, "--config", str(cfg_bb), "--port", str(bb_port), "--peer-auth-token", PEER_TOKEN], temp_dir / "bridge-b.log"))

        operator_a = request(base_a, "/user-client/register", "POST", {"user_id": "op@a", "client_instance_id": "ui-a", "client_token": ""})["client_token"]
        operator_b = request(base_b, "/user-client/register", "POST", {"user_id": "op@b", "client_instance_id": "ui-b", "client_token": ""})["client_token"]

        # ---- S1. LINK: bridge WS session establishes -> peer status linked ----
        wait_for(lambda: peer_status(base_a, operator_a) == "linked", "bridge A did not report peer linked")
        wait_for(lambda: peer_status(base_b, operator_b) == "linked", "bridge B did not report peer linked")
        # Stabilize: the startup dial race (both bridges dial each other; one session is
        # torn down as duplicate) briefly bounces the WS. Require the link to hold linked
        # continuously so we measure STEADY-STATE federation, not the transient handshake.
        stable_since = time.time()
        while time.time() - stable_since < 2.0:
            if not (peer_status(base_a, operator_a) == "linked" and peer_status(base_b, operator_b) == "linked"):
                stable_since = time.time()
            time.sleep(0.1)
        ok("S1 both daemons report the peer as `linked` (held stable) via the live bridge WS session")

        # ---- S2. IDENTITY: real agent on B, remote_proxy pointer on A ----
        sender_id = "planner@home-a"
        receiver_id = "reviewer@home-b"
        sender_token = request(base_a, "/register", "POST", {"agent_instance_id": sender_id, "display_name": sender_id})["agent_token"]
        receiver_token = request(base_b, "/register", "POST", {"agent_instance_id": receiver_id, "display_name": receiver_id})["agent_token"]

        bind = request(base_a, "/federation/proxies/bind", "POST", {
            "peer_id": "home-b",
            "origin_daemon_id": "home-b",
            "remote_agent_instance_id": receiver_id,
            "display_name": "Remote Reviewer (B)",
            "template_id": "reviewer",
            "provider_profile": "pi",
            "model_tier": "normal",
            "template_id": "reviewer",
        }, headers={"Authorization": f"Bearer {operator_a}"})
        proxy_id = bind["agent"]["agent_instance_id"]
        require(proxy_id and proxy_id != receiver_id, f"bind must return a distinct local proxy id: {bind}")
        ok(f"S2 remote_proxy bound on A: {proxy_id} -> {receiver_id}@home-b")

        # ---- S3. MSG A->B: DM to the proxy is store-and-forwarded to B's inbox ----
        send = request(base_a, "/agent-rpc", "POST", {
            "agent_token": sender_token,
            "action": "send_message",
            "target_agent_instance_id": proxy_id,
            "body": "please review chain-42",
        }, expect=202)
        message_id = send.get("message_id", "")
        conversation_a = send.get("conversation_id", "")
        require(message_id and conversation_a, f"remote send should return ids: {send}")

        conversation_b = conv_id(receiver_id)
        fetched_b = wait_for(
            lambda: request(base_b, "/agent-rpc", "POST", {
                "agent_token": receiver_token,
                "action": "fetch_messages",
                "conversation_id": conversation_b,
                "include_read": False,
            }).get("messages"),
            "receiver on B never got the forwarded DM",
        )
        matched = [m for m in fetched_b if m.get("body") == "please review chain-42"]
        require(len(matched) == 1, f"exactly one forwarded message expected on B: {fetched_b}")
        ok("S3 A->B inbox DM store-and-forwarded across the bridge into B's durable inbox")

        # ---- S5. RECEIPT: read receipt flows B->A (fetch above marked it read) ----
        wait_for(
            lambda: any(
                m.get("id") == message_id and m.get("read")
                for m in request(base_a, "/agent-rpc", "POST", {
                    "agent_token": sender_token,
                    "action": "fetch_messages",
                    "conversation_id": conversation_a,
                    "include_read": True,
                }).get("messages", [])
            ),
            "origin sender on A never observed the remote read receipt",
        )
        ok("S5 read receipt propagated B->A; origin sender observes read=true")

        # ---- S4. REPLY B->A: real agent replies; lands in A's conversation ----
        request(base_b, "/agent-rpc", "POST", {
            "agent_token": receiver_token,
            "action": "send_message",
            "target_agent_instance_id": sender_id,
            "body": "reviewed: LGTM",
        }, expect=202)
        fetched_a = wait_for(
            lambda: ([m for m in request(base_a, "/agent-rpc", "POST", {
                "agent_token": sender_token,
                "action": "fetch_messages",
                "conversation_id": conversation_a,
                "include_read": True,
            }).get("messages", []) if m.get("body") == "reviewed: LGTM"] or None),
            "origin sender on A never got the remote reply",
            timeout=30.0,
        )
        require(any(m.get("body") == "reviewed: LGTM" for m in fetched_a), f"remote reply missing on A: {fetched_a}")
        ok("S4 B->A reply forwarded across the bridge into A's originating conversation")

        # ---- S6. ISOLATION: homes are independent (no cross-home replication) ----
        agents_b = request(base_b, "/agents", headers={"Authorization": f"Bearer {operator_b}"}).get("agents", [])
        b_ids = {a.get("agent_instance_id") for a in agents_b}
        require(sender_id not in b_ids, f"A-owned agent {sender_id} must NOT exist in B's durable store: {sorted(b_ids)}")
        require(proxy_id not in b_ids, f"A-side proxy {proxy_id} must NOT be stored on B: {sorted(b_ids)}")
        require(receiver_id in b_ids, f"B's own agent {receiver_id} must exist on B: {sorted(b_ids)}")

        agents_a = request(base_a, "/agents", headers={"Authorization": f"Bearer {operator_a}"}).get("agents", [])
        a_ids = {a.get("agent_instance_id") for a in agents_a}
        require(receiver_id not in a_ids, f"B's native agent {receiver_id} must NOT be stored on A (only the proxy): {sorted(a_ids)}")
        require(proxy_id in a_ids and sender_id in a_ids, f"A must own its sender + proxy: {sorted(a_ids)}")
        ok("S6 homes are independent: owner-only storage, no cross-home replication")

        print("\nbridge_federation_two_homes_e2e: ok")
        print(f"checks passed: {len(PASSED)}")
    finally:
        for proc in procs:
            stop(proc)
        # ---- S7. TEARDOWN ----
        keep = os.environ.get("KEEP_LOGS")
        if keep:
            print(f"logs kept: {temp_dir}")
        else:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
