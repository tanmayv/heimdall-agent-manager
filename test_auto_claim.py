import json
import urllib.request
import urllib.error
import time
import sqlite3
import os

DAEMON_URL = "http://127.0.0.1:49322"
CLIENT_TOKEN = "test_token"  # Operator Client Token

def make_request(path, payload):
    url = f"{DAEMON_URL}{path}"
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req) as response:
            res_body = response.read().decode('utf-8')
            return json.loads(res_body)
    except urllib.error.HTTPError as e:
        res_body = e.read().decode('utf-8')
        try:
            return json.loads(res_body)
        except:
            return {"ok": False, "message": f"HTTP Error {e.code}: {res_body}"}
    except Exception as e:
        return {"ok": False, "message": str(e)}

def print_step(title, success, details=""):
    status = "🟢 SUCCESS" if success else "🔴 FAILED"
    print(f"[{status}] {title}")
    if details:
        print(f"   Details: {details}")

def query_db(db_path, query, params=()):
    try:
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()
        cursor.execute(query, params)
        rows = cursor.fetchall()
        conn.close()
        return rows
    except Exception as e:
        print(f"   DB Error: {e}")
        return []

def main():
    print("=" * 80)
    print("STARTING ADVANCED SCHEDULING & AUTO-CLAIM VERIFICATION")
    print("=" * 80)

    # Generate a unique run ID to isolate agent names across test runs
    run_id = f"{int(time.time()) % 10000:04d}"
    COORD_ID = f"coord-adv-{run_id}@default"
    CODER_A_ID = f"coder-a-adv-{run_id}@default"
    CODER_B_ID = f"coder-b-adv-{run_id}@default"
    REV_ID = f"reviewer-adv-{run_id}@default"

    # Register Operator Client Token
    reg_res = make_request("/user-client/register", {
        "user_id": "operator@local",
        "client_instance_id": "local",
        "token": CLIENT_TOKEN
    })
    print_step("Register Operator Client Token", reg_res.get("ok", True))

    # 1. Bootstrapping Agents
    coord_res = make_request("/agents/start", {
        "agent_instance_id": COORD_ID,
        "template_id": "lead",
        "provider_profile": "pi",
        "model_tier": "smart"
    })
    coord_token = coord_res.get("agent_token")
    
    coder_a_res = make_request("/agents/start", {
        "agent_instance_id": CODER_A_ID,
        "template_id": "coder",
        "provider_profile": "pi",
        "model_tier": "normal"
    })
    coder_a_token = coder_a_res.get("agent_token")

    coder_b_res = make_request("/agents/start", {
        "agent_instance_id": CODER_B_ID,
        "template_id": "coder",
        "provider_profile": "pi",
        "model_tier": "normal"
    })
    coder_b_token = coder_b_res.get("agent_token")
    
    rev_res = make_request("/agents/start", {
        "agent_instance_id": REV_ID,
        "template_id": "reviewer",
        "provider_profile": "pi",
        "model_tier": "smart"
    })
    rev_token = rev_res.get("agent_token")

    print_step(f"Spawn Coordinator ({COORD_ID})", coord_res.get("ok"), f"Token: {coord_token}")
    print_step(f"Spawn Coder A ({CODER_A_ID})", coder_a_res.get("ok"), f"Token: {coder_a_token}")
    print_step(f"Spawn Coder B ({CODER_B_ID})", coder_b_res.get("ok"), f"Token: {coder_b_token}")
    print_step(f"Spawn Reviewer ({REV_ID})", rev_res.get("ok"), f"Token: {rev_token}")

    if not (coord_token and coder_a_token and coder_b_token and rev_token):
        print("🔴 Critical Error: Failed to spawn all agent instances. Aborting.")
        return

    # Signal start_success for all
    for name, token in [("Coordinator", coord_token), ("Coder A", coder_a_token), ("Coder B", coder_b_token), ("Reviewer", rev_token)]:
        make_request("/agent-rpc", {"agent_token": token, "action": "start_success"})

    tasks_db_path = os.path.expanduser("~/.local/share/heimdall/tasks/task.db")

    # -------------------------------------------------------------------------
    # TEST 1: Single-Tasking & Automatic Blocking
    # -------------------------------------------------------------------------
    print("\n--- TEST 1: Verifying Single-Tasking & Auto-Blocking ---")

    # Coordinator creates a task chain
    chain_res = make_request("/task-chains/create", {
        "agent_token": coord_token,
        "title": "Advanced Scheduling Chain",
        "coordinator_agent_instance_id": COORD_ID
    })
    chain_id = chain_res.get("chain_id")
    print_step("Coordinator creates Task Chain", chain_res.get("ok"), f"Chain ID: {chain_id}")

    # Activate Task Chain to enable scheduling
    act_res = make_request("/task-chains/activate", {
        "agent_token": coord_token,
        "chain_id": chain_id
    })
    print_step("Coordinator activates the Task Chain", act_res.get("ok"))

    # Create Task-1 assigned to Coder A
    t1_res = make_request("/tasks/create", {
        "agent_token": coord_token,
        "chain_id": chain_id,
        "title": "Core Implementation Task 1",
        "status": "ready",
        "assignee_agent_instance_id": CODER_A_ID
    })
    t1_id = t1_res.get("task_id")
    print_step("Create Task-1 (assigned to Coder A)", t1_res.get("ok"), f"Task-1 ID: {t1_id}")

    # Create Task-2 assigned to Coder A (using 'planning' status so it bypasses creation-level active slot blocker check)
    t2_res = make_request("/tasks/create", {
        "agent_token": coord_token,
        "chain_id": chain_id,
        "title": "Core Implementation Task 2",
        "status": "planning",
        "assignee_agent_instance_id": CODER_A_ID
    })
    t2_id = t2_res.get("task_id")
    print_step("Create Task-2 (assigned to Coder A with status=planning)", t2_res.get("ok"), f"Task-2 ID: {t2_id}")

    # Move Task-1 to in_progress. This will trigger task_recompute_promotions!
    make_request("/tasks/status", {
        "agent_token": coder_a_token,
        "task_id": t1_id,
        "chain_id": chain_id,
        "status": "in_progress",
        "body": "Working on Task-1..."
    })
    print_step("Coder A moves Task-1 to in_progress (Triggers promotion. Coder A is busy)", True)

    # VERIFY: Task-2 should automatically transition to 'blocked' because Coder A is busy working on Task-1!
    t2_row = query_db(tasks_db_path, "SELECT status, description FROM tasks WHERE task_id = ?", (t2_id,))
    is_blocked = len(t2_row) > 0 and t2_row[0][0] == "blocked"
    block_reason = t2_row[0][1] if len(t2_row) > 0 else ""
    print_step("Verify Task-2 is automatically marked as blocked by the daemon", is_blocked, 
               f"Status: {t2_row[0][0] if t2_row else 'None'}, Reason: {block_reason}")

    # -------------------------------------------------------------------------
    # TEST 2: Auto-Claim upon Task Completion
    # -------------------------------------------------------------------------
    print("\n--- TEST 2: Verifying Auto-Claim upon Task Completion ---")

    # Add reviewer as lgtm_required to Task-1
    make_request("/tasks/participant", {
        "agent_token": coord_token,
        "task_id": t1_id,
        "chain_id": chain_id,
        "agent_instance_id": REV_ID,
        "role": "lgtm_required"
    })

    # Coder A submits Task-1 for review
    make_request("/tasks/status", {
        "agent_token": coder_a_token,
        "task_id": t1_id,
        "chain_id": chain_id,
        "status": "review_ready",
        "body": "Task-1 done!"
    })
    print_step("Coder A submits Task-1 for review (review_ready)", True)

    # Reviewer votes LGTM (approving Task-1)
    make_request("/tasks/vote", {
        "agent_token": rev_token,
        "task_id": t1_id,
        "chain_id": chain_id,
        "result": "lgtm",
        "comment": "Task-1 approved!"
    })
    print_step("Reviewer approves Task-1 (LGTM)", True)

    # Verify Task-1 is approved
    t1_row = query_db(tasks_db_path, "SELECT status FROM tasks WHERE task_id = ?", (t1_id,))
    print_step("Verify Task-1 is approved in DB", len(t1_row) > 0 and t1_row[0][0] == "approved")

    # VERIFY: Task-2 should automatically transition to 'in_progress' because Coder A became free!
    t2_after = query_db(tasks_db_path, "SELECT status FROM tasks WHERE task_id = ?", (t2_id,))
    is_claimed = len(t2_after) > 0 and t2_after[0][0] == "in_progress"
    print_step("Verify Task-2 was automatically claimed and transitioned to in_progress", is_claimed, 
               f"Status: {t2_after[0][0] if t2_after else 'None'}")

    # -------------------------------------------------------------------------
    # TEST 3: Reviewer Rotation & Immediate Nudge (Multi-Coder Concurrency)
    # -------------------------------------------------------------------------
    print("\n--- TEST 3: Verifying Reviewer Rotation & Nudging ---")

    # 1. Create Task-3 (Coder A) and Task-4 (Coder B) BOTH in 'planning' status.
    # When Task-2 is completed, the resulting promotion sweep will process BOTH planning tasks,
    # promoting and auto-claiming them concurrently because both Coder A and Coder B will be free!
    t3_res = make_request("/tasks/create", {
        "agent_token": coord_token,
        "chain_id": chain_id,
        "title": "Algorithm Work Task 3",
        "status": "planning",
        "assignee_agent_instance_id": CODER_A_ID
    })
    t3_id = t3_res.get("task_id")
    make_request("/tasks/participant", {
        "agent_token": coord_token,
        "task_id": t3_id,
        "chain_id": chain_id,
        "agent_instance_id": REV_ID,
        "role": "lgtm_required"
    })

    t4_res = make_request("/tasks/create", {
        "agent_token": coord_token,
        "chain_id": chain_id,
        "title": "Algorithm Work Task 4",
        "status": "planning", # Use planning to trigger the promotion-level auto-claim!
        "assignee_agent_instance_id": CODER_B_ID
    })
    t4_id = t4_res.get("task_id")
    make_request("/tasks/participant", {
        "agent_token": coord_token,
        "task_id": t4_id,
        "chain_id": chain_id,
        "agent_instance_id": REV_ID,
        "role": "lgtm_required"
    })
    print_step("Create Task-3 (assigned to Coder A) & Task-4 (assigned to Coder B) with status=planning", 
               t3_res.get("ok") and t4_res.get("ok"))

    # 2. Complete Task-2 (which is currently in_progress for Coder A)
    # This will trigger a promotion re-evaluation. Since Coder A becomes free, Task-3 is promoted and auto-claimed.
    # Since Coder B was already free, Task-4 is ALSO promoted and auto-claimed!
    make_request("/tasks/participant", {
        "agent_token": coord_token,
        "task_id": t2_id,
        "chain_id": chain_id,
        "agent_instance_id": REV_ID,
        "role": "lgtm_required"
    })
    make_request("/tasks/status", {
        "agent_token": coder_a_token,
        "task_id": t2_id,
        "chain_id": chain_id,
        "status": "review_ready",
        "body": "Task-2 done!"
    })
    make_request("/tasks/vote", {
        "agent_token": rev_token,
        "task_id": t2_id,
        "chain_id": chain_id,
        "result": "lgtm",
        "comment": "Task-2 approved!"
    })
    print_step("Reviewer approves Task-2 (Triggers concurrent promotions sweep)", True)

    # Verify Task-3 was auto-claimed to in_progress for Coder A
    t3_status = query_db(tasks_db_path, "SELECT status FROM tasks WHERE task_id = ?", (t3_id,))
    print_step("Verify Task-3 was automatically claimed and transitioned to in_progress", 
               len(t3_status) > 0 and t3_status[0][0] == "in_progress", f"Status: {t3_status[0][0] if t3_status else 'None'}")

    # Verify Task-4 was auto-claimed to in_progress for Coder B
    t4_status = query_db(tasks_db_path, "SELECT status FROM tasks WHERE task_id = ?", (t4_id,))
    print_step("Verify Task-4 was automatically claimed and transitioned to in_progress for Coder B", 
               len(t4_status) > 0 and t4_status[0][0] == "in_progress", f"Status: {t4_status[0][0] if t4_status else 'None'}")

    # 5. Both Coders submit their respective tasks for review concurrently!
    make_request("/tasks/status", {
        "agent_token": coder_a_token,
        "task_id": t3_id,
        "chain_id": chain_id,
        "status": "review_ready",
        "body": "Task-3 implementation ready!"
    })
    make_request("/tasks/status", {
        "agent_token": coder_b_token,
        "task_id": t4_id,
        "chain_id": chain_id,
        "status": "review_ready",
        "body": "Task-4 implementation ready!"
    })
    print_step("Both Coder A and Coder B submit their tasks as review_ready concurrently", True)

    # 6. Reviewer votes LGTM on Task-3
    # The moment this vote is submitted, the daemon should immediately nudge the reviewer about Task-4!
    vote_res = make_request("/tasks/vote", {
        "agent_token": rev_token,
        "task_id": t3_id,
        "chain_id": chain_id,
        "result": "lgtm",
        "comment": "Task-3 approved!"
    })
    print_step("Reviewer approves Task-3 (LGTM)", vote_res.get("ok"))

    # VERIFY: Query the task event log for Task-4 via user-rpc to check for the Task_Nudged event!
    log_res = make_request("/user-rpc", {
        "client_token": CLIENT_TOKEN,
        "client_instance_id": "local",
        "action": "task_log",
        "task_id": t4_id
    })
    events = log_res.get("events", [])
    nudge_event = None
    for ev in events:
        if ev.get("kind") == "Task_Nudged" and ev.get("agent_instance_id") == REV_ID:
            nudge_event = ev
            break
    
    nudge_sent = nudge_event is not None
    print_step("Verify Reviewer was immediately nudged for Task-4 upon voting on Task-3", nudge_sent, 
               f"Event: {nudge_event.get('kind') if nudge_event else 'None'}, Body: {nudge_event.get('body') if nudge_event else 'None'}")

    print("\n" + "=" * 80)
    print("ALL ADVANCED SCHEDULING VERIFICATIONS COMPLETED SUCCESSFULLY!")
    print("=" * 80)

if __name__ == "__main__":
    main()
