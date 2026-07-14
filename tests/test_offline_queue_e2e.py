import urllib.request
import urllib.error
import json
import sys
import socket
import time

DAEMON_URL = "http://127.0.0.1:49325"
HOST = "127.0.0.1"
PORT = 49325

def request_post(path, data):
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    try:
        res = urllib.request.urlopen(req)
        raw_body = res.read()
        try:
            return json.loads(raw_body.decode("utf-8"))
        except json.JSONDecodeError as je:
            print(f"JSONDecodeError on POST {path}!")
            print("Raw response body (first 1000 chars):", raw_body.decode("utf-8")[:1000])
            print("Raw response body (last 1000 chars):", raw_body.decode("utf-8")[-1000:])
            raise je
    except urllib.error.HTTPError as e:
        print(f"HTTP ERROR on POST {path}: {e.code} - {e.read().decode('utf-8')}")
        raise e

def recv_ws_text(s, initial_buffer=b""):
    buffer = initial_buffer
    
    def read_exactly(n):
        nonlocal buffer
        while len(buffer) < n:
            chunk = s.recv(n - len(buffer))
            if not chunk:
                break
            buffer += chunk
        res = buffer[:n]
        buffer = buffer[n:]
        return res

    # Read the first two bytes of the WebSocket frame
    header = read_exactly(2)
    if len(header) < 2:
        return None
    fin_opcode = header[0]
    payload_len = header[1] & 0x7f
    if payload_len == 126:
        len_bytes = read_exactly(2)
        payload_len = int.from_bytes(len_bytes, byteorder='big')
    elif payload_len == 127:
        len_bytes = read_exactly(8)
        payload_len = int.from_bytes(len_bytes, byteorder='big')
    
    # Read payload
    payload = read_exactly(payload_len)
    return payload.decode('utf-8')

