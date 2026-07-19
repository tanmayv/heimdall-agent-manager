import urllib.request
import json
import sys

DAEMON_URL = "http://127.0.0.1:49325"

EXPECTED_TEMPLATES = {
    "planner": {
        "template_id": "planner",
        "display_name": "Planner",
        "description": "Use this template for analytical strategist agents that decompose goals, map dependencies, and draft execution schedules.",
        "default_provider_profile": ""
    },
    "lead": {
        "template_id": "lead",
        "display_name": "Tech Lead",
        "description": "Use this template for coordinator agents that delegate tasks, track progress, resolve blockers, and consolidate results.",
        "default_provider_profile": ""
    },
    "reviewer": {
        "template_id": "reviewer",
        "display_name": "Reviewer",
        "description": "Use this template for quality gatekeeper agents that audit code readability, correctness, and style standards.",
        "default_provider_profile": ""
    },
    "coder": {
        "template_id": "coder",
        "display_name": "Coder",
        "description": "Use this template for implementation agents that write functional code, run tests, and address reviewer feedback.",
        "default_provider_profile": ""
    },
    "tester": {
        "template_id": "tester",
        "display_name": "Tester",
        "description": "Use this template for validation agents that design test cases, execute suites, and report bugs.",
        "default_provider_profile": ""
    },
    "researcher": {
        "template_id": "researcher",
        "display_name": "Researcher",
        "description": "Use this template for evidence-driven investigation, RCA, and synthesis agents that answer questions without owning production code changes.",
        "suggested_model_tier": "smart",
        "default_provider_profile": ""
    },
    "memory_auditor": {
        "template_id": "memory_auditor",
        "display_name": "Memory Auditor",
        "description": "Use this template for reflective agents that analyze task histories and logs to extract reusable learnings.",
        "default_provider_profile": ""
    },
    "memory_reviewer": {
        "template_id": "memory_reviewer",
        "display_name": "Memory Reviewer",
        "description": "Use this template for decision-making agents that inspect and approve/reject proposed memories.",
        "default_provider_profile": ""
    },
    "specialist": {
        "template_id": "specialist",
        "display_name": "Specialist",
        "description": "Use this template for specialist service agents that act as domain experts, answering requester queries via task comments.",
        "suggested_model_tier": "normal",
        "persona": "The Specialist is a domain-specific expert designed to act as a query service. They accept standalone or chain tasks containing query descriptions, process them, and output results using task comments, notifying the requester who reviewer-approves the task.",
        "instructions": "1. Receive Query: Accept a query task where the requester is the reviewer.\n2. Process Request: Execute the query, research, or compilation task.\n3. Reply: Document findings and results in task comments.\n4. Complete: Run `ham-ctl tasks done --token <your_token> --task-id <task_id> --comment \"<summary and evidence>\"` to move the task to `review_ready` and notify the requester for LGTM validation.\n5. Cooperation:\n   * Requester: Receives queries and returns comments.",
        "default_provider_profile": ""
    }
}

def main():
    print("[*] Fetching seeded agent templates from daemon...")
    req = urllib.request.Request(f"{DAEMON_URL}/agents/templates")
    try:
        res = urllib.request.urlopen(req)
        body = json.loads(res.read().decode("utf-8"))
    except Exception as e:
        print("[-] Failed to query /agents/templates:", e)
        sys.exit(1)
    
    if not body.get("ok"):
        print("[-] Daemon templates response status not OK:", body)
        sys.exit(1)
        
    templates_list = body.get("templates", [])
    templates_dict = {t["template_id"]: t for t in templates_list}
    
    print(f"[*] Found {len(templates_list)} templates.")
    
    errors = 0
    for key, expected in EXPECTED_TEMPLATES.items():
        if key not in templates_dict:
            print(f"[-] Missing expected template: {key}")
            errors += 1
            continue
            
        actual = templates_dict[key]
        for field, exp_val in expected.items():
            act_val = actual.get(field)
            if act_val != exp_val:
                print(f"[-] Template '{key}' field '{field}' mismatch:")
                print(f"    Expected: {repr(exp_val)}")
                print(f"    Actual:   {repr(act_val)}")
                errors += 1
                
    if errors > 0:
        print(f"[-] Validation failed with {errors} errors.")
        sys.exit(1)
        
    print("[+] All templates seeded and validated successfully!")
    sys.exit(0)

if __name__ == "__main__":
    main()
