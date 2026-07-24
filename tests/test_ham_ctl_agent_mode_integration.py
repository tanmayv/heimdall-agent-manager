#!/usr/bin/env python3
"""Integration test for ham-ctl agent mode against a mock local Bridge endpoint.

Builds ham-ctl, stands up a mock JSONL v1 TCP endpoint, and drives the real
`ham-ctl agent` binary through the local endpoint contract (RTE2E-7):
- request envelope (v=1, id, token, method, params),
- success response passthrough,
- clear offline error when the endpoint is unreachable.
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = Path("/tmp/ham-ctl-rte2e7/bin/ham-ctl")


def require(cond, msg):
    if not cond:
        print(f"FAIL: {msg}", file=sys.stderr)
        sys.exit(1)


def build_binary():
    subprocess.run(
        ["nix", "build", ".#ham-ctl", "-o", str(BIN.parent.parent)],
        cwd=ROOT, check=True, capture_output=True,
    )


class MockEndpoint:
    """A one-shot JSONL v1 TCP endpoint that captures the request and replies."""

    def __init__(self):
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.captured = None
        self.reply = '{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"agent_instance_id":"inst_mock"}}'

    def serve_once(self):
        conn, _ = self.listener.accept()
        conn.settimeout(5)
        try:
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            self.captured = data.decode().strip()
            conn.sendall((self.reply + "\n").encode())
        finally:
            conn.close()

    def close(self):
        self.listener.close()


def run_agent(args, env_extra=None):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(
        [str(BIN), "agent"] + args,
        capture_output=True, text=True, timeout=15, env=env,
    )
    return proc


def main():
    if not BIN.exists():
        build_binary()
    require(BIN.exists(), "ham-ctl binary must build")

    # --- missing endpoint/token -> usage -----------------------------------
    proc = run_agent(["--bridge-endpoint", "tcp:127.0.0.1:1", "context"],
                     env_extra={"HEIMDALL_AGENT_TOKEN": "hlat_test"})
    require(proc.returncode != 0 or "reachable" in proc.stdout,
            "missing endpoint should not silently succeed")

    # --- offline endpoint -> clear error -----------------------------------
    proc = run_agent(["--bridge-endpoint", "tcp:127.0.0.1:1",
                      "--agent-token", "hlat_test", "context"])
    require("reachable" in proc.stdout,
            f"offline endpoint must report clear error; got: {proc.stdout!r}")

    # --- live endpoint: context.get round-trip -----------------------------
    mock = MockEndpoint()
    t = threading.Thread(target=mock.serve_once)
    t.start()
    proc = run_agent([
        "--bridge-endpoint", f"tcp:127.0.0.1:{mock.port}",
        "--agent-token", "hlat_test_token", "context",
    ])
    t.join(timeout=10)
    mock.close()

    require(proc.returncode == 0, f"agent context should succeed; stderr={proc.stderr!r}")
    require(mock.captured is not None, "endpoint must capture the request line")
    req = json.loads(mock.captured)
    require(req["v"] == 1, "request must declare protocol v1")
    require(req["token"] == "hlat_test_token", "request must carry the local agent token")
    require(req["method"] == "agent.context.get", "request method must be agent.context.get")
    require("params" in req, "request must carry params object")
    require("agent_instance_id" in proc.stdout,
            f"stdout must pass through the endpoint data; got: {proc.stdout!r}")

    # --- env discovery (no flags) ------------------------------------------
    mock2 = MockEndpoint()
    t2 = threading.Thread(target=mock2.serve_once)
    t2.start()
    proc2 = run_agent(["start-success"],
                      env_extra={
                          "HEIMDALL_BRIDGE_ENDPOINT": f"tcp:127.0.0.1:{mock2.port}",
                          "HEIMDALL_AGENT_TOKEN": "hlat_env_token",
                      })
    t2.join(timeout=10)
    mock2.close()
    require(mock2.captured is not None, "env-based endpoint discovery must connect")
    req2 = json.loads(mock2.captured)
    require(req2["token"] == "hlat_env_token",
            "token must be discovered from HEIMDALL_AGENT_TOKEN env")
    require(req2["method"] == "agent.start_success",
            "start-success subcommand must map to agent.start_success")

    print("PASS: ham-ctl agent mode integration")


if __name__ == "__main__":
    main()
