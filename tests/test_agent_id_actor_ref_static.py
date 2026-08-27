#!/usr/bin/env python3
"""Regression: durable agent_id actor refs (assignee/reviewer) resolve-or-reuse.

Feature (task_18c71ad56ef51e9c): allow passing a durable agent_id (e.g.
"default-agent", "reviewer") as a task assignee/reviewer. The hub normalizes an
{"type":"agent_id",...} ref into a concrete {"type":"agent_instance",...} ref by
reusing an existing instance of that agent_id for the chain owner (Phase 1), adding it
to the chain members so validation passes. ham-ctl emits agent_id refs for non-inst_
values.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
TC = (ROOT / 'src/hub/service/taskchain/taskchain_service.odin').read_text(encoding='utf-8')
CTL = (ROOT / 'src/ctl/hub_mode.odin').read_text(encoding='utf-8')


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f'FAILED: {msg}')
        sys.exit(1)


# --- Hub: normalization exists and is wired before validation in create + update ---
for sym in [
    'normalize_actor_refs ::',
    'resolve_agent_id_instance ::',
    'ensure_chain_member ::',
]:
    require(sym in TC, f'taskchain_service must define {sym}')

# normalize must run before validate in both create_task and update_task.
create = re.search(r'create_task ::.*?return saved_task', TC, re.S)
require(create is not None, 'create_task not found')
cbody = create.group(0)
require(cbody.index('normalize_actor_refs(service, chain, assignee_ref)') <
        cbody.index('validate_actor_refs(service, chain, assignee_ref'),
        'create_task must normalize agent_id refs before validation')

update = re.search(r'update_task ::.*?saved, save_ok, save_err', TC, re.S)
require(update is not None, 'update_task not found')
ubody = update.group(0)
require(ubody.index('normalize_actor_refs(service, chain, task.assignee_ref_json)') <
        ubody.index('validate_actor_refs(service, chain, task.assignee_ref_json'),
        'update_task must normalize agent_id refs before validation')

# Resolution prefers in-chain, then owner-owned; skips stopped/failed; errors clearly.
require('chain.coordinator_agent_instance_id' in TC and 'inst.agent_id == agent_id' in TC,
        'resolve must prefer the in-chain coordinator instance of the agent_id')
require('taskchain_list_members_by_chain' in TC, 'resolve must consider chain members')
require('agent_list_instances_by_owner' in TC, 'resolve must fall back to owner-owned instances')
require('runtime_status == "stopped"' in TC and 'runtime_status == "failed"' in TC,
        'resolve must skip stopped/failed instances')
require('no reusable instance found for agent_id' in TC,
        'resolve must return a clear error when no instance can be reused')

# Membership add so agent_instance_same_chain passes.
require('taskchain_save_member' in TC, 'ensure_chain_member must persist a chain member')

# --- ctl: emits agent_id refs for durable ids, agent_instance for inst_ ids ---
require('ctl_ref_json ::' in CTL, 'ctl must have ctl_ref_json helper')
require('ctl_build_assignee_ref ::' in CTL, 'ctl must have ctl_build_assignee_ref')
require('ctl_build_reviewer_refs ::' in CTL, 'ctl must have ctl_build_reviewer_refs')
require('"type", "agent_id"' in CTL, 'ctl must be able to emit agent_id refs')
require('has_prefix(plain_value, "inst_")' in CTL,
        'ctl must treat inst_-prefixed values as agent_instance and others as agent_id')
require('--assignee-agent-id' in CTL and '--reviewer-agent-id' in CTL,
        'ctl must expose explicit --assignee-agent-id / --reviewer-agent-id flags')

print('AGENT_ID ACTOR REF STATIC TEST PASSED')
