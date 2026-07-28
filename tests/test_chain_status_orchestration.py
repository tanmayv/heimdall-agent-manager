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


def assert_status(label, expected, actual):
    if expected != actual:
        print(f"[-] FAIL: {label} (expected status '{expected}', got '{actual}')")
        sys.exit(1)
    print(f"[+] PASS: {label} ({actual})")


def show_task(agent_token, task_id):
    return request_post("/tasks/show", {"agent_token": agent_token, "task_id": task_id})["task"]


def approve_discovery(agent_token, client_token, chain_id, discovery_task_id):
    done_res = request_post("/tasks/done", {
        "agent_token": agent_token,
        "task_id": discovery_task_id,
        "chain_id": chain_id,
        "body": "discovery complete"
    })
    if not done_res.get("ok"):
        print("[-] Discovery handoff failed:", done_res)
        sys.exit(1)
    vote_res = request_post("/tasks/vote", {
        "agent_token": client_token,
        "client_instance_id": "test-client-orch-run",
        "task_id": discovery_task_id,
        "chain_id": chain_id,
        "result": "lgtm",
        "comment": "approved"
    })
    if not vote_res.get("ok"):
        print("[-] Discovery approval failed:", vote_res)
        sys.exit(1)


def main():
    print("[*] Registering user client...")
    try:
        client_token = request_post("/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "test-client-orch-run"
        })["client_token"]
    except Exception as e:
        print("[-] User registration failed:", e)
        sys.exit(1)

    try:
        agent_token = request_post("/register", {
            "agent_class": "test-orch-agent",
            "agent_instance_id": "test-orch-agent@default",
            "display_name": "Test Orch Agent"
        })["agent_token"]
    except Exception as e:
        print("[-] Agent registration failed:", e)
        sys.exit(1)

    print("[*] Creating project & chain...")
    try:
        project_id = request_post("/projects/create", {
            "agent_token": agent_token,
            "name": "Orch Test Project",
            "description": "testing status orchestration"
        })["project_id"]

        chain = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "project_id": project_id,
            "wants_vcs": False,
            "title": "Orch Chain",
            "description": "test",
            "coordinator_agent_instance_id": "test-orch-agent@default"
        })
        chain_id = chain["chain_id"]
        discovery_task_id = chain["discovery_task_id"]
    except Exception as e:
        print("[-] Project/chain creation failed:", e)
        sys.exit(1)

    print("[*] Creating Task A and Task B...")
    try:
        task_a_id = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id,
            "title": "Task A",
            "assignee_agent_instance_id": "test-orch-agent@default"
        })["task_id"]

        task_b_id = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id,
            "title": "Task B",
            "depends_on": task_a_id,
            "assignee_agent_instance_id": "test-orch-agent@default"
        })["task_id"]
    except Exception as e:
        print("[-] Task creation failed:", e)
        sys.exit(1)

    print("[*] Approving discovery for the chain...")
    try:
        approve_discovery(agent_token, client_token, chain_id, discovery_task_id)
    except Exception as e:
        print("[-] Discovery approval failed:", e)
        sys.exit(1)

    try:
        show_a = show_task(agent_token, task_a_id)
        assert_status("Task A status after discovery approval", "in_progress", show_a.get("status"))

        show_b = show_task(agent_token, task_b_id)
        assert_status("Task B status after discovery approval", "planning", show_b.get("status"))
    except Exception as e:
        print("[-] Verification after discovery approval failed:", e)
        sys.exit(1)

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

    try:
        assert_status("Task A status after chain completed", "cancelled", show_task(agent_token, task_a_id).get("status"))
        assert_status("Task B status after chain completed", "cancelled", show_task(agent_token, task_b_id).get("status"))
    except Exception as e:
        print("[-] Verification after chain completion failed:", e)
        sys.exit(1)

    print("[*] Creating second chain for planning reversion test...")
    try:
        chain2 = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "project_id": project_id,
            "wants_vcs": False,
            "title": "Orch Chain 2",
            "description": "test 2",
            "coordinator_agent_instance_id": "test-orch-agent@default"
        })
        chain2_id = chain2["chain_id"]
        discovery_task2 = chain2["discovery_task_id"]

        task_c_id = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain2_id,
            "title": "Task C",
            "assignee_agent_instance_id": "test-orch-agent@default"
        })["task_id"]

        task_d_id = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain2_id,
            "title": "Task D"
        })["task_id"]
    except Exception as e:
        print("[-] Second chain / Tasks creation failed:", e)
        sys.exit(1)

    print("[*] Approving discovery for second chain...")
    try:
        approve_discovery(agent_token, client_token, chain2_id, discovery_task2)
    except Exception as e:
        print("[-] Discovery approval for chain 2 failed:", e)
        sys.exit(1)

    try:
        assert_status("Task C status after discovery approval", "in_progress", show_task(agent_token, task_c_id).get("status"))
        assert_status("Task D status after discovery approval", "queued", show_task(agent_token, task_d_id).get("status"))
    except Exception as e:
        print("[-] Verification of Task C/D after discovery approval failed:", e)
        sys.exit(1)

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

    try:
        assert_status("Task C status after chain reverted to planning", "queued", show_task(agent_token, task_c_id).get("status"))
        assert_status("Task D status after chain reverted to planning", "queued", show_task(agent_token, task_d_id).get("status"))
    except Exception as e:
        print("[-] Verification of Task C/D after planning reversion failed:", e)
        sys.exit(1)

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

    try:
        assert_status("Task C status after chain transitioned to in_progress", "in_progress", show_task(agent_token, task_c_id).get("status"))
        assert_status("Task D status after chain transitioned to in_progress", "queued", show_task(agent_token, task_d_id).get("status"))
    except Exception as e:
        print("[-] Verification of Task C/D after in_progress transition failed:", e)
        sys.exit(1)

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

    try:
        assert_status("Task C status after chain transitioned to ready", "queued", show_task(agent_token, task_c_id).get("status"))
        assert_status("Task D status after chain transitioned to ready", "queued", show_task(agent_token, task_d_id).get("status"))
    except Exception as e:
        print("[-] Verification of Task C/D after ready transition failed:", e)
        sys.exit(1)

    print("[+] CHAIN STATUS ORCHESTRATION TEST PASSED!")
    sys.exit(0)


if __name__ == "__main__":
    main()
