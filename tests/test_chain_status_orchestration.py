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
    # 1. Register user client
    print("[*] Registering user client...")
    try:
        user_res = request_post("/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "test-client-orch-run"
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
            "agent_class": "test-orch-agent",
            "agent_instance_id": "test-orch-agent@default",
            "display_name": "Test Orch Agent"
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
            "name": "Orch Test Project",
            "description": "testing status orchestration"
        })
        project_id = proj.get("project_id")
        
        chain = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "project_id": project_id,
            "title": "Orch Chain",
            "description": "test",
            "coordinator_agent_instance_id": "test-orch-agent@default"
        })
        chain_id = chain.get("chain_id")
    except Exception as e:
        print("[-] Project/chain creation failed:", e)
        sys.exit(1)

    # 4. Create Task A and Task B
    print("[*] Creating Task A and Task B...")
    try:
        task_a_res = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id,
            "title": "Task A",
            "assignee_agent_instance_id": "test-orch-agent@default"
        })
        task_a_id = task_a_res.get("task_id")

        task_b_res = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id,
            "title": "Task B",
            "depends_on": task_a_id,
            "assignee_agent_instance_id": "test-orch-agent@default"
        })
        task_b_id = task_b_res.get("task_id")
    except Exception as e:
        print("[-] Task creation failed:", e)
        sys.exit(1)

    # 5. Activate the chain
    print("[*] Activating the chain...")
    try:
        act_res = request_post("/task-chains/activate", {
            "agent_token": agent_token,
            "chain_id": chain_id
        })
        if not act_res.get("ok"):
            print("[-] Chain activation failed:", act_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Chain activation request failed:", e)
        sys.exit(1)

    # Verify initial statuses after activation
    try:
        show_a = request_post("/tasks/show", {"agent_token": agent_token, "task_id": task_a_id})
        assert_status("Task A status after activation", "in_progress", show_a.get("task", {}).get("status"))

        show_b = request_post("/tasks/show", {"agent_token": agent_token, "task_id": task_b_id})
        assert_status("Task B status after activation", "planning", show_b.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Verification after activation failed:", e)
        sys.exit(1)

    # 6. Complete the chain (which should cancel all non-terminal tasks, freeing up slots)
    print("[*] Completing the chain...")
    try:
        comp_res = request_post("/task-chains/complete", {
            "agent_token": agent_token,
            "chain_id": chain_id,
            "final_summary": "done testing chain completion status orchestration"
        })
        if not comp_res.get("ok"):
            print("[-] Chain completion failed:", comp_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Chain completion request failed:", e)
        sys.exit(1)

    # Verify that Task A and Task B have been cancelled
    try:
        show_a = request_post("/tasks/show", {"agent_token": agent_token, "task_id": task_a_id})
        assert_status("Task A status after chain completed", "cancelled", show_a.get("task", {}).get("status"))

        show_b = request_post("/tasks/show", {"agent_token": agent_token, "task_id": task_b_id})
        assert_status("Task B status after chain completed", "cancelled", show_b.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Verification after chain completion failed:", e)
        sys.exit(1)

    # 7. Test Transition back to planning status
    print("[*] Creating second chain for planning reversion test...")
    try:
        chain2 = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "project_id": project_id,
            "title": "Orch Chain 2",
            "description": "test 2",
            "coordinator_agent_instance_id": "test-orch-agent@default"
        })
        chain2_id = chain2.get("chain_id")

        task_c_res = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain2_id,
            "title": "Task C",
            "assignee_agent_instance_id": "test-orch-agent@default"
        })
        task_c_id = task_c_res.get("task_id")

        task_d_res = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain2_id,
            "title": "Task D"
        })
        task_d_id = task_d_res.get("task_id")
    except Exception as e:
        print("[-] Second chain / Tasks creation failed:", e)
        sys.exit(1)

    print("[*] Activating second chain...")
    try:
        act_res = request_post("/task-chains/activate", {
            "agent_token": agent_token,
            "chain_id": chain2_id
        })
        if not act_res.get("ok"):
            print("[-] Chain 2 activation failed:", act_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Chain 2 activation request failed:", e)
        sys.exit(1)

    # Verify Task C is active, Task D is ready (since it has no assignee to auto-claim)
    try:
        show_c = request_post("/tasks/show", {"agent_token": agent_token, "task_id": task_c_id})
        assert_status("Task C status after activation", "in_progress", show_c.get("task", {}).get("status"))

        show_d = request_post("/tasks/show", {"agent_token": agent_token, "task_id": task_d_id})
        assert_status("Task D status after activation", "ready", show_d.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Verification of Task C/D after activation failed:", e)
        sys.exit(1)

    # Revert Chain 2 status back to planning
    print("[*] Reverting Chain 2 back to planning status...")
    try:
        revert_res = request_post("/task-chains/status", {
            "agent_token": agent_token,
            "chain_id": chain2_id,
            "status": "planning"
        })
        if not revert_res.get("ok"):
            print("[-] Chain 2 revert failed:", revert_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Chain 2 revert request failed:", e)
        sys.exit(1)

    # Verify Task C and D are reverted to planning status
    try:
        show_c = request_post("/tasks/show", {"agent_token": agent_token, "task_id": task_c_id})
        assert_status("Task C status after chain reverted to planning", "planning", show_c.get("task", {}).get("status"))

        show_d = request_post("/tasks/show", {"agent_token": agent_token, "task_id": task_d_id})
        assert_status("Task D status after chain reverted to planning", "planning", show_d.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Verification of Task C/D after planning reversion failed:", e)
        sys.exit(1)

    # 8. Transition Chain 2 back to in_progress via status REST endpoint
    print("[*] Transitioning Chain 2 back to in_progress status...")
    try:
        revert_res = request_post("/task-chains/status", {
            "agent_token": agent_token,
            "chain_id": chain2_id,
            "status": "in_progress"
        })
        if not revert_res.get("ok"):
            print("[-] Chain 2 transition to in_progress failed:", revert_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Chain 2 transition to in_progress request failed:", e)
        sys.exit(1)

    # Verify Task C is promoted back to in_progress (via ready -> in_progress) and Task D is ready
    try:
        show_c = request_post("/tasks/show", {"agent_token": agent_token, "task_id": task_c_id})
        assert_status("Task C status after chain transitioned to in_progress", "in_progress", show_c.get("task", {}).get("status"))

        show_d = request_post("/tasks/show", {"agent_token": agent_token, "task_id": task_d_id})
        assert_status("Task D status after chain transitioned to in_progress", "ready", show_d.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Verification of Task C/D after in_progress transition failed:", e)
        sys.exit(1)

    # 9. Transition Chain 2 to ready status via status REST endpoint
    # Revert to planning first
    print("[*] Reverting Chain 2 back to planning status for ready transition test...")
    try:
        revert_res = request_post("/task-chains/status", {
            "agent_token": agent_token,
            "chain_id": chain2_id,
            "status": "planning"
        })
        if not revert_res.get("ok"):
            print("[-] Chain 2 revert failed:", revert_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Chain 2 revert request failed:", e)
        sys.exit(1)

    print("[*] Transitioning Chain 2 to ready status...")
    try:
        revert_res = request_post("/task-chains/status", {
            "agent_token": agent_token,
            "chain_id": chain2_id,
            "status": "ready"
        })
        if not revert_res.get("ok"):
            print("[-] Chain 2 transition to ready failed:", revert_res)
            sys.exit(1)
    except Exception as e:
        print("[-] Chain 2 transition to ready request failed:", e)
        sys.exit(1)

    # Verify Task C is promoted back to in_progress (since slot is free) and Task D is ready
    try:
        show_c = request_post("/tasks/show", {"agent_token": agent_token, "task_id": task_c_id})
        assert_status("Task C status after chain transitioned to ready", "in_progress", show_c.get("task", {}).get("status"))

        show_d = request_post("/tasks/show", {"agent_token": agent_token, "task_id": task_d_id})
        assert_status("Task D status after chain transitioned to ready", "ready", show_d.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Verification of Task C/D after ready transition failed:", e)
        sys.exit(1)

    print("[+] CHAIN STATUS ORCHESTRATION TEST PASSED!")
    sys.exit(0)

if __name__ == "__main__":
    main()
