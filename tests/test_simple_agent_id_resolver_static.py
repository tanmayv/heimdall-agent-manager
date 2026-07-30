#!/usr/bin/env python3
"""Static regression checks for explicit durable agent-id task assignment behavior."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TASK_COMMANDS = ROOT / "src" / "daemon" / "task_commands.odin"
TASK_SERVICE = ROOT / "src" / "daemon" / "task_service.odin"
TASK_HTTP = ROOT / "src" / "daemon" / "task_http.odin"
USER_RPC = ROOT / "src" / "daemon" / "user_rpc.odin"
CTL = ROOT / "src" / "ctl" / "main.odin"


def require(src: str, needle: str, path: Path) -> None:
    if needle not in src:
        raise AssertionError(f"missing {needle!r} in {path}")


def main() -> None:
    commands = TASK_COMMANDS.read_text(encoding="utf-8")
    task_service = TASK_SERVICE.read_text(encoding="utf-8")
    task_http = TASK_HTTP.read_text(encoding="utf-8")
    user_rpc = USER_RPC.read_text(encoding="utf-8")
    ctl = CTL.read_text(encoding="utf-8")

    # Public command structs carry durable agent_id fields separately from
    # concrete agent_instance_id fields.
    for needle in [
        "assignee_agent_id:            string",
        "reviewer_agent_id:            string",
        "coordinator_agent_id:               string",
        "default_reviewer_agent_id:          string",
        "agent_id:                 string",
    ]:
        require(commands, needle, TASK_COMMANDS)

    # Instance references are exact only: syntactically valid, already-known, and
    # never materialized by guessing a durable agent id from an instance field.
    require(task_service, "valid_agent_instance_id(agent_ref)", TASK_SERVICE)
    require(task_service, "agent_record_index_by_instance(agent_ref)", TASK_SERVICE)
    require(task_service, "agent_instance_id is unknown; use agent_id to materialize a durable agent", TASK_SERVICE)
    require(task_service, "invalid agent_instance_id; use agent_id for durable agent ids", TASK_SERVICE)

    # Durable agent ids are explicit, format-validated, and then materialized.
    require(task_service, "task_service_validate_agent_id_reference", TASK_SERVICE)
    require(task_service, "agent_id must not contain '@'; use agent_instance_id for concrete instances", TASK_SERVICE)
    require(task_service, "task_service_resolve_agent_id_reference_for_chain", TASK_SERVICE)
    require(task_service, "task_service_resolve_explicit_agent_target_for_chain", TASK_SERVICE)
    require(task_service, "task_service_create_concrete_instance_for_agent_id(agent_id", TASK_SERVICE)
    require(task_service, "specify either %s agent_instance_id or %s agent_id, not both", TASK_SERVICE)

    # Agent-facing HTTP and user RPC surfaces forward both explicit forms.
    for src, path in [(task_http, TASK_HTTP), (user_rpc, USER_RPC)]:
        for needle in [
            'extract_json_string(body, "assignee_agent_id", "")',
            'extract_json_string(body, "reviewer_agent_id", "")',
            'extract_json_string(body, "agent_id", "")',
            'extract_json_string(body, "coordinator_agent_id", "")',
            'extract_json_string(body, "default_reviewer_agent_id", "")',
        ]:
            require(src, needle, path)

    # ham-ctl exposes agent-id flags so agents can use the flow without raw HTTP.
    for needle in [
        "--agent-id <agent_id>",
        "--assignee-agent-id <agent_id>",
        "--reviewer-agent-id <agent_id>",
        "--coordinator-agent-id <agent_id>",
        "agent_instance_id flags target existing concrete instances only; agent_id flags materialize a new instance from a durable id",
        '`,"agent_id":"`',
        '`,"assignee_agent_id":"`',
        '`,"reviewer_agent_id":"`',
    ]:
        require(ctl, needle, CTL)

    print("PASS: explicit durable agent-id task assignment static checks")


if __name__ == "__main__":
    main()
