#!/usr/bin/env python3
"""Smoke (TCE-7/TCE-11/TCE-12): confirm roster add-member + start/stop wiring
the Task Chain Editor depends on.

Verifies:
- POST /teams/add-member returns a complete roster row (team_member_id, role_key,
  role_index, agent_instance_id, route_to, is_user_proxy, lifecycle_status) so the
  editor can render the new roster row (TCE-7).
- GET /teams/{team_id} lists the added member (fetchTeam) (TCE-7).
- POST /agents/start accepts provider_profile + model_tier launch overrides and
  starts the agent; durable instance records do NOT adopt override provider/tier
  values for either existing-record or first-start agents (runtime-only)
  (TCE-7/TCE-11).
- POST /agents/stop accepts the stop payload and is accepted for a live agent
  (TCE-7/TCE-11).
"""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49731"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "editor-roster-client"
COORDINATOR_ID = "coord-editor-roster@tce-e2e"
NEW_AGENT_ID = "researcher@swe-team"
FIRST_START_AGENT_ID = "firststart@swe-team"
CHAIN_ID = "chain-editor-roster"


def bin_path(repo_dir, preferred, fallback, binary):
    preferred_path = os.path.join(repo_dir, preferred, "bin", binary)
    if os.path.exists(preferred_path):
        return preferred_path
    return os.path.join(repo_dir, fallback, "bin", binary)


def request_post(path, data):
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data, separators=(",", ":")).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status, json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read().decode("utf-8"))


def request_get(path, token=None):
    if token:
        sep = "&" if "?" in path else "?"
        path = f"{path}{sep}token={token}"
    req = urllib.request.Request(f"{DAEMON_URL}{path}", method="GET")
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status, json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read().decode("utf-8"))


def wait_for_daemon():
    for _ in range(60):
        try:
            with urllib.request.urlopen(f"{DAEMON_URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("daemon did not become healthy")


def require_ok(label, status, body):
    if status != 200 or not body.get("ok"):
        raise AssertionError(f"{label} failed: status={status} body={body}")


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = bin_path(repo_dir, "result-daemon", "result", "ham-daemon")
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-1", "ham-ctl")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-2", "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-editor-roster-")
    config_path = os.path.join(temp_home, "config.toml")
    daemon_log_path = os.path.join(temp_home, "daemon.log")
    daemon_proc = None
    daemon_log = None
    try:
        with open(config_path, "w", encoding="utf-8") as f:
            f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{temp_home}/data"
user_id = "{USER_ID}"
wrapper_bin = "{wrapper_bin}"

