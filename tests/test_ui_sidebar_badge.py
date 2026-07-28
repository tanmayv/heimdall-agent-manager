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


def compute_badge_count(tasks):
    count = 0
    for task in tasks:
        if task.get("status") != "review_ready":
            continue
        participants = task.get("participants", [])
        needs_user_review = any(
            p["agent_instance_id"] == "user_proxy" and p["role"] == "lgtm_required"
            for p in participants
        )
        if not needs_user_review:
            continue
        votes = task.get("votes", [])
        has_voted = any(v["reviewer_agent_instance_id"] == "user_proxy" for v in votes)
        if not has_voted:
            count += 1
    return count


def main():
    print("Registering clients...")
    try:
        client_token = request_post("/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "test-client-badge-run"
        })["client_token"]
    except Exception as e:
        print("[-] User registration failed:", e)
        sys.exit(1)

    try:
        agent_token = request_post("/register", {
            "agent_class": "test-coder-badge-agent",
            "agent_instance_id": "test-coder-badge-agent@default",
            "display_name": "Test Coder Badge Agent"
        })["agent_token"]
    except Exception as e:
        print("[-] Agent registration failed:", e)
        sys.exit(1)

    try:
        tasks_list = request_post("/tasks/list", {"agent_token": agent_token})
        initial_count = compute_badge_count(tasks_list["tasks"])
        print(f"[*] Initial badge count: {initial_count}")
        assert initial_count == 0, f"Expected 0 badge count initially, got {initial_count}"

        chain_id = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "wants_vcs": False,
            "title": "Badge Test Chain",
            "coordinator_agent_instance_id": "test-coder-badge-agent@default"
        })["chain_id"]

        print("[*] Creating Task A...")
        task_id_a = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id,
            "title": "Task A",
            "assignee_agent_instance_id": "test-coder-badge-agent@default"
        })["task_id"]

        request_post("/tasks/participant", {
            "agent_token": agent_token,
            "task_id": task_id_a,
            "chain_id": chain_id,
            "agent_instance_id": "user_proxy",
            "role": "lgtm_required"
        })

        request_post("/tasks/status", {
            "agent_token": client_token,
            "client_instance_id": "test-client-badge-run",
            "task_id": task_id_a,
            "chain_id": chain_id,
            "status": "review_ready",
            "body": "ready for review"
        })

        tasks_list_after = request_post("/tasks/list", {"agent_token": agent_token})
        badge_count_after = compute_badge_count(tasks_list_after["tasks"])
        print(f"[*] Badge count after review request: {badge_count_after}")
        assert badge_count_after == 1, f"Expected badge count 1, got {badge_count_after}"

        print("[*] Voting on Task A...")
        request_post("/tasks/vote", {
            "agent_token": client_token,
            "client_instance_id": "test-client-badge-run",
            "task_id": task_id_a,
            "chain_id": chain_id,
            "result": "lgtm",
            "comment": "LGTM!"
        })

        tasks_list_final = request_post("/tasks/list", {"agent_token": agent_token})
        final_badge_count = compute_badge_count(tasks_list_final["tasks"])
        print(f"[*] Final badge count after voting: {final_badge_count}")
        assert final_badge_count == 0, f"Expected 0 badge count after voting, got {final_badge_count}"

        print("[+] PASS: Sidebar badge count accurately reflects outstanding pending approvals.")
        print("[+] ALL SIDEBAR BADGE TEST CASES PASSED SUCCESSFULLY!")
        sys.exit(0)
    except Exception as e:
        print("[-] Sidebar Badge Test failed:", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
