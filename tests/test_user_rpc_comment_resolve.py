import urllib.request
import json
import sys

DAEMON_URL = "http://127.0.0.1:49325"

def request_post(path, data):
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    res = urllib.request.urlopen(req)
    return json.loads(res.read().decode("utf-8"))

def main():
    # 1. Register user client
    print("[*] Registering user client...")
    try:
        user_res = request_post("/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "test-client-resolve-run"
        })
        client_token = user_res.get("client_token")
        if not client_token:
            print("[-] Registration response missing client_token:", user_res)
            sys.exit(1)
    except Exception as e:
        print("[-] User registration failed:", e)
        sys.exit(1)

    # 2. Register agent
    try:
        agent_res = request_post("/register", {
            "agent_class": "test-resolve-agent",
            "agent_instance_id": "test-resolve-agent@default",
            "display_name": "Test Resolve Agent"
        })
        agent_token = agent_res.get("agent_token")
    except Exception as e:
        print("[-] Agent registration failed:", e)
        sys.exit(1)

    # 3. Create project & chain
    print("[*] Creating project & chain...")
    try:
        proj = request_post("/projects/create", {
            "agent_token": agent_token,
            "name": "Resolve Test Project",
            "description": "testing comments resolution"
        })
        project_id = proj.get("project_id")
        
        chain = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "project_id": project_id,
            "title": "Resolve Chain",
            "description": "test",
            "coordinator_agent_instance_id": "test-resolve-agent@default"
        })
        chain_id = chain.get("chain_id")
    except Exception as e:
        print("[-] Project/chain creation failed:", e)
        sys.exit(1)

    # 4. Create task
    print("[*] Creating task...")
    try:
        task_res = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id,
            "title": "Resolve Task",
            "status": "ready"
        })
        task_id = task_res.get("task_id")
    except Exception as e:
        print("[-] Task creation failed:", e)
        sys.exit(1)

    # 5. Add unresolved comment via user-rpc
    print("[*] Adding comment via user-rpc...")
    try:
        comment_res = request_post("/user-rpc", {
            "action": "task_comment",
            "client_instance_id": "test-client-resolve-run",
            "client_token": client_token,
            "task_id": task_id,
            "chain_id": chain_id,
            "body": "Need verification of component status"
        })
        if not comment_res.get("ok"):
            print("[-] Comment creation failed:", comment_res)
            sys.exit(1)
        comment_id = comment_res.get("comment_id")
        print("[+] Created comment ID:", comment_id)
    except Exception as e:
        print("[-] Comment request failed:", e)
        sys.exit(1)

    # 6. Verify comment is unresolved
    print("[*] Verifying comment is unresolved...")
    try:
        show_res = request_post("/tasks/show", {
            "agent_token": agent_token,
            "task_id": task_id
        })
        task = show_res.get("task")
        unresolved = task.get("unresolved_comments", [])
        if not any(c.get("comment_id") == comment_id for c in unresolved):
            print("[-] Comment not found in unresolved list:", unresolved)
            sys.exit(1)
    except Exception as e:
        print("[-] Show task request failed:", e)
        sys.exit(1)

    # 7. Resolve comment via user-rpc task_comment_resolve
    print("[*] Resolving comment via user-rpc task_comment_resolve...")
    try:
        resolve_res = request_post("/user-rpc", {
            "action": "task_comment_resolve",
            "client_instance_id": "test-client-resolve-run",
            "client_token": client_token,
            "task_id": task_id,
            "chain_id": chain_id,
            "comment_id": comment_id
        })
        if not resolve_res.get("ok"):
            print("[-] Comment resolution failed:", resolve_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Comment resolution request failed:", e)
        sys.exit(1)

    # 8. Verify comment is no longer unresolved
    print("[*] Verifying comment is resolved...")
    try:
        show_res = request_post("/tasks/show", {
            "agent_token": agent_token,
            "task_id": task_id
        })
        task = show_res.get("task")
        unresolved = task.get("unresolved_comments", [])
        if any(c.get("comment_id") == comment_id for c in unresolved):
            print("[-] Comment still present in unresolved list after resolution:", unresolved)
            sys.exit(1)
    except Exception as e:
        print("[-] Show task request failed post-resolution:", e)
        sys.exit(1)

    print("[+] USER-RPC COMMENT RESOLVE TEST PASSED!")
    sys.exit(0)

if __name__ == "__main__":
    main()
