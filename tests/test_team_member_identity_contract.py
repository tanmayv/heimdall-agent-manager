#!/usr/bin/env python3
"""Static contract checks for team role-slot identity/routing.

Team rows keep stable indexed role-slot labels, while task assignment/review
routing persists concrete agent instances resolved from simple durable agent ids.
This complements daemon integration coverage by guarding critical implementation
points.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEAM_DB = ROOT / "src" / "daemon" / "team_db_service.odin"
TEAM_SERVICE = ROOT / "src" / "daemon" / "team_service.odin"
TASK_SERVICE = ROOT / "src" / "daemon" / "task_service.odin"
TEAM_HTTP = ROOT / "src" / "daemon" / "team_http.odin"
DOC = ROOT / "docs" / "teams-v1" / "03-lifecycle.md"


def require(src: str, needle: str, path: Path) -> None:
    if needle not in src:
        raise AssertionError(f"missing {needle!r} in {path}")


def main() -> None:
    team_db = TEAM_DB.read_text(encoding="utf-8")
    team_service = TEAM_SERVICE.read_text(encoding="utf-8")
    task_service = TASK_SERVICE.read_text(encoding="utf-8")
    team_http = TEAM_HTTP.read_text(encoding="utf-8")
    doc = DOC.read_text(encoding="utf-8")

    # Durable schema identity.
    require(team_db, "TEAM_DB_USER_VERSION :: 3", TEAM_DB)
    require(team_db, "team_member_id: string", TEAM_DB)
    require(team_db, "agent_instance_id: string", TEAM_DB)
    require(team_db, "idx_team_members_member_id", TEAM_DB)
    require(team_db, "idx_team_members_agent_instance_id", TEAM_DB)
    require(team_db, "team_member_with_identity_defaults", TEAM_DB)
    require(team_db, "if m.team_member_id == \"\" do m.team_member_id", TEAM_DB)
    require(team_db, "if m.agent_instance_id == \"\" && !m.is_user_proxy", TEAM_DB)

    # Stable generated role-slot label shape: <role>-<index+1>@<team-scope>.
    # The slot label is not the runtime identity; route_to stores the concrete
    # <durable-agent-id>@s-... instance used by tasks.
    require(team_service, "team_service_member_id", TEAM_SERVICE)
    require(team_service, "team_service_member_agent_instance_id", TEAM_SERVICE)
    require(team_service, '"%s-%d@%s"', TEAM_SERVICE)
    require(team_service, "team_service_member_slot_label", TEAM_SERVICE)
    require(team_service, "team_service_role_durable_agent_id", TEAM_SERVICE)
    require(team_service, "member.route_to = resolved_instance_id", TEAM_SERVICE)
    require(team_service, "agent_instance_id_new(durable_agent_id)", TEAM_SERVICE)
    require(task_service, "team_service_create_for_chain(cmd.project_id, chain_id, cmd.kind, \"\", team_coordinator_override)", TASK_SERVICE)
    require(task_service, "team_service_ensure_member_route", TASK_SERVICE)
    require(task_service, "task_service_resolve_agent_reference_for_chain", TASK_SERVICE)
    require(task_service, "task_service_create_concrete_instance_for_agent_id", TASK_SERVICE)

    # Direct assignments/participants resolve slot/durable refs, then validate
    # known concrete instances for the chain.
    require(task_service, "task_agent_instance_allowed_for_chain", TASK_SERVICE)
    require(task_service, "role slot is unknown for this chain", TASK_SERVICE)
    require(task_service, "agent is not an eligible agent", TASK_SERVICE)

    # HTTP roster exposes the stable member identity to UI/testers.
    require(team_http, "team_member_id", TEAM_HTTP)
    require(team_http, "member.agent_instance_id", TEAM_HTTP)

    migration = (ROOT / "src" / "daemon" / "teams_v1_migration.odin").read_text(encoding="utf-8")
    require(migration, "worker_ok", ROOT / "src" / "daemon" / "teams_v1_migration.odin")
    require(migration, "failed member insert", ROOT / "src" / "daemon" / "teams_v1_migration.odin")

    # Docs must state routing is by durable slot identity, not string parsing.
    require(doc, "team_member_id", DOC)
    require(doc, "not by parsing", DOC)

    print("PASS: team-member scoped identity/routing contract")


if __name__ == "__main__":
    main()
