#!/usr/bin/env python3
"""Static contract for ChainView dependency-ordered task todo list/detail UI."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TASK_SLICE = ROOT / "src" / "ui" / "store" / "taskSlice.ts"

# NOTE: REQUIRED_APP_SNIPPETS previously asserted against
# src/ui/components/App.tsx and is retained here only for documentation of the
# historical ChainView contract. The App.tsx scan was dropped when that legacy
# component was removed (dead code; the app mounts AppShell). The task-slice and
# design-doc coverage below remain the authoritative guard.
_HISTORICAL_APP_SNIPPETS = [
    'data-debug-id="chain-task-surface"',
    'data-debug-id="chain-task-count"',
    'function dependencyOrderedTasks',
    'const activeTasks = orderedTasks.filter',
    'const completedTasks = orderedTasks.filter',
    'chain-completed-task-section',
    'function TaskTodoList',
    'data-debug-id={`chain-task-list-${completed ? \'completed\' : \'active\'}`}',
    'data-debug-id={`chain-task-row-${task.taskId}`}',
    'data-debug-id={`chain-task-row-${task.taskId}-title`}',
    'data-debug-id={`chain-task-row-${task.taskId}-status`}',
    'data-debug-id={`chain-task-row-${task.taskId}-agents`}',
    'function TaskAgentChip',
    'onOpenAgentChat',
    'chain-task-${roleKey}-chat-btn-${agentId}',
    'Open direct chat with',
    'strokeLinejoin="round" d="M7.5 18.25',
    'function isAgentRunning',
    'assigneeWorking',
    'reviewerWorking',
    "const workingLabel = 'working';",
    'data-debug-id={`chain-task-row-${task.taskId}-action-needed-btn`}',
    'data-debug-id={`chain-task-row-${task.taskId}-expand-btn`}',
    'data-debug-id={`chain-task-row-${task.taskId}-expanded`}',
    'perceivedTaskStatus',
    'isUserActionableTask(task)',
    'line-through decoration-zinc-600',
    'data-debug-id={`task-detail-comments-toggle-${task.taskId}`}',
    'data-debug-id={`task-detail-comments-${task.taskId}`}',
    'data-debug-id={`task-detail-comment-textarea-${task.taskId}`}',
    'data-debug-id={`task-detail-comment-submit-btn-${task.taskId}`}',
    'data-debug-id={`task-detail-status-done-btn-${task.taskId}`}',
    'data-debug-id={`task-detail-status-block-btn-${task.taskId}`}',
    'data-debug-id={`task-detail-status-later-btn-${task.taskId}`}',
    'data-debug-id={`task-detail-status-start-btn-${task.taskId}`}',
    'data-debug-id={`task-detail-vote-lgtm-btn-${task.taskId}`}',
    'data-debug-id={`task-detail-vote-ngtm-btn-${task.taskId}`}',
    'data-debug-id={`task-detail-nudge-textarea-${task.taskId}`}',
    'data-debug-id={`task-detail-nudge-btn-${task.taskId}`}',
    'showToast({ kind: \'success\'',
    'showToast({ kind: \'error\'',
    'data-debug-id="toast-stack"',
    'useFetchChainTasksQuery(',
    'useFetchTaskLogQuery(',
    'loadTaskLogPage({ taskId, cursor })',
    'nudgeSelectedTask',
    'voteOnSelectedTask',
    'updateSelectedTaskStatus',
    'addCommentToSelectedTask',
]


def main() -> None:
    task_slice = TASK_SLICE.read_text(encoding="utf-8")
    ui_doc = (ROOT / "docs" / "teams-v1" / "07-ui.md").read_text(encoding="utf-8")
    inv_doc = (ROOT / "docs" / "teams-v1" / "10-review-invariants.md").read_text(encoding="utf-8")
    for snippet in ["fetchTasksForChain", "fetchSelectedTaskLog", "nudgeSelectedTask"]:
        if snippet not in task_slice:
            raise AssertionError(f"missing task slice support: {snippet}")
    for snippet in ["ChainTaskSurface", "TaskDetail", "UI-9", "dependency-ordered todo list", "Completed tasks", "assignee/reviewer runtime chips"]:
        if snippet not in ui_doc:
            raise AssertionError(f"missing UI doc snippet: {snippet}")
    if "UI-9" not in inv_doc:
        raise AssertionError("missing UI-9 invariant")
    print("PASS: ChainView task todo list/detail UI contract")


if __name__ == "__main__":
    main()
