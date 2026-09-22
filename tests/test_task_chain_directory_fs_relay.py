#!/usr/bin/env python3
"""Regression test for REQ-BE-TASK-CHAIN-DIRECTORY-FS-RELAY:
Backend filesystem relay and endpoints for task chain directories.
Tests:
1. Static code verification (handlers, router wiring, sandboxing, and service procs).
2. Live Hub REST API and WebSocket bridge relay:
   - Authentication guards (require_auth_any).
   - Task chain directory resolution and bridge routing.
   - Bridge runtime command relay sandboxed to dir.path.
   - All directory fs endpoints: list, read file, write file, batch write, create file, mkdir, move, delete, quick-open.
"""

import base64
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def require(ok: bool, message: str) -> None:
    if not ok:
        print(f"FAILED: {message}", file=sys.stderr)
        raise AssertionError(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


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


def test_static_requirements() -> None:
    print("Testing static code requirements for REQ-BE-TASK-CHAIN-DIRECTORY-FS-RELAY...")
    service_odin = read(ROOT / "src/hub/service/taskchain/taskchain_service.odin")
    require("get_chain_directory :: proc" in service_odin, "taskchain_service.odin must define get_chain_directory")

    bridge_handlers = read(ROOT / "src/hub/transport/http/bridge_handlers.odin")
    require("directory_fs_relay :: proc" in bridge_handlers, "bridge_handlers.odin must define directory_fs_relay")
    require("project_fs_command_json(cmd, command_id, dir.path)" in bridge_handlers,
            "directory_fs_relay must sandbox command root to dir.path")
    require("require_auth_any(h.auth, req)" in bridge_handlers, "directory_fs_relay must enforce require_auth_any")

    # Verify all 9 HTTP handlers exist
    for handler in [
        "list_chain_directory_fs_handler :: proc",
        "read_chain_directory_file_handler :: proc",
        "create_chain_directory_file_handler :: proc",
        "write_chain_directory_file_handler :: proc",
        "batch_write_chain_directory_files_handler :: proc",
        "create_chain_directory_dir_handler :: proc",
        "move_chain_directory_path_handler :: proc",
        "delete_chain_directory_path_handler :: proc",
        "quick_open_chain_directory_fs_handler :: proc",
    ]:
        require(handler in bridge_handlers, f"bridge_handlers.odin missing handler: {handler}")

    # Verify router wiring in wiring.odin
    wiring = read(ROOT / "src/hub/app/wiring.odin")
    for route in [
        '"/api/v1/task-chains/*/directories/*/fs"',
        '"/api/v1/task-chains/*/directories/*/fs/quick-open"',
        '"/api/v1/task-chains/*/directories/*/fs/file"',
        '"/api/v1/task-chains/*/directories/*/fs/files"',
        '"/api/v1/task-chains/*/directories/*/fs/dir"',
        '"/api/v1/task-chains/*/directories/*/fs/move"',
    ]:
        require(route in wiring, f"wiring.odin missing route: {route}")

    print("Static requirements PASSED.")


def test_live_directory_fs_relay() -> None:
    print("Testing live Hub task chain directory fs relay with mock bridge...")
    hub_bin = Path("/tmp/test_hub")
    if not hub_bin.exists():
        print("Building test_hub binary...")
        build_cmd = "nix develop --command bash -c 'odin build src/hub -collection:odin_test=src -out:/tmp/test_hub'"
        res = subprocess.run(build_cmd, shell=True, cwd=ROOT, capture_output=True, text=True)
        require(res.returncode == 0, f"build failed: {res.stderr}")

    port = find_free_port()
    db_path = f"/tmp/ham-test-dir-fs-{port}.db"
    if os.path.exists(db_path):
        os.remove(db_path)

    migrations_dir = str(ROOT / "src/hub/repository/sqlite/migrations")
    user_out = subprocess.check_output(
        [str(hub_bin), "users", "create", "--name", "Dir Test User", "--email", "dirtest@example.com", "--db", db_path, "--migrations-dir", migrations_dir],
        text=True,
    )
    user_tok = None
    for line in user_out.splitlines():
        line = line.strip()
        if line.startswith("token="):
            user_tok = line.split("=", 1)[1].strip()
            break
    require(user_tok is not None and len(user_tok) > 0, "Failed to provision user token")

    hub_proc = subprocess.Popen(
        [str(hub_bin), "--listen", f"127.0.0.1:{port}", "--db", db_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    ws_sock = None
    bridge_running = True

    try:
        # Wait for Hub to be ready
        ready = False
        base_url = f"http://127.0.0.1:{port}"
        for _ in range(50):
            try:
                with urllib.request.urlopen(f"{base_url}/api/v1/health", timeout=1) as resp:
                    if resp.status == 200:
                        ready = True
                        break
            except Exception:
                time.sleep(0.1)

        require(ready, "Hub failed to start up within timeout")

        def api_request(method: str, path: str, payload=None, token=user_tok) -> tuple[int, dict]:
            url = f"{base_url}{path}"
            data = json.dumps(payload).encode("utf-8") if payload is not None else None
            req = urllib.request.Request(url, data=data, method=method)
            if token:
                req.add_header("Authorization", f"Bearer {token}")
            req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    return resp.status, json.loads(resp.read().decode("utf-8"))
            except urllib.error.HTTPError as e:
                body = e.read().decode("utf-8")
                try:
                    parsed = json.loads(body)
                except Exception:
                    parsed = {"raw": body}
                return e.code, parsed

        # 1. Create task chain
        status, data = api_request("POST", "/api/v1/task-chains", {"title": "Directory FS Chain", "kind": "team_work"})
        require(status == 201 or status == 200, f"failed to create chain: {status} {data}")
        chain_id = data["data"]["chain_id"]

        # 2. Add directory
        target_dir_path = "/tmp/sandboxed_task_chain_dir"
        status, data = api_request("POST", f"/api/v1/task-chains/{chain_id}/directories", {
            "path": target_dir_path,
        })
        require(status == 201, f"failed to add directory: {status} {data}")
        dir_id = data["data"]["directory_id"]

        # 3. Test unauthenticated request -> 401 Unauthorized
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs", token=None)
        require(status == 401, f"expected 401 for unauthenticated request, got {status} {data}")

        # 4. Test non-existent directory -> 404 Not Found
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/dir_not_exist/fs")
        require(status == 404, f"expected 404 for non-existent directory, got {status}")

        # 5. Test single directory GET endpoint -> 200 OK
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}")
        require(status == 200, f"expected 200 for single directory get, got {status} {data}")
        require(data["data"]["directory_id"] == dir_id, "directory_id mismatch")
        require(data["data"]["path"] == target_dir_path, "directory path mismatch")

        # 6. Test bridge offline error when no bridge is online
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs")
        require(status == 400 or status == 503, f"expected bridge offline error (400/503), got {status} {data}")

        # 7. Enroll a bridge
        status, data = api_request("POST", "/api/v1/bridge-enrollments", {"label": "Test Mock Bridge"})
        require(status == 201, f"enrollment failed: {status} {data}")
        enrollment_token = data["data"]["enrollment_token"]

        status, data = api_request(
            "POST", "/api/v1/bridges/enroll",
            {"machine": {"hostname": "mock-bridge-host"}, "capabilities": [{"provider": "claude", "tiers": ["normal"], "default_tier": "normal"}]},
            token=enrollment_token
        )
        require(status == 201, f"bridge enroll failed: {status} {data}")
        bridge_id = data["data"]["bridge_id"]
        bridge_token = data["data"]["bridge_token"]

        # 8. Update directory with enrolled bridge_id
        status, data = api_request("PATCH", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}", {
            "bridge_id": bridge_id,
        })
        require(status == 200, f"patch directory failed: {status} {data}")
        require(data["data"]["bridge_id"] == bridge_id, "bridge_id was not updated on directory")

        # 9. Connect mock bridge over WebSocket (/api/v1/bridge-ws)
        ws_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ws_sock.connect(("127.0.0.1", port))
        raw_key = base64.b64encode(os.urandom(16)).decode()
        ws_handshake = (
            f"GET /api/v1/bridge-ws HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {raw_key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Authorization: Bearer {bridge_token}\r\n\r\n"
        )
        ws_sock.sendall(ws_handshake.encode())
        resp_hdr = b""
        while b"\r\n\r\n" not in resp_hdr:
            chunk = ws_sock.recv(1024)
            require(bool(chunk), "connection closed during ws handshake")
            resp_hdr += chunk
        require(b"101 Switching Protocols" in resp_hdr, "WebSocket upgrade failed")

        # Send bridge_hello
        hello_msg = json.dumps({
            "type": "bridge_hello",
            "protocol_version": 1,
            "bridge_id": bridge_id,
            "hostname": "mock-bridge-host",
            "capabilities": [{"provider": "claude", "tiers": ["normal"], "default_tier": "normal"}],
        })
        ws_sock.sendall(encode_ws_frame(hello_msg, is_client=True))

        # Background thread to handle incoming Hub filesystem commands and reply
        received_commands = []
        lock = threading.Lock()

        def mock_bridge_worker():
            buf = b""
            while bridge_running:
                try:
                    chunk = ws_sock.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                    while True:
                        frame_text, remainder = decode_ws_frame(buf)
                        if not frame_text and remainder == buf:
                            break
                        buf = remainder
                        if not frame_text:
                            continue
                        try:
                            cmd_json = json.loads(frame_text)
                        except Exception:
                            continue

                        cmd_type = cmd_json.get("type", "")
                        cmd_id = cmd_json.get("command_id", "")
                        with lock:
                            received_commands.append(cmd_json)

                        # Handle and reply to filesystem commands
                        if cmd_type == "fs_list_dir":
                            reply = json.dumps({
                                "type": "fs_list_dir_result",
                                "command_id": cmd_id,
                                "ok": True,
                                "path": cmd_json.get("path", ""),
                                "entries": [
                                    {"name": "file1.txt", "type": "file", "size": 128},
                                    {"name": "subdir", "type": "directory", "size": 0},
                                ],
                            })
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_read_file":
                            reply = json.dumps({
                                "type": "fs_read_file_result",
                                "command_id": cmd_id,
                                "ok": True,
                                "path": cmd_json.get("path", ""),
                                "content": "Hello from sandboxed task chain directory!",
                            })
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_create_file":
                            reply = json.dumps({"type": "fs_create_file_result", "command_id": cmd_id, "ok": True})
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_write_file":
                            reply = json.dumps({"type": "fs_write_file_result", "command_id": cmd_id, "ok": True})
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_batch_write":
                            reply = json.dumps({"type": "fs_batch_write_result", "command_id": cmd_id, "ok": True, "saved": []})
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_make_dir":
                            reply = json.dumps({"type": "fs_make_dir_result", "command_id": cmd_id, "ok": True})
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_move":
                            reply = json.dumps({"type": "fs_move_result", "command_id": cmd_id, "ok": True})
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_delete":
                            reply = json.dumps({"type": "fs_delete_result", "command_id": cmd_id, "ok": True})
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_find_files":
                            reply = json.dumps({
                                "type": "fs_find_files_result",
                                "command_id": cmd_id,
                                "ok": True,
                                "matches": ["file1.txt", "subdir/inner.txt"],
                            })
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                except Exception:
                    break

        th = threading.Thread(target=mock_bridge_worker, daemon=True)
        th.start()

        # Give bridge handshake a moment to register as live
        time.sleep(0.3)

        # 10. Test GET /api/v1/task-chains/*/directories/*/fs (list dir)
        print("Testing GET /fs (list dir)...")
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs")
        require(status == 200, f"fs list dir failed: {status} {data}")
        require("entries" in data["data"], "data must contain entries")
        require(any(e["name"] == "file1.txt" for e in data["data"]["entries"]), "entries missing file1.txt")

        # Verify command received by mock bridge had root sandboxed to dir.path
        with lock:
            last_cmd = received_commands[-1]
            require(last_cmd["type"] == "fs_list_dir", f"expected fs_list_dir, got {last_cmd}")
            require(last_cmd["root"] == target_dir_path, f"sandbox root mismatch: {last_cmd['root']} != {target_dir_path}")

        # 11. Test GET /api/v1/task-chains/*/directories/*/fs/file (read file)
        print("Testing GET /fs/file (read file)...")
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/file?path=file1.txt")
        require(status == 200, f"fs read file failed: {status} {data}")
        require(data["data"]["content"] == "Hello from sandboxed task chain directory!", f"content mismatch: {data}")

        with lock:
            last_cmd = received_commands[-1]
            require(last_cmd["type"] == "fs_read_file", f"expected fs_read_file, got {last_cmd}")
            require(last_cmd["root"] == target_dir_path, f"sandbox root mismatch: {last_cmd['root']}")
            require(last_cmd["path"] == "file1.txt", f"path mismatch: {last_cmd['path']}")

        # 12. Test GET /api/v1/task-chains/*/directories/*/fs/quick-open (quick-open)
        print("Testing GET /fs/quick-open...")
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/quick-open?query=file")
        require(status == 200, f"fs quick-open failed: {status} {data}")
        require("file1.txt" in data["data"]["matches"], f"matches mismatch: {data}")

        # 13. Test POST /api/v1/task-chains/*/directories/*/fs/file (create file)
        print("Testing POST /fs/file (create file)...")
        status, data = api_request("POST", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/file", {"path": "new.txt"})
        require(status == 200, f"fs create file failed: {status} {data}")
        with lock:
            require(received_commands[-1]["type"] == "fs_create_file", "expected fs_create_file")

        # 14. Test PUT /api/v1/task-chains/*/directories/*/fs/file (write file)
        print("Testing PUT /fs/file (write file)...")
        status, data = api_request("PUT", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/file", {"path": "new.txt", "content": "test content"})
        require(status == 200, f"fs write file failed: {status} {data}")
        with lock:
            require(received_commands[-1]["type"] == "fs_write_file", "expected fs_write_file")
            require(received_commands[-1]["content"] == "test content", "content mismatch")

        # 15. Test PUT /api/v1/task-chains/*/directories/*/fs/files (batch write)
        print("Testing PUT /fs/files (batch write)...")
        status, data = api_request("PUT", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/files", {
            "files": [{"path": "b1.txt", "content": "c1"}, {"path": "b2.txt", "content": "c2"}]
        })
        require(status == 200, f"fs batch write failed: {status} {data}")
        with lock:
            require(received_commands[-1]["type"] == "fs_batch_write", "expected fs_batch_write")

        # 16. Test POST /api/v1/task-chains/*/directories/*/fs/dir (mkdir)
        print("Testing POST /fs/dir (mkdir)...")
        status, data = api_request("POST", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/dir", {"path": "new_folder"})
        require(status == 200, f"fs mkdir failed: {status} {data}")
        with lock:
            require(received_commands[-1]["type"] == "fs_make_dir", "expected fs_make_dir")

        # 17. Test POST /api/v1/task-chains/*/directories/*/fs/move (move/rename)
        print("Testing POST /fs/move (move)...")
        status, data = api_request("POST", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/move", {"from": "a.txt", "to": "b.txt"})
        require(status == 200, f"fs move failed: {status} {data}")
        with lock:
            require(received_commands[-1]["type"] == "fs_move", "expected fs_move")

        # 18. Test DELETE /api/v1/task-chains/*/directories/*/fs (delete)
        print("Testing DELETE /fs (delete)...")
        status, data = api_request("DELETE", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs?path=b.txt")
        require(status == 200, f"fs delete failed: {status} {data}")
        with lock:
            require(received_commands[-1]["type"] == "fs_delete", "expected fs_delete")

        print("End-to-end directory filesystem relay tests PASSED successfully.")

    finally:
        bridge_running = False
        if ws_sock:
            try:
                ws_sock.close()
            except Exception:
                pass
        hub_proc.terminate()
        try:
            hub_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            hub_proc.kill()
        if os.path.exists(db_path):
            os.remove(db_path)


if __name__ == "__main__":
    test_static_requirements()
    test_live_directory_fs_relay()
    print("\nALL DIRECTORY FS RELAY TESTS PASSED! (0 errors)")
