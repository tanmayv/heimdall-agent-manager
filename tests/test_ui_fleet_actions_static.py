#!/usr/bin/env python3
"""
test_ui_fleet_actions_static.py

Static verification test for REQ-FLEET-UI-ACTIONS-1:
- TaskCard.ts action button helpers (isRoleAssignedWithoutLiveInstance, canStartTask, hasLiveNudgeTarget, getUnpauseStatus)
- Re-exports in FleetManagementDrawer.tsx
- TaskChainOverview.tsx action buttons logic:
  1. Start button: Hidden when task assignee ref is declarative agent_id without live bound instance.
  2. Nudge button: Hidden when no target instance exists to receive the IPC wake notification.
  3. Pause & Cancel buttons: Kept accessible for operator control over pending/queued tasks.
  4. Unpause action: Returns status to queued for role-assigned tasks without live instance.
  5. LGTM & NGTM voting buttons: Kept accessible for operator validation in TaskChainOverview and ChainOverviewPanel.
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

def check_file_contains(filepath: Path, needles: list[str]) -> list[str]:
    if not filepath.exists():
        return [f"File {filepath} does not exist"]
    content = filepath.read_text(encoding="utf-8")
    missing = []
    for needle in needles:
        if needle not in content:
            missing.append(f"{filepath.name}: missing '{needle}'")
    return missing

def main() -> int:
    errors = []

    # 1. TaskCard.ts action button helpers
    task_card_file = REPO_ROOT / "src/ui/components/tasks/TaskCard.ts"
    errors.extend(check_file_contains(task_card_file, [
        "export function isRoleAssignedWithoutLiveInstance",
        "export function canStartTask",
        "export function hasLiveNudgeTarget",
        "export function getUnpauseStatus",
    ]))

    # 2. FleetManagementDrawer.tsx re-exports
    drawer_file = REPO_ROOT / "src/ui/components/tasks/FleetManagementDrawer.tsx"
    errors.extend(check_file_contains(drawer_file, [
        "isRoleAssignedWithoutLiveInstance",
        "canStartTask",
        "hasLiveNudgeTarget",
        "getUnpauseStatus",
    ]))

    # 3. TaskChainOverview.tsx wiring
    overview_file = REPO_ROOT / "src/ui/components/taskchain/TaskChainOverview.tsx"
    errors.extend(check_file_contains(overview_file, [
        "isRoleAssignedWithoutLiveInstance",
        "canStartTask",
        "hasLiveNudgeTarget",
        # Start button gated
        "{canStartTask(task, allInstances) && (",
        'data-debug-id={`taskchain-task-start-btn-${taskId}`}',
        # Nudge button gated
        "{hasLiveNudgeTarget(task, allInstances) && (",
        'data-debug-id={`taskchain-task-nudge-btn-${taskId}`}',
        # Unpause logic for role-assigned tasks
        "isRoleAssignedWithoutLiveInstance(task, allInstances)",
        "handleStatusChange(taskId, 'queued')",
        "handleStatusChange(taskId, 'in_progress')",
        'data-debug-id={`taskchain-task-unpause-btn-${taskId}`}',
        # Pause and Cancel accessible on pending tasks
        'data-debug-id={`taskchain-task-pause-btn-${taskId}`}',
        'data-debug-id={`taskchain-task-cancel-btn-${taskId}`}',
        # LGTM and NGTM voting accessible
        'data-debug-id={`taskchain-task-lgtm-btn-${taskId}`}',
        'data-debug-id={`taskchain-task-ngtm-btn-${taskId}`}',
    ]))

    # 4. ChainOverviewPanel.tsx voting buttons preserved
    panel_file = REPO_ROOT / "src/ui/components/chat/ChainOverviewPanel.tsx"
    errors.extend(check_file_contains(panel_file, [
        'data-debug-id={`chain-overview-vote-lgtm-${taskId}`}',
        'data-debug-id={`chain-overview-vote-ngtm-${taskId}`}',
    ]))

    if errors:
        print("FAIL: test_ui_fleet_actions_static failed with errors:")
        for err in errors:
            print(f"  - {err}")
        return 1

    print("PASS: test_ui_fleet_actions_static passed with all assertions satisfied.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
