import json
import re
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TASK_NOTIFICATIONS = ROOT / "src" / "daemon" / "task_notifications.odin"
TASK_QUERIES = ROOT / "src" / "daemon" / "task_queries.odin"
HOST = "127.0.0.1"
PORT = 49439
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


class TaskNotificationRecipientScopeTests(unittest.TestCase):
    def test_notification_participant_matching_is_task_scoped_not_chain_wide(self):
        source = TASK_NOTIFICATIONS.read_text()

        # Any participant fanout must be gated on p.task_id == this task_id,
        # never a chain-wide fallback. Regardless of refactoring shape, the
        # loops must include a per-task guard before touching participant rows.
        self.assertNotIn('p.task_id != task_id && (chain_id == "" || p.chain_id != chain_id)', source)
        self.assertNotIn('p.task_id != state.task_id && (state.chain_id == "" || p.chain_id != state.chain_id)', source)

        # Central recipient builder must scope participants by task.
        self.assertRegex(
            source,
            r'task_actionable_recipients[\s\S]+?if p\.task_id != state\.task_id do continue[\s\S]+?if p\.role != "subscriber" do continue',
        )
        self.assertRegex(
            source,
            r'task_recipients_for_role[\s\S]+?if p\.task_id != state\.task_id do continue[\s\S]+?if p\.role != role do continue',
        )
        self.assertRegex(
            source,
            r'task_notify_all_lgtm_required[\s\S]+?if p\.task_id != task_id do continue[\s\S]+?if p\.role != "lgtm_required" do continue',
        )

    def test_related_task_role_queries_are_task_scoped_not_chain_wide(self):
        source = TASK_QUERIES.read_text()

        self.assertNotIn('p.task_id != state.task_id && (state.chain_id == "" || p.chain_id != state.chain_id)', source)
        self.assertRegex(
            source,
            r'task_actor_has_role[\s\S]+?if p\.task_id != state\.task_id do continue[\s\S]+?return true',
        )
        self.assertRegex(
            source,
            r'task_target_for_role[\s\S]+?if p\.task_id != state\.task_id do continue[\s\S]+?return p\.agent_instance_id',
        )

    def test_status_policy_matches_actionable_roles(self):
        """The routing table in task_notification_policy_for_status must:
           - assign coordinator-only to planning,
           - assign assignee-only to queued/in_progress,
           - assign assignee+coordinator to approved (chain-19f4b3d0617 fix),
           - assign assignee+coordinator to blocked and cancelled,
           - explicitly abstain for review_ready (dispatched separately).
        """
        source = TASK_NOTIFICATIONS.read_text()
        m = re.search(
            r'task_notification_policy_for_status[\s\S]+?switch status \{([\s\S]+?)\n\t\}',
            source,
        )
        self.assertIsNotNone(m, "policy switch not found")
        body = m.group(1)
        self.assertIn('case "planning":', body)
        self.assertRegex(body, r'case "planning":[\s\S]+?TASK_NOTIFY_ROLES_COORDINATOR')
        self.assertRegex(body, r'case "queued", "in_progress":[\s\S]+?TASK_NOTIFY_ROLES_ASSIGNEE')
        self.assertRegex(body, r'case "review_ready":[\s\S]+?return nil, false')
        self.assertRegex(body, r'case "approved":[\s\S]+?TASK_NOTIFY_ROLES_ASSIGNEE_COORDINATOR')
        self.assertRegex(body, r'case "blocked":[\s\S]+?TASK_NOTIFY_ROLES_ASSIGNEE_COORDINATOR')
        self.assertRegex(body, r'case "cancelled":[\s\S]+?TASK_NOTIFY_ROLES_ASSIGNEE_COORDINATOR')

    def test_actionable_set_has_fallback_when_empty(self):
        """When the actionable recipient set collapses (author-only, empty roster),
        we must not silently drop the event. task_notify_by_status must invoke
        task_notify_fallback which routes to default_reviewer -> coordinator ->
        operator@local (durable outbox)."""
        source = TASK_NOTIFICATIONS.read_text()
        self.assertIn('task_notify_fallback', source)
        self.assertRegex(
            source,
            r'task_notify_fallback[\s\S]+?task_chain_default_reviewer_agent_instance_id[\s\S]+?task_coordinator_agent_instance_id[\s\S]+?operator@local',
        )
        self.assertRegex(
            source,
            r'if required && sent_actionable == 0[\s\S]+?task_notify_fallback',
        )

    def test_review_ready_has_full_fallback_chain(self):
        """review_ready must never end with zero notified recipients. If every
        lgtm_required reviewer is voted or slot-blocked, fall through to
        default_reviewer, then coordinator, then durable operator@local queue."""
        source = TASK_NOTIFICATIONS.read_text()
        self.assertRegex(
            source,
            r'task_notify_all_lgtm_required[\s\S]+?if notified_count > 0[\s\S]+?return[\s\S]+?default_reviewer[\s\S]+?coord[\s\S]+?operator@local',
        )

    def test_no_cross_task_same_chain_participant_fallback_remains(self):
        combined = TASK_NOTIFICATIONS.read_text() + "\n" + TASK_QUERIES.read_text()
        same_chain_participant_fallbacks = re.findall(
            r'p\.task_id\s*!=\s*(?:task_id|state\.task_id)\s*&&\s*\([^\n]*chain_id[^\n]*\)',
            combined,
        )
        self.assertEqual(same_chain_participant_fallbacks, [])

    def test_runtime_recipient_scope_for_same_chain_tasks(self):
        temp_dir = tempfile.mkdtemp(prefix="heimdall-task-notify-scope-")
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
                "client_instance_id": "task-notify-scope-user",
            })
            user_token = user["client_token"]

            agent_ids = [
                "coord@default",
                "assignee-a@default",
                "assignee-b@default",
                "subscriber-a@default",
                "reviewer-a@default",
                "reviewer-b@default",
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

            chain_id = request_post(url, "/task-chains/create", {
                "agent_token": agent_tokens["coord@default"],
                "title": "Recipient scope chain",
                "coordinator_agent_instance_id": "coord@default",
            })["chain_id"]
            task_a = request_post(url, "/tasks/create", {
                "agent_token": agent_tokens["coord@default"],
                "chain_id": chain_id,
                "title": "Task A",
                "assignee_agent_instance_id": "assignee-a@default",
            })["task_id"]
            task_b = request_post(url, "/tasks/create", {
                "agent_token": agent_tokens["coord@default"],
                "chain_id": chain_id,
                "title": "Task B",
                "assignee_agent_instance_id": "assignee-b@default",
            })["task_id"]
            request_post(url, "/tasks/participant", {
                "agent_token": agent_tokens["coord@default"],
                "task_id": task_a,
                "chain_id": chain_id,
                "agent_instance_id": "subscriber-a@default",
                "role": "subscriber",
            })
            request_post(url, "/tasks/participant", {
                "agent_token": agent_tokens["coord@default"],
                "task_id": task_a,
                "chain_id": chain_id,
                "agent_instance_id": "reviewer-a@default",
                "role": "lgtm_required",
            })
            request_post(url, "/tasks/participant", {
                "agent_token": agent_tokens["coord@default"],
                "task_id": task_b,
                "chain_id": chain_id,
                "agent_instance_id": "reviewer-b@default",
                "role": "lgtm_required",
            })

            def drain_all():
                for ws_state in agent_sockets.values():
                    while recv_ws_json(ws_state):
                        pass

            def status_recipients(status: str):
                request_post(url, "/tasks/status", {
                    "agent_token": user_token,
                    "client_instance_id": "task-notify-scope-user",
                    "task_id": task_a,
                    "chain_id": chain_id,
                    "status": status,
                    "body": status,
                })
                time.sleep(0.2)
                recipients = set()
                payloads = {}
                for agent_id, ws_state in agent_sockets.items():
                    while True:
                        payload = recv_ws_json(ws_state)
                        if not payload:
                            break
                        if payload.get("type") == "task_event" and payload.get("task_id") == task_a and payload.get("status") == status:
                            recipients.add(agent_id)
                            payloads.setdefault(agent_id, []).append(payload)
                return recipients, payloads

            drain_all()
            queued_recipients, _ = status_recipients("queued")
            self.assertEqual(queued_recipients, {"assignee-a@default", "subscriber-a@default"})

            drain_all()
            in_progress_recipients, _ = status_recipients("in_progress")
            self.assertEqual(in_progress_recipients, {"assignee-a@default", "subscriber-a@default"})

            drain_all()
            review_ready_recipients, _ = status_recipients("review_ready")
            self.assertIn("reviewer-a@default", review_ready_recipients)
            self.assertIn("subscriber-a@default", review_ready_recipients)
            self.assertNotIn("reviewer-b@default", review_ready_recipients)
            self.assertNotIn("assignee-b@default", review_ready_recipients)

            drain_all()
            approved_recipients, _ = status_recipients("approved")
            # chain-19f4b3d0617 fix: assignee must also learn their task landed.
            # coordinator still learns closeout is actionable.
            self.assertEqual(
                approved_recipients,
                {"coord@default", "assignee-a@default", "subscriber-a@default"},
            )

            drain_all()
            blocked_recipients, _ = status_recipients("blocked")
            self.assertEqual(blocked_recipients, {"coord@default", "assignee-a@default", "subscriber-a@default"})

            drain_all()
            cancelled_recipients, _ = status_recipients("cancelled")
            self.assertEqual(cancelled_recipients, {"coord@default", "assignee-a@default", "subscriber-a@default"})
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
