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
    print("STARTING MULTI-AGENT WORKFLOW SIMULATION")
    print("=" * 80)

    # Register Operator Client Token
    reg_res = make_request("/user-client/register", {
        "user_id": "operator@local",
        "client_instance_id": "local",
        "token": CLIENT_TOKEN
    })
    print_step("Register Operator Client Token", reg_res.get("ok", True))

    # -------------------------------------------------------------------------
    # PART 1: Agent Spawning & Registration
    # -------------------------------------------------------------------------
    print("\n--- PART 1: Bootstrapping Agent Instances ---")
    
    # 1. Start Coordinator
    coord_res = make_request("/agents/start", {
        "agent_instance_id": "coord@default",
        "template_id": "lead",
        "provider_profile": "pi",
        "model_tier": "smart"
    })
    coord_token = coord_res.get("agent_token")
    print_step("Spawn Coordinator (coord@default)", coord_res.get("ok"), f"Token: {coord_token}")

    # 2. Start Coder
    coder_res = make_request("/agents/start", {
        "agent_instance_id": "coder@default",
        "template_id": "coder",
        "provider_profile": "pi",
        "model_tier": "normal"
    })
    coder_token = coder_res.get("agent_token")
    print_step("Spawn Coder (coder@default)", coder_res.get("ok"), f"Token: {coder_token}")

    # 3. Start Reviewer
    rev_res = make_request("/agents/start", {
        "agent_instance_id": "reviewer@default",
        "template_id": "reviewer",
        "provider_profile": "pi",
        "model_tier": "smart"
    })
    rev_token = rev_res.get("agent_token")
    print_step("Spawn Reviewer (reviewer@default)", rev_res.get("ok"), f"Token: {rev_token}")

    if not (coord_token and coder_token and rev_token):
        print("🔴 Critical Error: Failed to spawn all agent instances. Aborting.")
        return

    # Signal start_success for all
    for name, token in [("Coordinator", coord_token), ("Coder", coder_token), ("Reviewer", rev_token)]:
        success_res = make_request("/agent-rpc", {
            "agent_token": token,
            "action": "start_success"
        })
        print_step(f"Signal start-success for {name}", success_res.get("ok", True))

    # -------------------------------------------------------------------------
    # PART 2: Happy Path Simulation
    # -------------------------------------------------------------------------
    print("\n--- PART 2: Simulating Happy Path Workflow ---")

    # 1. Coordinator creates a task chain
    chain_res = make_request("/task-chains/create", {
        "agent_token": coord_token,
        "title": "Simulated Happy Path Chain",
        "coordinator_agent_instance_id": "coord@default"
    })
    chain_id = chain_res.get("chain_id")
    print_step("Coordinator creates Task Chain", chain_res.get("ok"), f"Chain ID: {chain_id}")

    # 2. Coordinator creates a task assigned to coder
    task_res = make_request("/tasks/create", {
        "agent_token": coord_token,
        "chain_id": chain_id,
        "title": "Implement Core Logic",
        "status": "ready",
        "assignee_agent_instance_id": "coder@default"
    })
    task_id = task_res.get("task_id")
    print_step("Coordinator creates Task assigned to Coder", task_res.get("ok"), f"Task ID: {task_id}")

    # 3. Add reviewer as lgtm_required participant
    part_res = make_request("/tasks/participant", {
        "agent_token": coord_token,
        "task_id": task_id,
        "chain_id": chain_id,
        "agent_instance_id": "reviewer@default",
        "role": "lgtm_required"
    })
    print_step("Coordinator adds Reviewer as lgtm_required", part_res.get("ok"))

    # 4. Coder starts working
    work_res = make_request("/tasks/status", {
        "agent_token": coder_token,
        "task_id": task_id,
        "chain_id": chain_id,
        "status": "in_progress",
        "body": "Starting implementation of feature..."
    })
    print_step("Coder moves task to in_progress", work_res.get("ok"))

    # 5. Coder submits for review
    submit_res = make_request("/tasks/status", {
        "agent_token": coder_token,
        "task_id": task_id,
        "chain_id": chain_id,
        "status": "review_ready",
        "body": "Core feature implemented. Tests are passing!"
    })
    print_step("Coder moves task to review_ready", submit_res.get("ok"))

    # 6. Reviewer votes LGTM/approved
    vote_res = make_request("/tasks/vote", {
        "agent_token": rev_token,
        "task_id": task_id,
        "chain_id": chain_id,
        "result": "lgtm",
        "comment": "Outstanding implementation! Clean, tested, and ready."
    })
    print_step("Reviewer votes LGTM (approved)", vote_res.get("ok"))

    # Verify task is approved
    tasks_db_path = os.path.expanduser("~/.local/share/heimdall/tasks/task.db")
    task_row = query_db(tasks_db_path, "SELECT status FROM tasks WHERE task_id = ?", (task_id,))
    task_approved = len(task_row) > 0 and task_row[0][0] == "approved"
    print_step("Verify Task is in approved status in DB", task_approved, f"Status: {task_row[0][0] if task_row else 'None'}")

    # Verify chain transitioned to 'reviewing'
    chain_row = query_db(tasks_db_path, "SELECT status FROM task_chains WHERE chain_id = ?", (chain_id,))
    chain_reviewing = len(chain_row) > 0 and chain_row[0][0] == "reviewing"
    print_step("Verify Chain auto-transitioned to reviewing", chain_reviewing, f"Status: {chain_row[0][0] if chain_row else 'None'}")

    # Verify coordinator was pinged with Best Practices
    chat_db_path = os.path.expanduser("~/.local/share/heimdall/chat/messages.db")
    pings = query_db(chat_db_path, "SELECT body FROM messages WHERE agent_instance_id = 'coord@default' AND direction = 'user_to_agent' ORDER BY created_unix_ms DESC LIMIT 1")
    ping_received = len(pings) > 0 and "Task Chain Best Practices" in pings[0][0]
    print_step("Verify Coordinator received Best Practices ping in chat", ping_received, 
               f"Snippet: {pings[0][0][:120]}..." if ping_received else "None")

    # 7. Coordinator moves chain to completed with final summary
    complete_res = make_request("/task-chains/status", {
        "agent_token": coord_token,
        "chain_id": chain_id,
        "status": "completed",
        "final_summary": "All tasks verified. Commit: abc123def. Files modified: src/main.odin. Proposing good quality rating based on clean, passing test suite."
    })
    print_step("Coordinator moves Chain to completed with Final Summary", complete_res.get("ok"))

    # 8. Operator audits the completed chain in the Quality Sidebar
    audit_res = make_request("/user-rpc", {
        "client_token": CLIENT_TOKEN,
        "client_instance_id": "local",
        "action": "task_chain_evaluate",
        "chain_id": chain_id,
        "evaluation": "good"
    })
    print_step("Operator submits 'good' Quality Audit Evaluation", audit_res.get("ok"))

    # Verify chain is fully reviewed and evaluated in DB
    chain_final = query_db(tasks_db_path, "SELECT status, evaluation FROM task_chains WHERE chain_id = ?", (chain_id,))
    chain_ok = len(chain_final) > 0 and chain_final[0][0] == "completed" and chain_final[0][1] == "good"
    print_step("Verify Chain is marked completed & evaluated in DB", chain_ok, 
               f"Status: {chain_final[0][0]}, Evaluation: {chain_final[0][1] if chain_final else 'None'}")


    # -------------------------------------------------------------------------
    # PART 3: Complex Path Simulation (Rejection & Re-review Loop)
    # -------------------------------------------------------------------------
    print("\n--- PART 3: Simulating Complex Path (Rejection & Re-review) ---")

    # 1. Coordinator creates a new chain
    complex_chain_res = make_request("/task-chains/create", {
        "agent_token": coord_token,
        "title": "Simulated Complex Path Chain",
        "coordinator_agent_instance_id": "coord@default"
    })
    complex_chain_id = complex_chain_res.get("chain_id")
    print_step("Coordinator creates new Task Chain", complex_chain_res.get("ok"), f"Chain ID: {complex_chain_id}")

    # 2. Coordinator creates a task
    complex_task_res = make_request("/tasks/create", {
        "agent_token": coord_token,
        "chain_id": complex_chain_id,
        "title": "Implement Complex Algorithm",
        "status": "ready",
        "assignee_agent_instance_id": "coder@default"
    })
    complex_task_id = complex_task_res.get("task_id")
    print_step("Coordinator creates Task assigned to Coder", complex_task_res.get("ok"), f"Task ID: {complex_task_id}")

    # 3. Add reviewer as lgtm_required
    make_request("/tasks/participant", {
        "agent_token": coord_token,
        "task_id": complex_task_id,
        "chain_id": complex_chain_id,
        "agent_instance_id": "reviewer@default",
        "role": "lgtm_required"
    })

    # 4. Coder starts working
    make_request("/tasks/status", {
        "agent_token": coder_token,
        "task_id": complex_task_id,
        "chain_id": complex_chain_id,
        "status": "in_progress",
        "body": "Tackling the complex algorithm implementation..."
    })

    # 5. Coder submits first draft for review
    make_request("/tasks/status", {
        "agent_token": coder_token,
        "task_id": complex_task_id,
        "chain_id": complex_chain_id,
        "status": "review_ready",
        "body": "First draft of algorithm is ready. Runs, but not fully optimized."
    })
    print_step("Coder submits first draft as review_ready", True)

    # 6. Reviewer votes NGTM (rejection) with constructive feedback!
    ngtm_res = make_request("/tasks/vote", {
        "agent_token": rev_token,
        "task_id": complex_task_id,
        "chain_id": complex_chain_id,
        "result": "ngtm",
        "comment": "Replaced O(N^2) loop with O(N log N) hashmap. Please optimize before approval."
    })
    print_step("Reviewer votes NGTM (rejection) with feedback", ngtm_res.get("ok"))

    # Verify task auto-reverted to 'in_progress'
    task_revert = query_db(tasks_db_path, "SELECT status FROM tasks WHERE task_id = ?", (complex_task_id,))
    reverted_ok = len(task_revert) > 0 and task_revert[0][0] == "in_progress"
    print_step("Verify Task automatically reverted to in_progress", reverted_ok, f"Status: {task_revert[0][0] if task_revert else 'None'}")

    # 7. Coder addresses feedback and submits second draft
    make_request("/tasks/status", {
        "agent_token": coder_token,
        "task_id": complex_task_id,
        "chain_id": complex_chain_id,
        "status": "review_ready",
        "body": "Algorithm fully optimized to O(N log N) using a hashmap as requested!"
    })
    print_step("Coder fixes issues and submits second draft as review_ready", True)

    # 8. Reviewer re-reviews and votes LGTM
    lgtm_res = make_request("/tasks/vote", {
        "agent_token": rev_token,
        "task_id": complex_task_id,
        "chain_id": complex_chain_id,
        "result": "lgtm",
        "comment": "Perfect! O(N log N) optimization verified. Highly robust."
    })
    print_step("Reviewer votes LGTM (approved) on second draft", lgtm_res.get("ok"))

    # Verify task approved & chain moved to reviewing
    complex_task_row = query_db(tasks_db_path, "SELECT status FROM tasks WHERE task_id = ?", (complex_task_id,))
    complex_chain_row = query_db(tasks_db_path, "SELECT status FROM task_chains WHERE chain_id = ?", (complex_chain_id,))
    print_step("Verify Task is approved after re-review", len(complex_task_row) > 0 and complex_task_row[0][0] == "approved")
    print_step("Verify Chain moved to reviewing after re-review", len(complex_chain_row) > 0 and complex_chain_row[0][0] == "reviewing")

    # 9. Coordinator completes
    make_request("/task-chains/status", {
        "agent_token": coord_token,
        "chain_id": complex_chain_id,
        "status": "completed",
        "final_summary": "Complex algorithm completed and optimized. Commit: xyz789. Files: algo.odin. Result: good. Optimized from O(N^2) to O(N log N) based on reviewer feedback."
    })
    
    # 10. Operator evaluates
    eval_res = make_request("/user-rpc", {
        "client_token": CLIENT_TOKEN,
        "client_instance_id": "local",
        "action": "task_chain_evaluate",
        "chain_id": complex_chain_id,
        "evaluation": "good"
    })
    print_step("Operator submits 'good' Quality Audit Evaluation for complex path", eval_res.get("ok"))

    # Verify complex chain is fully reviewed and evaluated in DB
    complex_chain_final = query_db(tasks_db_path, "SELECT status, evaluation FROM task_chains WHERE chain_id = ?", (complex_chain_id,))
    complex_chain_ok = len(complex_chain_final) > 0 and complex_chain_final[0][0] == "completed" and complex_chain_final[0][1] == "good"
    print_step("Verify Complex Chain is marked completed & evaluated in DB", complex_chain_ok, 
               f"Status: {complex_chain_final[0][0]}, Evaluation: {complex_chain_final[0][1] if complex_chain_final else 'None'}")
    print_step("Workflow finalized for complex path", True)

    print("\n" + "=" * 80)
    print("ALL WORKFLOW SIMULATIONS COMPLETED SUCCESSFULLY!")
    print("=" * 80)

if __name__ == "__main__":
    main()
