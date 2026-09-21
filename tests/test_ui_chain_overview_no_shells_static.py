#!/usr/bin/env python3
"""Static regression test suite for UI shell panel removal from chain overview,
removal of Background jobs sidebar tab, and preview max width expansion.

Requirements:
- REQ-UI-REMOVE-SHELLS-FROM-CHAIN-VIEW:
  - TaskChainOverview.tsx does NOT import ShellsPanel or render <ShellsPanel
- REQ-UI-REMOVE-BACKGROUND-JOBS-TAB:
  - ConversationThreadPage.tsx does NOT render conversation-right-panel-tab-jobs
  - clientPersistence.ts RIGHT_SIDEBAR_TABS does NOT include 'jobs'
- REQ-UI-EXPAND-PREVIEW-MAX-WIDTH:
  - PreviewSidebar.tsx MAX_WIDTH is 1800 and clamps properly with maxAllowed
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
TASK_CHAIN_OVERVIEW = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskChainOverview.tsx"
CONVERSATION_THREAD_PAGE = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
CLIENT_PERSISTENCE = ROOT / "src" / "ui" / "utils" / "clientPersistence.ts"
PREVIEW_SIDEBAR = ROOT / "src" / "ui" / "components" / "shells" / "PreviewSidebar.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_task_chain_overview_no_shells() -> None:
    require(TASK_CHAIN_OVERVIEW.is_file(), f"TaskChainOverview.tsx must exist at {TASK_CHAIN_OVERVIEW}")
    src = TASK_CHAIN_OVERVIEW.read_text(encoding="utf-8")

    # 1. Must not import ShellsPanel
    require("ShellsPanel" not in src,
            "TaskChainOverview.tsx must not contain any reference to ShellsPanel")
    require(not re.search(r"import\s+.*ShellsPanel", src),
            "TaskChainOverview.tsx must not import ShellsPanel")

    # 2. Must not render <ShellsPanel
    require("<ShellsPanel" not in src,
            "TaskChainOverview.tsx must not render <ShellsPanel")


def test_conversation_thread_page_no_jobs_tab() -> None:
    require(CONVERSATION_THREAD_PAGE.is_file(), f"ConversationThreadPage.tsx must exist at {CONVERSATION_THREAD_PAGE}")
    src = CONVERSATION_THREAD_PAGE.read_text(encoding="utf-8")

    # 1. Must not render conversation-right-panel-tab-jobs
    require("conversation-right-panel-tab-jobs" not in src,
            "ConversationThreadPage.tsx must not render conversation-right-panel-tab-jobs")

    # 2. Must not render ShellJobsPanel
    require("<ShellJobsPanel" not in src,
            "ConversationThreadPage.tsx must not render <ShellJobsPanel")
    require("import ShellJobsPanel" not in src,
            "ConversationThreadPage.tsx must not import ShellJobsPanel")


def test_client_persistence_no_jobs_tab() -> None:
    require(CLIENT_PERSISTENCE.is_file(), f"clientPersistence.ts must exist at {CLIENT_PERSISTENCE}")
    src = CLIENT_PERSISTENCE.read_text(encoding="utf-8")

    # Find definition of RIGHT_SIDEBAR_TABS
    match = re.search(r"export\s+const\s+RIGHT_SIDEBAR_TABS\s*=\s*\[(.*?)\]\s*as\s*const", src, re.DOTALL)
    require(match is not None, "clientPersistence.ts must define RIGHT_SIDEBAR_TABS array")
    tabs_content = match.group(1)

    # Must NOT include 'jobs'
    require("'jobs'" not in tabs_content and '"jobs"' not in tabs_content,
            "clientPersistence.ts RIGHT_SIDEBAR_TABS must not include 'jobs'")

    # Must still contain standard expected tabs
    for expected_tab in ["tasks", "files", "rundir", "shells", "chain", "vcs"]:
        require(f"'{expected_tab}'" in tabs_content or f'"{expected_tab}"' in tabs_content,
                f"clientPersistence.ts RIGHT_SIDEBAR_TABS must include '{expected_tab}'")


def test_preview_sidebar_max_width_and_clamping() -> None:
    require(PREVIEW_SIDEBAR.is_file(), f"PreviewSidebar.tsx must exist at {PREVIEW_SIDEBAR}")
    src = PREVIEW_SIDEBAR.read_text(encoding="utf-8")

    # 1. MAX_WIDTH must be 1800
    require("const MAX_WIDTH = 1800;" in src,
            "PreviewSidebar.tsx must define 'const MAX_WIDTH = 1800;'")
    require("const MAX_WIDTH = 900;" not in src,
            "PreviewSidebar.tsx must not use old MAX_WIDTH = 900")

    # 2. Clamps properly using maxAllowed with MAX_WIDTH and window.innerWidth - 320
    require("const maxAllowed = Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, window.innerWidth - 320));" in src,
            "PreviewSidebar.tsx onMove must calculate maxAllowed clamped to MAX_WIDTH and window.innerWidth - 320")
    require("const next = Math.min(maxAllowed, Math.max(MIN_WIDTH, window.innerWidth - event.clientX));" in src,
            "PreviewSidebar.tsx onMove must clamp next width to maxAllowed")


def main() -> None:
    test_task_chain_overview_no_shells()
    test_conversation_thread_page_no_jobs_tab()
    test_client_persistence_no_jobs_tab()
    test_preview_sidebar_max_width_and_clamping()
    print("PASS: test_ui_chain_overview_no_shells_static")


if __name__ == "__main__":
    main()
