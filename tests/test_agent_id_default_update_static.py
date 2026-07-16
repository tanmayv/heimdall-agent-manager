#!/usr/bin/env python3
"""Static regression checks for updating durable agent_id defaults from the Agents tab.

The Agents tab identity edit must be able to change an agent_id's default
provider / tier / project, and clearing the default project must persist (not be
silently ignored). This exercises the event-sourced round-trip contract:
struct field, JSON writer, JSON reader, apply/replay, and the update helper +
handler + UI wiring.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
ID_STORE = (ROOT / "src/daemon/agent_id_store.odin").read_text(encoding="utf-8")
AGENTS_START = (ROOT / "src/daemon/agents_start.odin").read_text(encoding="utf-8")
DAEMON_API = (ROOT / "src/ui/api/daemonApi.ts").read_text(encoding="utf-8")
APP = (ROOT / "src/ui/components/App.tsx").read_text(encoding="utf-8")


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


# Event-sourced field must be present in ALL of struct, writer, reader, apply.
require("default_project_set: bool," in ID_STORE, "event struct should carry default_project_set flag")
require('strings.write_string(&b, `","default_project_set":`)' in ID_STORE, "JSON writer must persist default_project_set")
require('default_project_set = extract_json_bool(line, "default_project_set", false),' in ID_STORE, "JSON reader must parse default_project_set")
require("if event.default_project_set || event.default_project_id != \"\" || rec.default_project_id == \"\"" in ID_STORE, "apply must honor explicit project set (including clear)")

# Update helper exists and preserves template/role/state while applying defaults verbatim.
require("agent_id_update_defaults :: proc(agent_id, display_name, default_provider_profile, default_model_tier, default_project_id, author: string) -> bool" in ID_STORE, "durable defaults update helper missing")
require("template_id = rec.template_id," in ID_STORE, "update helper must preserve template id")
require("default_project_set = true," in ID_STORE, "update helper must apply project verbatim")

# Explicit set/clear must be sticky across replay: backfill from older instance
# events MUST NOT rehydrate an explicitly cleared default project.
require("default_project_explicit: bool," in ID_STORE, "record must track explicit default-project set/clear")
require("if event.default_project_set do rec.default_project_explicit = true" in ID_STORE, "apply must mark explicit on default_project_set events")
require('if !rec.default_project_explicit && rec.default_project_id == "" && default_project_id != ""' in ID_STORE, "backfill must not rehydrate an explicitly cleared default project")
require("default_project_set = rec.default_project_explicit," in ID_STORE, "record->event re-emit must preserve explicit flag, not fabricate it")

# Backend handler wires the durable update behind an explicit flag.
require('extract_json_bool(body, "update_agent_id_defaults", false)' in AGENTS_START, "instance update should gate durable defaults on explicit flag")
require("agent_id_update_defaults(resolved_agent_id, display_name, provider_profile, model_tier, project_id, \"api\")" in AGENTS_START, "instance update should propagate to durable agent_id defaults")

# UI wiring: API forwards the flag; identity edit sets it.
require("updateAgentIdDefaults?: boolean" in DAEMON_API, "updateAgent API should accept updateAgentIdDefaults")
require("if (updateAgentIdDefaults) body.update_agent_id_defaults = true;" in DAEMON_API, "updateAgent API should forward the flag")
require("modelTier: editTier, updateAgentIdDefaults: true" in APP, "identity edit save must request durable default update")

# Runtime restart must be able to set/clear an EXACT instance project via
# /agents/start project_id_set, without going through /agents/disassociate.
require("project_id_set: bool = false," in AGENTS_START, "agent_record_upsert must accept an explicit project_id_set flag")
require('if resolved_project_id == "" && !project_id_set do resolved_project_id = agent_instance_records[idx].project_id' in AGENTS_START, "empty project must only be preserved when not explicitly set")
require('project_id_set := extract_json_bool(body, "project_id_set", false)' in AGENTS_START, "/agents/start must read project_id_set")
require("persisted_model_tier, \"\", manual_scope, agent_role, project_id_set)" in AGENTS_START, "/agents/start must forward project_id_set to agent_record_upsert")

print("PASS: agent_id durable default update static checks")
