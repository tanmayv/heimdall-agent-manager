#!/usr/bin/env python3
"""Static regression test for WebSocket resource_changed events emitted by agent task actions and vote resolutions.

Requirements:
- REQ-WS-AGENT-TASK-1: agent_action_task_status_handler emits publish_task_event(..., "status_changed") and publish_chain_event(..., "updated").
- REQ-WS-AGENT-TASK-2: agent_action_task_comment_handler emits publish_task_event(..., "commented").
- REQ-WS-AGENT-TASK-3: agent_action_task_vote_handler emits publish_task_event(..., "voted") and publish_chain_event(..., "updated").
  When vote resolves quorum to Completed or Validated_Not_Good, also emits publish_task_event(..., "status_changed").
- REQ-WS-AGENT-TASK-4: agent_action_task_create_handler, agent_action_task_update_handler, and agent_action_task_depend_handler
  emit both task and chain events.
- REQ-WS-AGENT-TASK-5: In taskchain_handlers.odin, vote_task_handler and update_task_handler / patch_task_handler emit chain updated events,
  and vote_task_handler emits task status_changed when quorum resolves.
- REQ-WS-AGENT-TASK-6: publish_task_event and publish_chain_event shared helpers enforce null safety and memory cleanup.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
AGENT_ACTIONS_FILE = ROOT / "src" / "hub" / "transport" / "http" / "agent_action_handlers.odin"
TASKCHAIN_HANDLERS_FILE = ROOT / "src" / "hub" / "transport" / "http" / "taskchain_handlers.odin"

AGENT_ACTIONS = AGENT_ACTIONS_FILE.read_text(encoding="utf-8")
TASKCHAIN_HANDLERS = TASKCHAIN_HANDLERS_FILE.read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def extract_proc(source: str, proc_name: str) -> str:
    # Check if proc_name is an alias to another proc, e.g. update_task_handler :: patch_task_handler
    alias_match = re.search(rf"{proc_name}\s*::\s*([a-zA-Z0-9_]+)\b", source)
    if alias_match and alias_match.group(1) != "proc":
        target = alias_match.group(1)
        return extract_proc(source, target)
    pattern = rf"{proc_name}\s*::\s*proc\b.*?(?=\n[a-zA-Z0-9_]+\s*::|\Z)"
    match = re.search(pattern, source, re.DOTALL)
    require(match is not None, f"Procedure '{proc_name}' not found in source")
    return match.group(0)


def main() -> None:
    # REQ-WS-AGENT-TASK-6: Shared helper definitions and null-safety
    require(
        "publish_task_event :: proc(" in TASKCHAIN_HANDLERS,
        "publish_task_event must be defined in taskchain_handlers.odin",
    )
    require(
        "publish_chain_event :: proc(" in TASKCHAIN_HANDLERS,
        "publish_chain_event must be defined in taskchain_handlers.odin",
    )

    task_event_proc = extract_proc(TASKCHAIN_HANDLERS, "publish_task_event")
    require(
        'events.publish_resource_changed(bus, owner_user_id, "task", task_id, change, summary)' in task_event_proc,
        "publish_task_event must call events.publish_resource_changed for 'task'",
    )
    require(
        "if bus == nil || owner_user_id == \"\" do return" in task_event_proc,
        "publish_task_event must check bus == nil and owner_user_id == ''",
    )
    require(
        "defer delete(summary)" in task_event_proc,
        "publish_task_event must clean up summary with defer delete(summary)",
    )

    chain_event_proc = extract_proc(TASKCHAIN_HANDLERS, "publish_chain_event")
    require(
        'events.publish_resource_changed(bus, owner_user_id, "task_chain", chain_id, change, summary)' in chain_event_proc,
        "publish_chain_event must call events.publish_resource_changed for 'task_chain'",
    )
    require(
        "if bus == nil || owner_user_id == \"\" do return" in chain_event_proc,
        "publish_chain_event must check bus == nil and owner_user_id == ''",
    )
    require(
        "defer delete(summary)" in chain_event_proc,
        "publish_chain_event must clean up summary with defer delete(summary)",
    )

    # Also verify backward-compatible delegation of existing helpers
    chain_changed_proc = extract_proc(TASKCHAIN_HANDLERS, "publish_chain_changed")
    require(
        "publish_chain_event(h.event_bus, owner_user_id, chain_id, change)" in chain_changed_proc,
        "publish_chain_changed must delegate to publish_chain_event",
    )
    task_changed_proc = extract_proc(TASKCHAIN_HANDLERS, "publish_task_changed")
    require(
        "publish_task_event(h.event_bus, owner_user_id, task_id, chain_id, change)" in task_changed_proc,
        "publish_task_changed must delegate to publish_task_event",
    )

    # REQ-WS-AGENT-TASK-1: agent_action_task_status_handler
    status_handler = extract_proc(AGENT_ACTIONS, "agent_action_task_status_handler")
    require(
        'publish_task_event(h.event_bus, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "status_changed")' in status_handler,
        "agent_action_task_status_handler must emit publish_task_event for status_changed",
    )
    require(
        'publish_chain_event(h.event_bus, string(task.owner_user_id), string(task.chain_id), "updated")' in status_handler,
        "agent_action_task_status_handler must emit publish_chain_event for updated",
    )

    # REQ-WS-AGENT-TASK-2: agent_action_task_comment_handler
    comment_handler = extract_proc(AGENT_ACTIONS, "agent_action_task_comment_handler")
    require(
        'publish_task_event(h.event_bus, string(comment.owner_user_id), string(comment.task_id), string(comment.chain_id), "commented")' in comment_handler,
        "agent_action_task_comment_handler must emit publish_task_event for commented",
    )

    # REQ-WS-AGENT-TASK-3: agent_action_task_vote_handler
    agent_vote_handler = extract_proc(AGENT_ACTIONS, "agent_action_task_vote_handler")
    require(
        'publish_task_event(h.event_bus, string(vote.owner_user_id), string(vote.task_id), string(vote.chain_id), "voted")' in agent_vote_handler,
        "agent_action_task_vote_handler must emit publish_task_event for voted",
    )
    require(
        'publish_chain_event(h.event_bus, string(vote.owner_user_id), string(vote.chain_id), "updated")' in agent_vote_handler,
        "agent_action_task_vote_handler must emit publish_chain_event for updated",
    )
    require(
        'updated_task.status == .Completed || updated_task.status == .Validated_Not_Good' in agent_vote_handler,
        "agent_action_task_vote_handler must check for status resolution (.Completed or .Validated_Not_Good)",
    )
    require(
        'publish_task_event(h.event_bus, string(vote.owner_user_id), string(vote.task_id), string(vote.chain_id), "status_changed")' in agent_vote_handler,
        "agent_action_task_vote_handler must emit status_changed when vote resolves quorum",
    )

    # REQ-WS-AGENT-TASK-4: create, update, depend handlers
    create_handler = extract_proc(AGENT_ACTIONS, "agent_action_task_create_handler")
    require(
        'publish_task_event(h.event_bus, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "created")' in create_handler,
        "agent_action_task_create_handler must emit publish_task_event for created",
    )
    require(
        'publish_chain_event(h.event_bus, string(task.owner_user_id), string(task.chain_id), "updated")' in create_handler,
        "agent_action_task_create_handler must emit publish_chain_event for updated",
    )

    update_agent_handler = extract_proc(AGENT_ACTIONS, "agent_action_task_update_handler")
    require(
        'publish_task_event(h.event_bus, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "updated")' in update_agent_handler,
        "agent_action_task_update_handler must emit publish_task_event for updated",
    )
    require(
        'publish_chain_event(h.event_bus, string(task.owner_user_id), string(task.chain_id), "updated")' in update_agent_handler,
        "agent_action_task_update_handler must emit publish_chain_event for updated",
    )

    depend_handler = extract_proc(AGENT_ACTIONS, "agent_action_task_depend_handler")
    require(
        'publish_task_event(h.event_bus, string(inst.owner_user_id), string(dep.task_id), string(inst.chain_id), "updated")' in depend_handler,
        "agent_action_task_depend_handler must emit publish_task_event for updated",
    )
    require(
        'publish_chain_event(h.event_bus, string(inst.owner_user_id), string(inst.chain_id), "updated")' in depend_handler,
        "agent_action_task_depend_handler must emit publish_chain_event for updated",
    )

    # REQ-WS-AGENT-TASK-5: vote_task_handler and update_task_handler in taskchain_handlers.odin
    vote_handler = extract_proc(TASKCHAIN_HANDLERS, "vote_task_handler")
    require(
        'publish_chain_changed(h, string(vote.owner_user_id), string(vote.chain_id), "updated")' in vote_handler,
        "vote_task_handler must emit publish_chain_changed updated",
    )
    require(
        'updated_task.status == .Completed || updated_task.status == .Validated_Not_Good' in vote_handler,
        "vote_task_handler must check for status resolution (.Completed or .Validated_Not_Good)",
    )
    require(
        'publish_task_changed(h, string(vote.owner_user_id), string(vote.task_id), string(vote.chain_id), "status_changed")' in vote_handler,
        "vote_task_handler must emit publish_task_changed status_changed on status resolution",
    )

    update_handler = extract_proc(TASKCHAIN_HANDLERS, "update_task_handler")
    require(
        'publish_chain_changed(h, string(task.owner_user_id), string(task.chain_id), "updated")' in update_handler,
        "update_task_handler must emit publish_chain_changed updated",
    )

    print("ALL WEBSOCKET AGENT ACTION & TASK EVENT STATIC TESTS PASSED")


if __name__ == "__main__":
    main()
