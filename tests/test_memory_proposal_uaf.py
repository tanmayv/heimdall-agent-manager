import urllib.request
import json
import sys

DAEMON_URL = "http://127.0.0.1:49325"

def request_post(path, data):
    headers = {"Content-Type": "application/json"}
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers=headers,
        method="POST"
    )
    res = urllib.request.urlopen(req)
    return json.loads(res.read().decode("utf-8"))

def main():
    agent_id = "test-mem-agent@default"
    
    # 1. Register agent connection
    try:
        reg_res = request_post("/register", {
            "agent_class": "test-mem-agent",
            "agent_instance_id": agent_id,
            "display_name": "Test Memory"
        })
        token = reg_res.get("agent_token")
        if not token:
            print("[-] Registration response missing token:", reg_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Registration failed:", e)
        sys.exit(1)

    # 2. Create the agent instance record in the database
    print("[*] Creating agent record...")
    try:
        create_res = request_post("/agents/create", {
            "agent_instance_id": agent_id,
            "display_name": "Test Memory",
            "provider_profile": "pi",
            "template_id": "test-mem-agent",
            "model_tier": "normal"
        })
        if not create_res.get("ok"):
            print("[-] Agent record creation failed:", create_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Agent record creation request failed:", e)
        sys.exit(1)

    # 3. Propose new memory
    print("[*] Proposing new memory...")
    try:
        prop_res = request_post("/memory/propose/new", {
            "agent_token": token,
            "subject_agent": agent_id,
            "type": "fact",
            "title": "Initial Title",
            "body": "Initial Body text of proposal",
            "reason": "Initial reason",
            "evidence": "Initial evidence"
        })
        if not prop_res.get("ok"):
            print("[-] Memory propose new failed:", prop_res)
            sys.exit(1)
        proposal_id = prop_res.get("proposal_id")
        memory_id = prop_res.get("memory_id")
    except Exception as e:
        print("[-] Memory propose new request failed:", e)
        sys.exit(1)

    # 4. Decide (approve) proposal so it becomes active record
    print("[*] Approving memory proposal...")
    try:
        dec_res = request_post("/memory/decide", {
            "agent_token": token,
            "proposal_id": proposal_id,
            "decision": "approve"
        })
        if not dec_res.get("ok"):
            print("[-] Memory decide failed:", dec_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Memory decide request failed:", e)
        sys.exit(1)

    # 5. Propose edit (this will load target record and clone strings before target is freed)
    print("[*] Proposing memory edit...")
    try:
        edit_res = request_post("/memory/propose/edit", {
            "agent_token": token,
            "memory_id": memory_id,
            "expected_version": 2,
            "type": "fact",
            "title": "Edited Title",
            "body": "Edited Body text of proposal",
            "reason": "Edit reason",
            "evidence": "Edit evidence"
        })
        if not edit_res.get("ok"):
            print("[-] Memory propose edit failed:", edit_res)
            sys.exit(1)
        edit_proposal_id = edit_res.get("proposal_id")
    except Exception as e:
        print("[-] Memory propose edit request failed:", e)
        sys.exit(1)

    # 6. Decide (approve) edit proposal
    print("[*] Approving memory edit proposal...")
    try:
        dec_edit_res = request_post("/memory/decide", {
            "agent_token": token,
            "proposal_id": edit_proposal_id,
            "decision": "approve"
        })
        if not dec_edit_res.get("ok"):
            print("[-] Memory edit decide failed:", dec_edit_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Memory edit decide request failed:", e)
        sys.exit(1)

    # 7. Propose archive (loads record and clones strings before target is freed)
    print("[*] Proposing memory archive...")
    try:
        arch_res = request_post("/memory/propose/archive", {
            "agent_token": token,
            "memory_id": memory_id,
            "expected_version": 3
        })
        if not arch_res.get("ok"):
            print("[-] Memory propose archive failed:", arch_res)
            sys.exit(1)
        arch_proposal_id = arch_res.get("proposal_id")
    except Exception as e:
        print("[-] Memory propose archive request failed:", e)
        sys.exit(1)

    # 8. Decide (approve) archive proposal
    print("[*] Approving memory archive proposal...")
    try:
        dec_arch_res = request_post("/memory/decide", {
            "agent_token": token,
            "proposal_id": arch_proposal_id,
            "decision": "approve"
        })
        if not dec_arch_res.get("ok"):
            print("[-] Memory archive decide failed:", dec_arch_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Memory archive decide request failed:", e)
        sys.exit(1)

    print("[+] All memory UAF and proposal integration tests passed successfully!")
    sys.exit(0)

if __name__ == "__main__":
    main()
