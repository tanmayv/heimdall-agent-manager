#!/usr/bin/env python3
"""Test the mock agent binary (RTE2E-8 enabler).

Exercises:
1. Mock runs standalone with a replay script (3 commands + gaps).
2. Log file contains each command + stdout, stdin capture, endpoint calls.
3. Mock can call ham-ctl agent against a mock local Bridge endpoint.
4. Mock behaves like a real agent process (reads stdin, exits cleanly on `done`).
"""
import json
import os
import shlex
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOCK = ROOT / "tools" / "mock_agent" / "mock-agent.sh"
HAM_CTL = Path("/tmp/ham-ctl-mock/bin/ham-ctl")
REPLAY_DEMO = ROOT / "tools" / "mock_agent" / "replay.demo.txt"


def require(cond, msg):
    if not cond:
        print(f"FAIL: {msg}", file=sys.stderr)
        sys.exit(1)


def build_ctl():
    subprocess.run(
        ["nix", "build", ".#ham-ctl", "-o", str(HAM_CTL.parent.parent)],
        cwd=ROOT, check=True, capture_output=True,
    )


class MockEndpoint:
    """One-shot-per-connection JSONL endpoint that replies ok to everything."""

    def __init__(self, port):
        self.s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.s.bind(("127.0.0.1", port))
        self.s.listen(4)
        self.port = port
        self.requests = []
        self._stop = False
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        self.s.settimeout(0.5)
        while not self._stop:
            try:
                conn, _ = self.s.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        conn.settimeout(5)
        try:
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            req = data.decode().strip()
            if req:
                self.requests.append(req)
            conn.sendall(b'{"v":1,"id":"mock","ok":true,"data":{"agent_instance_id":"agent_mock","accepted":true}}\n')
        except Exception:
            pass
        finally:
            conn.close()

    def close(self):
        self._stop = True
        try:
            self.s.close()
        except Exception:
            pass


def run_mock(env_extra, timeout=20):
    env = dict(os.environ)
    env.update(env_extra)
    proc = subprocess.run(
        ["/bin/sh", str(MOCK)],
        capture_output=True, text=True, timeout=timeout, env=env,
        stdin=subprocess.PIPE,
    )
    return proc


def main():
    if not HAM_CTL.exists():
        build_ctl()
    require(MOCK.exists(), "mock-agent.sh must exist")
    require(REPLAY_DEMO.exists(), "replay.demo.txt must exist")

    # ── Test 1: standalone replay without endpoint (endpoint_skipped logged) ──
    with tempfile_dir() as workdir:
        log = Path(workdir) / "mock.log"
        env = {
            "HEIMDALL_MOCK_LOG": str(log),
            "HEIMDALL_MOCK_REPLAY": str(REPLAY_DEMO),
            "HOME": os.environ.get("HOME", "/tmp"),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        }
        proc = subprocess.run(
            ["/bin/sh", str(MOCK)], capture_output=True, text=True,
            timeout=20, env={**os.environ, **env},
        )
        require(proc.returncode == 0, f"mock should exit 0 on done; rc={proc.returncode} stderr={proc.stderr!r}")
        log_text = log.read_text()
        require('"kind":"replay_step"' in log_text, "log must record replay steps")
        require('"kind":"replay_done"' in log_text, "log must record clean done exit")
        require('"kind":"run_stdout"' in log_text, "log must record run command stdout")
        require("Step 2 of 3" in log_text, "log must contain run echo output")
        require('"kind":"endpoint_skipped"' in log_text, "log must note skipped endpoint calls (no endpoint)")
        require("Step 3 of 3" in log_text, "echo action must be logged")

    # ── Test 2: with a mock local endpoint — agent makes real ham-ctl calls ───
    ep = MockEndpoint(49601)
    try:
        with tempfile_dir() as workdir:
            log = Path(workdir) / "mock.log"
            replay = Path(workdir) / "replay.txt"
            replay.write_text(
                "sleep 1\nstart-success\nsleep 1\ncontext\nsleep 1\n"
                'say "hello from mock"\nsleep 1\ndone\n'
            )
            env = {
                "HEIMDALL_BRIDGE_ENDPOINT": f"tcp:127.0.0.1:{ep.port}",
                "HEIMDALL_AGENT_TOKEN": "hlat_mock_token",
                "HEIMDALL_AGENT_INSTANCE_ID": "agent_mock_1",
                "HEIMDALL_MOCK_LOG": str(log),
                "HEIMDALL_MOCK_REPLAY": str(replay),
                "HAM_CTL": str(HAM_CTL),
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "HOME": os.environ.get("HOME", "/tmp"),
            }
            proc = subprocess.run(
                ["/bin/sh", str(MOCK)], capture_output=True, text=True,
                timeout=30, env={**os.environ, **env},
            )
            require(proc.returncode == 0, f"mock should exit 0; rc={proc.returncode} stderr={proc.stderr!r}")
            log_text = log.read_text()
            # The mock made real JSONL calls to the endpoint.
            require(len(ep.requests) >= 3, f"endpoint should receive >=3 requests; got {len(ep.requests)}: {ep.requests}")
            methods = []
            for req in ep.requests:
                try:
                    methods.append(json.loads(req).get("method", ""))
                except Exception:
                    pass
            require("agent.start_success" in methods, f"start-success must be called; methods={methods}")
            require("agent.context.get" in methods, f"context must be called; methods={methods}")
            require("agent.chat.send_to_user" in methods, f"chat send must be called; methods={methods}")
            # Token and instance from env used in the wire requests.
            for req in ep.requests:
                parsed = json.loads(req)
                require(parsed.get("token") == "hlat_mock_token", "wire request must carry the agent token")
                require(parsed.get("v") == 1, "wire request must be protocol v1")
            # Log captured the endpoint responses.
            require('"kind":"endpoint_call"' in log_text, "log must record endpoint calls")
            require('"agent_instance_id":"agent_mock"' in log_text, "log must record endpoint response data")
    finally:
        ep.close()

    # ── Test 3: stdin capture (tmux send-keys input) ──────────────────────────
    with tempfile_dir() as workdir:
        log = Path(workdir) / "mock.log"
        replay = Path(workdir) / "replay.txt"
        replay.write_text("sleep 2\ndone\n")
        env = {
            "HEIMDALL_MOCK_LOG": str(log),
            "HEIMDALL_MOCK_REPLAY": str(replay),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": os.environ.get("HOME", "/tmp"),
        }
        proc = subprocess.run(
            ["/bin/sh", str(MOCK)], input="hello via stdin\nsecond line\n",
            capture_output=True, text=True, timeout=20, env={**os.environ, **env},
        )
        log_text = log.read_text()
        require('"kind":"stdin"' in log_text, "log must capture stdin lines")
        require("hello via stdin" in log_text, "stdin content must be logged")

    print("PASS: mock agent standalone test")


def tempfile_dir():
    import tempfile
    d = tempfile.mkdtemp(prefix="mock-agent-test-")
    return _Ctx(d)


class _Ctx:
    def __init__(self, path):
        self.path = path
    def __enter__(self):
        return self.path
    def __exit__(self, *a):
        import shutil
        shutil.rmtree(self.path, ignore_errors=True)


if __name__ == "__main__":
    main()
