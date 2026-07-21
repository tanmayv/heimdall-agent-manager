import urllib.request
import urllib.error
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

def assert_http_error(label, path, data, expected_status=400):
    try:
        request_post(path, data)
        print(f"[-] FAIL: {label} (expected HTTP {expected_status}, but request succeeded)")
        sys.exit(1)
    except urllib.error.HTTPError as e:
        if e.code == expected_status:
            print(f"[+] PASS: {label} (received HTTP {expected_status} as expected)")
        else:
            print(f"[-] FAIL: {label} (expected HTTP {expected_status}, got {e.code})")
            sys.exit(1)
    except Exception as e:
        print(f"[-] FAIL: {label} (unexpected error: {e})")
        sys.exit(1)

def main():
    # 1. Register User Client
    print("[*] Registering user client...")
    try:
        user_res = request_post("/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "test-client-conflict-run"
        })
        user_token = user_res.get("client_token")
    except Exception as e:
        print("[-] User registration failed:", e)
        sys.exit(1)

    # 2. Register Coder and Coordinator Agents
    try:
        agent_res = request_post("/register", {
            "agent_class": "agent-a",
            "agent_instance_id": "agent-a@default",
            "display_name": "Agent A"
        })
        agent_token = agent_res.get("agent_token")

        coord_res = request_post("/register", {
            "agent_class": "coordinator-agent",
            "agent_instance_id": "coordinator-agent@default",
            "display_name": "Coordinator Agent"
        })
        coord_token = coord_res.get("agent_token")
    except Exception as e:
        print("[-] Agent registration failed:", e)
        sys.exit(1)

    # 3. Create a chain
    chain_res = request_post("/task-chains/create", {
        "agent_token": agent_token,
        "status": "planning",
        "title": "Conflict Test Chain",
        "coordinator_agent_instance_id": "coordinator-agent@default"
    })
    chain_id = chain_res.get("chain_id")

    # Scenario 1: Reject task creation if assignee == reviewer
    print("[*] Test 1: Reject task creation if assignee == reviewer")
    assert_http_error(
        "Task creation conflict (assignee == reviewer)",
        "/tasks/create",
        {
            "agent_token": agent_token,
            "chain_id": chain_id,
            "title": "Conflicting Task",
            "assignee_agent_instance_id": "agent-a@default",
            "reviewer_agent_instance_id": "agent-a@default"
        },
        expected_status=400
    )

    # Scenario 2: Create a task with specific reviewer, try to assign it to them
    print("[*] Test 2: Reject assignment if agent is already required reviewer")
    # First create a valid task with reviewer="agent-a@default" and no assignee
    task_res2 = request_post("/tasks/create", {
        "agent_token": agent_token,
        "chain_id": chain_id,
        "title": "Task with reviewer first",
        "reviewer_agent_instance_id": "agent-a@default"
    })
    task_id2 = task_res2.get("task_id")
    
    # Try to assign it to agent-a@default (who is already a required reviewer)
    assert_http_error(
        "Task assignment conflict (assignee is already reviewer)",
        "/tasks/assign",
        {
            "agent_token": agent_token,
            "task_id": task_id2,
            "chain_id": chain_id,
            "agent_instance_id": "agent-a@default"
        },
        expected_status=400
    )

    # Scenario 3: Create a task with assignee="agent-a@default", try to add them as required reviewer
    print("[*] Test 3: Reject participant addition of role lgtm_required if assignee")
    task_res3 = request_post("/tasks/create", {
        "agent_token": agent_token,
        "chain_id": chain_id,
        "title": "Task with assignee first",
        "assignee_agent_instance_id": "agent-a@default"
    })
    task_id3 = task_res3.get("task_id")

    assert_http_error(
        "Participant role conflict (adding assignee as reviewer)",
        "/tasks/participant",
        {
            "agent_token": agent_token,
            "task_id": task_id3,
            "chain_id": chain_id,
            "agent_instance_id": "agent-a@default",
            "role": "lgtm_required"
        },
        expected_status=400
    )

    # Scenario 4: Create a task with reviewer="agent-a@default", try to add them as assignee
    print("[*] Test 4: Reject participant addition of role assignee if required reviewer")
    task_res4 = request_post("/tasks/create", {
        "agent_token": agent_token,
        "chain_id": chain_id,
        "title": "Task with reviewer first for participant add",
        "reviewer_agent_instance_id": "agent-a@default"
    })
    task_id4 = task_res4.get("task_id")

    assert_http_error(
        "Participant role conflict (adding reviewer as assignee)",
        "/tasks/participant",
        {
            "agent_token": agent_token,
            "task_id": task_id4,
            "chain_id": chain_id,
            "agent_instance_id": "agent-a@default",
            "role": "assignee"
        },
        expected_status=400
    )

    # Scenario 5: Default reviewer self-review prevention
    print("[*] Test 5: Reject task creation if assignee is default reviewer")
    chain_res5 = request_post("/task-chains/create", {
        "agent_token": agent_token,
        "title": "Chain with default reviewer self-review",
        "coordinator_agent_instance_id": "coordinator-agent@default",
        "default_reviewer_agent_instance_id": "agent-a@default"
    })
    chain_id5 = chain_res5.get("chain_id")

    assert_http_error(
        "Task creation conflict (assignee == default reviewer)",
        "/tasks/create",
        {
            "agent_token": agent_token,
            "chain_id": chain_id5,
            "title": "Task assigned to default reviewer",
            "assignee_agent_instance_id": "agent-a@default"
        },
        expected_status=400
    )

    # Scenario 6: Default reviewer can vote and approve
    print("[*] Test 6: Default reviewer voting and auto-approval")
    # Register another agent for the task (assignee: agent-a@default, reviewer: default-reviewer@default)
    try:
        rev_agent_res = request_post("/register", {
            "agent_class": "default-reviewer",
            "agent_instance_id": "default-reviewer@default",
            "display_name": "Default Reviewer"
        })
        rev_agent_token = rev_agent_res.get("agent_token")
    except Exception as e:
        print("[-] Reviewer registration failed:", e)
        sys.exit(1)

    chain_res6 = request_post("/task-chains/create", {
        "agent_token": agent_token,
        "status": "planning",
        "title": "Chain for voting test",
        "coordinator_agent_instance_id": "coordinator-agent@default",
        "default_reviewer_agent_instance_id": "default-reviewer@default"
    })
    chain_id6 = chain_res6.get("chain_id")

    task_res6 = request_post("/tasks/create", {
        "agent_token": agent_token,
        "chain_id": chain_id6,
        "title": "Task for voting test",
        "assignee_agent_instance_id": "agent-a@default"
    })
    task_id6 = task_res6.get("task_id")

    # Activate the chain
    act_res = request_post("/task-chains/activate", {
        "agent_token": agent_token,
        "chain_id": chain_id6
    })
    if not act_res.get("ok"):
        print(f"[-] FAIL: Chain activation failed: {act_res}")
        sys.exit(1)

    # Let's verify status of task is in_progress
    tasks_list6 = request_post("/tasks/list", {
        "agent_token": agent_token
    })
    task6 = next(t for t in tasks_list6["tasks"] if t["task_id"] == task_id6)
    if task6["status"] != "in_progress":
        print(f"[-] FAIL: Expected status 'in_progress', got '{task6['status']}'")
        sys.exit(1)

    request_post("/tasks/done", {
        "agent_token": agent_token,
        "task_id": task_id6,
        "chain_id": chain_id6,
        "body": "completed work, ready for review"
    })

    # Default reviewer votes approved
    vote_res = request_post("/tasks/vote", {
        "agent_token": rev_agent_token,
        "task_id": task_id6,
        "chain_id": chain_id6,
        "result": "lgtm",
        "comment": "lgtm!"
    })
    if not vote_res.get("ok"):
        print(f"[-] FAIL: Default reviewer vote failed: {vote_res}")
        sys.exit(1)

    # Verify task auto-approves
    tasks_list_final = request_post("/tasks/list", {
        "agent_token": agent_token
    })
    task6_final = next(t for t in tasks_list_final["tasks"] if t["task_id"] == task_id6)
    if task6_final["status"] != "approved":
        print(f"[-] FAIL: Expected task status 'approved', got '{task6_final['status']}'")
        sys.exit(1)
    print("[+] PASS: Default reviewer voting and auto-approval verified successfully")

    print("[+] ALL CONFLICT AND VOTING TESTS PASSED SUCCESSFULLY!")

if __name__ == "__main__":
    main()