def main():
    agent_id = "test-queue-agent@default"
    
    # 1. Register User Client
    print("[*] Registering user client...")
    user_res = request_post("/user-client/register", {
        "user_id": "operator@local",
        "client_instance_id": "test-client-queue-run"
    })
    user_token = user_res.get("client_token")
    if not user_token:
        print("[-] FAIL: Failed to register user client")
        sys.exit(1)

    # 2. Register Agent and Coordinator
    print("[*] Registering agent and coordinator...")
    agent_res = request_post("/register", {
        "agent_class": "test-queue-agent",
        "agent_instance_id": agent_id,
        "display_name": "Test Queue Agent"
    })
    agent_token = agent_res.get("agent_token")
    if not agent_token:
        print("[-] FAIL: Failed to register agent")
        sys.exit(1)

    coord_res = request_post("/register", {
        "agent_class": "coordinator-agent",
        "agent_instance_id": "coordinator-agent@default",
        "display_name": "Coordinator Agent"
    })
    coord_token = coord_res.get("agent_token")
    if not coord_token:
        print("[-] FAIL: Failed to register coordinator")
        sys.exit(1)

    # 3. Connect WebSocket first time (establishes the online record)
    print("[*] Connecting agent WebSocket...")
    s1 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s1.connect((HOST, PORT))
    
    handshake = (
        f"GET /ws/{agent_id} HTTP/1.1\r\n"
        f"Host: {HOST}:{PORT}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    s1.sendall(handshake.encode("utf-8"))
    resp = s1.recv(4096).decode("utf-8")
    if "101 Switching Protocols" not in resp:
        print("[-] FAIL: WebSocket upgrade failed")
        sys.exit(1)
        
    print("[+] Agent WebSocket connected successfully!")

    # 4. Create Project, Chain, and Task
    print("[*] Creating project, chain, and task...")
    proj_res = request_post("/projects/create", {
        "agent_token": agent_token,
        "name": "Queue Test Proj",
        "description": "test queueing"
    })
    project_id = proj_res["project_id"]
    
    chain_res = request_post("/task-chains/create", {
        "agent_token": agent_token,
        "project_id": project_id,
        "kind": "coding",
        "status": "planning",
        "no_scaffold": True,
        "title": "Queue Test Chain",
        "description": "test queueing",
        "coordinator_agent_instance_id": "coordinator-agent@default"
    })
    chain_id = chain_res["chain_id"]
    
    task_res = request_post("/tasks/create", {
        "agent_token": agent_token,
        "chain_id": chain_id,
        "title": "Queue Test Task",
        "description": "test queueing",
        "assignee_agent_instance_id": agent_id
    })
    task_id = task_res["task_id"]
    
    # Activate the chain
    request_post("/task-chains/activate", {
        "agent_token": agent_token,
        "chain_id": chain_id
    })

    # 5. Disconnect WebSocket (going offline)
    print("[*] Disconnecting agent WebSocket (going offline)...")
    s1.close()
    time.sleep(0.5)  # Allow server to detect disconnect

    # 6. Send nudge notification from user client (agent is offline, so notification should be queued)
    print("[*] Sending nudge to offline agent...")
    nudge_res = request_post("/tasks/nudge", {
        "agent_token": user_token,
        "task_id": task_id,
        "chain_id": chain_id,
        "body": "Nudge message to offline agent"
    })
    if not nudge_res.get("ok"):
        print("[-] FAIL: Nudge failed:", nudge_res)
        sys.exit(1)
    
    print("[+] Nudge request completed successfully (queued by server).")

    # 7. Connect WebSocket second time (reconnecting)
    print("[*] Reconnecting agent WebSocket...")
    s2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s2.connect((HOST, PORT))
    s2.sendall(handshake.encode("utf-8"))
    resp_bytes = s2.recv(4096)
    header_end = resp_bytes.find(b"\r\n\r\n")
    if header_end < 0:
        print("[-] FAIL: WebSocket reconnect handshake response header end not found")
        sys.exit(1)
        
    header_part = resp_bytes[:header_end].decode("utf-8")
    if "101 Switching Protocols" not in header_part:
        print("[-] FAIL: WebSocket reconnect failed, handshake response:", header_part)
        sys.exit(1)
        
    remaining_bytes = resp_bytes[header_end + 4:]
    print("[+] Reconnected! Waiting to receive queued notification...")
    
    # 8. Read frame from s2 (should be the queued nudge notification)
    s2.settimeout(3.0)
    try:
        frame_text = recv_ws_text(s2, remaining_bytes)
        if not frame_text:
            print("[-] FAIL: No notification received upon reconnect")
            sys.exit(1)
        
        print("[+] Received frame content:", frame_text)
        notification = json.loads(frame_text)
        if (notification.get("type") == "task_event" and 
            notification.get("event") == "Task_Nudged" and 
            "Nudge message to offline agent" in notification.get("body", "")):
            # Check event_id, created_unix_ms, interrupt
            evt_id = notification.get("event_id")
            created = notification.get("created_unix_ms")
            inter = notification.get("interrupt")
            if not isinstance(evt_id, str) or not evt_id.startswith("taskevt_"):
                print("[-] FAIL: event_id is invalid:", evt_id)
                sys.exit(1)
            if not isinstance(created, int) or created <= 0:
                print("[-] FAIL: created_unix_ms is invalid:", created)
                sys.exit(1)
            if inter is not True:
                print("[-] FAIL: interrupt is not True:", inter)
                sys.exit(1)
            print("[+] SUCCESS: Queued offline notification with event_id, created_unix_ms, and interrupt received successfully!")
        else:
            print("[-] FAIL: Received unexpected notification:", notification)
            sys.exit(1)
            
    except socket.timeout:
        print("[-] FAIL: Timeout waiting for queued notification")
        sys.exit(1)
    except Exception as e:
        print("[-] FAIL: Error receiving notification:", e)
        sys.exit(1)
    finally:
        s2.close()

    print("ALL OFFLINE NOTIFICATION QUEUEING TESTS PASSED!")
    sys.exit(0)

if __name__ == "__main__":
    main()
