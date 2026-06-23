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

def partition_participants(task):
    participants = task.get("participants", [])
    required = [p for p in participants if p["role"] == "lgtm_required"]
    optional = [p for p in participants if p["role"] != "lgtm_required"]
    return required, optional

def main():
    print("Registering clients...")
    try:
        # Register User Client
        user_res = request_post("/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "test-client-merge-run"
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
            "agent_class": "test-coder-merge-agent",
            "agent_instance_id": "test-coder-merge-agent@default",
            "display_name": "Test Coder Merge Agent"
        })
        agent_token = agent_res.get("agent_token")
    except Exception as e:
        print("[-] Agent registration failed:", e)
        sys.exit(1)

    # Create chain
    try:
        chain_res = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "title": "Merge Test Chain",
            "coordinator_agent_instance_id": "test-coder-merge-agent@default"
        })
        chain_id = chain_res.get("chain_id")

        # Create Task A
        print("[*] Creating Task A...")
        task_res_a = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id,
            "title": "Task A",
            "assignee_agent_instance_id": "test-coder-merge-agent@default"
        })
        task_id_a = task_res_a.get("task_id")

        # Add participants with varying roles
        print("[*] Adding participants...")
        # 1. lgtm_required reviewer
        request_post("/tasks/participant", {
            "agent_token": agent_token,
            "task_id": task_id_a,
            "chain_id": chain_id,
            "agent_instance_id": "required-reviewer@default",
            "role": "lgtm_required"
        })
        # 2. lgtm_optional reviewer
        request_post("/tasks/participant", {
            "agent_token": agent_token,
            "task_id": task_id_a,
            "chain_id": chain_id,
            "agent_instance_id": "optional-reviewer@default",
            "role": "lgtm_optional"
        })
        # 3. subscriber
        request_post("/tasks/participant", {
            "agent_token": agent_token,
            "task_id": task_id_a,
            "chain_id": chain_id,
            "agent_instance_id": "subscriber-agent@default",
            "role": "subscriber"
        })

        # Fetch task details and partition
        tasks_list = request_post("/tasks/list", {
            "agent_token": agent_token
        })
        task = next(t for t in tasks_list["tasks"] if t["task_id"] == task_id_a)
        
        required, optional = partition_participants(task)
        
        print(f"[*] Required reviewers: {[r['agent_instance_id'] for r in required]}")
        print(f"[*] Optional reviewers & participants: {[o['agent_instance_id'] for o in optional]}")

        # Assertions
        assert len(required) == 1, f"Expected 1 required reviewer, got {len(required)}"
        assert required[0]["agent_instance_id"] == "required-reviewer@default", "Mismatch in required reviewer ID"
        
        # Note: the assignee (test-coder-merge-agent@default) is also in optional/participants list
        assert len(optional) == 3, f"Expected 3 optional participants, got {len(optional)}"
        optional_ids = [o["agent_instance_id"] for o in optional]
        assert "optional-reviewer@default" in optional_ids, "optional-reviewer missing from optional list"
        assert "subscriber-agent@default" in optional_ids, "subscriber missing from optional list"
        assert "test-coder-merge-agent@default" in optional_ids, "assignee missing from optional list"
        
        print("[+] PASS: Partition criteria correctly split participants into required and optional groups.")
        print("[+] ALL CONCEPTS MERGE TEST CASES PASSED SUCCESSFULLY!")
        sys.exit(0)
    except Exception as e:
        print("[-] Reviewer Merge Test failed:", e)
        sys.exit(1)

if __name__ == "__main__":
    main()
