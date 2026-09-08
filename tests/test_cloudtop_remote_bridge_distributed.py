#!/usr/bin/env python3
"""Automated integration tests for CT-8: Multi-Cloudtop Remote Bridge & Distributed Topology Verification.

Verifies:
1. ham-dev-proxy on port 8989 forwards Bridge WebSocket runtime connections (/api/v1/bridge-ws) and
   token-authenticated enrollment (/api/v1/bridges/enroll) to Hub.
2. Unauthenticated local auto-pairing (/api/v1/bridges/auto-pair) remains strictly forbidden through dev-proxy (403).
3. Remote bridge enrollment over edge gateway using enrollment token (hbe_...).
4. Outbound persistent reverse-tunnel WebSocket (/api/v1/bridge-ws) over the edge gateway using bridge token (hbr_...).
5. Hello handshake, bridge registration, and periodic heartbeat keepalive across the WebSocket.
6. Remote agent instance launch command dispatch from Hub to remote bridge over the established tunnel.
"""
from __future__ import annotations

import base64
import hashlib
import http.server
import json
import os
import socket
import struct
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p

def ws_accept_key(key: str) -> str:
    combined = key.strip() + WS_GUID
    return base64.b64encode(hashlib.sha1(combined.encode()).digest()).decode()

def encode_ws_frame(payload: str, is_client: bool = True) -> bytes:
    data = payload.encode("utf-8")
    length = len(data)
    frame = bytearray()
    frame.append(0x81)  # FIN + text opcode (1)
    mask_bit = 0x80 if is_client else 0x00
    if length <= 125:
        frame.append(mask_bit | length)
    elif length <= 65535:
        frame.append(mask_bit | 126)
        frame.extend(struct.pack("!H", length))
    else:
        frame.append(mask_bit | 127)
        frame.extend(struct.pack("!Q", length))

    if is_client:
        mask_key = os.urandom(4)
        frame.extend(mask_key)
        masked_data = bytearray(length)
        for i in range(length):
            masked_data[i] = data[i] ^ mask_key[i % 4]
        frame.extend(masked_data)
    else:
        frame.extend(data)
    return bytes(frame)

def decode_ws_frame(raw: bytes) -> tuple[str, bytes]:
    if len(raw) < 2:
        return "", raw
    masked = bool(raw[1] & 0x80)
    length = raw[1] & 0x7F
    offset = 2
    if length == 126:
        if len(raw) < 4:
            return "", raw
        length = struct.unpack("!H", raw[2:4])[0]
        offset = 4
    elif length == 127:
        if len(raw) < 10:
            return "", raw
        length = struct.unpack("!Q", raw[2:10])[0]
        offset = 10

    if masked:
        if len(raw) < offset + 4 + length:
            return "", raw
        mask_key = raw[offset:offset + 4]
        offset += 4
        payload_bytes = bytearray(length)
        for i in range(length):
            payload_bytes[i] = raw[offset + i] ^ mask_key[i % 4]
        remainder = raw[offset + length:]
        return payload_bytes.decode("utf-8", errors="replace"), remainder
    else:
        if len(raw) < offset + length:
            return "", raw
        payload_bytes = raw[offset:offset + length]
        remainder = raw[offset + length:]
        return payload_bytes.decode("utf-8", errors="replace"), remainder

