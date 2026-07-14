import urllib.request
import urllib.error
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
            "kind": "coding",
            "status": "planning",
            "wants_vcs": False,
            "no_scaffold": True,
            "title": "Gating Chain",
            "description": "test gating",
            "coordinator_agent_instance_id": "coder-agent@default"
        })
        chain_id = chain.get("chain_id")
        discovery_task_id = chain.get("discovery_task_id")
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

    # Verify discovery task is in_progress, Task A is in_progress, and Task B is queued (coder busy with discovery)
    try:
        show_disc = request_post("/tasks/show", {"agent_token": coder_token, "task_id": discovery_task_id})
        assert_status("Discovery task status after activation", "in_progress", show_disc.get("task", {}).get("status"))

        show_a = request_post("/tasks/show", {"agent_token": coder_token, "task_id": task_a_id})
        assert_status("Task A status after activation", "in_progress", show_a.get("task", {}).get("status"))

        show_b = request_post("/tasks/show", {"agent_token": coder_token, "task_id": task_b_id})
        assert_status("Task B status after activation", "queued", show_b.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Initial status check failed:", e)
        sys.exit(1)

    # Complete Discovery Task
    print("[*] Transitioning Discovery task to review_ready...")
    try:
        done_disc = request_post("/tasks/done", {
            "agent_token": coder_token,
            "task_id": discovery_task_id,
            "chain_id": chain_id,
            "comment": "Discovery complete"
        })
        if not done_disc.get("ok"):
            print("[-] Discovery task done failed:", done_disc)
            sys.exit(1)
    except Exception as e:
        print("[-] Discovery task done request failed:", e)
        sys.exit(1)

    # Approve Discovery Task (requires user review)
    print("[*] Approving Discovery task...")
    try:
        vote_disc = request_post("/tasks/vote", {
            "agent_token": user_token,
            "task_id": discovery_task_id,
            "chain_id": chain_id,
            "result": "lgtm",
            "comment": "Approved Discovery"
        })
        if not vote_disc.get("ok"):
            print("[-] Vote Discovery failed:", vote_disc)
            sys.exit(1)
    except Exception as e:
        print("[-] Vote Discovery request failed:", e)
        sys.exit(1)

    # Verify Discovery Task is approved and Task B is now in_progress (auto-claimed)
    try:
        show_disc = request_post("/tasks/show", {"agent_token": coder_token, "task_id": discovery_task_id})
        assert_status("Discovery task status after approval", "approved", show_disc.get("task", {}).get("status"))

        show_b = request_post("/tasks/show", {"agent_token": coder_token, "task_id": task_b_id})
        assert_status("Task B status after discovery approval", "in_progress", show_b.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Verification after discovery approval failed:", e)
        sys.exit(1)

    # 7. Complete Task A (assigned to reviewer) first, so they have no active tasks
    print("[*] Transitioning Task A to review_ready...")
    try:
        done_a = request_post("/tasks/done", {
            "agent_token": reviewer_token,
            "task_id": task_a_id,
            "chain_id": chain_id,
            "comment": "Completed Task A"
        })
        if not done_a.get("ok"):
            print("[-] Task A done failed:", done_a)
            sys.exit(1)
    except Exception as e:
        print("[-] Task A done request failed:", e)
        sys.exit(1)

    # Approve Task A via user (operator) so it is fully terminal (approved)
    print("[*] Approving Task A...")
    try:
        vote_a = request_post("/tasks/vote", {
            "agent_token": user_token,
            "task_id": task_a_id,
            "chain_id": chain_id,
            "result": "lgtm",
            "comment": "Approved Task A"
        })
        if not vote_a.get("ok"):
            print("[-] Vote Task A failed:", vote_a)
            sys.exit(1)
    except Exception as e:
        print("[-] Vote Task A request failed:", e)
        sys.exit(1)

    # Verify Task A is approved
    try:
        show_a = request_post("/tasks/show", {"agent_token": coder_token, "task_id": task_a_id})
        assert_status("Task A status after approval", "approved", show_a.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Verification of Task A approval failed:", e)
        sys.exit(1)

    # 8. Complete Task B (assigned to coder) so it transitions to review_ready
    # This creates a pending review for reviewer-agent
    print("[*] Transitioning Task B to review_ready...")
    try:
        done_b = request_post("/tasks/done", {
            "agent_token": coder_token,
            "task_id": task_b_id,
            "chain_id": chain_id,
            "comment": "Completed Task B, needs review"
        })
        if not done_b.get("ok"):
            print("[-] Task B done failed:", done_b)
            sys.exit(1)
    except Exception as e:
        print("[-] Task B done request failed:", e)
        sys.exit(1)

    # Verify Task B is review_ready
    try:
        show_b = request_post("/tasks/show", {"agent_token": coder_token, "task_id": task_b_id})
        assert_status("Task B status", "review_ready", show_b.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Verification of Task B review_ready failed:", e)
        sys.exit(1)

    # 9. Create a new Task C assigned to reviewer-agent
    print("[*] Creating Task C (assigned to reviewer)...")
    try:
        task_c_res = request_post("/tasks/create", {
            "agent_token": coder_token,
            "chain_id": chain_id,
            "title": "Task C (New Reviewer Task)",
            "assignee_agent_instance_id": "reviewer-agent@default"
        })
        task_c_id = task_c_res.get("task_id")
    except Exception as e:
        print("[-] Task C creation failed:", e)
        sys.exit(1)

    # Try to claim Task C via /tasks/next -> should return null because reviewer is gated
    print("[*] Attempting to claim Task C via /tasks/next (should return null due to pending review)...")
    try:
        next_res = request_post("/tasks/next", {
            "agent_token": reviewer_token
        })
        if next_res.get("task") is not None:
            print("[-] FAIL: Claim Task C with pending review (expected task to be null, got:", next_res.get("task"))
            sys.exit(1)
        print("[+] PASS: Claim Task C with pending review returned null")
    except Exception as e:
        print("[-] Claim Task C request failed:", e)
        sys.exit(1)

    # 10. Cast LGTM review vote on Task B from reviewer-agent@default
    print("[*] Casting LGTM vote on Task B from reviewer-agent...")
    try:
        vote_b = request_post("/tasks/vote", {
            "agent_token": reviewer_token,
            "task_id": task_b_id,
            "chain_id": chain_id,
            "result": "lgtm",
            "comment": "LGTM! Approved Task B"
        })
        if not vote_b.get("ok"):
            print("[-] Vote Task B failed:", vote_b)
            sys.exit(1)
    except Exception as e:
        print("[-] Vote Task B request failed:", e)
        sys.exit(1)

    # Verify Task B is approved
    try:
        show_b = request_post("/tasks/show", {"agent_token": coder_token, "task_id": task_b_id})
        assert_status("Task B status after review approval", "approved", show_b.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Verification of Task B approval failed:", e)
        sys.exit(1)

    # 11. Now try to claim Task C again via /tasks/next -> should SUCCEED
    print("[*] Attempting to claim Task C again via /tasks/next (should succeed)...")
    try:
        next_res = request_post("/tasks/next", {
            "agent_token": reviewer_token
        })
        task_c = next_res.get("task")
        if task_c is None:
            print("[-] FAIL: Claim Task C after review approval (expected task C, got null)")
            sys.exit(1)
        assert_status("Task C status after claim via next", "in_progress", task_c.get("status"))
        if task_c.get("task_id") != task_c_id:
            print(f"[-] FAIL: Claimed wrong task (expected {task_c_id}, got {task_c.get('task_id')})")
            sys.exit(1)
        print("[+] PASS: Claim Task C succeeded")
    except Exception as e:
        print("[-] Claim Task C request failed:", e)
        sys.exit(1)

    # Verify Task C is in_progress via show
    try:
        show_c = request_post("/tasks/show", {"agent_token": coder_token, "task_id": task_c_id})
        assert_status("Task C status after claim (show)", "in_progress", show_c.get("task", {}).get("status"))
    except Exception as e:
        print("[-] Verification of Task C status failed:", e)
        sys.exit(1)

    print("[+] REVIEWER GATING TEST PASSED!")
    sys.exit(0)

if __name__ == "__main__":
    main()
