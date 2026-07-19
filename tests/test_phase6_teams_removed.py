#!/usr/bin/env python3
"""Phase 6 regression: durable teams and team/kind surfaces are removed.

Covers TR-12/TR-13:
- team daemon stores/routes/source packages and flake test packages are gone;
- ham-ctl has no teams command dispatch;
- /teams* is not served;
- task-chain create/show payloads expose no team_id and no chain kind;
- task nudge boot leases are keyed by chain_id.
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
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49767"))
URL = f"http://{HOST}:{PORT}"
ROOT = Path(__file__).resolve().parents[1]


def require(cond, message):
    if not cond:
        raise AssertionError(message)


def read_rel(path):
    return (ROOT / path).read_text(encoding="utf-8")


def request_json(method, path, body=None):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(f"{URL}{path}", data=data, headers={"Content-Type": "application/json"}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            payload = res.read().decode("utf-8")
            return res.status, (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as e:
        payload = e.read().decode("utf-8")
        try:
            parsed = json.loads(payload) if payload else {}
        except json.JSONDecodeError:
            parsed = {"raw": payload}
        return e.code, parsed


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


def write_config(path, data_dir):
    Path(path).write_text(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{data_dir}"
user_id = "operator@local"
wrapper_bin = "/bin/sh"
default_agent_provider_profile = "pi"
default_agent_model_tier = "normal"
default_agent_id_coordinator = "coordinator"
default_agent_id_reviewer = "reviewer"

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
''', encoding="utf-8")


def assert_no_team_or_kind(obj, label):
    dumped = json.dumps(obj, sort_keys=True)
    require('"team_id"' not in dumped, f"{label} leaked team_id: {dumped}")
    require('"kind"' not in dumped, f"{label} leaked chain kind: {dumped}")


def static_checks():
    for rel in [
        "src/daemon/team_db_service.odin",
        "src/daemon/team_service.odin",
        "src/daemon/team_http.odin",
        "src/daemon/team_kinds.odin",
        "src/daemon/teams_v1_migration.odin",
    ]:
        require(not (ROOT / rel).exists(), f"obsolete team source still exists: {rel}")

    flake = read_rel("flake.nix")
    require("ham-team-kinds-test" not in flake, "obsolete team kinds flake package remains")
    require("ham-team-db-service-test" not in flake, "obsolete team DB flake package remains")
    require("ham-team-service-test" not in flake, "obsolete team service flake package remains")

    server = read_rel("src/daemon/server.odin")
    require("handle_teams_request" not in server, "server still dispatches /teams")
    require("team_service_init" not in server, "server still initializes team service")
    require("teams_v1_migration_maybe_run" not in server, "server still runs teams migration")

    ctl = read_rel("src/ctl/main.odin")
    require('command == "teams"' not in ctl and 'case "teams"' not in ctl, "ham-ctl teams dispatch remains")

    store = read_rel("src/daemon/task_store.odin")
    projection = read_rel("src/daemon/task_projection.odin")
    db = read_rel("src/daemon/task_db_service.odin")
    require("team_id:" not in store, "task event/chain store still has team_id field")
    require('`\",\"team_id\":\"`' not in store, "task event JSON still writes team_id")
    require("team_id" not in projection, "task chain projection still exposes team_id")
    require("team_id" not in db, "task DB schema/projection still persists team_id")

    nudge = read_rel("src/daemon/task_nudge_scheduler.odin")
    require("Chain_Boot_Lease" in nudge and "chain_boot_leases" in nudge, "boot leases are not chain-keyed")
    require("Team_Boot_Lease" not in nudge and "team_boot" not in nudge, "team boot lease names remain")


def live_checks():
    daemon_bin = os.environ.get("HEIMDALL_DAEMON_BIN", str(ROOT / "result" / "bin" / "ham-daemon"))
    require(os.path.exists(daemon_bin), f"missing ham-daemon binary: {daemon_bin}")

    temp_dir = tempfile.mkdtemp(prefix="heimdall-phase6-teams-removed-")
    config_path = os.path.join(temp_dir, "config.toml")
    log_path = os.path.join(temp_dir, "daemon.log")
    data_dir = os.path.join(temp_dir, "data")
    write_config(config_path, data_dir)
    log_file = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], cwd=ROOT, stdout=log_file, stderr=subprocess.STDOUT)
    try:
        wait_for_health()
        for path in ["/teams", "/teams/add-member", "/teams/missing"]:
            status, _ = request_json("GET" if path != "/teams/add-member" else "POST", path, {})
            require(status == 404, f"{path} should be removed/404, got {status}")

        status, reg = request_json("POST", "/register", {
            "agent_class": "phase6-teams-removed",
            "agent_instance_id": "phase6-teams-removed@default",
            "display_name": "Phase 6 Teams Removed",
        })
        require(status == 200 and reg.get("agent_token"), reg)
        token = reg["agent_token"]

        status, chain = request_json("POST", "/task-chains/create", {
            "agent_token": token,
            "title": "Phase 6 no team chain",
            "goal": "Verify chains have no team metadata",
            "wants_vcs": False,
        })
        require(status == 200 and chain.get("ok"), chain)
        assert_no_team_or_kind(chain, "chain create response")

        status, shown = request_json("GET", f"/task-chains/{chain['chain_id']}?agent_token={token}")
        require(status == 200, shown)
        assert_no_team_or_kind(shown, "chain show response")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        log_file.close()
        shutil.rmtree(temp_dir, ignore_errors=True)


def main():
    static_checks()
    live_checks()


if __name__ == "__main__":
    main()
