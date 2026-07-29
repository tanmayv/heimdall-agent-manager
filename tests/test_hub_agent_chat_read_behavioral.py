#!/usr/bin/env python3
"""Behavioral tests for low-noise agent chat read filters and metadata."""
from __future__ import annotations
import base64, json, os, socket, subprocess, tempfile, time, urllib.error, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def free_port() -> int:
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

def wait_get(url: str, timeout: float = 10) -> None:
    end = time.time() + timeout
    while time.time() < end:
        try:
            urllib.request.urlopen(url, timeout=.5).close(); return
        except Exception:
            time.sleep(.1)
    raise RuntimeError(url)

def req(method: str, url: str, body=None, headers=None):
    data = None if body is None else json.dumps(body).encode()
    h = {'Content-Type': 'application/json', **(headers or {})}
    r = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=5) as resp:
            raw = resp.read().decode(); print(f"HTTP {resp.status} {raw[:200]}"); return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode(); return e.code, json.loads(raw) if raw else {}

def ws_send_json(s, obj):
    payload = json.dumps(obj).encode(); mask = os.urandom(4)
    if len(payload) <= 125: header = bytes([0x81, 0x80 | len(payload)])
    else: header = bytes([0x81, 0x80 | 126, (len(payload) >> 8) & 255, len(payload) & 255])
    s.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

def ws_recv_json(s):
    frame = s.recv(65536); assert frame and frame[0] & 0x0f == 1, frame
    ln = frame[1] & 0x7f; start = 2
    if ln == 126: ln = (frame[2] << 8) | frame[3]; start = 4
    return json.loads(frame[start:start+ln].decode())

def ws_connect(path, port, headers=None):
    key = base64.b64encode(os.urandom(16)).decode(); s = socket.create_connection(("127.0.0.1", port), timeout=5)
    extra = ''.join(f"{k}: {v}\r\n" for k, v in (headers or {}).items())
    request = (f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n{extra}\r\n").encode()
    s.sendall(request); resp = s.recv(4096); assert b"101 Switching Protocols" in resp, resp
    return s

def ws_connect_bridge(port, token, bridge_id):
    s = ws_connect('/api/v1/bridge-ws', port, {"Authorization": f"Bearer {token}"})
    ws_send_json(s, {"type": "bridge_hello", "bridge_id": bridge_id, "protocol_version": 1, "hostname": "runner"})
    ready = ws_recv_json(s); assert ready["type"] == "bridge_ready", ready
    return s

def main() -> None:
    hub_bin = Path(os.environ.get('HAM_HUB_BIN', '/tmp/ham-hub-test'))
    if not hub_bin.exists():
        raise SystemExit(f'missing HAM_HUB_BIN: {hub_bin}')
    port = free_port(); base = f'http://127.0.0.1:{port}/api/v1'
    alice = {'X-authentik-username': 'alice'}
    with tempfile.TemporaryDirectory(prefix='ham-hub-test-') as tmp:
        hub = subprocess.Popen([str(hub_bin), '--listen', f'127.0.0.1:{port}', '--db', str(Path(tmp)/'hub.db'), '--logout-url', '/_dev/logout'], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            wait_get(f'{base}/health')
            
            # Setup prerequisites
            st, enr = req("POST", f"{base}/bridge-enrollments", {"label": "runtime"}, alice); assert st == 201
            st, br = req("POST", f"{base}/bridges/enroll", {"machine": {"hostname": "test"}, "capabilities": [{"provider": "claude", "tiers": ["normal"], "default_tier": "normal"}]}, {"Authorization": f"Bearer {enr['data']['enrollment_token']}"}); assert st == 201
            bridge_id = br['data']['bridge_id']
            bridge_token = br['data']['bridge_token']
            
            # Connect bridge so it is online
            bridge_ws = ws_connect_bridge(port, bridge_token, bridge_id)
            
            st, agent = req("POST", f"{base}/agents", {"name": "Agent1", "slug": "agent1", "default_provider": "claude", "default_tier": "normal", "instructions": "test"}, alice); assert st == 201
            agent_id = agent['data']['agent_id']
            st, support = req("PATCH", f"{base}/agents/{agent_id}/bridge-support/{bridge_id}", {"enabled": True, "provider": "claude", "tier": "normal"}, alice); assert st == 200
            
            st, project = req("POST", f"{base}/projects", {"name": "Proj", "slug": "proj", "default_path": "/tmp", "vcs_kind": "none"}, alice); assert st == 201
            project_id = project['data']['project_id']
            
            st, conv_res = req("POST", f"{base}/chats", {"agent_id": agent_id, "bridge_id": bridge_id, "project_id": project_id, "title": "Test Chat"}, alice); assert st == 201, conv_res
            cid = conv_res['data']['conversation_id']
            inst_id = conv_res['data']['agent_instance_id']
            
            st, bs = req("GET", f"{base}/bridge/agent-instances/{inst_id}/bootstrap", headers={"Authorization": f"Bearer {bridge_token}"}); assert st == 200, bs
            agent_token = bs['data']['instance_token']

            # Send a user_to_agent message
            st, msg = req("POST", f"{base}/chats/{cid}/messages", {"body": "hello from user"}, alice); assert st == 201, msg

            # Fetch via agent API (should see the user message because it's inbound)
            # Add small sleep to allow async SQLite writes
            time.sleep(0.1)
            
            st, fetch_res = req("POST", f"{base}/agent-actions/chat/fetch", {"agent_instance_id": inst_id}, {"Authorization": f"Bearer {bridge_token}"})
            assert st == 200, fetch_res
            assert len(fetch_res['data']['messages']) == 1, fetch_res['data']['messages']
            
            # Send an agent_to_user message
            st, a2u = req("POST", f"{base}/agent-actions/chat/send-to-user", {"agent_instance_id": inst_id, "params": {"body": "hello from agent", "conversation_id": cid}}, {"Authorization": f"Bearer {bridge_token}"})
            assert st == 201, a2u
            time.sleep(0.2)
            
            # Fetch again (should NOT see the agent_to_user message because include_outgoing is false)
            st, fetch_res2 = req("POST", f"{base}/agent-actions/chat/fetch", {"agent_instance_id": inst_id}, {"Authorization": f"Bearer {bridge_token}"})
            assert st == 200, fetch_res2
            assert len(fetch_res2['data']['messages']) == 1, fetch_res2['data']['messages']
            assert fetch_res2['data']['messages'][0]['body'] == "hello from user"
            
            # Read via agent API
            st, read_res = req("POST", f"{base}/agent-actions/chat/read", {"agent_instance_id": inst_id}, {"Authorization": f"Bearer {bridge_token}"})
            assert st == 200, read_res
            assert read_res['data']['read']['marked_count'] == 1, read_res
            time.sleep(0.2)
            
            # Fetch again (should be 0 because unread_only is true by default)
            st, fetch_res3 = req("POST", f"{base}/agent-actions/chat/fetch", {"agent_instance_id": inst_id}, {"Authorization": f"Bearer {bridge_token}"})
            assert st == 200, fetch_res3
            assert len(fetch_res3['data']['messages']) == 0, fetch_res3['data']['messages']

            print("Behavioral test passed successfully!")

        finally:
            hub.terminate()
            hub.wait()

if __name__ == '__main__':
    main()
