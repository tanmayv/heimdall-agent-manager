#!/usr/bin/env python3
"""Integration: memory list returns metadata only by default, lazy load details.

Covers task-19f836f0e46 (AI-2):
- /memory/list excludes body, evidence, metadata_json by default.
- /memory/list includes them if include_body=True.
- /memory/show always includes them.
- /memory/applicable includes them by default (for wrapper) but supports include_body=False.
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
USER_ID = "operator@local"


def post(path, data):
    req = urllib.request.Request(
        f"{URL}{path}",
        data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=10) as res:
        return json.loads(res.read().decode())


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
        for base in ["result-daemon", "result"]:
            path = ROOT / base / "bin" / "ham-daemon"
            if path.exists():
                daemon_bin = str(path)
                break
    if not daemon_bin:
        daemon_bin = str(ROOT / "result" / "bin" / "ham-daemon")
    require(os.path.exists(daemon_bin), f"missing ham-daemon binary: {daemon_bin}")
    tmp = tempfile.mkdtemp(prefix="heimdall-mem-pg-")
    cfg = os.path.join(tmp, "config.toml")
    log = os.path.join(tmp, "daemon.log")
    data_dir = os.path.join(tmp, "data")
    with open(cfg, "w", encoding="utf-8") as f:
        f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{data_dir}"
user_id = "{USER_ID}"
wrapper_bin = "/bin/sh"

[guide_agent]
agent_id = "guide"
provider_profile = "noop"
model_tier = "normal"
''')

    proc, lf = start(daemon_bin, cfg, log)
    try:
        wait_health()

        # Register user client
        user_client = post("/user-client/register", {"user_id": USER_ID, "client_instance_id": "test-user"})
        require(user_client.get("ok"), "failed to register user")
        ctok = user_client["client_token"]
        auth = {"client_instance_id": "test-user", "client_token": ctok}

        # Propose memory
        prop_req = {
            "type": "fact",
            "title": "Test Memory Title",
            "body": "Test Memory Body Content",
            "evidence": "Test Evidence",
            "metadata_json": '{"key": "value"}',
            "target_agent_id": "",
            "target_project_id": ""
        }
        prop_req.update(auth)
        prop_res = post("/memory/propose/new", prop_req)
        require(prop_res.get("ok"), f"propose failed: {prop_res}")
        proposal_id = prop_res["proposal_id"]
        memory_id = prop_res["memory_id"]

        # Approve memory
        dec_req = {
            "proposal_id": proposal_id,
            "decision": "approve"
        }
        dec_req.update(auth)
        dec_res = post("/memory/decide", dec_req)
        require(dec_res.get("ok"), f"decide failed: {dec_res}")

        # 1. List memories (default, include_body=False)
        list_req = {}
        list_req.update(auth)
        list_res = post("/memory/list", list_req)
        require(list_res.get("ok"), f"list failed: {list_res}")
        records = list_res.get("records", [])
        require(len(records) > 0, "expected at least 1 record")
        
        # Verify ALL records have body/evidence/metadata_json excluded
        for r in records:
            require("body" not in r, f"body unexpectedly present in record: {r}")
            require("evidence" not in r, f"evidence unexpectedly present in record: {r}")
            require("metadata_json" not in r, f"metadata_json unexpectedly present in record: {r}")
            
        our_rec = next((r for r in records if r["memory_id"] == memory_id), None)
        require(our_rec is not None, "our memory not found in list")
        require(our_rec["title"] == "Test Memory Title", "title mismatch")

        # Print the default list response for evidence
        print("Default /memory/list response (body excluded):")
        print(json.dumps(list_res, indent=2))

        # 2. List memories (include_body=True)
        list_req_wb = {"include_body": True}
        list_req_wb.update(auth)
        list_res_wb = post("/memory/list", list_req_wb)
        require(list_res_wb.get("ok"), f"list with body failed: {list_res_wb}")
        records_wb = list_res_wb.get("records", [])
        
        our_rec_wb = next((r for r in records_wb if r["memory_id"] == memory_id), None)
        require(our_rec_wb is not None, "our memory not found in list (with body)")
        print("our_rec_wb:", json.dumps(our_rec_wb, indent=2))
        require(our_rec_wb["body"] == "Test Memory Body Content", "body mismatch")
        require(our_rec_wb["evidence"] == "Test Evidence", "evidence mismatch")
        meta_wb = json.loads(our_rec_wb["metadata_json"])
        inner_meta_wb = json.loads(meta_wb["metadata_json"]) if isinstance(meta_wb, dict) and "metadata_json" in meta_wb else meta_wb
        require(isinstance(inner_meta_wb, dict) and inner_meta_wb.get("key") == "value", "metadata_json mismatch")

        # 3. Show memory (should always have body)
        show_req = {"memory_id": memory_id}
        show_req.update(auth)
        show_res = post("/memory/show", show_req)
        require(show_res.get("ok"), f"show failed: {show_res}")
        rec_show = show_res.get("record", {})
        require(rec_show["body"] == "Test Memory Body Content", "body mismatch in show")
        require(rec_show["evidence"] == "Test Evidence", "evidence mismatch in show")
        meta_show = json.loads(rec_show["metadata_json"])
        inner_meta_show = json.loads(meta_show["metadata_json"]) if isinstance(meta_show, dict) and "metadata_json" in meta_show else meta_show
        require(isinstance(inner_meta_show, dict) and inner_meta_show.get("key") == "value", "metadata_json mismatch in show")

        # Print the show response for evidence
        print("\n/memory/show response (body included):")
        print(json.dumps(show_res, indent=2))

        # 4. Applicable memories (default, include_body=True)
        app_req = {}
        app_req.update(auth)
        app_res = post("/memory/applicable", app_req)
        require(app_res.get("ok"), f"applicable failed: {app_res}")
        records_app = app_res.get("records", [])
        
        our_rec_app = next((r for r in records_app if r["memory_id"] == memory_id), None)
        require(our_rec_app is not None, "our memory not found in applicable")
        require(our_rec_app["body"] == "Test Memory Body Content", "body mismatch in applicable")

        # 5. Applicable memories (include_body=False)
        app_req_nb = {"include_body": False}
        app_req_nb.update(auth)
        app_res_nb = post("/memory/applicable", app_req_nb)
        require(app_res_nb.get("ok"), f"applicable with include_body=False failed: {app_res_nb}")
        records_app_nb = app_res_nb.get("records", [])
        
        for r in records_app_nb:
            require("body" not in r, f"body unexpectedly present in applicable nb record: {r}")
            
        our_rec_app_nb = next((r for r in records_app_nb if r["memory_id"] == memory_id), None)
        require(our_rec_app_nb is not None, "our memory not found in applicable nb")

        print("\ntest_memory_list_metadata_only: ok")
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
