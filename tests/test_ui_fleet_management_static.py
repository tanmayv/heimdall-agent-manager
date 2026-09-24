#!/usr/bin/env python3
"""
test_ui_fleet_management_static.py

Static verification test for REQ-FLEET-UI-1:
- RTK Query endpoints for task chain fleets in taskChains.ts and heimdallApi.ts
- FleetSlotChips and FleetManagementDrawer components
- ChainHeader and ChainOverviewPanel integrations
- TaskChainOverview fleet slots and queue badges
- CreateTaskModal role selector and elimination of instance ID assignment
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

def check_file_not_contains(filepath: Path, needles: list[str]) -> list[str]:
    if not filepath.exists():
        return [f"File {filepath} does not exist"]
    content = filepath.read_text(encoding="utf-8")
    present = []
    for needle in needles:
        if needle in content:
            present.append(f"{filepath.name}: unexpectedly contains '{needle}'")
    return present

def main() -> int:
    errors = []

    # 1. RTK Query endpoints
    endpoints_file = REPO_ROOT / "src/ui/api/endpoints/taskChains.ts"
    errors.extend(check_file_contains(endpoints_file, [
        "getTaskChainFleets:",
        "/task-chains/${encodeURIComponent(chainId)}/fleets",
        "updateTaskChainFleet:",
        "/task-chains/${encodeURIComponent(chainId)}/fleets/${encodeURIComponent(agentId)}",
        "'PUT'",
        "export interface TaskChainFleet",
        "providesTags: (_result, _error, { chainId }) => [{ type: 'TaskChainFleets' as const, id: chainId }]",
        "invalidatesTags: (_result, _error, { chainId }) => [",
        "useGetTaskChainFleetsQuery",
        "useUpdateTaskChainFleetMutation",
    ]))

    heimdall_api_file = REPO_ROOT / "src/ui/api/heimdallApi.ts"
    errors.extend(check_file_contains(heimdall_api_file, [
        "'TaskChainFleets'",
    ]))

    tasks_api_file = REPO_ROOT / "src/ui/api/endpoints/tasks.ts"
    errors.extend(check_file_contains(tasks_api_file, [
        "useGetTaskChainFleetsQuery",
        "useUpdateTaskChainFleetMutation",
        "export type { TaskChainFleet }",
    ]))

    # 2. FleetManagementDrawer component
    drawer_file = REPO_ROOT / "src/ui/components/tasks/FleetManagementDrawer.tsx"
    errors.extend(check_file_contains(drawer_file, [
        "export const FleetSlotChips",
        "export const FleetManagementDrawer",
        "export function formatFleetRoleName",
        "export function renderSlotDots",
        "export function getQueuedWaitingSlotName",
        'data-debug-id={`fleet-slot-chip-${fleet.agent_id}`}',
        'data-debug-id="fleet-slot-chips-manage-btn"',
        'data-debug-id={`fleet-capacity-slider-${agentId}`}',
        'data-debug-id={`fleet-capacity-dec-${agentId}`}',
        'data-debug-id={`fleet-capacity-inc-${agentId}`}',
        'data-debug-id="fleet-drawer-apply-btn"',
        'data-debug-id="fleet-drawer-reset-btn"',
        'data-debug-id="fleet-drawer-pending-count"',
        'data-debug-id={`fleet-staged-indicator-${agentId}`}',
        'draftCapacities',
        'handleApply',
        'handleReset',
    ]))

    # 3. ChainHeader component
    header_file = REPO_ROOT / "src/ui/components/chat/ChainHeader.tsx"
    errors.extend(check_file_contains(header_file, [
        "data-debug-id=\"chain-header\"",
        "<FleetSlotChips",
        "<FleetManagementDrawer",
    ]))

    # 4. CreateTaskModal component
    create_modal_file = REPO_ROOT / "src/ui/components/tasks/CreateTaskModal.tsx"
    errors.extend(check_file_contains(create_modal_file, [
        "data-debug-id=\"create-task-modal\"",
        "data-debug-id=\"create-task-assignee-agentid-select\"",
        "data-debug-id=\"create-task-reviewer-agentid-select\"",
        "data-debug-id=\"create-task-submit-btn\"",
    ]))
    # Ensure instance ID inputs / launch options are NOT present
    errors.extend(check_file_not_contains(create_modal_file, [
        "create-task-assignee-instance-select",
        "create-task-launch-tier",
        "create-task-launch-provider",
        "launch_tier",
    ]))

    # 5. ChainOverviewPanel component
    panel_file = REPO_ROOT / "src/ui/components/chat/ChainOverviewPanel.tsx"
    errors.extend(check_file_contains(panel_file, [
        "<FleetSlotChips",
        "<FleetManagementDrawer",
        "Queued (Waiting for",
        "formatFleetRoleName",
    ]))

    # 6. TaskChainOverview component
    overview_file = REPO_ROOT / "src/ui/components/taskchain/TaskChainOverview.tsx"
    errors.extend(check_file_contains(overview_file, [
        "<FleetSlotChips",
        "<FleetManagementDrawer",
        "Queued (Waiting for",
        "formatFleetRoleName",
    ]))

    if errors:
        print("FAIL: test_ui_fleet_management_static failed with errors:")
        for err in errors:
            print(f"  - {err}")
        return 1

    print("PASS: test_ui_fleet_management_static passed with all assertions satisfied.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
