#!/usr/bin/env python3
"""HBR-27 real-binary HTTPS/WSS smoke via a local TLS TCP proxy."""
from __future__ import annotations

import json
import os
import select
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_get(url: str, timeout: float = 10.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=0.5):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"timed out waiting for {url}")


def request(method: str, url: str, body: dict | None = None, headers: dict[str, str] | None = None) -> tuple[int, dict]:
    data = None if body is None else json.dumps(body).encode()
    req_headers = {"Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode())


class TlsTcpProxy:
    def __init__(self, listen_port: int, target_port: int, cert: Path, key: Path) -> None:
        self.listen_port = listen_port
        self.target_port = target_port
        self.cert = cert
        self.key = key
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.ready = threading.Event()
        self.sock: socket.socket | None = None

    def start(self) -> None:
        self.thread.start()
        if not self.ready.wait(5):
            raise RuntimeError("TLS proxy did not start")

    def close(self) -> None:
        self.stop.set()
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.thread.join(timeout=2)

    def run(self) -> None:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(self.cert), str(self.key))
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", self.listen_port))
        srv.listen(20)
        srv.settimeout(0.2)
        self.sock = srv
        self.ready.set()
        while not self.stop.is_set():
            try:
                client, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self.handle, args=(ctx, client), daemon=True).start()

    def handle(self, ctx: ssl.SSLContext, raw_client: socket.socket) -> None:
        try:
            with ctx.wrap_socket(raw_client, server_side=True) as client, socket.create_connection(("127.0.0.1", self.target_port), timeout=5) as upstream:
                client.setblocking(False)
                upstream.setblocking(False)
                sockets = [client, upstream]
                deadline = time.time() + 30
                while time.time() < deadline:
                    readable, _, _ = select.select(sockets, [], [], 0.2)
                    if not readable:
                        continue
                    for src in readable:
                        try:
                            data = src.recv(65536)
                        except (ssl.SSLWantReadError, BlockingIOError):
                            continue
                        if not data:
                            return
                        dst = upstream if src is client else client
                        dst.sendall(data)
        except Exception:
            try:
                raw_client.close()
            except OSError:
                pass


def wait_bridge_online(base: str, bridge_id: str, headers: dict[str, str], timeout: float = 15.0) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        st, detail = request("GET", f"{base}/bridges/{bridge_id}", headers=headers)
        if st == 200 and detail["data"].get("status") == "online":
            return detail
        time.sleep(0.25)
    raise RuntimeError(f"bridge {bridge_id} did not become online")


