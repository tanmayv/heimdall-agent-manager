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

def assert_reviewer(label, expected, actual):
    if expected != actual:
        print(f"[-] FAIL: {label} (expected reviewer '{expected}', got '{actual}')")
        sys.exit(1)
    print(f"[+] PASS: {label} ({actual})")

def main():
    # 1. Register User Client
    print("[*] Registering user client...")
    try:
        user_res = request_post("/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "test-client-reviewer-run"
        })
        client_token = user_res.get("client_token")
        if not client_token:
            print("[-] Registration response missing client_token:", user_res)
            sys.exit(1)
    except Exception as e:
        print("[-] User registration failed:", e)
        sys.exit(1)

    # 2. Register Coder Agent
    try:
        agent_res = request_post("/register", {
            "agent_class": "test-coder-reviewer-agent",
            "agent_instance_id": "test-coder-reviewer-agent@default",
            "display_name": "Test Coder Reviewer Agent"
        })
        agent_token = agent_res.get("agent_token")
    except Exception as e:
        print("[-] Agent registration failed:", e)
        sys.exit(1)

    # 3. Test User Fallback: Create a chain with NO default reviewer
    print("[*] Test 1: User Fallback (no default reviewer)")
    try:
        chain_res1 = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "title": "Chain with no default reviewer",
            "coordinator_agent_instance_id": "test-coder-reviewer-agent@default"
        })
        chain_id1 = chain_res1.get("chain_id")

        task_res1 = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id1,
            "title": "Task with fallback reviewer",
            "assignee_agent_instance_id": "test-coder-reviewer-agent@default"
        })
        task_id1 = task_res1.get("task_id")

        # Fetch task details and verify fallback to operator@local
        tasks_list1 = request_post("/tasks/list", {
            "agent_token": agent_token
        })
        task1 = next(t for t in tasks_list1["tasks"] if t["task_id"] == task_id1)
        assert_reviewer("Fallback to operator@local", "operator@local", task1.get("reviewer_agent_instance_id"))
    except Exception as e:
        print("[-] Test 1 failed:", e)
        sys.exit(1)

    # 4. Test Chain Default Reviewer
    print("[*] Test 2: Chain Default Reviewer")
    try:
        chain_res2 = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "title": "Chain with default reviewer",
            "coordinator_agent_instance_id": "test-coder-reviewer-agent@default",
            "default_reviewer_agent_instance_id": "default-reviewer@default"
        })
        chain_id2 = chain_res2.get("chain_id")

        task_res2 = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id2,
            "title": "Task using default reviewer",
            "assignee_agent_instance_id": "test-coder-reviewer-agent@default"
        })
        task_id2 = task_res2.get("task_id")

        tasks_list2 = request_post("/tasks/list", {
            "agent_token": agent_token
        })
        task2 = next(t for t in tasks_list2["tasks"] if t["task_id"] == task_id2)
        assert_reviewer("Resolve default reviewer", "default-reviewer@default", task2.get("reviewer_agent_instance_id"))
    except Exception as e:
        print("[-] Test 2 failed:", e)
        sys.exit(1)

    # 5. Test Specific Reviewer Assignment and Replacement (Removal)
    print("[*] Test 3: Specific Reviewer Assignment & Removal")
    try:
        task_res3 = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id2,
            "title": "Task with specific reviewer",
            "assignee_agent_instance_id": "test-coder-reviewer-agent@default",
            "reviewer_agent_instance_id": "specific-reviewer@default"
        })
        task_id3 = task_res3.get("task_id")

        # Assert specific reviewer
        tasks_list3 = request_post("/tasks/list", {
            "agent_token": agent_token
        })
        task3 = next(t for t in tasks_list3["tasks"] if t["task_id"] == task_id3)
        assert_reviewer("Resolve specific reviewer", "specific-reviewer@default", task3.get("reviewer_agent_instance_id"))

        # Remove the specific reviewer participant
        print("[*] Removing specific reviewer participant...")
        remove_res = request_post("/tasks/participant/remove", {
            "agent_token": agent_token,
            "task_id": task_id3,
            "chain_id": chain_id2,
            "agent_instance_id": "specific-reviewer@default",
            "role": "lgtm_required"
        })
        if not remove_res.get("ok"):
            raise Exception(f"Failed to remove participant: {remove_res}")

        # Assert reviewer falls back to chain default reviewer
        tasks_list4 = request_post("/tasks/list", {
            "agent_token": agent_token
        })
        task3_after = next(t for t in tasks_list4["tasks"] if t["task_id"] == task_id3)
        assert_reviewer("Fallback to default reviewer after specific removed", "default-reviewer@default", task3_after.get("reviewer_agent_instance_id"))
    except Exception as e:
        print("[-] Test 3 failed:", e)
        sys.exit(1)

    print("[+] ALL REVIEWER TESTS PASSED SUCCESSFULLY!")
    sys.exit(0)

if __name__ == "__main__":
    main()
