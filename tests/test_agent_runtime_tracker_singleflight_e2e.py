#!/usr/bin/env python3
"""E2E regression: queued->auto_claim must not launch the same agent twice.

Uses a fake wrapper binary that only records invocations. The daemon should route
both status_change and auto_claim launch requests through the agent runtime
tracker, coalescing them into one in-flight launch for the same agent_instance_id.
"""

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
PORT = 49473
USER_ID = "operator@local"
AGENT_ID = "singleflight-agent@default"
COORDINATOR_ID = "coord-singleflight@default"


def bin_path(repo: Path, preferred: str, fallback: str, binary: str) -> str:
    preferred_path = repo / preferred / "bin" / binary
    if preferred_path.exists():
        return str(preferred_path)
    return str(repo / fallback / "bin" / binary)


def post(url: str, path: str, body: dict) -> dict:
    req = urllib.request.Request(
        f"{url}{path}",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as res:
            return json.loads(res.read().decode())
    except urllib.error.HTTPError as exc:
        body_text = exc.read().decode()
        raise RuntimeError(f"POST {path} failed {exc.code}: {body_text}") from exc


def wait_health(url: str) -> None:
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{url}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def wait_for(predicate, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    return predicate()


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    temp = tempfile.mkdtemp(prefix="heimdall-agent-tracker-singleflight-")
    proc = None
    log = None
    try:
        daemon_bin = bin_path(repo, "result-daemon", "result", "ham-daemon")
        ctl_bin = bin_path(repo, "result-ctl", "result-2", "ham-ctl")
        fake_wrapper = Path(temp) / "fake-wrapper.sh"
        wrapper_calls = Path(temp) / "wrapper-calls.log"
        fake_wrapper.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$*\" >> \"$FAKE_WRAPPER_CALLS\"\n"
            "sleep 30\n",
            encoding="utf-8",
        )
        fake_wrapper.chmod(0o755)
        url = f"http://{HOST}:{PORT}"
        config = Path(temp) / "config.toml"
        config.write_text(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{temp}/data"
user_id = "{USER_ID}"
wrapper_bin = "{fake_wrapper}"
nudge_enabled = false

[ctl]
daemon_url = "{url}"
ham_ctl_bin = "{ctl_bin}"
''', encoding="utf-8")
        log_path = Path(temp) / "daemon.log"
        log = open(log_path, "a", encoding="utf-8")
        env = os.environ.copy()
        env["FAKE_WRAPPER_CALLS"] = str(wrapper_calls)
        proc = subprocess.Popen([daemon_bin, "--config", str(config)], stdout=log, stderr=subprocess.STDOUT, env=env)
        wait_health(url)

        coordinator = post(url, "/register", {
            "agent_class": COORDINATOR_ID.split("@", 1)[0],
            "agent_instance_id": COORDINATOR_ID,
            "display_name": "Single-flight Coordinator",
        })
        coord_token = coordinator["agent_token"]
        user = post(url, "/user-client/register", {"user_id": USER_ID, "client_instance_id": "singleflight-user"})
        token = user["client_token"]
        chain = post(url, "/user-rpc", {
            "action": "task_chain_create",
            "client_instance_id": "singleflight-user",
            "client_token": token,
            "chain_id": "chain-singleflight",
            "kind": "coding",
            "title": "Single-flight chain",
            "description": "verify launch coalescing",
            "coordinator_agent_instance_id": COORDINATOR_ID,
            "wants_vcs": False,
            "no_scaffold": True,
        })
        post(url, "/teams/add-member", {
            "agent_token": coord_token,
            "team_id": chain["team_id"],
            "role_key": "specialist",
            "agent_instance_id": AGENT_ID,
        })
        task = post(url, "/tasks/create", {
            "agent_token": coord_token,
            "chain_id": chain["chain_id"],
            "title": "Single-flight task",
            "description": "promote to queued then auto-claim",
            "assignee_agent_instance_id": AGENT_ID,
        })
        post(url, "/tasks/status", {
            "agent_token": token,
            "task_id": task["task_id"],
            "chain_id": chain["chain_id"],
            "status": "queued",
            "body": "single-flight status promotion",
        })

        def call_count() -> int:
            if not wrapper_calls.exists():
                return 0
            return len([line for line in wrapper_calls.read_text(encoding="utf-8").splitlines() if AGENT_ID in line])

        count = wait_for(lambda: call_count() if call_count() >= 1 else 0, timeout=5)
        if count != 1:
            raise SystemExit(f"expected exactly one wrapper launch after promotion/auto-claim, got {count}")

        nudge = post(url, "/tasks/nudge", {
            "agent_token": coord_token,
            "task_id": task["task_id"],
            "chain_id": chain["chain_id"],
            "body": "singleflight nudge while launch in progress",
        })
        if not nudge.get("ok"):
            raise SystemExit(f"nudge should be durably accepted while launch in progress: {nudge}")
        time.sleep(0.5)
        count_after_nudge = call_count()
        if count_after_nudge != 1:
            raise SystemExit(f"nudge during launching spawned duplicate wrapper: {count_after_nudge}")

        daemon_log = log_path.read_text(encoding="utf-8", errors="replace")
        if "AGENT_TRACKER" not in daemon_log or "event=launch_coalesced" not in daemon_log:
            raise SystemExit("daemon log did not show agent tracker launch coalescing")
        target_spawn_results = [line for line in daemon_log.splitlines() if "stage=wrapper_spawn_result" in line and f"target={AGENT_ID}" in line]
        if len(target_spawn_results) != 1:
            raise SystemExit(f"daemon emitted unexpected target wrapper_spawn_result entries: {target_spawn_results}")

        print(json.dumps({
            "ok": True,
            "task_id": task["task_id"],
            "nudge": nudge,
            "wrapper_launches": count_after_nudge,
            "log_contains_launch_coalesced": True,
        }, indent=2, sort_keys=True))
        print("TEST PASSED: agent runtime tracker single-flight e2e")
    finally:
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        if log is not None:
            log.close()
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp}")
        else:
            shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    main()
