#!/usr/bin/env python3
"""Static regression checks for teams-removal Phase 3 de-hardcoded agent selection."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

AGENTS_START = (ROOT / "src/daemon/agents_start.odin").read_text(encoding="utf-8")
TASK_SERVICE = (ROOT / "src/daemon/task_service.odin").read_text(encoding="utf-8")
TEAM_SERVICE = (ROOT / "src/daemon/team_service.odin").read_text(encoding="utf-8")
AGENT_STORE = (ROOT / "src/daemon/agent_store.odin").read_text(encoding="utf-8")
AGENT_IDS = (ROOT / "src/daemon/agent_id_store.odin").read_text(encoding="utf-8")
GUIDE = (ROOT / "src/daemon/guide_service.odin").read_text(encoding="utf-8")
NUDGE = (ROOT / "src/daemon/task_nudge_scheduler.odin").read_text(encoding="utf-8")
FEDERATION = (ROOT / "src/daemon/federation_peers.odin").read_text(encoding="utf-8")
USER_RPC = (ROOT / "src/daemon/user_rpc.odin").read_text(encoding="utf-8")
CONFIG = (ROOT / "src/lib/config/config.odin").read_text(encoding="utf-8")
SAMPLE_CONFIG = (ROOT / "config.toml").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    combined_selection = "\n".join([AGENTS_START, TASK_SERVICE])
    require('agent_id_ref == "coordinator"' not in combined_selection, "coordinator agent id must not trigger a hardcoded template fixup")
    require('template_id = "lead"' not in combined_selection, "runtime selection must not force coordinator to lead template")
    require('durable_agent_id == "coordinator"' not in TASK_SERVICE, "task-created custom coordinator ids must not be special-cased")

    require('agent_default_id_for_use(role_key)' in TEAM_SERVICE, "legacy scaffold/team provisioning must resolve role slots through default-agent map")
    require('agent_id_template_id(durable_agent_id)' in TEAM_SERVICE, "default-agent durable identity should choose the template for scaffold provisioning")
    require('team_service_role_durable_agent_id(role_key, template_id)' in TEAM_SERVICE, "legacy fallback can remain only after default-agent map lookup")

    require('system_agent_ids: []string' in CONFIG, "daemon config must expose a system-agent id allowlist")
    require('case "system_agent_ids"' in CONFIG, "system-agent id allowlist must be configurable")
    require('system_agent_ids = ["guide", "memory-auditor", "memory-reviewer"]' in SAMPLE_CONFIG, "sample config should document system-agent ids")
    require('agent_system_id_configured :: proc' in AGENT_IDS, "system behavior must go through named system-agent helper")
    require('server_config.daemon.system_agent_ids' in AGENT_IDS, "system-agent helper must read operator config")

    require('template_id == "guide"' not in AGENT_STORE, "default-project seeding must not identify guide by template literal")
    require('template_id == "memory_auditor"' not in AGENT_STORE and 'template_id == "memory_reviewer"' not in AGENT_STORE, "memory system agents must not be identified by template literal")
    require('agent_system_id_configured(agent_instance_id)' in AGENT_STORE, "system default-project behavior should use configured agent ids")
    require('rec.template_id == "guide"' not in NUDGE, "idle shutdown skip must not use guide template literal")
    require('agent_system_id_configured(rec.agent_instance_id)' in NUDGE, "idle shutdown skip should use configured system-agent ids")

    require('skip_reason=invalid_singleton_id' not in GUIDE, "guide autostart must not reject configured custom guide ids")
    require('agent_id_records[idx].template_id' in GUIDE, "custom guide durable identity should be able to supply its own template")

    require('rec.agent_id == "conversation"' not in FEDERATION and 'rec.template_id == "conversation"' not in FEDERATION, "federation filtering must not hardcode conversation id/template")
    require('agent_id_matches_default_use(rec.agent_id, "conversation")' in FEDERATION, "federation should use configured conversation default id")
    require('rec.template_id == "conversation"' not in USER_RPC, "chat list detection must not hardcode conversation template")
    require('agent_id_matches_default_use(durable, "conversation")' in USER_RPC, "chat list should use configured conversation default id")

    print("PASS: Phase 3 de-hardcoded agent selection static checks")


if __name__ == "__main__":
    main()
