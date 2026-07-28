#!/usr/bin/env python3
"""Integration: daemon task chains pagination and slim templates catalog.

Covers:
- PAG-5: Task chains list drops description/final_summary, supports limit/offset.
- PAG-6: Agent templates catalog drops persona/instructions, on-demand fetch has them.
"""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49784"))
URL = f"http://{HOST}:{PORT}"
ROOT = Path(__file__).resolve().parents[1]
CID = "heimdall-pg-chains-test"


def req(method, path, body=None, headers=None):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    h = {"Content-Type": "application/json"}
    if headers:
        h.update(headers)
    r = urllib.request.Request(f"{URL}{path}", data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=10) as res:
            payload = res.read().decode("utf-8")
            return res.status, (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as e:
        payload = e.read().decode("utf-8")
        return e.code, (json.loads(payload) if payload else {})


def wait_health():
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("daemon did not become healthy")


def require(cond, msg):
    if not cond:
        raise AssertionError(msg)


def start(daemon_bin, cfg, log):
    lf = open(log, "a", encoding="utf-8")
    return subprocess.Popen([daemon_bin, "--config", cfg], cwd=ROOT, stdout=lf, stderr=subprocess.STDOUT), lf


def main():
    daemon_bin = os.environ.get("HEIMDALL_DAEMON_BIN")
    if not daemon_bin:
        for path in [ROOT / "result" / "bin" / "ham-daemon", ROOT / "result-daemon" / "bin" / "ham-daemon"]:
            if path.exists():
                daemon_bin = str(path)
                break
    if not daemon_bin:
        daemon_bin = str(ROOT / "result" / "bin" / "ham-daemon") # fallback for error message
    require(os.path.exists(daemon_bin), f"missing ham-daemon binary: {daemon_bin}")
    tmp = tempfile.mkdtemp(prefix="heimdall-chains-pg-")
    cfg = os.path.join(tmp, "config.toml")
    log = os.path.join(tmp, "daemon.log")
    data_dir = os.path.join(tmp, "data")
    with open(cfg, "w", encoding="utf-8") as f:
        f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{data_dir}"
user_id = "operator@local"
wrapper_bin = "/bin/sh"

[guide_agent]
enabled = false
autostart = false

[ctl]
daemon_url = "{URL}"
''')
    proc, lf = start(daemon_bin, cfg, log)
    try:
        wait_health()
        
        # 1. Register operator client
        _, reg = req("POST", "/user-client/register", {"user_id": "operator@local", "client_instance_id": CID})
        ctok = reg["client_token"]
        headers = {"Authorization": f"Bearer {ctok}"}

        # Register the coordinator agent identity so it exists in daemon
        status, coord_reg = req("POST", "/register", {
            "agent_class": "coordinator",
            "agent_instance_id": "coordinator@default",
            "display_name": "Test Coordinator"
        })
        require(status == 200, f"failed to register coordinator agent: {coord_reg}")

        # 2. Create 3 task chains with descriptions
        chain_ids = []
        for i in range(3):
            status, chain_res = req("POST", "/task-chains/create", {
                "agent_token": ctok,
                "wants_vcs": False,
                "title": f"Chain {i}",
                "description": f"Detailed description for chain {i}",
                "coordinator_agent_instance_id": "coordinator@default"
            })
            require(status == 200, f"failed to create chain {i}: {chain_res}")
            chain_ids.append(chain_res["chain_id"])
            time.sleep(0.1) # ensure creation order

        # Complete the first chain to set a final_summary
        status, comp_res = req("POST", "/task-chains/complete", {
            "agent_token": ctok,
            "chain_id": chain_ids[0],
            "final_summary": "Summary of completed chain 0"
        })
        require(status == 200, f"failed to complete chain 0: {comp_res}")

        # 3. Verify PAG-5 (List drops description & final_summary + respects pagination)
        print("[*] Verifying task chains list pagination and slim output...")
        
        # Fetch with limit=2
        status, list_res = req("GET", f"/task-chains?limit=2&offset=0", headers=headers)
        require(status == 200, f"failed to list chains: {list_res}")
        chains = list_res.get("chains", [])
        require(len(chains) == 2, f"expected 2 chains, got {len(chains)}")
        require(list_res.get("total_count") == 3, f"expected total_count=3, got {list_res.get('total_count')}")

        for chain in chains:
            require("description" not in chain, f"description should not be in list response for chain {chain.get('chain_id')}")
            require("final_summary" not in chain, f"final_summary should not be in list response for chain {chain.get('chain_id')}")

        # Fetch offset=2
        status, list_res2 = req("GET", f"/task-chains?limit=2&offset=2", headers=headers)
        require(status == 200, f"failed to list chains page 2: {list_res2}")
        chains2 = list_res2.get("chains", [])
        require(len(chains2) == 1, f"expected 1 chain, got {len(chains2)}")
        require("description" not in chains2[0], "description should not be in list response")

        # 4. Verify GET /task-chains/{id} yields full details
        print("[*] Verifying individual task chain fetch has full details...")
        status, detail_res = req("GET", f"/task-chains/{chain_ids[0]}", headers=headers)
        require(status == 200, f"failed to fetch chain detail: {detail_res}")
        chain_detail = detail_res.get("chain", {})
        require(chain_detail.get("description") == "Detailed description for chain 0", f"expected description, got {chain_detail.get('description')}")
        require(chain_detail.get("final_summary") == "Summary of completed chain 0", f"expected final_summary, got {chain_detail.get('final_summary')}")

        # 5. Create a custom template with persona and instructions
        print("[*] Creating an agent template...")
        template_payload = {
            "template_id": "test-pg-template",
            "display_name": "Test Paged Template",
            "description": "Template description",
            "persona": "System persona: you are a tester.",
            "instructions": "System instructions: do testing.",
            "default_provider_profile": "pi",
            "suggested_model_tier": "normal"
        }
        status, create_res = req("POST", "/agents/templates/create", template_payload, headers)
        require(status == 200 and create_res.get("ok"), f"failed to create template: {create_res}")

        # 6. Verify PAG-6 (List /agents/templates drops persona/instructions)
        print("[*] Verifying templates list is slim (no persona or instructions)...")
        status, templates_res = req("GET", "/agents/templates", headers=headers)
        require(status == 200, f"failed to list templates: {templates_res}")
        templates = templates_res.get("templates", [])
        found_test_tpl = False
        for tpl in templates:
            # Check default templates too
            require("persona" not in tpl, f"persona should not be in list response for template {tpl.get('template_id')}")
            require("instructions" not in tpl, f"instructions should not be in list response for template {tpl.get('template_id')}")
            if tpl.get("template_id") == "test-pg-template":
                found_test_tpl = True
                require(tpl.get("description") == "Template description", "expected description in list")

        require(found_test_tpl, "test-pg-template not found in template list")

        # 7. Verify showAgentTemplate (/agents/templates/show) has full details on-demand
        print("[*] Verifying show template has full details on-demand...")
        status, show_res = req("POST", "/agents/templates/show", {"template_id": "test-pg-template"}, headers)
        require(status == 200 and show_res.get("ok"), f"failed to show template: {show_res}")
        tpl_detail = show_res.get("template", {})
        require(tpl_detail.get("persona") == "System persona: you are a tester.", f"expected persona, got {tpl_detail.get('persona')}")
        require(tpl_detail.get("instructions") == "System instructions: do testing.", f"expected instructions, got {tpl_detail.get('instructions')}")

        print("[+] Integration test for paged chains and slim templates passed successfully!")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        lf.close()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
