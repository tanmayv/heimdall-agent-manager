import socket
import urllib.request
import json
import sys

DAEMON_URL = "http://127.0.0.1:49325"

def main():
    agent_id = "test-reconnect-agent@default"
    
    # 1. Register agent (first time, no token)
    reg_data = json.dumps({
        "agent_class": "test-reconnect-agent",
        "agent_instance_id": agent_id,
        "display_name": "Test Reconnect"
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
        
    # 2. Re-register (reconnect) passing the same token
    reconnect_data = json.dumps({
        "agent_class": "test-reconnect-agent",
        "agent_instance_id": agent_id,
        "display_name": "Test Reconnect",
        "agent_token": token
    }).encode("utf-8")
    
    req2 = urllib.request.Request(
        f"{DAEMON_URL}/register",
        data=reconnect_data,
        headers={"Content-Type": "application/json"}
    )
    try:
        res2 = urllib.request.urlopen(req2)
        body2 = json.loads(res2.read().decode("utf-8"))
        print("Second registration response (reconnect):", body2)
        if "agent_token" in body2:
            print("SUCCESS: Re-registration with token succeeded!")
        else:
            print("FAIL: Re-registration failed:", body2)
            sys.exit(1)
    except urllib.error.HTTPError as e:
        print("FAIL: HTTP error during reconnect:", e.code, e.read().decode('utf-8'))
        sys.exit(1)
    except Exception as e:
        print("FAIL: Re-registration request failed:", e)
        sys.exit(1)
        
    print("RECONNECT TOKEN TEST PASSED!")
    sys.exit(0)

if __name__ == "__main__":
    main()
