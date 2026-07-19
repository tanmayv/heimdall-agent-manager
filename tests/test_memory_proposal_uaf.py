#!/usr/bin/env python3
"""Self-contained proposal lifecycle regression for simplified memory targets."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = 49325
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
AGENT_ID = "test-mem-agent@default"
PROJECT_ID = "test-mem-project"


def build_bin(repo: Path, attr: str, binary: str) -> str:
    env_map = {
        "ham-daemon": "HAM_DAEMON_BIN",
        "ham-wrapper": "HAM_WRAPPER_BIN",
        "ham-ctl": "HAM_CTL_BIN",
    }
    env_key = env_map.get(binary)
    if env_key and os.environ.get(env_key):
        return os.environ[env_key]
    for base in ["result-daemon-new", "result-daemon", "result-wrapper", "result-ctl", "result", "result-1", "result-2"]:
        candidate = repo / base / "bin" / binary
        if candidate.exists():
            return str(candidate)
    out = subprocess.check_output(["nix", "build", f".#${attr}".replace("$", ""), "--no-link", "--print-out-paths"], cwd=repo, text=True)
    return str(Path(out.strip().splitlines()[-1]) / "bin" / binary)


def request_post(path: str, data: dict) -> tuple[int, dict]:
    headers = {"Content-Type": "application/json"}
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status, json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8"))


def wait_for_daemon() -> None:
    for _ in range(100):
        try:
            with urllib.request.urlopen(f"{DAEMON_URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    temp_home = tempfile.mkdtemp(prefix="heimdall-memory-proposal-")
    daemon_proc = None
    daemon_log = None
    try:
        daemon_bin = build_bin(repo, "ham-daemon", "ham-daemon")
        wrapper_bin = build_bin(repo, "ham-wrapper", "ham-wrapper")
        ctl_bin = build_bin(repo, "ham-ctl", "ham-ctl")

        config_path = Path(temp_home) / "config.toml"
        daemon_log_path = Path(temp_home) / "daemon.log"
        config_path.write_text(
            f'''[daemon]\nbind_host = "{HOST}"\nport = {PORT}\ndata_dir = "{temp_home}/data"\nuser_id = "{USER_ID}"\nwrapper_bin = "{wrapper_bin}"\n\n[ctl]\ndaemon_url = "{DAEMON_URL}"\nham_ctl_bin = "{ctl_bin}"\n''',
            encoding="utf-8",
        )

        daemon_log = open(daemon_log_path, "w", encoding="utf-8")
        daemon_proc = subprocess.Popen([daemon_bin, "--config", str(config_path)], stdout=daemon_log, stderr=subprocess.STDOUT)
        wait_for_daemon()

        status, reg_res = request_post("/register", {
            "agent_class": "test-mem-agent",
            "agent_instance_id": AGENT_ID,
            "display_name": "Test Memory",
        })
        if status != 200 or not reg_res.get("agent_token"):
            raise SystemExit(f"[-] Registration failed: status={status} body={reg_res}")
        token = reg_res["agent_token"]

        status, user_reg = request_post("/user-client/register", {
            "user_id": USER_ID,
            "client_instance_id": "test-mem-user",
        })
        if status != 200 or not user_reg.get("client_token"):
            raise SystemExit(f"[-] User registration failed: status={status} body={user_reg}")

        status, project_res = request_post("/user-rpc", {
            "action": "project_create",
            "client_instance_id": "test-mem-user",
            "client_token": user_reg["client_token"],
            "project_id": PROJECT_ID,
            "name": "Test Memory Project",
            "description": "memory proposal test",
        })
        if status != 200 or not project_res.get("ok"):
            raise SystemExit(f"[-] Project creation failed: {project_res}")

        # /register backfills the durable target agent id used by memory targeting.

        status, prop_res = request_post("/memory/propose/new", {
            "agent_token": token,
            "target_agent_id": "test-mem-agent",
            "target_project_id": PROJECT_ID,
            "type": "fact",
            "title": "Initial Title",
            "body": "Initial Body text of proposal",
            "reason": "Initial reason",
            "evidence": "Initial evidence",
        })
        if status != 200 or not prop_res.get("ok"):
            raise SystemExit(f"[-] Memory propose new failed: {prop_res}")
        proposal_id = prop_res["proposal_id"]
        memory_id = prop_res["memory_id"]

        for payload, expected_version in [
            ({"agent_token": token, "proposal_id": proposal_id, "decision": "approve"}, None),
            ({
                "agent_token": token,
                "memory_id": memory_id,
                "expected_version": 2,
                "type": "fact",
                "title": "Edited Title",
                "body": "Edited Body text of proposal",
                "reason": "Edit reason",
                "evidence": "Edit evidence",
            }, 2),
        ]:
            if expected_version is None:
                status, res = request_post("/memory/decide", payload)
                if status != 200 or not res.get("ok"):
                    raise SystemExit(f"[-] Memory approve failed: {res}")
            else:
                status, edit_res = request_post("/memory/propose/edit", payload)
                if status != 200 or not edit_res.get("ok"):
                    raise SystemExit(f"[-] Memory propose edit failed: {edit_res}")
                status, res = request_post("/memory/decide", {
                    "agent_token": token,
                    "proposal_id": edit_res["proposal_id"],
                    "decision": "approve",
                })
                if status != 200 or not res.get("ok"):
                    raise SystemExit(f"[-] Memory edit decide failed: {res}")

        status, arch_res = request_post("/memory/propose/archive", {
            "agent_token": token,
            "memory_id": memory_id,
            "expected_version": 3,
        })
        if status != 200 or not arch_res.get("ok"):
            raise SystemExit(f"[-] Memory propose archive failed: {arch_res}")
        status, dec_arch_res = request_post("/memory/decide", {
            "agent_token": token,
            "proposal_id": arch_res["proposal_id"],
            "decision": "approve",
        })
        if status != 200 or not dec_arch_res.get("ok"):
            raise SystemExit(f"[-] Memory archive decide failed: {dec_arch_res}")

        _, show_res = request_post("/memory/show", {"agent_token": token, "memory_id": memory_id})
        _, list_res = request_post("/memory/list", {"agent_token": token, "target_project_id": PROJECT_ID, "include_all_statuses": True})
        _, history_res = request_post("/memory/history", {"agent_token": token, "memory_id": memory_id})
        payload = json.dumps({"show": show_res, "list": list_res, "history": history_res})
        for forbidden in ["subject_agent", "subject_key", '"scope"', '"project_ids"', '"role_keys"', '"task_chain_types"']:
            if forbidden in payload:
                raise SystemExit(f"[-] Legacy fields still exposed in public memory JSON: {payload}")

        record = show_res.get("record", {})
        if record.get("target_agent_id") != "test-mem-agent" or record.get("target_project_id") != PROJECT_ID:
            raise SystemExit(f"[-] Simplified target pair missing from record: {record}")
        if record.get("status") != "archived":
            raise SystemExit(f"[-] Expected archived status after archive approval: {record}")

        print("[+] All simplified memory proposal integration tests passed successfully!")
    finally:
        if daemon_proc is not None:
            daemon_proc.terminate()
            try:
                daemon_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon_proc.kill()
        if daemon_log is not None:
            daemon_log.close()
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp_home}")
        else:
            shutil.rmtree(temp_home, ignore_errors=True)


if __name__ == "__main__":
    main()