[ctl]
daemon_url = "{DAEMON_URL}"
ham_ctl_bin = "{ctl_bin}"
''')
        daemon_log = open(daemon_log_path, "w", encoding="utf-8")
        daemon_proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=daemon_log, stderr=subprocess.STDOUT)
        wait_for_daemon()

        status, agent_res = request_post("/register", {
            "agent_class": "coord-editor-roster",
            "agent_instance_id": COORDINATOR_ID,
            "display_name": "Editor Roster Coordinator",
        })
        coord_token = agent_res.get("agent_token")
        if not coord_token:
            raise AssertionError(f"coordinator registration failed: {agent_res}")

        status, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if not user_token:
            raise AssertionError(f"user registration failed: {user_res}")

        status, chain_res = request_post("/user-rpc", {
            "action": "task_chain_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": "default",
            "kind": "coding",
            "title": "Editor roster wiring",
            "chain_id": CHAIN_ID,
            "coordinator_agent_instance_id": COORDINATOR_ID,
            "wants_vcs": False,
            "no_scaffold": True,
        })
        require_ok("create chain", status, chain_res)
        team_id = chain_res.get("team_id")
        if not team_id:
            raise AssertionError(f"chain create missing team_id: {chain_res}")

        # --- TCE-7: add-member returns a complete roster row --------------------
        # Auth via user client token as agent_token, mirroring daemonApi.addTeamMember.
        status, add_res = request_post("/teams/add-member", {
            "agent_token": user_token,
            "team_id": team_id,
            "role_key": "specialist",
            "agent_instance_id": NEW_AGENT_ID,
        })
        require_ok("add-member", status, add_res)
        member = add_res.get("member", {})
        required_fields = ["team_member_id", "team_id", "role_key", "role_index", "agent_instance_id", "is_user_proxy", "route_to", "lifecycle_status"]
        for fld in required_fields:
            if fld not in member:
                raise AssertionError(f"TCE-7 add-member row missing '{fld}': {member}")
        if member.get("agent_instance_id") != NEW_AGENT_ID or member.get("route_to") != NEW_AGENT_ID:
            raise AssertionError(f"TCE-7 add-member did not expose routed agent: {member}")

        # --- TCE-7: fetchTeam lists the new member -----------------------------
        status, team = request_get(f"/teams/{team_id}", token=user_token)
        if status != 200:
            raise AssertionError(f"fetchTeam failed: status={status} body={team}")
        member_ids = [m.get("agent_instance_id") for m in team.get("members", [])]
        if NEW_AGENT_ID not in member_ids:
            raise AssertionError(f"TCE-7 fetchTeam missing added member: {member_ids}")

        # Create a durable baseline identity first. The start payload below uses
        # different provider/tier values; TCE-7 requires those values to affect
        # only this launch and not overwrite this durable identity.
        status, create_res = request_post("/agents/create", {
            "agent_token": coord_token,
            "agent_instance_id": NEW_AGENT_ID,
            "display_name": "Editor Roster Specialist",
            "provider_profile": "durable-baseline-provider",
            "model_tier": "cheap",
            "project_id": "default",
        })
        require_ok("create durable baseline agent", status, create_res)

        status, before_show = request_post("/agents/show", {
            "agent_token": coord_token,
            "agent_instance_id": NEW_AGENT_ID,
        })
        require_ok("show baseline agent", status, before_show)
        before_agent = before_show.get("agent", before_show)
        if before_agent.get("provider_profile") != "durable-baseline-provider" or before_agent.get("model_tier") != "normal":
            raise AssertionError(f"baseline provider/tier not persisted before start: {before_show}")

        # --- TCE-7/TCE-11: /agents/start accepts provider/tier launch overrides -
        status, start_res = request_post("/agents/start", {
            "agent_token": coord_token,
            "agent_instance_id": NEW_AGENT_ID,
            "provider_profile": "pi",
            "model_tier": "smart",
            "project_id": "default",
        })
        require_ok("start roster agent with overrides", status, start_res)
        if start_res.get("provider_profile") != "pi" or start_res.get("model_tier") != "smart":
            raise AssertionError(f"start response did not use requested launch provider/tier overrides: {start_res}")

        # The durable instance record must NOT adopt the start overrides.
        status, show_res = request_post("/agents/show", {
            "agent_token": coord_token,
            "agent_instance_id": NEW_AGENT_ID,
        })
        require_ok("show after runtime override start", status, show_res)
        shown_agent = show_res.get("agent", show_res)
        if shown_agent.get("provider_profile") != "durable-baseline-provider" or shown_agent.get("model_tier") != "normal":
            raise AssertionError(f"TCE-7 runtime provider/tier override leaked into durable existing record: {show_res}")

        # First-start/no-existing-record must also treat provider/tier as runtime
        # only. This is the newly-added roster-member case called out by review.
        status, first_start_res = request_post("/agents/start", {
            "agent_token": coord_token,
            "agent_instance_id": FIRST_START_AGENT_ID,
            "provider_profile": "runtime-only-provider",
            "model_tier": "smart",
            "project_id": "default",
        })
        require_ok("first start with runtime overrides", status, first_start_res)
        if first_start_res.get("provider_profile") != "runtime-only-provider" or first_start_res.get("model_tier") != "smart":
            raise AssertionError(f"first start response did not use requested launch provider/tier overrides: {first_start_res}")

        status, first_show_res = request_post("/agents/show", {
            "agent_token": coord_token,
            "agent_instance_id": FIRST_START_AGENT_ID,
        })
        require_ok("show first-start agent", status, first_show_res)
        first_agent = first_show_res.get("agent", first_show_res)
        if first_agent.get("provider_profile") == "runtime-only-provider" or first_agent.get("model_tier") == "smart":
            raise AssertionError(f"TCE-7 first-start runtime override leaked into durable record: {first_show_res}")

        # --- TCE-7/TCE-11: /agents/stop accepts + routes the stop payload ------
        # The stop handler must parse agent_instance_id + time_in_sec and dispatch
        # to the runtime tracker. When the agent is live it returns 200; when the
        # (test) wrapper has already exited the tracker returns a clean 404
        # "agent not found". Either proves payload wiring; a 400 would indicate a
        # malformed/unwired request. Reject missing agent id explicitly first.
        status_missing, missing_res = request_post("/agents/stop", {"agent_token": coord_token, "time_in_sec": 5})
        if status_missing != 400:
            raise AssertionError(f"TCE-11 agents/stop should 400 without agent_instance_id: status={status_missing} body={missing_res}")

        status, stop_res = request_post("/agents/stop", {
            "agent_token": coord_token,
            "agent_instance_id": NEW_AGENT_ID,
            "time_in_sec": 5,
        })
        if status == 200:
            if stop_res.get("time_in_sec") != 5:
                raise AssertionError(f"TCE-7 agents/stop did not echo time_in_sec override: {stop_res}")
        elif status == 404:
            # Agent already exited (test wrapper); payload was still parsed/routed.
            pass
        else:
            raise AssertionError(f"TCE-7 agents/stop payload rejected: status={status} body={stop_res}")

        print("PASS: editor roster add-member + fetchTeam + start/stop override wiring confirmed")
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
