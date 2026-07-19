#!/usr/bin/env python3
"""
Bridge daemon-federation E2E: one-way outbound dialing with bidirectional work.

Goal: prove the deterministic single-dialer design still carries B->A pushes
and inbox delivery over the single websocket session that only A dials.

Topology:

    daemon A (alpha) <-loopback-> bridge A  ==WS(dialed by A only)==>  bridge B <-loopback-> daemon B (zulu)

Checks:
  W0 setup             two homes boot with one bridge per daemon
  W1 directional dial  alpha dials zulu; zulu stays deterministic_acceptor-only
  W2 B->A push         zulu bridge sends a federation inbox push to alpha over A's dialed session
  W3 A durable fetch   alpha's target agent fetches exactly one delivered remote message
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
    data = json.dumps(body, separators=(",", ":")).encode("utf-8") if body is not None else None
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


def wait_for(predicate, message: str, timeout: float = 20.0, interval: float = 0.2):
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


def wait_for_health(base: str, name: str):
    for _ in range(200):
        try:
            if request(base, "/health", timeout=5).get("ok"):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"{name} ({base}) did not become healthy")


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


def bridge_send(base: str, dest_daemon_id: str, payload: dict, idempotency_key: str):
    return request(
        base,
        "/bridge/send",
        "POST",
        {
            "contract_version": 1,
            "src_daemon_id": "zulu",
            "dest_daemon_id": dest_daemon_id,
            "route_kind": "federation_inbox",
            "idempotency_key": idempotency_key,
            "payload": json.dumps(payload),
            "created_unix_ms": int(time.time() * 1000),
        },
        headers={"Authorization": f"Bearer {BRIDGE_TOKEN}"},
        expect=202,
    )


def stop(proc):
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)


def log_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""


def main():
    daemon = daemon_bin()
    bridge = bridge_bin()
    print(f"daemon: {daemon}")
    print(f"bridge: {bridge}")

    temp_dir = Path(tempfile.mkdtemp(prefix="bridge-one-way-"))
    home_a = temp_dir / "heimdall-home-a"
    home_b = temp_dir / "heimdall-home-b"
    procs = []
    try:
        da_port, db_port = free_port(), free_port()
        ba_port, bb_port = free_port(), free_port()
        cfg_da, cfg_db = temp_dir / "daemon-a.toml", temp_dir / "daemon-b.toml"
        cfg_ba, cfg_bb = temp_dir / "bridge-a.toml", temp_dir / "bridge-b.toml"
        log_ba, log_bb = temp_dir / "bridge-a.log", temp_dir / "bridge-b.log"

        # alpha < zulu, so deterministic BR-3 ordering means only A dials.
        write_daemon_config(cfg_da, da_port, "alpha", ba_port, home_a)
        write_daemon_config(cfg_db, db_port, "zulu", bb_port, home_b)
        write_bridge_config(cfg_ba, "alpha", da_port, "zulu", bb_port)
        write_bridge_config(cfg_bb, "zulu", db_port, "alpha", ba_port)

        base_a = f"http://127.0.0.1:{da_port}"
        base_b = f"http://127.0.0.1:{db_port}"

        procs.append(start([daemon, "--config", str(cfg_da)], temp_dir / "daemon-a.log"))
        procs.append(start([daemon, "--config", str(cfg_db)], temp_dir / "daemon-b.log"))
        wait_for_health(base_a, "daemon A")
        wait_for_health(base_b, "daemon B")

        target_a = "planner@alpha"
        target_a_token = request(base_a, "/register", "POST", {"agent_instance_id": target_a, "display_name": target_a})["agent_token"]
        source_b = "reviewer@zulu"
        _ = request(base_b, "/register", "POST", {"agent_instance_id": source_b, "display_name": source_b})["agent_token"]

        procs.append(start([bridge, "--config", str(cfg_ba), "--port", str(ba_port), "--peer-auth-token", PEER_TOKEN], log_ba))
        procs.append(start([bridge, "--config", str(cfg_bb), "--port", str(bb_port), "--peer-auth-token", PEER_TOKEN], log_bb))
        ok("W0 two daemons and two bridges booted with isolated homes")

        wait_for(lambda: "bridge ws dial begin zulu" in log_text(log_ba), "A never initiated the outbound dial to zulu")
        wait_for(lambda: "bridge ws linked zulu" in log_text(log_ba), "A never linked its outbound websocket")
        wait_for(lambda: "bridge ws dial skipped deterministic_acceptor alpha self zulu" in log_text(log_bb), "B never entered deterministic acceptor-only mode")
        wait_for(lambda: "bridge ws accepted alpha" in log_text(log_bb), "B never accepted A's dialed websocket")
        require("bridge ws dial begin alpha" not in log_text(log_bb), f"B must not initiate an outbound dial to A:\n{log_text(log_bb)}")
        ok("W1 only A dialed; B stayed acceptor-only and still accepted the session")

        delivery = bridge_send(
            f"http://127.0.0.1:{bb_port}",
            "alpha",
            {
                "kind": "inbox_message",
                "idempotency_key": "msg:zulu-one-way-1",
                "origin_daemon_id": "zulu",
                "message_id": "zulu-one-way-1",
                "from_agent_instance_id": source_b,
                "from_native_id": source_b,
                "target_agent_instance_id": target_a,
                "target_native_id": target_a,
                "proxy_agent_instance_id": "",
                "origin_conversation_id": conv_id(source_b),
                "body": "one-way bridge delivery from zulu",
                "created_unix_ms": int(time.time() * 1000),
            },
            "msg:zulu-one-way-1",
        )
        require(delivery.get("acceptance") == "accepted_queued", f"bridge send should be accepted over the A-dialed session: {delivery}")
        ok("W2 zulu bridge accepted a B->A federation inbox push over A's dialed session")

        fetched_a = wait_for(
            lambda: request(base_a, "/agent-rpc", "POST", {
                "agent_token": target_a_token,
                "action": "fetch_messages",
                "conversation_id": conv_id(target_a),
                "include_read": True,
            }).get("messages"),
            "alpha target agent never observed the B->A bridge push",
            timeout=30.0,
        )
        matched = [m for m in fetched_a if m.get("body") == "one-way bridge delivery from zulu"]
        require(len(matched) == 1, f"expected exactly one B->A delivered message on alpha: {fetched_a}")
        ok("W3 alpha fetched exactly one durable B->A message without any reverse dial")

        print("\nbridge_one_way_reachability_e2e: ok")
        print(f"checks passed: {len(PASSED)}")
    finally:
        for proc in procs:
            stop(proc)
        keep = os.environ.get("KEEP_LOGS")
        if keep:
            print(f"logs kept: {temp_dir}")
        else:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
