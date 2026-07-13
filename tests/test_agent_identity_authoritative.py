#!/usr/bin/env python3
"""Static regression checks for authoritative agent identity classification."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
QUERIES = (ROOT / "src/daemon/task_queries.odin").read_text(encoding="utf-8")
TEAM = (ROOT / "src/daemon/team_service.odin").read_text(encoding="utf-8")
NUDGE = (ROOT / "src/daemon/task_nudge_scheduler.odin").read_text(encoding="utf-8")
STORE = (ROOT / "src/daemon/agent_store.odin").read_text(encoding="utf-8")
LIFECYCLE = (ROOT / "src/daemon/lifecycle.odin").read_text(encoding="utf-8")


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


require('state: string' in STORE, 'agent identity record/event should carry lifecycle state')
require('AGENT_IDENTITY_STATE_PROVISIONED :: "provisioned"' in STORE, 'provisioned state constant missing')
require('AGENT_IDENTITY_STATE_RUNNING :: "running"' in STORE, 'running state constant missing')
require('AGENT_IDENTITY_STATE_ARCHIVED :: "archived"' in STORE, 'archived state constant missing')
require('agent_store_sequence' in STORE and 'agent_new_record_id :: proc() -> string { return fmt.tprintf("agent_rec_%d_%d"' in STORE, 'agent record ids should be monotonic enough for same-ms provisioning')

identity_body = re.search(r'identity_is_agent :: proc\(agent_instance_id: string\) -> bool \{([\s\S]+?)\n\}', QUERIES)
require(identity_body is not None, 'identity_is_agent predicate missing')
require('agent_record_index_by_instance(agent_instance_id) >= 0' in identity_body.group(1), 'identity_is_agent must use durable agent records')
require('registry_agent_exists' not in identity_body.group(1), 'identity_is_agent must not consult live registry')

actor_body = re.search(r'task_actor_is_user :: proc\(actor: string\) -> bool \{([\s\S]+?)\n\}', QUERIES)
require(actor_body is not None, 'task_actor_is_user predicate missing')
require('!identity_is_agent(actor)' in actor_body.group(1), 'task_actor_is_user should be the inverse of identity_is_agent for non-empty ids')
require('registry_agent_exists' not in actor_body.group(1), 'task_actor_is_user must not consult live registry')

runtime_body = re.search(r'task_runtime_agent_target :: proc\(agent_instance_id: string\) -> string \{([\s\S]+?)\n\}', QUERIES)
require(runtime_body is not None, 'task_runtime_agent_target missing')
require('!identity_is_agent(agent_instance_id)' in runtime_body.group(1), 'runtime target should gate through authoritative classifier')

require('team_service_provision_member_agent' in TEAM, 'team service should provision generated agent identities')
require('agent_record_upsert(agent_instance_id, agent_instance_id, template, provider_profile, project_id, "", tier, AGENT_IDENTITY_STATE_PROVISIONED)' in TEAM, 'generated team agent ids should be persisted as provisioned at creation')
require('member.agent_record_id = rec_id' in TEAM, 'team members should retain their durable agent record id')
require('coordinator := task_runtime_agent_target(chain.coordinator_agent_instance_id)' in NUDGE, 'coordinator boot path should use runtime target helper')
require('coordinator == HUMAN_RECIPIENT_ID' not in NUDGE and 'coordinator == "user_proxy"' not in NUDGE and 'coordinator == "operator@local"' not in NUDGE, 'coordinator boot path should not carry emergency human-placeholder string list')
require('agent_record_upsert(agent_instance_id, stored_display, agent_class, "", "", "", "normal", AGENT_IDENTITY_STATE_RUNNING)' in LIFECYCLE, 'first external register should persist a running agent identity record')

print('PASS: authoritative agent identity checks')
