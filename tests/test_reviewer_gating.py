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

def assert_status(label, expected, actual):
    if expected != actual:
        print(f"[-] FAIL: {label} (expected status '{expected}', got '{actual}')")
        sys.exit(1)
    print(f"[+] PASS: {label} ({actual})")

def main():
    # 1. Register User Client
    print("[*] Registering user client...")
    try:
        user_res = request_post("/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "test-client-gating-run"
        })
        user_token = user_res.get("client_token")
        if not user_token:
            print("[-] Registration response missing client_token:", user_res)
            sys.exit(1)
    except Exception as e:
        print("[-] User registration failed:", e)
        sys.exit(1)

    # 2. Register Coder and Reviewer Agents
    print("[*] Registering agents...")
    try:
        coder_res = request_post("/register", {
            "agent_class": "coder-agent",
            "agent_instance_id": "coder-agent@default",
            "display_name": "Coder Agent"
        })
        coder_token = coder_res.get("agent_token")

        reviewer_res = request_post("/register", {
            "agent_class": "reviewer-agent",
            "agent_instance_id": "reviewer-agent@default",
            "display_name": "Reviewer Agent"
        })
        reviewer_token = reviewer_res.get("agent_token")
    except Exception as e:
        print("[-] Agent registration failed:", e)
        sys.exit(1)

    # 3. Create project & chain
    print("[*] Creating project & chain...")
    try:
        proj = request_post("/projects/create", {
            "agent_token": coder_token,
            "name": "Gating Test Project",
            "description": "testing reviewer gating constraint"
        })
        project_id = proj.get("project_id")
        
        chain = request_post("/task-chains/create", {
            "agent_token": coder_token,
            "project_id": project_id,
            "title": "Gating Chain",
            "description": "test gating",
            "coordinator_agent_instance_id": "coder-agent@default"
        })
        chain_id = chain.get("chain_id")
    except Exception as e:
        print("[-] Project/chain creation failed:", e)
        sys.exit(1)

    # 4. Create Task A (assigned to reviewer) and Task B (assigned to coder)
    print("[*] Creating Task A and Task B...")
    try:
        task_a_res = request_post("/tasks/create", {
            "agent_token": coder_token,
            "chain_id": chain_id,
            "title": "Task A (Reviewer Task)",
            "assignee_agent_instance_id": "reviewer-agent@default"
        })
        task_a_id = task_a_res.get("task_id")

        task_b_res = request_post("/tasks/create", {
            "agent_token": coder_token,
            "chain_id": chain_id,
            "title": "Task B (Coder Task)",
            "assignee_agent_instance_id": "coder-agent@default"
        })
        task_b_id = task_b_res.get("task_id")
    except Exception as e:
        print("[-] Task creation failed:", e)
        sys.exit(1)

    # 5. Add reviewer-agent@default as lgtm_required participant to Task B
    print("[*] Setting reviewer-agent as required reviewer for Task B...")
    try:
        part_res = request_post("/tasks/participant", {
            "agent_token": coder_token,
            "task_id": task_b_id,
            "chain_id": chain_id,
            "agent_instance_id": "reviewer-agent@default",
            "role": "lgtm_required"
        })
        if not part_res.get("ok"):
            print("[-] Failed to add participant:", part_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Participant request failed:", e)
        sys.exit(1)

    # 6. Activate the chain
    print("[*] Activating the chain...")
    try:
        act_res = request_post("/task-chains/activate", {
            "agent_token": coder_token,
            "chain_id": chain_id
        })
        if not act_res.get("ok"):
            print("[-] Chain activation failed:", act_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Chain activation request failed:", e)
        sys.exit(1)

    # Verify both tasks auto-claimed to in_progress
    try:
        show_a = request_post("/tasks/show", {"agent_token": coder_token, "task_id": task_a_id})
        assert_status("Task A status after activation", "in_progress", show_a.get("task", {}).get("status"))

        show_b = request_post("/tasks/show", {"agent_token": coder_token, "task_id": task_b_id})
        assert_status("Task B status after activation", "in_progress", show_b.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Initial status check failed:", e)
        sys.exit(1)

    # 7. Complete Task B (assigned to coder) so it transitions to review_ready
    print("[*] Transitioning Task B to review_ready...")
    try:
        done_res = request_post("/tasks/done", {
            "agent_token": coder_token,
            "task_id": task_b_id,
            "chain_id": chain_id,
            "comment": "Completed Task B, needs review"
        })
        if not done_res.get("ok"):
            print("[-] Task B transition to review_ready failed:", done_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Task B done request failed:", e)
        sys.exit(1)

    # Verify Task B is review_ready and Task A is now blocked!
    try:
        show_b = request_post("/tasks/show", {"agent_token": coder_token, "task_id": task_b_id})
        assert_status("Task B status", "review_ready", show_b.get("task", {}).get("status"))

        show_a = request_post("/tasks/show", {"agent_token": coder_token, "task_id": task_a_id})
        assert_status("Task A status (gated reviewer)", "blocked", show_a.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Verification after Task B completion failed:", e)
        sys.exit(1)

    # 8. Cast LGTM review vote on Task B from reviewer-agent@default
    print("[*] Casting LGTM vote on Task B from reviewer-agent...")
    try:
        vote_res = request_post("/tasks/vote", {
            "agent_token": reviewer_token,
            "task_id": task_b_id,
            "chain_id": chain_id,
            "result": "lgtm",
            "comment": "LGTM! Approved."
        })
        if not vote_res.get("ok"):
            print("[-] Vote failed:", vote_res)
            sys.exit(1)
    except Exception as e:
        print("[*] Vote request failed:", e)
        sys.exit(1)

    # Verify Task B is approved and Task A is resumed back to in_progress!
    try:
        show_b = request_post("/tasks/show", {"agent_token": coder_token, "task_id": task_b_id})
        assert_status("Task B status after review approval", "approved", show_b.get("task", {}).get("status"))

        show_a = request_post("/tasks/show", {"agent_token": coder_token, "task_id": task_a_id})
        assert_status("Task A status after review approval (unblocked)", "in_progress", show_a.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Verification after review approval failed:", e)
        sys.exit(1)

    print("[+] REVIEWER GATING TEST PASSED!")
    sys.exit(0)

if __name__ == "__main__":
    main()
