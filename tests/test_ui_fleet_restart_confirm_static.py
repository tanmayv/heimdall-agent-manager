#!/usr/bin/env python3
"""
test_ui_fleet_restart_confirm_static.py

Static verification test for REQ-RS-3 / REQ-RS-4 (confirm-before-restart):

- src/ui/components/tasks/FleetManagementDrawer.tsx: the restart confirmation modal
  (data-debug-ids, three actions, per-role live/active counts + provider/tier delta),
  the decision path that opens it BEFORE any PUT, cancel performing zero mutations,
  and the post-apply restart summary.
- src/ui/api/endpoints/taskChains.ts: the restartLiveInstances request flag (added to
  the body only when true) and the two additive PUT response fields.

The behavioral decisions behind this wiring are covered executably by
`node --test tests/ui_fleet_actions_test.ts`; this file pins the JSX/wiring that a
DOM-free node harness cannot reach.
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


def check_slice_not_contains(filepath: Path, start: str, end: str, needles: list[str]) -> list[str]:
    """Assert none of `needles` appear in the [start, end) slice of the file."""
    if not filepath.exists():
        return [f"File {filepath} does not exist"]
    content = filepath.read_text(encoding="utf-8")
    if start not in content:
        return [f"{filepath.name}: missing slice start '{start}'"]
    if end not in content:
        return [f"{filepath.name}: missing slice end '{end}'"]
    block = content.split(start, 1)[1].split(end, 1)[0]
    present = [n for n in needles if n in block]
    return [f"{filepath.name}: slice after '{start}' unexpectedly contains '{n}'" for n in present]


def main() -> int:
    errors = []

    drawer_file = REPO_ROOT / "src/ui/components/tasks/FleetManagementDrawer.tsx"
    errors.extend(check_file_contains(drawer_file, [
        # Modal + actions with their debug ids (fleet-restart-* naming).
        'data-debug-id="fleet-restart-confirm-modal"',
        'data-debug-id={`fleet-restart-role-${role.agentId}`}',
        'data-debug-id="fleet-restart-now-btn"',
        'data-debug-id="fleet-restart-new-only-btn"',
        'data-debug-id="fleet-restart-cancel-btn"',
        'data-debug-id="fleet-restart-summary"',
        'Apply &amp; Restart Now',
        'Apply to New Instances Only',
        # Modal built on the shared composite (Esc / backdrop / focus return).
        'title="Restart live instances?"',
        'onOpenChange={(next) => {',
        '{pendingRestart && (',
        # Per-role warning content: counts + provider/tier delta.
        'live {role.liveCount === 1',
        'role.activeTaskCount',
        'provider {role.originalProvider',
        # Decision + request/summary helpers from the dependency-free leaf module.
        'restartAffectedEntries(',
        'fleetApplyRequests(',
        'summarizeFleetRestartResults(',
        'restartLiveInstances: cf.restartLiveInstances',
        # Refetch after a flagged apply.
        'await refetch();',
        'chainDetailQuery.refetch()',
    ]))

    # The modal opens (state set) WITHOUT any PUT: the PUT call lives only inside
    # applyFleetChanges, and handleApply branches on the affected-role decision.
    errors.extend(check_slice_not_contains(
        drawer_file,
        "const handleApply = useCallback(() => {",
        "const handleConfirmRestartNow = useCallback(() => {",
        ["updateFleet({"],
    ))
    errors.extend(check_file_contains(drawer_file, [
        # Zero-affected branches straight into the flag-less apply and returns;
        # only the affected path reaches setPendingRestart (the modal).
        "if (affected.length === 0) {",
        "void applyFleetChanges([]);",
        "return;",
        "setPendingRestart(",
    ]))

    # Cancel: closes the modal and performs zero mutations.
    errors.extend(check_slice_not_contains(
        drawer_file,
        "const handleCancelRestart = useCallback(() => {",
        "}, []);",
        ["updateFleet", "applyFleetChanges"],
    ))

    # applyFleetChanges is the single PUT site, and it applies all roles in parallel.
    errors.extend(check_file_contains(drawer_file, [
        "Promise.all(",
        "const applyFleetChanges = useCallback(",
    ]))
    content = drawer_file.read_text(encoding="utf-8")
    if content.count("updateFleet({") != 1:
        errors.append(
            "FleetManagementDrawer.tsx: expected exactly 1 updateFleet({ call site "
            f"(inside applyFleetChanges), found {content.count('updateFleet({')}"
        )

    # Endpoint: request flag + additive response fields.
    endpoints_file = REPO_ROOT / "src/ui/api/endpoints/taskChains.ts"
    errors.extend(check_file_contains(endpoints_file, [
        "restartLiveInstances?: boolean;",
        "if (restartLiveInstances === true) body.restart_live_instances = true;",
        "export interface FleetRestartFailure",
        "restarted_instance_ids?: string[];",
        "restart_failures?: FleetRestartFailure[];",
        "restarted_instance_ids: Array.isArray(f.restarted_instance_ids)",
        "restart_failures: Array.isArray(f.restart_failures)",
    ]))

    if errors:
        print("FAIL: test_ui_fleet_restart_confirm_static failed with errors:")
        for err in errors:
            print(f"  - {err}")
        return 1

    print("PASS: test_ui_fleet_restart_confirm_static passed with all assertions satisfied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
