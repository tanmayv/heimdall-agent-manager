#!/usr/bin/env python3
"""Backend regression coverage for simplified memory targeting.

Covers:
- public list/show/history/applicable JSON exposes only target_team_kind/target_role/target_project_id
- null/empty targets act as wildcards
- populated targets use strict AND semantics
- expertise dedup uses canonical target triple + title
"""

import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = 49423
URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
AGENT_ID = "memory-target-coder@default"
PROJECT_ID = "memory-target-project"
OTHER_PROJECT_ID = "memory-target-project-2"
TEAM_KIND = "coding"
ROLE = "coder"
OTHER_ROLE = "reviewer"


def bin_path(repo: Path, binary: str) -> str:
    env_key = {
        "ham-daemon": "HAM_DAEMON_BIN",
        "ham-wrapper": "HAM_WRAPPER_BIN",
        "ham-ctl": "HAM_CTL_BIN",
    }[binary]
    if os.environ.get(env_key):
        return os.environ[env_key]
    for base in ["result-daemon-new", "result-daemon", "result-wrapper", "result-ctl", "result", "result-1", "result-2"]:
        path = repo / base / "bin" / binary
        if path.exists():
            return str(path)
    package = {
        "ham-daemon": "ham-daemon",
        "ham-wrapper": "ham-wrapper",
        "ham-ctl": "ham-ctl",
    }[binary]
    build = subprocess.run(["nix", "build", f".#${package}".replace("$", ""), "--no-link", "--print-out-paths"], cwd=repo, capture_output=True, text=True, check=True)
    out_path = build.stdout.strip().splitlines()[-1]
    return str(Path(out_path) / "bin" / binary)


