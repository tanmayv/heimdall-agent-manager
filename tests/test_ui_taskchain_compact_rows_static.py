#!/usr/bin/env python3
"""Static guard for task card layout overhaul: 2-row header, sticky accordion,
action matrix, and removed pill counters (REQ-UI-LAYOUT-1, REQ-UI-STICKY-1,
REQ-UI-ACTIONS-1, REQ-UI-PILLS-1).

- REQ-UI-PILLS-1: Pill counters (todo, doing, review, done, blocked) removed.
- REQ-UI-LAYOUT-1: Two-row task card layout (Row 1 title + chevron, Row 2 chips + contextual actions).
  Clicking Row 1 toggles expanded/collapsed state.
- REQ-UI-STICKY-1: Sticky accordion header when isExpanded (sticky top-0 z-10 bg-[#111111] border-b border-white/5).
- REQ-UI-ACTIONS-1: Contextual action buttons strictly implementing validated Action Matrix:
  * cancelled: Uncancel
  * paused: Unpause
  * completed: Not Complete, Re-validate
  * in_progress: Validate, Pause, Cancel, Nudge
  * in_validation: LGTM, NGTM, Pause, Cancel, Nudge
  * assigned/queued: Start, Pause, Cancel, Nudge
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
    desc_idx = src.index("<TaskDescription")
    expand_guard_idx = src.index("{isExpanded && (")
    require(desc_idx > expand_guard_idx,
            "task description must render inside the isExpanded block (D2), not the header")

    # --- REQ-UI-PILLS-1: Pill counters removed ---
    require("taskchain-overview-progress-todo" not in src,
            "progress summary pill counters must be removed from TaskChainOverview (REQ-UI-PILLS-1)")
    require("taskchain-overview-progress-in_progress" not in src,
            "doing counter must be removed from TaskChainOverview (REQ-UI-PILLS-1)")
    require("taskchain-overview-progress-in_validation" not in src,
            "review counter must be removed from TaskChainOverview (REQ-UI-PILLS-1)")
    require("taskchain-overview-progress-validated_good" not in src,
            "done counter must be removed from TaskChainOverview (REQ-UI-PILLS-1)")

    # --- REQ-UI-LAYOUT-1: Two-row header with chevron + title on Row 1, chips on Row 2 ---
    require("taskchain-task-row-" in src, "task row data-debug-id must be preserved")
    require("taskchain-task-expand-btn-" in src, "Row 1 must have expand/collapse chevron")
    require("taskchain-task-title-" in src, "Row 1 must have task title")
    require("toggleTaskExpanded(taskId)" in src, "clicking Row 1 must toggle expand/collapse")

    # Row 2 left metadata chips + edit pencils
    require("taskchain-task-assignee-" in src and "InstanceIdLink" in src,
            "Row 2 must keep assignee with InstanceIdLink")
    require("taskchain-task-edit-assignee-btn-" in src, "Row 2 must keep edit assignee button")
    require("taskchain-task-reviewers-" in src, "Row 2 must keep reviewers chip")
    require("taskchain-task-edit-reviewers-btn-" in src, "Row 2 must keep edit reviewers button")
    require("taskchain-task-depends-on-" in src, "Row 2 must keep depends-on chip")
    require("taskchain-task-edit-dependencies-btn-" in src, "Row 2 must keep edit dependencies button")
    require("taskchain-task-priority-" in src, "Row 2 must keep priority badge")
    require("taskchain-task-status-${taskId}" in src, "Row 2 must keep status badge")
    require("taskchain-task-blocked-" in src, "Row 2 must keep blocked badge")

    # --- REQ-UI-STICKY-1: Sticky accordion behavior when expanded ---
    require(("sticky top-0 z-10 bg-surface border-b border-subtle" in src) or
            ("sticky top-0 z-10 bg-[#111111] border-b border-white/5" in src),
            "header must receive sticky top-0 z-10 bg-surface border-b border-subtle when isExpanded (REQ-UI-STICKY-1)")

    # --- REQ-UI-ACTIONS-1: Contextual action buttons matching Action Matrix ---
    matrix_buttons = [
        ("taskchain-task-uncancel-btn-", "Uncancel"),
        ("taskchain-task-unpause-btn-", "Unpause"),
        ("taskchain-task-not-complete-btn-", "Not Complete"),
        ("taskchain-task-revalidate-btn-", "Re-validate"),
        ("taskchain-task-validate-btn-", "Validate"),
        ("taskchain-task-start-btn-", "Start"),
        ("taskchain-task-pause-btn-", "Pause"),
        ("taskchain-task-cancel-btn-", "Cancel"),
        ("taskchain-task-nudge-btn-", "Nudge"),
        ("taskchain-task-lgtm-btn-", "LGTM"),
        ("taskchain-task-ngtm-btn-", "NGTM"),
    ]
    for did, label in matrix_buttons:
        require(did in src, f"action matrix must render {label} button with debug-id {did} (REQ-UI-ACTIONS-1)")

    # Verify action handlers wired correctly
    require("handleStatusChange(taskId, 'assigned')" in src, "Uncancel and Not Complete must set status to assigned")
    require("handleStatusChange(taskId, 'in_progress')" in src, "Unpause and Start must set status to in_progress")
    require("handleStatusChange(taskId, 'in_validation')" in src, "Validate and Re-validate must set status to in_validation")
    require("handleStatusChange(taskId, 'paused')" in src, "Pause must set status to paused")
    require("handleCancelTask(taskId)" in src, "Cancel must invoke handleCancelTask")
    require("handleNudge(taskId)" in src, "Nudge must invoke handleNudge")
    require("handleVote(taskId, 'lgtm')" in src, "LGTM must cast lgtm vote")
    require("handleVote(taskId, 'ngtm')" in src, "NGTM must cast ngtm vote")

    print("PASS: Task card layout overhaul static guard (REQ-UI-LAYOUT-1, REQ-UI-STICKY-1, REQ-UI-ACTIONS-1, REQ-UI-PILLS-1)")


if __name__ == "__main__":
    main()