class DistributedHubServer:
    """Mock Hub server that handles HTTP API and WebSocket upgrade for remote bridge."""
    def __init__(self, expected_secret: str) -> None:
        self.expected_secret = expected_secret
        self.enrolled_bridges: dict[str, str] = {}  # bridge_id -> token
        self.connected_sockets: list[socket.socket] = []
        self.received_frames: list[dict] = []
        self.requests: list[dict] = []
        self.lock = threading.Lock()
        self.sock: socket.socket | None = None
        self.port = free_port()
        self.running = True

    def start(self) -> None:
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", self.port))
        self.sock.listen(10)
        threading.Thread(target=self._accept_loop, daemon=True).start()

    def _accept_loop(self) -> None:
        while self.running:
            try:
                conn, _ = self.sock.accept()
                threading.Thread(target=self._handle_client, args=(conn,), daemon=True).start()
            except OSError:
                break

    def _handle_client(self, conn: socket.socket) -> None:
        try:
            req_data = b""
            while b"\r\n\r\n" not in req_data:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                req_data += chunk
            header_part, rest = req_data.split(b"\r\n\r\n", 1)
            lines = header_part.decode("utf-8", errors="replace").split("\r\n")
            first_line = lines[0]
            method, path, _ = first_line.split(" ", 2)
            headers = {}
            for line in lines[1:]:
                if ":" in line:
                    k, v = line.split(":", 1)
                    headers[k.strip().lower()] = v.strip()

            content_len = int(headers.get("content-length", 0))
            body = rest
            while len(body) < content_len:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                body += chunk

            with self.lock:
                self.requests.append({"method": method, "path": path, "headers": headers, "body": body.decode(errors="replace")})

            # Check dev-proxy secret trust
            if headers.get("x-heimdall-proxy-secret") != self.expected_secret:
                conn.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 17\r\n\r\nForbidden: secret")
                conn.close()
                return

            # Handle POST /api/v1/bridges/enroll
            if path == "/api/v1/bridges/enroll" and method == "POST":
                auth = headers.get("authorization", "")
                if not auth.startswith("Bearer hbe_"):
                    conn.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 19\r\n\r\nUnauthorized: token")
                    conn.close()
                    return
                # Return 201 Created with bridge credentials
                bridge_id = "brg_cloudtop2_node"
                bridge_token = "hbr_token_cloudtop2_xyz"
                with self.lock:
                    self.enrolled_bridges[bridge_id] = bridge_token
                resp_body = json.dumps({"bridge_id": bridge_id, "bridge_token": bridge_token, "status": "enrolled"}).encode()
                conn.sendall(
                    f"HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: {len(resp_body)}\r\nConnection: close\r\n\r\n".encode() + resp_body
                )
                conn.close()
                return

            # Handle GET /api/v1/bridge-ws (WebSocket Upgrade)
            if path.startswith("/api/v1/bridge-ws") and headers.get("upgrade", "").lower() == "websocket":
                auth = headers.get("authorization", "")
                if not auth.startswith("Bearer hbr_"):
                    conn.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 26\r\n\r\nUnauthorized: bridge token")
                    conn.close()
                    return
                ws_key = headers.get("sec-websocket-key", "")
                accept = ws_accept_key(ws_key)
                upgrade_resp = (
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    "Upgrade: websocket\r\n"
                    "Connection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
                )
                conn.sendall(upgrade_resp.encode())
                with self.lock:
                    self.connected_sockets.append(conn)

                # Read WebSocket frames
                buf = bytearray()
                while self.running:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    buf.extend(chunk)
                    while True:
                        msg, remainder = decode_ws_frame(bytes(buf))
                        if not msg:
                            break
                        buf = bytearray(remainder)
                        parsed = json.loads(msg)
                        with self.lock:
                            self.received_frames.append(parsed)
                        # Handle hello -> reply with bridge_ready
                        if parsed.get("type") == "hello":
                            ready_frame = encode_ws_frame(
                                json.dumps({"type": "bridge_ready", "bridge_id": parsed.get("bridge_id"), "generation": 1}),
                                is_client=False,
                            )
                            conn.sendall(ready_frame)
                        elif parsed.get("type") == "heartbeat":
                            ack_frame = encode_ws_frame(
                                json.dumps({"type": "heartbeat_ack", "timestamp": parsed.get("timestamp")}),
                                is_client=False,
                            )
                            conn.sendall(ack_frame)
                return

            # General response
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
            conn.close()
        except Exception as e:
            pass

    def stop(self) -> None:
        self.running = False
        if self.sock:
            self.sock.close()

def wait_for_port(port: int, proc: subprocess.Popen) -> None:
    deadline = time.time() + 10
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"process exited early with code {proc.poll()}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise TimeoutError(f"timed out waiting for port {port}")

