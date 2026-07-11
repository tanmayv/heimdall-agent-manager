import urllib.request
import json
import sys

DAEMON_URL = "http://127.0.0.1:49325"

def main():
    agent_id = "test-pref-agent@default"
    
    # 1. Register agent to get a token
    reg_data = json.dumps({
        "agent_class": "test-pref-agent",
        "agent_instance_id": agent_id,
        "display_name": "Test Preferences"
    }).encode("utf-8")
    
    req = urllib.request.Request(
        f"{DAEMON_URL}/register",
        data=reg_data,
        headers={"Content-Type": "application/json"}
    )
    try:
        res = urllib.request.urlopen(req)
        body = json.loads(res.read().decode("utf-8"))
        token = body.get("agent_token")
        if not token:
            print("[-] Registration response missing token:", body)
            sys.exit(1)
    except Exception as e:
        print("[-] Registration failed:", e)
        sys.exit(1)
        
    # 2. Fetch preferences
    req2 = urllib.request.Request(
        f"{DAEMON_URL}/preferences",
        headers={
            "Authorization": f"Bearer {token}"
        }
    )
    try:
        res2 = urllib.request.urlopen(req2)
        body2 = json.loads(res2.read().decode("utf-8"))
    except Exception as e:
        print("[-] Failed to query /preferences:", e)
        sys.exit(1)
        
    if not body2.get("preferences"):
        print("[-] Missing preferences list in response:", body2)
        sys.exit(1)
        
    # Find bootstrap_profile_guidance
    guidance = None
    for pref in body2["preferences"]:
        if pref.get("key") == "bootstrap_profile_guidance":
            guidance = pref.get("value")
            break
            
    if not guidance:
        print("[-] Missing bootstrap_profile_guidance key in preferences list.")
        sys.exit(1)
        
    expected_substr = "If you are the coordinator, reply to `operator@local` with `{ctl_bin} chat send-to-user --token {token} --user-id operator@local --body \"your message\"`."
    if expected_substr not in guidance:
        print("[-] Coordinator-owned user contact instruction NOT found in bootstrap_profile_guidance template!")
        print("    Guidance content was:")
        print(guidance)
        sys.exit(1)
        
    if "If you are not the coordinator, do not use direct `chat send-to-user` for normal user contact." not in guidance:
        print("[-] Non-coordinator user-contact routing instruction NOT found in bootstrap_profile_guidance template!")
        print("    Guidance content was:")
        print(guidance)
        sys.exit(1)

    print("[+] Bootstrap preferences coordinator-only user contact guidance verified successfully!")
    sys.exit(0)

if __name__ == "__main__":
    main()
