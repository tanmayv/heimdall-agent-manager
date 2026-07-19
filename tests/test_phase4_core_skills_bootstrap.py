#!/usr/bin/env python3
"""Phase 4 regression: bootstrap behavior comes from editable core skill memories.

Covers TR-8/TR-9 on an empty data dir:
- daemon seeds approved/active editable core skills as normal memory records;
- skill records are globally applicable and can be listed through the memory API;
- wrapper bootstrap source no longer injects template persona/instructions or
  coordinator-only branches into generated AGENTS.md.
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
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49764"))
URL = f"http://{HOST}:{PORT}"
ROOT = Path(__file__).resolve().parents[1]

CORE_SKILLS = {
    "task-workflow",
    "review-and-evidence",
    "coordinator-playbook",
    "git-hygiene",
    "contracts-first",
    "testing-discipline",
}


def request_json(method: str, path: str, body=None):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(f"{URL}{path}", data=data, headers={"Content-Type": "application/json"}, method=method)
    with urllib.request.urlopen(req, timeout=10) as res:
        payload = res.read().decode("utf-8")
        return res.status, (json.loads(payload) if payload else {})


def wait_for_health():
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("daemon did not become healthy")


def require(cond: bool, message):
    if not cond:
        raise AssertionError(message)


def write_config(path: str, data_dir: str):
    with open(path, "w", encoding="utf-8") as f:
        f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{data_dir}"
user_id = "operator@local"
wrapper_bin = "/bin/sh"
default_agent_provider_profile = "pi"
default_agent_model_tier = "normal"

[guide_agent]
enabled = false
autostart = false
restart_if_stopped = false
agent_instance_id = "guide@heimdall"
template_id = "guide"
provider_profile = "pi"
model_tier = "smart"

[ctl]
daemon_url = "{URL}"
''')


def static_wrapper_bootstrap_assertions():
    src = (ROOT / "src" / "wrapper" / "main.odin").read_text(encoding="utf-8")
    forbidden = [
        "template_persona",
        "template_instructions",
        "is_coordinator",
        "# Coordinator Instructions",
        "# Role Persona",
        "# Role Instructions",
        "coordinator_instructions.md",
    ]
    for needle in forbidden:
        require(needle not in src, f"wrapper still has role-specific bootstrap injection: {needle}")
    require("write_skills" in src and "render_skill_file" in src, "wrapper must discover/render skill memories")
    require("# Collaboration Context" in src, "wrapper should emit shared collaboration context")
    bootstrap_prompt = (ROOT / "src" / "prompts" / "bootstrap_profile_guidance.md").read_text(encoding="utf-8")
    require("`coordinator-playbook` skill" in bootstrap_prompt, "shared bootstrap should point coordinator responsibilities to the seeded skill")
    require("# Coordinator Instructions" not in bootstrap_prompt, "shared bootstrap must not reference an injected coordinator section")


def main():
    static_wrapper_bootstrap_assertions()
    daemon_bin = os.environ.get("HEIMDALL_DAEMON_BIN", str(ROOT / "result" / "bin" / "ham-daemon"))
    require(os.path.exists(daemon_bin), f"missing ham-daemon binary: {daemon_bin}")

    temp_dir = tempfile.mkdtemp(prefix="heimdall-phase4-core-skills-")
    config_path = os.path.join(temp_dir, "config.toml")
    log_path = os.path.join(temp_dir, "daemon.log")
    data_dir = os.path.join(temp_dir, "data")
    write_config(config_path, data_dir)
    log_file = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], cwd=ROOT, stdout=log_file, stderr=subprocess.STDOUT)
    try:
        wait_for_health()
        status, reg = request_json("POST", "/register", {
            "agent_class": "phase4-core-skills",
            "agent_instance_id": "phase4-core-skills@default",
            "display_name": "Phase 4 Core Skills",
        })
        require(status == 200 and reg.get("agent_token"), reg)
        token = reg["agent_token"]

        status, listed = request_json("POST", "/memory/list", {"agent_token": token, "type": "skill"})
        require(status == 200 and listed.get("ok"), listed)
        records = listed.get("records", [])
        by_title = {rec.get("title"): rec for rec in records}
        missing = CORE_SKILLS - set(by_title)
        require(not missing, f"missing seeded core skills: {sorted(missing)} from {sorted(by_title)}")
        for title in CORE_SKILLS:
            rec = by_title[title]
            require(rec.get("status") == "active", rec)
            require(rec.get("type") == "skill", rec)
            require(rec.get("target_agent_id", "") == "" and rec.get("target_project_id", "") == "", rec)
            body = rec.get("body", "")
            require(f"name: {title}" in body and "description:" in body, rec)
            require("core-skill" in rec.get("metadata_json", ""), rec)

        # Idempotent restart: stable seed IDs should not duplicate records.
        proc.terminate()
        proc.wait(timeout=5)
        log_file.close()
        log_file2 = open(log_path, "a", encoding="utf-8")
        proc = subprocess.Popen([daemon_bin, "--config", config_path], cwd=ROOT, stdout=log_file2, stderr=subprocess.STDOUT)
        wait_for_health()
        status, listed = request_json("POST", "/memory/list", {"agent_token": token, "type": "skill"})
        require(status == 200 and listed.get("ok"), listed)
        titles = [rec.get("title") for rec in listed.get("records", [])]
        for title in CORE_SKILLS:
            require(titles.count(title) == 1, f"seeded skill duplicated after restart: {title}: {titles}")
        log_file2.close()
        print("test_phase4_core_skills_bootstrap: ok")
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        try:
            log_file.close()
        except Exception:
            pass
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