def main() -> None:
    proxy_bin = Path("/tmp/ham-dev-proxy-ct8-test")
    odin = "/nix/store/lrzcmy4vglphhshdpsqmsgjpnf5z1yhi-odin-dev-2026-05/bin/odin"
    subprocess.check_call([odin, "build", "src/dev_proxy", f"-out:{proxy_bin}", "-collection:odin_test=src"], cwd=ROOT)

    expected_secret = "secret_ct8_shared_key_555"
    hub = DistributedHubServer(expected_secret=expected_secret)
    hub.start()

    with tempfile.TemporaryDirectory() as tmp:
        secret_file = Path(tmp) / "proxy_secret"
        secret_file.write_text(f"{expected_secret}\n")
        os.chmod(secret_file, 0o600)

        gateway_port = free_port()
        env = dict(os.environ)
        env["HEIMDALL_HOME"] = tmp
        env["HAM_PROXY_SECRET_FILE"] = str(secret_file)
        env["USER"] = "tanmayvijay"
        env["HEIMDALL_MOCK_GCERT_REMAINING_MINUTES"] = "1200"

        # Launch dev-proxy representing the port 8989 edge gateway on Cloudtop 1
        proc = subprocess.Popen(
            [
                str(proxy_bin),
                "--listen", f"0.0.0.0:{gateway_port}",
                "--hub-url", f"http://127.0.0.1:{hub.port}",
                "--default-user", "tanmayvijay",
            ],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        try:
            wait_for_port(gateway_port, proc)

            # TEST 1: Unauthenticated bridge auto-pair is FORBIDDEN through gateway
            req_autopair = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/bridges/auto-pair",
                data=b"{}",
                headers={"Host": "tanmayvijay.c.googlers.com:8989", "Content-Type": "application/json", "X-Goog-Authenticated-User-Email": "tanmayvijay@google.com"},
            )
            try:
                urllib.request.urlopen(req_autopair, timeout=5)
                assert False, "expected 403 Forbidden for bridge auto-pair through dev-proxy"
            except urllib.error.HTTPError as e:
                assert e.code == 403
                body = e.read().decode()
                assert "bridge auto-pair forbidden" in body
            print("PASS 1: Sensitive unauthenticated /api/v1/bridges/auto-pair is blocked through gateway")

            # TEST 2: Remote Bridge Enrollment via Token (hbe_...) over Edge Gateway
            enrollment_token = "hbe_remote_cloudtop2_token_abc"
            enroll_body = json.dumps({
                "hostname": "cloudtop2.c.googlers.com",
                "os": "linux",
                "arch": "x86_64",
            }).encode()
            req_enroll = urllib.request.Request(
                f"http://127.0.0.1:{gateway_port}/api/v1/bridges/enroll",
                data=enroll_body,
                headers={
                    "Host": "tanmayvijay.c.googlers.com:8989",
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {enrollment_token}",
                },
            )
            with urllib.request.urlopen(req_enroll, timeout=5) as resp:
                assert resp.status == 201
                enroll_data = json.loads(resp.read().decode())
                assert enroll_data["bridge_id"] == "brg_cloudtop2_node"
                assert enroll_data["bridge_token"] == "hbr_token_cloudtop2_xyz"
            print("PASS 2: Remote bridge successfully enrolled via Bearer hbe_... through edge gateway")

            # TEST 3: Persistent Outbound Reverse-Tunnel WebSocket (/api/v1/bridge-ws)
            ws_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            ws_sock.connect(("127.0.0.1", gateway_port))

            raw_key = base64.b64encode(os.urandom(16)).decode()
            bridge_token = enroll_data["bridge_token"]
            ws_handshake = (
                f"GET /api/v1/bridge-ws HTTP/1.1\r\n"
                f"Host: tanmayvijay.c.googlers.com:8989\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {raw_key}\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                f"Authorization: Bearer {bridge_token}\r\n\r\n"
            )
            ws_sock.sendall(ws_handshake.encode())

            # Read 101 Switching Protocols
            handshake_resp = b""
            while b"\r\n\r\n" not in handshake_resp:
                chunk = ws_sock.recv(1024)
                assert chunk, "connection closed prematurely during handshake"
                handshake_resp += chunk

            assert b"101 Switching Protocols" in handshake_resp
            assert b"Upgrade: websocket" in handshake_resp or b"upgrade: websocket" in handshake_resp
            print("PASS 3: Reverse-tunnel WebSocket successfully upgraded through port 8989 gateway")

            # TEST 4: Hello frame exchange & Bridge Registration
            hello_payload = json.dumps({
                "type": "hello",
                "bridge_id": "brg_cloudtop2_node",
                "hostname": "cloudtop2.c.googlers.com",
                "protocol_version": 1,
            })
            ws_sock.sendall(encode_ws_frame(hello_payload, is_client=True))

            # Receive bridge_ready frame from Hub
            buf = bytearray()
            msg = ""
            deadline = time.time() + 5
            while time.time() < deadline:
                chunk = ws_sock.recv(4096)
                if not chunk:
                    break
                buf.extend(chunk)
                msg, _ = decode_ws_frame(bytes(buf))
                if msg:
                    break
            assert msg, "expected bridge_ready message from Hub"
            ready_data = json.loads(msg)
            assert ready_data.get("type") == "bridge_ready"
            assert ready_data.get("bridge_id") == "brg_cloudtop2_node"
            print("PASS 4: Remote bridge registered and received bridge_ready from Hub")

            # TEST 5: Heartbeat keepalive over WebSocket
            now_str = "2026-09-08T15:00:00Z"
            heartbeat_payload = json.dumps({
                "type": "heartbeat",
                "bridge_id": "brg_cloudtop2_node",
                "timestamp": now_str,
            })
            ws_sock.sendall(encode_ws_frame(heartbeat_payload, is_client=True))

            buf = bytearray()
            ack_msg = ""
            deadline = time.time() + 5
            while time.time() < deadline:
                chunk = ws_sock.recv(4096)
                if not chunk:
                    break
                buf.extend(chunk)
                ack_msg, _ = decode_ws_frame(bytes(buf))
                if ack_msg:
                    break
            assert ack_msg, "expected heartbeat_ack from Hub"
            ack_data = json.loads(ack_msg)
            assert ack_data.get("type") == "heartbeat_ack"
            assert ack_data.get("timestamp") == now_str
            print("PASS 5: Heartbeat keepalive active over WebSocket")

            # TEST 6: Command dispatch from Hub to Remote Bridge (Launch Instance)
            # Hub dispatches a command through its server-side socket to the remote bridge
            assert len(hub.connected_sockets) > 0, "Hub must have active connection socket"
            hub_conn = hub.connected_sockets[0]
            cmd_payload = json.dumps({
                "type": "command",
                "command_id": "cmd_remote_launch_001",
                "action": "launch_instance",
                "agent_id": "agent_coder",
                "instance_id": "inst_remote_cloudtop2_001",
                "owner_user_id": "tanmayvijay",
            })
            hub_conn.sendall(encode_ws_frame(cmd_payload, is_client=False))

            # Remote bridge receives command frame from Hub through the tunnel
            buf = bytearray()
            received_cmd = ""
            deadline = time.time() + 5
            while time.time() < deadline:
                chunk = ws_sock.recv(4096)
                if not chunk:
                    break
                buf.extend(chunk)
                received_cmd, _ = decode_ws_frame(bytes(buf))
                if received_cmd:
                    break
            assert received_cmd, "expected command from Hub to remote bridge"
            cmd_data = json.loads(received_cmd)
            assert cmd_data.get("command_id") == "cmd_remote_launch_001"
            assert cmd_data.get("instance_id") == "inst_remote_cloudtop2_001"
            assert cmd_data.get("owner_user_id") == "tanmayvijay"
            print("PASS 6: Hub command dispatch received by remote bridge over tunnel (remote launch verified)")

            ws_sock.close()
        finally:
            proc.terminate()
            proc.wait()
            hub.stop()

    print("ALL CT-8 MULTI-CLOUDTOP REMOTE BRIDGE DISTRIBUTED TESTS PASSED!")

if __name__ == "__main__":
    main()
