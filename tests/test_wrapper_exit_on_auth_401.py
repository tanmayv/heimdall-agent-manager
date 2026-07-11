#!/usr/bin/env python3
"""Regression: wrapper exits on daemon 401 auth failure during heartbeat.

Starts a tiny fake daemon + websocket endpoint, runs ham-wrapper against it in an
isolated tmux session/run dir, and verifies the wrapper exits quickly after the
first heartbeat returns HTTP 401.
"""

from __future__ import annotations

import http.server
import json
import shutil
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
from pathlib import Path

HOST = "127.0.0.1"
HTTP_PORT = 49451
WS_PORT = 49452


def bin_path(repo: Path, preferred: str, fallback: str, binary: str) -> str:
    preferred_path = repo / preferred / "bin" / binary
    if preferred_path.exists():
        return str(preferred_path)
    return str(repo / fallback / "bin" / binary)


class FakeDaemonHandler(http.server.BaseHTTPRequestHandler):
    heartbeat_count = 0

    def log_message(self, fmt: str, *args) -> None:
        return

    def _write_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._write_json(200, {"ok": True, "protocol_version": 1})
            return
        self._write_json(404, {"ok": False, "message": "not found"})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b"{}"
        _ = json.loads(body.decode() or "{}")

        if self.path == "/register":
            self._write_json(
                200,
                {
                    "agent_instance_id": "fake401@default",
                    "agent_class": "fake401",
                    "conversation_id": "conv_fake401_default",
                    "ws_url": f"ws://{HOST}:{WS_PORT}/ws/fake401@default",
                    "agent_token": "agt_test_fake401",
                    "preferences": {},
                },
            )
            return

        if self.path == "/startup":
            self._write_json(200, {"ok": True})
            return

        if self.path == "/projects/show":
            self._write_json(200, {"ok": True, "project_id": "default", "name": "default"})
            return

        if self.path == "/heartbeat":
            FakeDaemonHandler.heartbeat_count += 1
            self._write_json(401, {"ok": False, "error": "token_not_found", "message": "forced auth failure"})
            return

        self._write_json(404, {"ok": False, "message": "not found"})


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class FakeWsServer(threading.Thread):
    def __init__(self) -> None:
        super().__init__(daemon=True)
        self._stop = threading.Event()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((HOST, WS_PORT))
        self.sock.listen(5)
        self.connections: list[socket.socket] = []

    def run(self) -> None:
        self.sock.settimeout(0.2)
        while not self._stop.is_set():
            try:
                conn, _addr = self.sock.accept()
            except socket.timeout:
                continue
            conn.settimeout(1)
            request = b""
            while b"\r\n\r\n" not in request:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                request += chunk
            conn.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\n"
                b"Connection: Upgrade\r\n"
                b"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
            )
            self.connections.append(conn)

    def close(self) -> None:
        self._stop.set()
        try:
            self.sock.close()
        except OSError:
            pass
        for conn in self.connections:
            try:
                conn.close()
            except OSError:
                pass


def write_config(path: Path, session_name: str) -> None:
    path.write_text(
        f'''
[wrapper]
agent_name = "fake"
daemon_url = "http://{HOST}:{HTTP_PORT}"
ham_ctl_bin = "/usr/bin/true"
tmux_session = "{session_name}"
agent_run_dir = "{path.parent / 'runs'}"
command = ["/bin/sh", "-lc", "sleep 30"]

[wrapper.agent-cmd.fake]
command = ["/bin/sh", "-lc", "sleep 30"]
prompt_flags = []
yolo_flags = []
starter_prompt = ""

[wrapper.agent-cmd.fake.models]
flag = "--model"
cheap = "none"
normal = "none"
smart = "none"

[wrapper.agent-cmd.fake.startup_detection]
enabled = false
''',
        encoding="utf-8",
    )


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    wrapper_bin = bin_path(repo, "result-wrapper", "result-1", "ham-wrapper")
    temp_dir = Path(tempfile.mkdtemp(prefix="heimdall-wrapper-401-"))
    httpd = ThreadedHTTPServer((HOST, HTTP_PORT), FakeDaemonHandler)
    http_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    ws_server = FakeWsServer()
    config_path = temp_dir / "config.toml"
    session_name = f"ham-test-401-{int(time.time())}"
    write_config(config_path, session_name)

    http_thread.start()
    ws_server.start()

    proc = None
    try:
        proc = subprocess.Popen(
            [wrapper_bin, "--config", str(config_path), "--agent", "fake", "fake401@default"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            stdout, _ = proc.communicate(timeout=12)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, _ = proc.communicate()
            raise SystemExit(f"wrapper did not exit after heartbeat 401\n{stdout}")

        if FakeDaemonHandler.heartbeat_count < 1:
            raise SystemExit(f"wrapper never sent heartbeat\n{stdout}")
        if "AUTH FAILURE: closing wrapper" not in stdout:
            raise SystemExit(f"wrapper did not log auth-failure shutdown\n{stdout}")
        if proc.returncode not in (0, 1):
            raise SystemExit(f"unexpected wrapper exit code {proc.returncode}\n{stdout}")

        print(json.dumps({
            "ok": True,
            "heartbeat_count": FakeDaemonHandler.heartbeat_count,
            "returncode": proc.returncode,
        }, indent=2, sort_keys=True))
        print("WRAPPER 401 EXIT TEST PASSED")
    finally:
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
        httpd.shutdown()
        httpd.server_close()
        ws_server.close()
        subprocess.run(["tmux", "kill-session", "-t", session_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
