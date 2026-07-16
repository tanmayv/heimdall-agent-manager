#!/usr/bin/env python3
"""Static regression checks for simple durable agent-id resolver behavior."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TASK_SERVICE = ROOT / "src" / "daemon" / "task_service.odin"
TEAM_SERVICE = ROOT / "src" / "daemon" / "team_service.odin"
AGENTS_START = ROOT / "src" / "daemon" / "agents_start.odin"
AGENT_STORE = ROOT / "src" / "daemon" / "agent_store.odin"
CTL = ROOT / "src" / "ctl" / "main.odin"


def require(src: str, needle: str, path: Path) -> None:
    if needle not in src:
        raise AssertionError(f"missing {needle!r} in {path}")


def main() -> None:
    task_service = TASK_SERVICE.read_text(encoding="utf-8")
    team_service = TEAM_SERVICE.read_text(encoding="utf-8")
    agents_start = AGENTS_START.read_text(encoding="utf-8")
    agent_store = AGENT_STORE.read_text(encoding="utf-8")
    ctl = CTL.read_text(encoding="utf-8")

    # Role slots remain indexed roster labels, but provisioning creates concrete
    # instances from simple durable ids such as coder/tester/reviewer.
    require(team_service, "team_service_role_durable_agent_id", TEAM_SERVICE)
    require(team_service, "durable_agent_id := team_service_role_durable_agent_id(role_key, template_id)", TEAM_SERVICE)
    require(team_service, "concrete_agent_instance_id := agent_instance_id_new(durable_agent_id)", TEAM_SERVICE)
    require(team_service, "member.route_to = resolved_instance_id", TEAM_SERVICE)
    require(team_service, "AGENT_SCOPE_GENERATED_CHAIN", TEAM_SERVICE)

    # Assignment/participants and chain role overrides resolve in this order:
    # exact instance, team slot, then simple durable agent_id -> new concrete
    # instance. Chain coordinator/default reviewer events must persist concrete
    # ids, not raw durable/slot refs.
    require(task_service, "task_service_resolve_agent_reference_for_chain", TASK_SERVICE)
    require(task_service, "task_service_resolve_agent_reference_for_new_chain", TASK_SERVICE)
    require(task_service, "agent_record_index_by_instance(agent_ref)", TASK_SERVICE)
    require(task_service, "task_service_resolve_team_slot_reference(chain_id, agent_ref)", TASK_SERVICE)
    require(task_service, "task_service_resolve_team_slot_reference_for_team", TASK_SERVICE)
    require(task_service, "task_service_agent_ref_looks_indexed_slot", TASK_SERVICE)
    require(task_service, "task_service_create_concrete_instance_for_agent_id", TASK_SERVICE)
    require(task_service, "instance_id := agent_instance_id_new(durable_agent_id)", TASK_SERVICE)
    require(task_service, "agent_instance_id        = agent_instance_id", TASK_SERVICE)
    require(task_service, "coordinator_agent_instance_id = event_coordinator", TASK_SERVICE)
    require(task_service, "reviewer_agent_instance_id    = event_default_reviewer", TASK_SERVICE)
    require(task_service, "coordinator_agent_instance_id = coordinator_agent_instance_id", TASK_SERVICE)
    require(task_service, "reviewer_agent_instance_id    = default_reviewer_agent_instance_id", TASK_SERVICE)
    require(task_service, "task_reviewer_ref_is_user_proxy", TASK_SERVICE)
    require(task_service, "if task_actor_is_user_proxy(agent_instance_id) do return true, false", TASK_SERVICE)
    require(task_service, "if task_actor_is_human_recipient(agent_instance_id)", TASK_SERVICE)
    require(task_service, "return agent_instance_id, false", TASK_SERVICE)

    # Generated team-chain instances must not seed durable identity default projects.
    require(agent_store, "if normalized_scope != AGENT_SCOPE_DURABLE do default_project_id = \"\"", AGENT_STORE)

    # /agents/start and ham-ctl distinguish durable agent ids from exact instances.
    require(agents_start, "extract_json_string(body, \"agent_id\", \"\")", AGENTS_START)
    require(agents_start, "agent_instance_id = agent_instance_id_new(agent_id_ref)", AGENTS_START)
    require(agents_start, "indexed role slots are not durable agent_id values", AGENTS_START)
    require(ctl, "cmd[1] == \"run\"", CTL)
    require(ctl, "--agent-id <agent_id>", CTL)
    require(ctl, "target_is_agent_id", CTL)

    print("PASS: simple durable agent-id resolver static checks")


if __name__ == "__main__":
    main()
