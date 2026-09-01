#!/usr/bin/env python3
"""Static guard for H10: clickable instance-id links in the task chain view.

Every agent instance id shown in TaskChainOverview (members, task assignee, each
reviewer) must be a clickable control that opens that agent's chat, via a reusable
InstanceIdLink that resolves instance_id -> conversation_id and links to
/conversations/<id> with a graceful fallback.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OVERVIEW = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskChainOverview.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    src = OVERVIEW.read_text(encoding="utf-8")

    # --- reusable InstanceIdLink component ---
    require("function InstanceIdLink" in src,
            "TaskChainOverview must define a reusable InstanceIdLink component")
    require("data-debug-id={`taskchain-instance-link-${" in src,
            "InstanceIdLink must carry data-debug-id=taskchain-instance-link-<id>")

    # --- resolves instance_id -> conversation_id via the agents API ---
    require("useFetchAgentInstanceQuery" in src,
            "InstanceIdLink must resolve conversation via useFetchAgentInstanceQuery (GET /agent-instances/{id})")
    require("conversation_id" in src,
            "InstanceIdLink must read conversation_id from the instance payload")
    require("/conversations/${conversationId}" in src,
            "clicking a resolved instance id must open shellHash(/conversations/<conversationId>)")

    # --- graceful fallback: no dead link, no crash ---
    require("shellHash(`/agents`)" in src or "/agents" in src,
            "InstanceIdLink must fall back to a real route when no conversation resolves")

    # --- wired into members, assignee, and EACH reviewer ---
    require("{m.role}: <InstanceIdLink instanceId={m.agentInstanceId || m.agent_instance_id} />" in src,
            "member instance ids must render as InstanceIdLink")
    require("assignee: {task.assigneeRef.agent_instance_id" in src and
            "<InstanceIdLink instanceId={task.assigneeRef.agent_instance_id} />" in src,
            "task assignee instance id must render as InstanceIdLink (user_id stays plain)")
    # Reviewers rendered as individual clickable chips, not a comma-joined string.
    require("task.reviewerRefs.map" in src and
            "<InstanceIdLink instanceId={r.agent_instance_id} />" in src,
            "each reviewer instance id must render as its own InstanceIdLink chip")
    require(".join(', ')" not in src.split("reviewers:")[1].split("</span>")[0]
            if "reviewers:" in src else True,
            "reviewers must NOT be a plain comma-joined string anymore")

    # --- existing member data-debug-ids preserved ---
    require("taskchain-overview-member-${" in src,
            "existing member data-debug-id attributes must be preserved")

    print("PASS: H10 taskchain instance links static guard")


if __name__ == "__main__":
    main()
