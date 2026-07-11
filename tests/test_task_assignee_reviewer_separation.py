#!/usr/bin/env python3
"""Regression: backend must forbid reviewer-role agents from becoming task assignees,
and must keep assignee/reviewer identities disjoint across create/assign/participant-add.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
TASK_SERVICE = ROOT / "src/daemon/task_service.odin"


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


def main() -> None:
    src = TASK_SERVICE.read_text(encoding="utf-8")

    require('task_agent_instance_has_chain_role :: proc' in src, 'missing shared chain-role helper')
    require('reviewer role agent cannot be the assignee' in src, 'missing explicit reviewer-role assignee rejection message')

    create_task = re.search(r'task_service_create_task :: proc[\s\S]+?task_service_create_chain :: proc', src)
    require(create_task is not None, 'create-task function block not found')
    create_block = create_task.group(0)
    require('cmd.assignee_agent_instance_id != "" && cmd.assignee_agent_instance_id == cmd.reviewer_agent_instance_id' in create_block, 'create-task must still reject assignee == reviewer')
    require('task_chain_default_reviewer_agent_instance_id(cmd.chain_id) == cmd.assignee_agent_instance_id' in create_block, 'create-task must still reject assignee == default reviewer')
    require('task_agent_instance_has_chain_role(chain_id, cmd.assignee_agent_instance_id, "reviewer")' in create_block, 'create-task must reject reviewer-role agents as assignees')

    assign_block = re.search(r'task_service_assign_command :: proc[\s\S]+?task_service_add_participant :: proc', src)
    require(assign_block is not None, 'assign function block not found')
    assign = assign_block.group(0)
    require('task_actor_has_role(state, cmd.agent_instance_id, "lgtm_required") || task_actor_has_role(state, cmd.agent_instance_id, "lgtm_optional")' in assign, 'assign must still reject current reviewer becoming assignee')
    require('task_chain_default_reviewer_agent_instance_id(state.chain_id) == cmd.agent_instance_id' in assign, 'assign must still reject default reviewer becoming assignee')
    require('task_agent_instance_has_chain_role(state.chain_id, cmd.agent_instance_id, "reviewer")' in assign, 'assign must reject reviewer-role team members becoming assignee')

    part_block = re.search(r'task_service_participant_command :: proc[\s\S]+?task_agent_instance_has_chain_role :: proc', src)
    require(part_block is not None, 'participant function block not found')
    part = part_block.group(0)
    require('(cmd.role == "lgtm_required" || cmd.role == "lgtm_optional") && state.assignee_agent_instance_id == cmd.agent_instance_id' in part, 'participant add must still reject assignee becoming reviewer')
    require('cmd.role == "assignee" && (task_actor_has_role(state, cmd.agent_instance_id, "lgtm_required") || task_actor_has_role(state, cmd.agent_instance_id, "lgtm_optional"))' in part, 'participant add must still reject reviewer becoming assignee')
    require('cmd.role == "assignee" && task_chain_default_reviewer_agent_instance_id(state.chain_id) == cmd.agent_instance_id' in part, 'participant add must still reject default reviewer becoming assignee')
    require('cmd.role == "assignee" && task_agent_instance_has_chain_role(state.chain_id, cmd.agent_instance_id, "reviewer")' in part, 'participant add must reject reviewer-role team members becoming assignee')

    print('TASK ASSIGNEE/REVIEWER SEPARATION TEST PASSED')


if __name__ == '__main__':
    main()
