import urllib.request
import json
import sys

DAEMON_URL = "http://127.0.0.1:49328"

def request_post(path, data):
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    res = urllib.request.urlopen(req)
    return json.loads(res.read().decode("utf-8"))

def evaluate_pending(tasks, user_id):
    pending = []
    print(f"DEBUG: evaluate_pending called with user_id={repr(user_id)}")
    user_reviewer_ids = {user_id, "user_proxy"}
    for task in tasks:
        if task.get("status") != "review_ready":
            continue
        participants = task.get("participants", [])
        is_part = any(p["agent_instance_id"] in user_reviewer_ids and p["role"] in ["lgtm_required", "lgtm_optional"] for p in participants)
        if not is_part:
            continue
        votes = task.get("votes", [])
        has_voted = any(v["reviewer_agent_instance_id"] in user_reviewer_ids for v in votes)
        print(f"DEBUG evaluate_pending: task={task.get('task_id')} participants={participants} votes={votes} is_part={is_part} has_voted={has_voted} user_reviewer_ids={user_reviewer_ids}")
        if not has_voted:
            pending.append(task)
    return pending

def main():
    print("Registering clients...")
    try:
        # Register User Client
        user_res = request_post("/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "test-client-pending-run"
        })
        client_token = user_res.get("client_token")
        if not client_token:
            print("[-] User client token missing from registration:", user_res)
            sys.exit(1)
    except Exception as e:
        print("[-] User registration failed:", e)
        sys.exit(1)

    try:
        # Register Agent
        agent_res = request_post("/register", {
            "agent_class": "test-coder-pending-agent",
            "agent_instance_id": "test-coder-pending-agent@default",
            "display_name": "Test Coder Pending Agent"
        })
        agent_token = agent_res.get("agent_token")
    except Exception as e:
        print("[-] Agent registration failed:", e)
        sys.exit(1)

    # Create chain
    try:
        chain_res = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "title": "Pending Approvals Test Chain",
            "coordinator_agent_instance_id": "test-coder-pending-agent@default"
        })
        chain_id = chain_res.get("chain_id")

        # 1. Create Task A: status review_ready, operator@local is participant, not voted yet
        print("[*] Creating Task A (pending approval)...")
        task_res_a = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id,
            "title": "Task A (Pending)",
            "assignee_agent_instance_id": "test-coder-pending-agent@default"
        })
        task_id_a = task_res_a.get("task_id")

        # Add operator@local as lgtm_required participant
        request_post("/tasks/participant", {
            "agent_token": agent_token,
            "task_id": task_id_a,
            "chain_id": chain_id,
            "agent_instance_id": "operator@local",
            "role": "lgtm_required"
        })

        # Transition task to review_ready
        request_post("/tasks/participant", {
            "agent_token": agent_token,
            "task_id": task_id_a,
            "chain_id": chain_id,
            "agent_instance_id": "test-coder-pending-agent@default",
            "role": "assignee"
        })
        
        # Move Task A to review_ready
        status_res = request_post("/tasks/status", {
            "agent_token": client_token,
            "client_instance_id": "test-client-pending-run",
            "task_id": task_id_a,
            "chain_id": chain_id,
            "status": "review_ready",
            "body": "ready for review"
        })

        # 2. Create Task B: status in_progress, operator@local is participant
        print("[*] Creating Task B (in progress, should not show in pending)...")
        task_res_b = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id,
            "title": "Task B (In Progress)",
            "assignee_agent_instance_id": "test-coder-pending-agent@default"
        })
        task_id_b = task_res_b.get("task_id")

        request_post("/tasks/participant", {
            "agent_token": agent_token,
            "task_id": task_id_b,
            "chain_id": chain_id,
            "agent_instance_id": "operator@local",
            "role": "lgtm_required"
        })

        # Fetch task lists and evaluate filter
        tasks_list = request_post("/tasks/list", {
            "agent_token": agent_token
        })
        pending_list = evaluate_pending(tasks_list["tasks"], "user_proxy")
        print(f"[*] Pending approvals list size: {len(pending_list)}")
        
        # Verify only Task A is present
        assert len(pending_list) == 1, f"Expected 1 pending task, got {len(pending_list)}"
        assert pending_list[0]["task_id"] == task_id_a, f"Expected pending task to be {task_id_a}"
        print("[+] PASS: Filter correctly identified Task A as pending and excluded Task B.")

        # 3. Vote on Task A and check that it is removed from the pending list
        print("[*] Voting on Task A...")
        vote_res = request_post("/tasks/vote", {
            "agent_token": client_token,
            "client_instance_id": "test-client-pending-run",
            "task_id": task_id_a,
            "chain_id": chain_id,
            "result": "lgtm",
            "comment": "Looks good!"
        })
        if not vote_res.get("ok"):
            raise Exception("Failed to cast vote")

        # Refetch list and evaluate
        tasks_list_after = request_post("/tasks/list", {
            "agent_token": agent_token
        })
        pending_list_after = evaluate_pending(tasks_list_after["tasks"], "user_proxy")
        print(f"[*] Pending approvals list size after vote: {len(pending_list_after)}")
        
        assert len(pending_list_after) == 0, f"Expected 0 pending tasks after vote, got {len(pending_list_after)}"
        print("[+] PASS: Vote correctly removed Task A from pending approvals list.")

        print("[+] ALL PENDING APPROVALS TEST CASES PASSED SUCCESSFULLY!")
        sys.exit(0)
    except Exception as e:
        print("[-] Pending Approvals Test failed:", e)
        sys.exit(1)

if __name__ == "__main__":
    main()
