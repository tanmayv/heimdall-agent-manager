import json
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOST = "127.0.0.1"
PORT = 49451
USER_ID = "operator@local"


def request_post(url: str, path: str, data: dict) -> dict:
    req = urllib.request.Request(
        f"{url}{path}",
        data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=5) as res:
        return json.loads(res.read().decode())


def wait_health(url: str) -> None:
    for _ in range(60):
        try:
            with urllib.request.urlopen(f"{url}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def connect_agent_ws(port: int, agent_id: str):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(3)
    sock.connect((HOST, port))
    handshake = (
        f"GET /ws/{agent_id} HTTP/1.1\r\n"
        f"Host: {HOST}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(handshake.encode())
    response = sock.recv(4096)
    header_end = response.find(b"\r\n\r\n")
    if header_end < 0 or b"101 Switching Protocols" not in response[:header_end]:
        raise RuntimeError(f"websocket upgrade failed: {response!r}")
    return {"socket": sock, "buffer": response[header_end + 4:]}


def recv_ws_json(ws_state):
    sock = ws_state["socket"]
    buffer = ws_state["buffer"]

    def read_exactly(n: int) -> bytes:
        nonlocal buffer
        while len(buffer) < n:
            chunk = sock.recv(n - len(buffer))
            if not chunk:
                break
            buffer += chunk
        result = buffer[:n]
        buffer = buffer[n:]
        return result

    try:
        header = read_exactly(2)
        if len(header) < 2:
            ws_state["buffer"] = buffer
            return None
        payload_len = header[1] & 0x7F
        if payload_len == 126:
            payload_len = int.from_bytes(read_exactly(2), "big")
        elif payload_len == 127:
            payload_len = int.from_bytes(read_exactly(8), "big")
        payload = read_exactly(payload_len).decode()
        ws_state["buffer"] = buffer
        return json.loads(payload)
    except socket.timeout:
        ws_state["buffer"] = buffer
        return None


class RoleChangeNotificationTests(unittest.TestCase):
    def test_old_and_new_task_and_chain_role_holders_are_notified(self):
        temp_dir = tempfile.mkdtemp(prefix="heimdall-role-change-notify-")
        daemon_proc = None
        agent_sockets = {}
        try:
            config_path = Path(temp_dir) / "config.toml"
            config_path.write_text(
                f'''[daemon]\nbind_host = "{HOST}"\nport = {PORT}\ndata_dir = "{temp_dir}/data"\nwrapper_bin = "{ROOT}/result-wrapper/bin/ham-wrapper"\n''',
                encoding="utf-8",
            )
            daemon_proc = subprocess.Popen(
                [str(ROOT / "result/bin/ham-daemon"), "--config", str(config_path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.STDOUT,
            )
            url = f"http://{HOST}:{PORT}"
            wait_health(url)

            user = request_post(url, "/user-client/register", {
                "user_id": USER_ID,
                "client_instance_id": "role-change-user",
            })
            user_token = user["client_token"]

            agent_ids = [
                "coord-old@default",
                "coord-new@default",
                "assignee-old@default",
                "assignee-new@default",
                "reviewer-old@default",
                "reviewer-new@default",
            ]
            agent_tokens = {}
            for agent_id in agent_ids:
                agent_tokens[agent_id] = request_post(url, "/register", {
                    "agent_class": agent_id.split("@", 1)[0],
                    "agent_instance_id": agent_id,
                    "display_name": agent_id,
                })["agent_token"]
                agent_sockets[agent_id] = connect_agent_ws(PORT, agent_id)
                agent_sockets[agent_id]["socket"].settimeout(0.15)

            chain = request_post(url, "/task-chains/create", {
                "agent_token": agent_tokens["coord-old@default"],
                "kind": "coding",
                "wants_vcs": False,
                "no_scaffold": True,
                "title": "Role change notifications",
                "coordinator_agent_instance_id": "coord-old@default",
                "default_reviewer_agent_instance_id": "reviewer-old@default",
            })
            chain_id = chain["chain_id"]
            task_id = request_post(url, "/tasks/create", {
                "agent_token": agent_tokens["coord-old@default"],
                "chain_id": chain_id,
                "title": "Role change task",
                "assignee_agent_instance_id": "assignee-old@default",
            })["task_id"]

            def drain_all():
                for ws_state in agent_sockets.values():
                    while recv_ws_json(ws_state):
                        pass

            def collect_bodies(wait=0.25):
                time.sleep(wait)
                bodies = {agent_id: [] for agent_id in agent_sockets}
                for agent_id, ws_state in agent_sockets.items():
                    while True:
                        payload = recv_ws_json(ws_state)
                        if not payload:
                            break
                        if payload.get("type") == "task_event":
                            bodies[agent_id].append(payload.get("body", ""))
                return bodies

            drain_all()
            request_post(url, "/tasks/assign", {
                "agent_token": user_token,
                "client_instance_id": "role-change-user",
                "task_id": task_id,
                "chain_id": chain_id,
                "agent_instance_id": "assignee-new@default",
            })
            bodies = collect_bodies()
            self.assertTrue(any("no longer the assignee" in body for body in bodies["assignee-old@default"]))
            self.assertTrue(any("now the assignee" in body for body in bodies["assignee-new@default"]))

            drain_all()
            request_post(url, "/tasks/participant", {
                "agent_token": user_token,
                "client_instance_id": "role-change-user",
                "task_id": task_id,
                "chain_id": chain_id,
                "agent_instance_id": "reviewer-new@default",
                "role": "lgtm_required",
            })
            bodies = collect_bodies()
            self.assertTrue(any("now the required reviewer" in body for body in bodies["reviewer-new@default"]))

            drain_all()
            request_post(url, "/tasks/participant/remove", {
                "agent_token": user_token,
                "client_instance_id": "role-change-user",
                "task_id": task_id,
                "chain_id": chain_id,
                "agent_instance_id": "reviewer-new@default",
                "role": "lgtm_required",
            })
            bodies = collect_bodies()
            self.assertTrue(any("no longer the required reviewer" in body for body in bodies["reviewer-new@default"]))

            drain_all()
            request_post(url, "/task-chains/update", {
                "agent_token": user_token,
                "client_instance_id": "role-change-user",
                "chain_id": chain_id,
                "coordinator_agent_instance_id": "coord-new@default",
                "default_reviewer_agent_instance_id": "reviewer-new@default",
            })
            bodies = collect_bodies()
            self.assertTrue(any("no longer the coordinator" in body for body in bodies["coord-old@default"]))
            self.assertTrue(any("now the coordinator" in body for body in bodies["coord-new@default"]))
            self.assertTrue(any("no longer the default reviewer" in body for body in bodies["reviewer-old@default"]))
            self.assertTrue(any("now the default reviewer" in body for body in bodies["reviewer-new@default"]))
        finally:
            for ws_state in agent_sockets.values():
                try:
                    ws_state["socket"].close()
                except Exception:
                    pass
            if daemon_proc is not None:
                daemon_proc.terminate()
                try:
                    daemon_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    daemon_proc.kill()
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
