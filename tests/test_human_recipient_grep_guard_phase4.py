#!/usr/bin/env python3
"""Phase 4 grep guard for human-recipient addressing decoupling."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
QUERIES = (ROOT / "src/daemon/task_queries.odin").read_text()
CHAT = (ROOT / "src/daemon/chat_http.odin").read_text()
SCHED_PROMPT = (ROOT / "src/daemon/scheduled_prompt_service.odin").read_text()
MERGE = (ROOT / "src/daemon/merge_lifecycle.odin").read_text()
NOTIFY = (ROOT / "src/daemon/task_notifications.odin").read_text()
NUDGE = (ROOT / "src/daemon/task_nudge_scheduler.odin").read_text()
TEAM = (ROOT / "src/daemon/team_service.odin").read_text()
SERVICE = (ROOT / "src/daemon/task_service.odin").read_text()
GUIDE = (ROOT / "src/daemon/guide_rpc.odin").read_text()


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


require('HUMAN_RECIPIENT_ID :: "operator@local"' in QUERIES, 'human recipient constant missing')
require('task_runtime_agent_target :: proc' in QUERIES, 'runtime target helper missing')

for label, src in [
    ('chat_http', CHAT),
    ('scheduled_prompt_service', SCHED_PROMPT),
    ('merge_lifecycle', MERGE),
]:
    require('HUMAN_RECIPIENT_ID' in src, f'{label} should use the shared human recipient constant')
    require('"operator@local"' not in src, f'{label} should not embed operator@local directly')
    require('"user_proxy"' not in src, f'{label} should not branch on user_proxy directly')

require('member.route_to = HUMAN_RECIPIENT_ID' in TEAM, 'team service should route user_proxy seat through HUMAN_RECIPIENT_ID')
require('if role.role_key == "user_proxy"' in TEAM, 'team service should keep user_proxy only as team-seat metadata')
require('member.route_to = "operator@local"' not in TEAM, 'team service should not hardcode operator route')

for label, src in [('task_notifications', NOTIFY), ('task_nudge_scheduler', NUDGE), ('task_service', SERVICE), ('guide_rpc', GUIDE)]:
    require(not re.search(r'[!=]=\s*"operator@local"', src), f'{label} should not compare ids to operator@local')
    require(not re.search(r'[!=]=\s*"user_proxy"', src), f'{label} should not compare ids to user_proxy')
    require(not re.search(r'[!=]=\s*HUMAN_RECIPIENT_ID', src), f'{label} should not compare ids to HUMAN_RECIPIENT_ID outside addressing-only paths')

require('task_runtime_agent_target(task_chain_default_reviewer_agent_instance_id(state.chain_id))' in NOTIFY, 'notification fallback should use runtime-agent helper for default reviewer')
require('if task_actor_is_user(agent_instance_id)' in SERVICE, 'task service user-review normalization should use explicit user identity, not HUMAN_RECIPIENT_ID')
require('task_runtime_agent_target(agent_id) == ""' in SERVICE, 'task service non-user reviewer picker should exclude human recipients via runtime helper')
require('if task_reviewer_matches_user_proxy_member(agent_instance_id, member) do return true' in SERVICE, 'task service chain-authorization should use team-seat metadata for user review seats')
require('chat_store_append_message_with_chain(HUMAN_RECIPIENT_ID, chain.coordinator_agent_instance_id, "user_to_agent"' in SERVICE, 'task service coordinator completion ping should use HUMAN_RECIPIENT_ID')
require('task.status == .Review_Ready && task_requires_user_review(task)' in GUIDE, 'guide actionable detection should use explicit user-review predicate')
require('task_runtime_agent_target(task_coordinator_agent_instance_id(state))' in NOTIFY, 'notification fallback should use runtime-agent helper for coordinator')
require('notification_outbox_insert_pending(HUMAN_RECIPIENT_ID, payload)' in NOTIFY, 'notification fallback should durable-queue to shared human recipient')
require('task_runtime_agent_target(chain.coordinator_agent_instance_id)' in NUDGE, 'scheduler should detect runtime coordinator via helper')
require('task_runtime_agent_target(candidate_id)' in NUDGE, 'chain shutdown should skip non-runtime human seats via helper')
require('chat_has_unread_direction(HUMAN_RECIPIENT_ID, agent_instance_id, "user_to_agent")' in NUDGE, 'unread mention check should use shared human recipient constant')

print('PHASE 4 HUMAN RECIPIENT GREP GUARD PASSED')
