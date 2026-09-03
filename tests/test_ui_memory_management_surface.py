#!/usr/bin/env python3
"""Static regression checks for the first-class Memory Management UI surface."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
MEMORY_PAGE = ROOT / "src" / "ui" / "components" / "MemoryManagementPage.tsx"
HOME_SLICE = ROOT / "src" / "ui" / "store" / "homeSlice.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    memory_page = MEMORY_PAGE.read_text(encoding="utf-8")
    home_slice = HOME_SLICE.read_text(encoding="utf-8")

    # NOTE: App.tsx nav/routing assertions (surface rail memory item, home memory
    # entry/counts, memory URL navigation, WS delegation) were dropped when that
    # legacy component was removed (dead code; the app mounts AppShell). The live
    # MemoryManagementPage surface, homeSlice deep-link, and wsInvalidation memory
    # event handling below remain the authoritative coverage.
    ws = (ROOT / "src" / "ui" / "api" / "wsInvalidation.ts").read_text(encoding="utf-8")
    require("case 'memory_event':" in ws and "dispatch(memoryEventReceived(payload));" in ws, "wsInvalidation should handle memory_event")
    require("case 'audit_start':" in ws and "case 'audit_end':" in ws, "wsInvalidation should handle audit lifecycle events for memory workflows")

    require("if (view === 'memory') return { surface: 'memory', chainId };" in home_slice, "homeSlice should support initial memory deep links")

    for marker, message in [
        ('data-debug-id="memory-management-surface"', 'memory surface root debug id missing'),
        ('data-debug-id="memory-stat-strip"', 'memory compact stat strip debug id missing'),
        ('data-debug-id="memory-metric-total"', 'memory loaded metric missing'),
        ('data-debug-id="memory-metric-pending"', 'memory pending metric missing'),
        ('data-debug-id="memory-refresh-btn"', 'memory refresh button debug id missing'),
        ('data-debug-id="memory-filters"', 'memory filters debug id missing'),
        ('debugId="memory-filter-agent-select"', 'memory target_agent_id dropdown missing'),
        ('debugId="memory-filter-project-select"', 'memory target_project_id dropdown missing'),
        ('debugId="memory-filter-template-select"', 'memory target_template_id dropdown missing'),
        ('debugId="memory-filter-bridge-select"', 'memory target_bridge_id dropdown missing'),
        ('debugId="memory-filter-search-input"', 'memory free-text filter missing'),
        ('debugId="memory-filter-type-select"', 'memory type filter missing'),
        ('debugId="memory-filter-status-select"', 'memory status filter missing'),
        ('debugId="memory-filter-targeting-select"', 'memory targeting filter missing'),
        ('data-debug-id="memory-filter-pending-active-checkbox"', 'memory pending-active checkbox missing'),
        ('data-debug-id="memory-browser-count"', 'memory browser count debug id missing'),
        ('data-debug-id="memory-detail-panel"', 'memory detail panel debug id missing'),
        ('data-debug-id="memory-detail-body"', 'memory detail body debug id missing'),
        ('data-debug-id="memory-history-list"', 'memory history list debug id missing'),
        ('data-debug-id="memory-proposal-form"', 'memory proposal form debug id missing'),
        ('data-debug-id="memory-form-expected-version"', 'expected-version helper debug id missing'),
        ('data-debug-id="memory-form-submit-btn"', 'memory proposal submit debug id missing'),
        ('data-debug-id="memory-pending-list"', 'memory pending list debug id missing'),
    ]:
        require(marker in memory_page, message)

    for marker, message in [
        ('debugId="memory-form-title-input"', 'memory form title input missing'),
        ('data-debug-id="memory-form-type-select"', 'memory form type select missing'),
        ('debugId="memory-form-agent-select"', 'memory form target_agent_id dropdown missing'),
        ('debugId="memory-form-project-select"', 'memory form target_project_id dropdown missing'),
        ('debugId="memory-form-template-select"', 'memory form target_template_id dropdown missing'),
        ('debugId="memory-form-bridge-select"', 'memory form target_bridge_id dropdown missing'),
        ('debugId="memory-form-source-task-input"', 'memory form source_task_id input missing'),
        ('debugId="memory-form-body-textarea"', 'memory form body textarea missing'),
        ('debugId="memory-form-metadata-textarea"', 'memory form metadata textarea missing'),
        ('debugId="memory-form-reason-textarea"', 'memory form reason textarea missing'),
        ('debugId="memory-form-evidence-textarea"', 'memory form evidence textarea missing'),
    ]:
        require(marker in memory_page, message)

    require("proposalAction: 'new'" in memory_page, "Memory page should submit new proposals")
    require("proposalAction: 'edit'" in memory_page, "Memory page should submit edit proposals")
    require("proposalAction: 'archive'" in memory_page, "Memory page should submit archive proposals")
    require("proposalAction: 'rollback'" in memory_page, "Memory page should submit rollback proposals")
    require("expectedVersion: selectedRecord.version" in memory_page, "Memory page should submit selected version for edit/archive/rollback")
    require("decideMemoryProposal" in memory_page, "Memory page should use decideMemoryProposal for approve/reject")
    require("target_agent_id" in memory_page and "target_project_id" in memory_page and "source_task_id" in memory_page, "Memory page should display simplified targeting fields")
    for forbidden in [
        'FilterInput debugId="memory-filter-agent-input"',
        'FilterInput debugId="memory-filter-project-input"',
        'FilterInput debugId="memory-filter-template-input"',
        'FilterInput debugId="memory-filter-bridge-input"',
        'FilterInput debugId="memory-form-agent-input"',
        'FilterInput debugId="memory-form-project-input"',
        'FilterInput debugId="memory-form-template-input"',
        'FilterInput debugId="memory-form-bridge-input"',
    ]:
        require(forbidden not in memory_page, f"fixed target should not be free-text input: {forbidden}")
    require("metadata_json" in memory_page and "Evidence" in memory_page and "Reason" in memory_page and "Version" in memory_page, "Memory page should display metadata/evidence/reason/version details")

    print("UI MEMORY MANAGEMENT SURFACE TEST PASSED")


if __name__ == "__main__":
    main()
