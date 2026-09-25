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

# --- ctl agent mode: emits agent_id refs for agt_ ids, agent_instance for other ids ---
AGENT_MODE = (ROOT / 'src/ctl/agent_mode.odin').read_text(encoding='utf-8')
require('ctl_v2_actor_ref ::' in AGENT_MODE, 'agent_mode must define ctl_v2_actor_ref')
require('ctl_v2_task_chain_fleet ::' in AGENT_MODE, 'agent_mode must define ctl_v2_task_chain_fleet')
require('case "fleet", "fleets":' in AGENT_MODE, 'agent_mode task-chain must dispatch fleet')
require('/api/v1/task-chains/%s/fleets' in AGENT_MODE, 'agent_mode fleet must call /fleets endpoint')

# --- ctl tasks mode: fleet dispatch & actor ref ---
TASKS_MODE = (ROOT / 'src/ctl/tasks.odin').read_text(encoding='utf-8')
require('ctl_task_chains_fleet_command ::' in TASKS_MODE, 'tasks.odin must define ctl_task_chains_fleet_command')
require('action == "fleet" || action == "fleets"' in TASKS_MODE, 'tasks.odin must route fleet action')

# --- Skills documentation ---
SKILL_HAM_CTL = (ROOT / 'src/prompts/skills/ham-ctl-reference/SKILL.md').read_text(encoding='utf-8')
require('### Fleet management (`task-chain fleet`)' in SKILL_HAM_CTL, 'ham-ctl-reference must document task-chain fleet')
require('task-chain fleet list' in SKILL_HAM_CTL, 'ham-ctl-reference must document task-chain fleet list')
require('task-chain fleet set' in SKILL_HAM_CTL, 'ham-ctl-reference must document task-chain fleet set')
require('agent_id' in SKILL_HAM_CTL and 'instance-or-agent-id' in SKILL_HAM_CTL, 'ham-ctl-reference must document polymorphic assignee/reviewer')

SKILL_COORD = (ROOT / 'src/prompts/skills/coordinator-task-management/SKILL.md').read_text(encoding='utf-8')
require('Fleet-based task delegation & capacity management' in SKILL_COORD, 'coordinator-task-management must document fleet delegation')
require('task-chain fleet set' in SKILL_COORD, 'coordinator-task-management must document fleet set command')
require('task-chain fleet list' in SKILL_COORD, 'coordinator-task-management must document fleet list command')

# --- UI (REQ-AUTO-1 / REQ-AUTO-4): no synthetic Fleet cards, no literal actor defaults ---
UI_DRAWER = (ROOT / 'src/ui/components/tasks/FleetManagementDrawer.tsx').read_text(encoding='utf-8')
UI_FLEETSEL = (ROOT / 'src/ui/components/tasks/fleetSelection.ts').read_text(encoding='utf-8')
UI_CREATE = (ROOT / 'src/ui/components/tasks/CreateTaskModal.tsx').read_text(encoding='utf-8')
UI_OVERVIEW = (ROOT / 'src/ui/components/taskchain/TaskChainOverview.tsx').read_text(encoding='utf-8')

# The Fleet must render exactly the persisted rows: no synthesized standard
# Worker/Reviewer cards and no capacity-1 fallback for the old literal IDs.
require('standardRoles' not in UI_DRAWER, 'Fleet drawer must not synthesize standard worker/reviewer cards')
require('agt_worker' not in UI_DRAWER and 'agt_reviewer' not in UI_DRAWER,
        'Fleet drawer must not reference literal agt_worker/agt_reviewer IDs')
require("if (agentId === 'agt_worker'" not in UI_FLEETSEL,
        'fleetSelection must not hardcode a capacity-1 fallback for agt_worker/agt_reviewer')

# Task forms must never default to (or fall back to) the literal placeholder
# role IDs; actors come from the durable identity catalog or stay unassigned.
for literal in [
    "useState('agt_worker')",
    "useState('agt_reviewer')",
    "setAssigneeAgentId('agt_worker')",
    "setReviewerAgentId('agt_reviewer')",
    "setNewTaskAssigneeAgentId('agt_worker')",
    "setNewTaskAddReviewerAgentId('agt_reviewer')",
    "{ value: 'agt_worker', label: 'Worker' }",
    "{ value: 'agt_reviewer', label: 'Reviewer' }",
]:
    require(literal not in UI_CREATE, f'CreateTaskModal must not contain {literal}')
    require(literal not in UI_OVERVIEW, f'TaskChainOverview must not contain {literal}')

# Task create/update must invalidate the Fleet query so an open drawer shows
# the hub-created capacity-1 row for durable actors without a reload.
UI_TASKS_API = (ROOT / 'src/ui/api/endpoints/tasks.ts').read_text(encoding='utf-8')
require(UI_TASKS_API.count('TaskChainFleets') >= 2,
        'tasks API must invalidate the TaskChainFleets tag on task create and update')

print('AGENT_ID ACTOR REF STATIC TEST PASSED')