def post(path: str, data: dict) -> dict:
    req = urllib.request.Request(
        f"{URL}{path}",
        data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as res:
            return json.loads(res.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        raise RuntimeError(f"POST {path} failed {exc.code}: {body}") from exc


def wait_health() -> None:
    for _ in range(100):
        try:
            with urllib.request.urlopen(f"{URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def start_daemon(repo: Path, temp_dir: str):
    daemon_bin = bin_path(repo, "ham-daemon")
    wrapper_bin = bin_path(repo, "ham-wrapper")
    ctl_bin = bin_path(repo, "ham-ctl")
    config_path = os.path.join(temp_dir, "config.toml")
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{temp_dir}/data"
user_id = "{USER_ID}"
wrapper_bin = "{wrapper_bin}"

[ctl]
daemon_url = "{URL}"
ham_ctl_bin = "{ctl_bin}"
''')
    log_path = os.path.join(temp_dir, "daemon.log")
    log = open(log_path, "a", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=log, stderr=subprocess.STDOUT)
    wait_health()
    return proc, log, log_path


def stop_daemon(proc, log) -> None:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
    log.close()


def assert_no_legacy_fields(payload: dict, label: str) -> None:
    text = json.dumps(payload)
    forbidden = [
        "subject_agent",
        "subject_key",
        '"scope"',
        "agent_instance_id",
        '"team_id"',
        "template_key",
        "project_ids",
        "role_keys",
        "task_chain_types",
    ]
    for item in forbidden:
        if item in text:
            raise AssertionError(f"{label} unexpectedly exposed legacy field {item}: {payload}")


def propose(agent_token: str, **body) -> dict:
    payload = {"agent_token": agent_token}
    payload.update(body)
    return post("/memory/propose/new", payload)


def approve(agent_token: str, proposal_id: str) -> dict:
    return post("/memory/decide", {"agent_token": agent_token, "proposal_id": proposal_id, "decision": "approve"})


def applicable(agent_token: str, **body) -> dict:
    payload = {"agent_token": agent_token}
    payload.update(body)
    return post("/memory/applicable", payload)


def memory_list(agent_token: str, **body) -> dict:
    payload = {"agent_token": agent_token}
    payload.update(body)
    return post("/memory/list", payload)


def create_project(user_client: dict, project_id: str) -> None:
    res = post(
        "/user-rpc",
        {
            "action": "project_create",
            "client_instance_id": user_client["client_instance_id"],
            "client_token": user_client["client_token"],
            "project_id": project_id,
            "name": project_id,
            "description": "memory target regression",
        },
    )
    if not res.get("ok"):
        raise AssertionError(f"project_create failed: {res}")


def titles(records: list[dict]) -> set[str]:
    return {str(record.get("title", "")) for record in records}


def status_by_id(records: list[dict]) -> dict[str, str]:
    return {str(rec["memory_id"]): str(rec["status"]) for rec in records}


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    temp_dir = tempfile.mkdtemp(prefix="heimdall-memory-targets-")
    proc = log = None
    try:
        proc, log, log_path = start_daemon(repo, temp_dir)

        user_client = post("/user-client/register", {"user_id": USER_ID, "client_instance_id": "memory-target-user"})
        user_client["client_instance_id"] = "memory-target-user"
        create_project(user_client, PROJECT_ID)
        create_project(user_client, OTHER_PROJECT_ID)

        agent_token = post(
            "/register",
            {
                "agent_class": "memory-target-coder",
                "agent_instance_id": AGENT_ID,
                "display_name": "Memory Target Coder",
            },
        )["agent_token"]
        agent_create = post(
            "/agents/create",
            {
                "agent_instance_id": AGENT_ID,
                "display_name": "Memory Target Coder",
                "provider_profile": "pi",
                "template_id": "coder",
                "model_tier": "normal",
                "project_id": PROJECT_ID,
            },
        )
        if not agent_create.get("ok"):
            raise AssertionError(f"agents/create failed: {agent_create}")

        created = []
        for kwargs in [
            dict(type="fact", title="Global memory", body="Applies everywhere."),
            dict(target_role=ROLE, type="fact", title="Coder only", body="Applies only to coder role."),
            dict(target_project_id=PROJECT_ID, type="fact", title="Project only", body="Applies only to project."),
            dict(target_project_id=PROJECT_ID, target_role=ROLE, type="fact", title="Project and role", body="Requires both project and role."),
            dict(target_team_kind=TEAM_KIND, type="fact", title="Team kind only", body="Applies only to coding teams."),
        ]:
            res = propose(agent_token, **kwargs)
            approve(agent_token, res["proposal_id"])
            created.append(res["memory_id"])

        show_res = post("/memory/show", {"agent_token": agent_token, "memory_id": created[0]})
        history_res = post("/memory/history", {"agent_token": agent_token, "memory_id": created[0]})
        listed = memory_list(agent_token, include_all_statuses=True)
        assert_no_legacy_fields(show_res, "show")
        assert_no_legacy_fields(history_res, "history")
        assert_no_legacy_fields(listed, "list")

        rec = show_res["record"]
        if sorted(rec.keys()) and {"target_team_kind", "target_role", "target_project_id"} - set(rec.keys()):
            raise AssertionError(f"show payload missing target triple: {rec}")

        exact_match = applicable(agent_token, target_team_kind=TEAM_KIND, target_role=ROLE, target_project_id=PROJECT_ID)
        exact_titles = titles(exact_match["records"])
        expected = {"Global memory", "Coder only", "Project only", "Project and role", "Team kind only"}
        if exact_titles != expected:
            raise AssertionError(f"exact applicability mismatch: {exact_titles} != {expected}")

        wrong_role = applicable(agent_token, target_team_kind=TEAM_KIND, target_role=OTHER_ROLE, target_project_id=PROJECT_ID)
        wrong_role_titles = titles(wrong_role["records"])
        if "Coder only" in wrong_role_titles or "Project and role" in wrong_role_titles:
            raise AssertionError(f"role mismatch should exclude role-targeted memories: {wrong_role_titles}")

        wrong_project = applicable(agent_token, target_team_kind=TEAM_KIND, target_role=ROLE, target_project_id=OTHER_PROJECT_ID)
        wrong_project_titles = titles(wrong_project["records"])
        if "Project only" in wrong_project_titles or "Project and role" in wrong_project_titles:
            raise AssertionError(f"project mismatch should exclude project-targeted memories: {wrong_project_titles}")

        wrong_team = applicable(agent_token, target_team_kind="research", target_role=ROLE, target_project_id=PROJECT_ID)
        wrong_team_titles = titles(wrong_team["records"])
        if "Team kind only" in wrong_team_titles:
            raise AssertionError(f"team-kind mismatch should exclude team-kind-targeted memory: {wrong_team_titles}")

        wildcard = applicable(agent_token)
        wildcard_titles = titles(wildcard["records"])
        if wildcard_titles != {"Global memory"}:
            raise AssertionError(f"wildcard request should only match fully global memories: {wildcard_titles}")

        # Expertise dedup remains keyed by canonical target triple + title.
        exp1 = propose(agent_token, target_project_id=PROJECT_ID, target_role=ROLE, type="expertise", title="Targeted expertise", body="first")
        approve(agent_token, exp1["proposal_id"])
        exp2 = propose(agent_token, target_project_id=PROJECT_ID, target_role=ROLE, type="expertise", title="Targeted expertise", body="second")
        approve(agent_token, exp2["proposal_id"])
        all_records = memory_list(agent_token, include_all_statuses=True, status="all")
        statuses = status_by_id(all_records["records"])
        if statuses[exp1["memory_id"]] != "archived" or statuses[exp2["memory_id"]] != "active":
            raise AssertionError(f"expertise dedup should archive prior matching target triple: {statuses}")

        print(json.dumps({
            "ok": True,
            "exact_titles": sorted(exact_titles),
            "wrong_role_titles": sorted(wrong_role_titles),
            "wrong_project_titles": sorted(wrong_project_titles),
            "wrong_team_titles": sorted(wrong_team_titles),
            "wildcard_titles": sorted(wildcard_titles),
            "daemon_log": log_path,
        }, indent=2))
    finally:
        if proc and log:
            stop_daemon(proc, log)


if __name__ == "__main__":
    main()
