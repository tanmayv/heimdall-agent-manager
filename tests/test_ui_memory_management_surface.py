#!/usr/bin/env python3
"""Static regression checks for the first-class Memory Management UI surface."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src" / "ui" / "components" / "App.tsx"
MEMORY_PAGE = ROOT / "src" / "ui" / "components" / "MemoryManagementPage.tsx"
HOME_SLICE = ROOT / "src" / "ui" / "store" / "homeSlice.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    app = APP.read_text(encoding="utf-8")
    memory_page = MEMORY_PAGE.read_text(encoding="utf-8")
    home_slice = HOME_SLICE.read_text(encoding="utf-8")

    require("import MemoryManagementPage from './MemoryManagementPage';" in app, "App should import MemoryManagementPage")
    require("{ key: 'memory', label: 'Memory', icon: '◫' }" in app, "Surface rail should expose a primary Memory nav item with a monochrome icon")
    require('data-debug-id="home-open-memory-btn"' in app, "Home should expose a direct memory entry button")
    require('data-debug-id="home-memory-total"' in app and 'data-debug-id="home-memory-pending"' in app, "Home should summarize memory counts")
    require("home.surface === 'memory' ? (" in app, "App should route a dedicated memory surface")
    require("selectedMemoryId={urlParams.memoryId}" in app, "Memory surface should preserve memory selection via URL")
    require("if (urlParams.view === 'memory' && home.surface !== 'memory')" in app, "App should respond to memory URL navigation")
    require("if (payload?.type === 'memory_event')" in app, "App should refresh memory from websocket memory events")
    require("if (payload?.type === 'audit_start')" in app and "if (payload?.type === 'audit_end')" in app, "App should refresh audit lifecycle events for memory workflows")

    require("if (view === 'memory') return { surface: 'memory', chainId };" in home_slice, "homeSlice should support initial memory deep links")

    for marker, message in [
        ('data-debug-id="memory-management-surface"', 'memory surface root debug id missing'),
        ('data-debug-id="memory-refresh-btn"', 'memory refresh button debug id missing'),
        ('data-debug-id="memory-filters"', 'memory filters debug id missing'),
        ('debugId="memory-filter-subject-input"', 'memory subject filter missing'),
        ('debugId="memory-filter-project-input"', 'memory project filter missing'),
        ('debugId="memory-filter-role-input"', 'memory role filter missing'),
        ('debugId="memory-filter-task-chain-type-input"', 'memory task-chain-type filter missing'),
        ('debugId="memory-filter-search-input"', 'memory free-text filter missing'),
        ('debugId="memory-filter-scope-select"', 'memory scope filter missing'),
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
        ('debugId="memory-form-subject-agent-input"', 'memory form subject-agent input missing'),
        ('debugId="memory-form-subject-key-input"', 'memory form subject-key input missing'),
        ('debugId="memory-form-project-ids-input"', 'memory form project_ids input missing'),
        ('debugId="memory-form-role-keys-input"', 'memory form role_keys input missing'),
        ('debugId="memory-form-task-chain-types-input"', 'memory form task_chain_types input missing'),
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
    require("subject_key" in memory_page and "project_ids" in memory_page and "role_keys" in memory_page and "task_chain_types" in memory_page, "Memory page should display targeting fields")
    require("metadata_json" in memory_page and "Evidence" in memory_page and "Reason" in memory_page and "Version" in memory_page, "Memory page should display metadata/evidence/reason/version details")

    print("UI MEMORY MANAGEMENT SURFACE TEST PASSED")


if __name__ == "__main__":
    main()
