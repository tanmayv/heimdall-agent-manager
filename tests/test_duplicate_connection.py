import socket
import urllib.request
import json
import time
import sys

DAEMON_URL = "http://127.0.0.1:49325"
HOST = "127.0.0.1"
PORT = 49325

def main():
    agent_id = "test-dup-agent@default"
    
    # 1. Register agent
    reg_data = json.dumps({
        "agent_class": "test-dup-agent",
        "agent_instance_id": agent_id,
        "display_name": "Test Dup"
    }).encode("utf-8")
    
    req = urllib.request.Request(
        f"{DAEMON_URL}/register",
        data=reg_data,
        headers={"Content-Type": "application/json"}
    )
    try:
        res = urllib.request.urlopen(req)
        body = json.loads(res.read().decode("utf-8"))
        print("First registration response:", body)
        token = body.get("agent_token")
    except Exception as e:
        print("First registration failed:", e)
        sys.exit(1)
        
    # 2. Establish TCP connection and send WebSocket upgrade handshake
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((HOST, PORT))
    
    handshake = (
        f"GET /ws/{agent_id} HTTP/1.1\r\n"
        f"Host: {HOST}:{PORT}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    s.sendall(handshake.encode("utf-8"))
    
    # Read response
    resp = s.recv(4096).decode("utf-8")
    print("Handshake response:")
    print(resp)
    if "101 Switching Protocols" not in resp:
        print("WebSocket upgrade failed!")
        sys.exit(1)
        
    # 3. Register duplicate agent
    req2 = urllib.request.Request(
        f"{DAEMON_URL}/register",
        data=reg_data,
        headers={"Content-Type": "application/json"}
    )
    try:
        res2 = urllib.request.urlopen(req2)
        body2 = json.loads(res2.read().decode("utf-8"))
        print("Second registration response:", body2)
        if "agent_token" in body2:
            print("SUCCESS: Second registration succeeded!")
        else:
            print("FAIL: Second registration failed:", body2)
            sys.exit(1)
    except Exception as e:
        print("FAIL: Second registration request failed:", e)
        sys.exit(1)
        
    # 4. Verify first connection was closed by the server
    s.settimeout(2.0)
    try:
        data = s.recv(1024)
        if len(data) == 0:
            print("SUCCESS: First connection was closed by the server!")
        else:
            # We might receive a duplicate check frame or similar first
            # But the server should close the connection shortly.
            # Let's read again if we received data
            print("Received data from server:", data)
            data2 = s.recv(1024)
            if len(data2) == 0:
                print("SUCCESS: First connection was closed by the server after sending frame!")
            else:
                print("FAIL: First connection is still open, received second data:", data2)
                sys.exit(1)
    except socket.timeout:
        print("FAIL: First connection did not close (timed out waiting for close)")
        sys.exit(1)
    except Exception as e:
        print("SUCCESS: First connection closed with exception:", e)

    print("ALL DUPLICATE CONNECTION PREFERENCE TESTS PASSED!")
    sys.exit(0)

if __name__ == "__main__":
    main()
