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


def task_show(agent_token, task_id, chain_id=""):
    body = {"agent_token": agent_token, "task_id": task_id}
    if chain_id:
        body["chain_id"] = chain_id
    return request_post("/tasks/show", body)["task"]


def main():
    print("[*] Registering agents...")
    try:
        agent_token = request_post("/register", {
            "agent_class": "test-coder-reviewer-agent",
            "agent_instance_id": "test-coder-reviewer-agent@default",
            "display_name": "Test Coder Reviewer Agent"
        })["agent_token"]
        request_post("/register", {
            "agent_class": "default-reviewer",
            "agent_instance_id": "default-reviewer@default",
            "display_name": "Default Reviewer"
        })
        request_post("/register", {
            "agent_class": "specific-reviewer",
            "agent_instance_id": "specific-reviewer@default",
            "display_name": "Specific Reviewer"
        })
    except Exception as e:
        print("[-] Agent registration failed:", e)
        sys.exit(1)

    print("[*] Test 1: No-reviewer tasks fall back to user_proxy")
    try:
        chain_res1 = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "kind": "coding",
            "wants_vcs": False,
            "no_scaffold": True,
            "title": "Chain with no default reviewer",
            "coordinator_agent_instance_id": "test-coder-reviewer-agent@default"
        })
        chain_id1 = chain_res1["chain_id"]
        task_id1 = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id1,
            "title": "Task with fallback reviewer",
            "assignee_agent_instance_id": "test-coder-reviewer-agent@default"
        })["task_id"]
        task1 = task_show(agent_token, task_id1, chain_id1)
        assert_reviewer("Fallback to user_proxy", "user_proxy", task1.get("reviewer_agent_instance_id"))
    except Exception as e:
        print("[-] Test 1 failed:", e)
        sys.exit(1)

    print("[*] Test 2: Chain default reviewer")
    try:
        chain_res2 = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "kind": "coding",
            "wants_vcs": False,
            "no_scaffold": True,
            "title": "Chain with default reviewer",
            "coordinator_agent_instance_id": "test-coder-reviewer-agent@default",
            "default_reviewer_agent_instance_id": "default-reviewer@default"
        })
        chain_id2 = chain_res2["chain_id"]
        task_id2 = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id2,
            "title": "Task using default reviewer",
            "assignee_agent_instance_id": "test-coder-reviewer-agent@default"
        })["task_id"]
        task2 = task_show(agent_token, task_id2, chain_id2)
        assert_reviewer("Resolve default reviewer", "default-reviewer@default", task2.get("reviewer_agent_instance_id"))
    except Exception as e:
        print("[-] Test 2 failed:", e)
        sys.exit(1)

    print("[*] Test 3: Specific reviewer assignment & removal")
    try:
        request_post("/teams/add-member", {
            "agent_token": agent_token,
            "team_id": chain_res2["team_id"],
            "role_key": "specialist",
            "agent_instance_id": "specific-reviewer@default"
        })

        task_id3 = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id2,
            "title": "Task with specific reviewer",
            "assignee_agent_instance_id": "test-coder-reviewer-agent@default",
            "reviewer_agent_instance_id": "specific-reviewer@default"
        })["task_id"]
        task3 = task_show(agent_token, task_id3, chain_id2)
        assert_reviewer("Resolve specific reviewer", "specific-reviewer@default", task3.get("reviewer_agent_instance_id"))

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

        task3_after = task_show(agent_token, task_id3, chain_id2)
        assert_reviewer(
            "Fallback to default reviewer after specific removed",
            "default-reviewer@default",
            task3_after.get("reviewer_agent_instance_id"),
        )
    except Exception as e:
        print("[-] Test 3 failed:", e)
        sys.exit(1)

    print("[+] ALL REVIEWER TESTS PASSED SUCCESSFULLY!")
    sys.exit(0)


if __name__ == "__main__":
    main()
