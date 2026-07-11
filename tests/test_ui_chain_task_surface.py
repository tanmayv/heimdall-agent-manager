#!/usr/bin/env python3
"""Static contract for ChainView task list/detail UI (UI-8/UI-9)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src" / "ui" / "components" / "App.tsx"
TASK_SLICE = ROOT / "src" / "ui" / "store" / "taskSlice.ts"

REQUIRED_APP_SNIPPETS = [
    'data-debug-id="chain-task-surface"',
    'data-debug-id="chain-task-count"',
    'data-debug-id={`chain-task-column-${group.key}`}',
    'data-debug-id={`chain-task-card-${task.taskId}`}',
    'data-debug-id="task-detail-drawer"',
    'data-debug-id="task-detail-title"',
    'data-debug-id="task-detail-status"',
    'data-debug-id="task-detail-description"',
    'data-debug-id="task-detail-votes"',
    'data-debug-id={`task-detail-vote-${index}`}',
    'data-debug-id={`task-detail-review-event-${index}`}',
    'selectedTask?.votes',
    'reviewEvents',
    'data-debug-id="task-detail-comments"',
    'data-debug-id="task-detail-comment-textarea"',
    'data-debug-id="task-detail-comment-submit-btn"',
    'data-debug-id="task-detail-status-done-btn"',
    'data-debug-id="task-detail-status-block-btn"',
    'data-debug-id="task-detail-status-later-btn"',
    'data-debug-id="task-detail-status-start-btn"',
    'data-debug-id="task-detail-vote-lgtm-btn"',
    'data-debug-id="task-detail-vote-ngtm-btn"',
    'data-debug-id="task-detail-nudge-textarea"',
    'data-debug-id="task-detail-nudge-btn"',
    'fetchTasksForChain(task.chainId)',
    'fetchSelectedTaskLog(task.taskId)',
    'nudgeSelectedTask',
    'voteOnSelectedTask',
    'updateSelectedTaskStatus',
    'addCommentToSelectedTask',
]


def main() -> None:
    app = APP.read_text(encoding="utf-8")
    task_slice = TASK_SLICE.read_text(encoding="utf-8")
    ui_doc = (ROOT / "docs" / "teams-v1" / "07-ui.md").read_text(encoding="utf-8")
    inv_doc = (ROOT / "docs" / "teams-v1" / "10-review-invariants.md").read_text(encoding="utf-8")
    for snippet in REQUIRED_APP_SNIPPETS:
        if snippet not in app:
            raise AssertionError(f"missing App.tsx snippet: {snippet}")
    for snippet in ["fetchTasksForChain", "fetchSelectedTaskLog", "nudgeSelectedTask"]:
        if snippet not in task_slice:
            raise AssertionError(f"missing task slice support: {snippet}")
    for snippet in ["ChainTaskSurface", "TaskDetail", "UI-9", "votes/review history"]:
        if snippet not in ui_doc:
            raise AssertionError(f"missing UI doc snippet: {snippet}")
    if "UI-9" not in inv_doc:
        raise AssertionError("missing UI-9 invariant")
    if "direct-agent" in app.lower() and "debug" not in app.lower():
        raise AssertionError("Chain task UI must not add main-path direct-agent chat")
    print("PASS: ChainView task surface/detail UI contract")


if __name__ == "__main__":
    main()