def main() -> None:
    hub_bin = Path(os.environ.get("HAM_HUB_BIN", "/tmp/ham-hub-hbr27"))
    bridge_bin = Path(os.environ.get("HAM_BRIDGE_BIN", "/tmp/ham-bridge-hbr27"))
    if not hub_bin.exists():
        raise SystemExit(f"missing HAM_HUB_BIN: {hub_bin}")
    if not bridge_bin.exists():
        raise SystemExit(f"missing HAM_BRIDGE_BIN: {bridge_bin}")

    hub_port = free_port()
    tls_port = free_port()
    bridge_port = free_port()
    base = f"http://127.0.0.1:{hub_port}/api/v1"
    alice = {"X-authentik-username": "alice"}
    with tempfile.TemporaryDirectory(prefix="ham-hbr27-") as tmp_s:
        tmp = Path(tmp_s)
        cert = tmp / "localhost.crt"
        key = tmp / "localhost.key"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
            "-keyout", str(key), "-out", str(cert),
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        hub = subprocess.Popen([str(hub_bin), "--listen", f"127.0.0.1:{hub_port}", "--db", str(tmp / "hub.db"), "--logout-url", "/_dev/logout"], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        bridge = None
        proxy = None
        try:
            wait_get(f"{base}/health")
            proxy = TlsTcpProxy(tls_port, hub_port, cert, key)
            proxy.start()
            env = {**os.environ, "HAM_TLS_CA_FILE": str(cert)}
            https_hub = f"https://localhost:{tls_port}"
            untrusted = subprocess.run([str(bridge_bin), "enroll", "--config", str(tmp / "untrusted.toml"), "--hub", https_hub, "--enrollment-token", "hbe_fake"], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            assert untrusted.returncode != 0, untrusted.stdout

            st, enr = request("POST", f"{base}/bridge-enrollments", {"label": "tls-runtime"}, alice)
            assert st == 201, enr
            cfg = tmp / "bridge.toml"
            out = subprocess.run([str(bridge_bin), "enroll", "--config", str(cfg), "--hub", https_hub, "--enrollment-token", enr["data"]["enrollment_token"]], cwd=ROOT, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
            cfg_text = cfg.read_text()
            assert https_hub in cfg_text and "bridge enrolled" in out, out
            bridge_id = next(line.split("=", 1)[1].strip().strip('"') for line in cfg_text.splitlines() if line.startswith("daemon_id"))
            bridge_token = next(line.split("=", 1)[1].strip().strip('"') for line in cfg_text.splitlines() if line.startswith("bridge_token"))
            st, detail = request("GET", f"{base}/bridges/{bridge_id}", headers=alice)
            assert st == 200 and detail["data"]["hub_url"] == https_hub, detail

            bad = subprocess.run([str(bridge_bin), "--bootstrap-fetch", "--daemon-url", f"https://127.0.0.1:{tls_port}", "--bridge-token", bridge_token, "--instance-id", "inst_bad", "--run-dir", str(tmp / "bad")], cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            assert bad.returncode != 0, bad.stdout

            bridge = subprocess.Popen([str(bridge_bin), "--config", str(cfg), "--bind-host", "127.0.0.1", "--port", str(bridge_port)], cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            wait_bridge_online(base, bridge_id, alice)

            st, agent = request("POST", f"{base}/agents", {"name": "TLS Agent", "slug": "tls-agent", "default_provider": "claude", "default_tier": "normal", "instructions": "TLS smoke"}, alice)
            assert st == 201, agent
            agent_id = agent["data"]["agent_id"]
            st, support = request("PATCH", f"{base}/agents/{agent_id}/bridge-support/{bridge_id}", {"enabled": True, "provider": "claude", "tier": "normal", "priority": 1}, alice)
            assert st == 200, support
            st, project = request("POST", f"{base}/projects", {"name": "TLS Project", "slug": "tls-project", "default_path": "/tmp/hbr27", "vcs_kind": "none"}, alice)
            assert st == 201, project
            st, created = request("POST", f"{base}/agent-instances", {"agent_id": agent_id, "bridge_id": bridge_id, "project_id": project["data"]["project_id"]}, alice)
            assert st == 201, created
            instance_id = created["data"]["agent_instance_id"]
            run_dir = tmp / "bootstrap"
            boot = subprocess.run([str(bridge_bin), "--bootstrap-fetch", "--daemon-url", https_hub, "--bridge-token", bridge_token, "--instance-id", instance_id, "--run-dir", str(run_dir)], cwd=ROOT, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
            assert (run_dir / "AGENTS.md").exists() and "bootstrap materialized" in boot, boot
        except Exception:
            if bridge and bridge.stdout:
                bridge.terminate()
                try: bridge.wait(timeout=3)
                except subprocess.TimeoutExpired: bridge.kill()
                print("--- bridge log ---")
                print(bridge.stdout.read())
                bridge = None
            if hub and hub.stdout:
                hub.terminate()
                try: hub.wait(timeout=3)
                except subprocess.TimeoutExpired: hub.kill()
                print("--- hub log ---")
                print(hub.stdout.read())
            raise
        finally:
            if bridge:
                bridge.terminate()
                try: bridge.wait(timeout=3)
                except subprocess.TimeoutExpired: bridge.kill()
            if proxy:
                proxy.close()
            hub.terminate()
            try: hub.wait(timeout=3)
            except subprocess.TimeoutExpired: hub.kill()
    print("PASS: hub HBR27 TLS real smoke")


if __name__ == "__main__":
    main()
