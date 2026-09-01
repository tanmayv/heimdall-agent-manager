#!/usr/bin/env python3
"""Static guard for H12: collapsed descriptions + compact task rows with a
quick-actions menu in the task chain view.

- Chain description collapsed by default (descExpanded=false).
- Task description rendered ONLY inside the expanded (isExpanded) block.
- Compact collapsed header = chevron + title + status badge + assignee.
- A single quick-actions MENU button (taskchain-task-actions-menu-btn-<id>)
  exposing Nudge/LGTM/NGTM/Status/Cancel, actionable without expanding, one open
  at a time with outside-click close.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OVERVIEW = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskChainOverview.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    src = OVERVIEW.read_text(encoding="utf-8")

    # --- D1: chain description collapsed by default ---
    require("useState(false)" in src and "const [descExpanded, setDescExpanded] = useState(false)" in src,
            "chain description must default to COLLAPSED (descExpanded=false)")
    require("{descExpanded && (" in src,
            "chain description body must be gated behind descExpanded")

    # --- D2: task description ONLY in the expanded block ---
    # The description paragraph must appear AFTER the isExpanded guard, not in the
    # always-visible header.
    desc_idx = src.index("taskchain-task-description-")
    expand_guard_idx = src.index("{isExpanded && (")
    require(desc_idx > expand_guard_idx,
            "task description must render inside the isExpanded block (D2), not the header")

    # --- D3: compact header keeps title, status, assignee (+ InstanceIdLink) ---
    require("taskchain-task-title-" in src, "compact header must keep the task title")
    require("taskchain-task-status-${taskId}" in src, "compact header must keep the status badge")
    require("taskchain-task-assignee-" in src and "InstanceIdLink" in src,
            "compact header must keep the assignee with InstanceIdLink (D3/H10)")

    # --- D4: single quick-actions MENU button (not the always-open strip) ---
    require("taskchain-task-actions-menu-btn-" in src,
            "must render a single quick-actions menu button (D4)")
    require("actionsMenuOpenTaskId" in src,
            "must track a single open actions menu (one-open-at-a-time, D4)")
    # All five actions are reachable from the menu, reusing existing handlers/ids.
    for did, handler in [
        ("taskchain-task-nudge-btn-", "handleNudge"),
        ("taskchain-task-lgtm-btn-", "handleVote(taskId, 'lgtm')"),
        ("taskchain-task-ngtm-btn-", "handleVote(taskId, 'ngtm')"),
        ("taskchain-task-status-menu-btn-", "handleStatusChange"),
        ("taskchain-task-cancel-btn-", "handleCancelTask"),
    ]:
        require(did in src, f"menu must expose action {did} (D4)")
        require(handler in src, f"menu action must reuse existing handler {handler} (D4)")
    # Status sub-options preserved (rendered via a ${st} template over the list).
    require("taskchain-task-status-${st}-btn-" in src,
            "status options must be rendered with the ${st}-btn template")
    for st in ["in_progress", "in_validation", "paused", "completed"]:
        require(f"'{st}'" in src, f"status option {st} must remain in the list")

    # --- D4: outside-click closes the menu; one open at a time ---
    require("addEventListener('mousedown'" in src and "setActionsMenuOpenTaskId(null)" in src,
            "actions menu must close on outside-click (D4)")

    # --- D6: no dead InstanceIdLink / preserved ids ---
    require("taskchain-task-row-" in src, "task row data-debug-id must be preserved")

    print("PASS: H12 taskchain compact rows + actions menu static guard")


if __name__ == "__main__":
    main()
